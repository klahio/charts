# ai-stack-lite

A Helm chart for a self-hosted AI stack on an on-prem Kubernetes cluster.

| Component | Role | Exposed |
|---|---|---|
| Ollama | LLM inference engine, holds the model weights | cluster-internal |
| Open WebUI | chat frontend | Ingress or HTTPRoute |
| ComfyUI | image generation workflows | port-forward |

Each component is a subchart and can be switched off on its own. A library chart
under `charts/common` holds the template helpers the three share, so naming,
labels, scheduling, persistence and GPU handling follow one set of rules.

## Prerequisites

- Kubernetes 1.24 or newer, and Helm 3.8 or newer
- A default StorageClass, or an explicit `storageClass` per volume
- For GPU inference: a node that advertises `nvidia.com/gpu`

**This chart does not install GPU support.** That is deliberate. A device plugin
or the GPU Operator is node-level infrastructure with a lifecycle of its own, and
bundling it would mean a `helm uninstall` of this stack takes the cluster's GPU
support with it. Instead the chart checks the prerequisites at install time and
fails with instructions.

## Installing

From the published repository:

```bash
helm repo add klahio https://charts.klah.io
helm repo update
helm install ai klahio/ai-stack-lite -n ai-stack --create-namespace
```

From a checkout of this repository, where this chart is the `ai-stack-lite`
directory:

```bash
cd ai-stack-lite
helm dependency build .
helm install ai . -n ai-stack --create-namespace
```

Profiles are included for the two common shapes:

```bash
# one consumer GPU shared by Ollama and ComfyUI
helm install ai . -n ai-stack --create-namespace -f values-single-gpu.yaml

# no GPU at all; Ollama on CPU, ComfyUI left out
helm install ai . -n ai-stack --create-namespace -f values-cpu.yaml
```

## Exposing the frontend

Both exposure methods are off by default, because neither is a safe default.
An Ingress object on a cluster whose only router is a Gateway is accepted by the
API server and then routes nothing, and an HTTPRoute needs the name of a Gateway
the chart cannot guess. Pick the one your cluster serves.

With an ingress controller:

```yaml
open-webui:
  ingress:
    enabled: true
    className: nginx
    host: ai.example.internal
```

With a Gateway and no ingress controller:

```yaml
open-webui:
  route:
    enabled: true
    parentRefs:
      - name: my-gateway
        namespace: gateway
        sectionName: https
    hostnames:
      - ai.example.internal
```

The hostname is not free. An HTTPRoute attaches only where its hostname
intersects the listener's, so a Gateway listening on `*.example.internal` will
silently ignore a route for `ai.local`: the route is created, reports nothing
useful, and the name does not resolve to anything. The install-time checks catch
this and print the listener hostnames the Gateway will actually accept.

The same applies to the listener's `allowedRoutes`. A listener set to `Same`
only accepts routes from the Gateway's own namespace, so a route in your release
namespace has to target a listener that allows `All`.

## GPU setup

Three things have to be in place before a container can see the GPU, and only
the first is usually already done.

1. **The NVIDIA driver on the host.** Check with `nvidia-smi`.
2. **The container toolkit, registered with containerd.** This is what injects
   the driver libraries into a container.
3. **A device plugin**, which advertises `nvidia.com/gpu` so the scheduler can
   allocate it.

For a single GPU node, the light path is three packages rather than the full
GPU Operator:

```bash
sudo apt-get install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=containerd
sudo systemctl restart containerd
```

Restarting containerd restarts the containers on that node, including control
plane static pods on a single-node cluster.

Then create the RuntimeClass and install the device plugin:

```bash
kubectl apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF

kubectl label node <node> nvidia.com/gpu.present=true

helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm install nvdp nvdp/nvidia-device-plugin \
  -n nvidia-device-plugin --create-namespace \
  --set runtimeClassName=nvidia
```

The node label is only needed when Node Feature Discovery is absent. The device
plugin's DaemonSet has a node affinity on one of three GPU labels, and without
NFD none of them exist, so it schedules nowhere and reports no error.

Confirm the result:

```bash
kubectl get node <node> -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
```

### Why `runtimeClassName` matters

The chart sets `runtimeClassName: nvidia` on every GPU pod, from
`global.gpu.runtimeClassName`. Leave it set unless the nvidia runtime is already
containerd's **default** runtime.

This is worth being precise about, because getting it wrong fails quietly. A pod
that requests `nvidia.com/gpu` without the RuntimeClass still passes admission,
still gets scheduled, and still starts. The GPU resource is accounted for and
consumed. But nothing injects the driver libraries, so the process inside the
container finds no GPU and dies with `nvidia-smi: not found`. Nothing in the
events or the pod status points at the cause. If the nvidia runtime *is* your
default, clear the value:

```bash
--set global.gpu.runtimeClassName=""
```

### Sharing one GPU

Ollama and ComfyUI each request one GPU, so the cluster has to advertise at
least two. On a single physical card that means time-slicing in the device
plugin:

```yaml
config:
  map:
    default: |-
      version: v1
      sharing:
        timeSlicing:
          resources:
          - name: nvidia.com/gpu
            replicas: 4
```

Time-slicing divides execution time, not memory. Nothing prevents the two
workloads from together requesting more VRAM than the card has, so the defaults
keep each one willing to release memory when idle:

- `OLLAMA_KEEP_ALIVE` is `5m`, so an idle model is unloaded. Setting it to `-1`
  pins the model in VRAM, which makes the first token faster and makes
  concurrent image generation much more likely to fail.
- ComfyUI runs with `--normalvram`, which unloads models between runs.
  `--highvram` pins them and will starve anything else on the card.

In practice, with one user alternating between chat and image generation, a 16 GB
card handles both. Simultaneous peaks are what break, not coexistence.

### Running without a GPU

```bash
--set global.gpu.enabled=false
```

Ollama falls back to CPU inference. Expect single-digit tokens per second even on
small models. ComfyUI on CPU is slow enough to be useless, which is why
`values-cpu.yaml` leaves it out.

## Testing an install

```bash
helm test ai -n ai-stack --logs
```

The tests check more than HTTP. Each GPU component asserts that a device is
actually visible inside the container, because the failure mode described above
produces a pod that looks healthy. A test that only checked that a port answered
would pass on a broken install.

The tests retry for a bounded period rather than failing on the first attempt,
since `helm test` can start before a Recreate rollout has finished. A test that
races the thing it tests gets ignored, which is worse than not having it.

## Install-time checks

Rather than letting a misconfiguration turn into Pending pods, the chart queries
the cluster during install and fails with a message that says what to do. It
checks that a node advertises `nvidia.com/gpu`, that enough are advertised for
what the components request, that the named RuntimeClass exists, and that a
default StorageClass exists when a volume does not name one.

The checks use Helm's `lookup`, which returns nothing during client-side
rendering. So they run on `helm install` and on `helm install --dry-run=server`,
and are skipped by `helm template`. That keeps template-only CI working without a
cluster, and it means testing the checks themselves requires `--dry-run=server`.

Any check can be waived:

```bash
--set global.preflight.skip=true
```

A check that is wrong should never be the reason an install cannot proceed.

## Storage

Every volume is a separate claim, annotated `helm.sh/resource-policy: keep`, so a
`helm uninstall` leaves the data behind. Re-downloading tens of gigabytes of
model weights is not a cheap mistake to recover from. Reclaim the space by
deleting the claims by hand.

ComfyUI gets four volumes rather than one. Its image builds a virtualenv with
PyTorch inside the run volume, which is both large and the thing to delete when
an install goes wrong. Checkpoints are large and rarely change, outputs grow
without bound, and configuration is small but worth backing up. Separate claims
let each be sized and reset on its own.

A claim cannot be shrunk after it is created. Lowering a `size` value on an
existing release fails the upgrade with a message about `status.capacity`, so
pick sizes with some room or plan to recreate the claim.

Freshly provisioned volumes are owned by root, and `fsGroup` changes only the
group, never the owning uid. ComfyUI's image refuses to start unless it owns its
directories outright, so the chart runs a small init container that fixes the
ownership of each mount root. It changes the roots only, since recursing would
mean walking every model file on every pod start. Turn it off if your
provisioner already hands over volumes with the right owner:

```yaml
comfyui:
  fixVolumeOwnership:
    enabled: false
```

Point any volume at a claim you already have:

```bash
--set ollama.persistence.models.existingClaim=my-model-pvc
```

An `existingClaim` renders no PVC, because the claim is owned elsewhere.

## ComfyUI notes

Two of its settings are worth reading before changing.

**VRAM mode.** `comfyui.vramMode` defaults to `default`, which passes no flag at
all. That is the right choice for a shared card: ComfyUI's dynamic VRAM manager
is on by default and unloads models to system RAM after use. The older
`--normalvram` flag no longer exists, having been removed once its behaviour
became the default, and passing it to a current ComfyUI is a hard startup
failure rather than a warning. Use `comfyui.reserveVram` to leave a couple of
gigabytes free for whatever else shares the card.

**Startup upgrades.** The image installs ComfyUI and its python dependencies
into the run volume on every start. `comfyui.disableUpgrades` must stay `false`
for the first boot, because that run is what builds the environment; setting it
true on an empty volume produces a half-installed ComfyUI that dies on an import
and looks like a broken image. Once the volume is populated, turning it on pins
the version, makes restarts deterministic and removes the need for egress at
startup.

The default image is `mmartial/comfyui-nvidia-docker`, chosen because it is
maintained and built on CUDA 13. Images pinned to CUDA 12.1 carry PyTorch builds
with no kernels for Blackwell cards and fail on recent hardware with "no kernel
image is available for execution on the device". There is no official ComfyUI
image, so substitute your own if you would rather not run a third party's build
with GPU access. That image's entrypoint is a wrapper script rather than ComfyUI
itself, which is why the chart configures it through environment variables; for
an image that takes plain arguments, set `comfyui.command` and `comfyui.args`.

## Image generation from the chat box

Asking for an image in chat needs one setting beyond pointing Open WebUI at
ComfyUI, and without it the failure is silent.

Open WebUI has two routes. The default route gives the model a `generate_image`
tool and waits for the model to call it. That tool is not actually offered to
Ollama models here, so the model replies that it cannot generate images, nothing
reaches ComfyUI, and no log anywhere records a problem. The legacy route sends
the prompt straight to the image backend and does not depend on a tool call.

The chart sets the legacy route as the default for every model:

```yaml
open-webui:
  env:
    DEFAULT_MODEL_PARAMS: '{"function_calling":"legacy"}'
```

That value only seeds the database on a first install. Open WebUI persists its
settings, and an environment variable does not override a row that already
exists, so on an existing release the setting has to be changed in Admin
Settings under Models instead. The same choice is available per chat under
Controls, as Function Calling.

Direct calls to the image API work regardless of this setting, which is why the
installation can look healthy while the chat box does not produce images.

## Models

None are installed by default. Pull one into the running pod:

```bash
kubectl -n ai-stack exec -it statefulset/ai-ollama -- ollama pull llama3.2:3b
```

Or have the chart do it once on install:

```yaml
ollama:
  modelPuller:
    enabled: true
    models:
      - llama3.2:3b
      - qwen2.5-coder:7b
```

That runs as a `post-install` hook, not `post-upgrade`, so a slow link cannot
stall every later upgrade. It pulls through the Ollama API, so it needs no GPU
and makes no second copy of the weights.

## Security notes

Open WebUI is the only component with an Ingress by default. Neither Ollama nor
ComfyUI has any authentication of its own, so exposing either one publishes an
open endpoint. ComfyUI's workflow API can read and write files inside its
container.

Open WebUI's session signing key is generated on first install and read back from
the existing Secret on upgrade, so an upgrade does not log everyone out. Supply
your own instead:

```yaml
open-webui:
  auth:
    existingSecret: my-secret   # must contain a WEBUI_SECRET_KEY key
```

The first account to register becomes the administrator. Register it before
anyone else can reach the host, or set `open-webui.auth.enableSignup=false`
after you have.

Telemetry is off by default, since an on-prem deployment usually means egress is
either absent or audited.

## Values

Settings that apply to the whole stack live under `global`.

| Key | Default | Notes |
|---|---|---|
| `global.gpu.enabled` | `true` | Source of truth for the stack. Open WebUI overrides it to `false`. |
| `global.gpu.count` | `1` | Per component, not in total. |
| `global.gpu.runtimeClassName` | `nvidia` | Clear it if nvidia is your containerd default. |
| `global.preflight.skip` | `false` | Waives the install-time checks. |
| `global.nodeSelector` | `{}` | Pin the stack to GPU nodes once. |
| `global.extraLabels` | `{}` | Added to every object, for label policies. |
| `global.podLabels` | `{}` | Added to every pod. |
| `ollama.enabled` | `true` | |
| `open-webui.enabled` | `true` | |
| `comfyui.enabled` | `true` | |

GPU precedence runs built-in default, then `global.gpu`, then the component's own
`gpu` block, resolved key by key. Ollama and ComfyUI leave their component block
empty so `global.gpu` governs them. Open WebUI sets `gpu.enabled: false`
explicitly, because a GPU given to the frontend is a time-slice taken from a
component that can use one.

Each subchart carries its own `global.gpu` defaults for standalone installation.
Under the umbrella the parent's `global` wins.

Per-component settings are documented in each subchart's `values.yaml`:
[ollama](charts/ollama/values.yaml), [open-webui](charts/open-webui/values.yaml),
[comfyui](charts/comfyui/values.yaml).

## Verified on

The chart was developed and tested against a working install rather than
rendered output alone.

| | |
|---|---|
| Kubernetes | 1.37, single node, containerd 2.2 |
| Helm | 4.3 |
| GPU | one RTX 5070 Ti, 16 GB, driver 595 |
| GPU access | container toolkit 1.20 plus device plugin 0.20, time-sliced to 4 |
| Storage | local-path |

Ollama and ComfyUI ran at the same time, each holding one time-slice of the
single card, with inference reported as fully GPU resident. ComfyUI reported
PyTorch 2.14 on CUDA 13 and recognised the Blackwell device.

## Development

```bash
helm dependency build .
helm lint .
helm template s . | kubectl apply --dry-run=server -f -

# the install-time checks need a cluster
helm install s . --dry-run=server -n ai-stack
```
