# A CPU-only ComfyUI for CI, built the way ComfyUI's own CI installs it: PyTorch
# from the CPU wheel index, so no CUDA in the image and none fetched at start.
# The chart's default image carries CUDA and builds a CUDA virtualenv on first
# boot, which is more disk than a GitHub runner has beside the rest of the
# stack.
#
# This stands in for that image to test the chart's wiring, not the image. It
# reads the same environment the chart sets (LISTEN_ADDRESS, LISTEN_PORT,
# BASE_DIRECTORY, COMFY_CMDLINE_EXTRA) and runs as the same uid, so the flags,
# mounts and ownership the chart produces are what ComfyUI actually starts with.
FROM python:3.12-slim

ARG COMFYUI_VERSION=v0.42.1

ADD https://github.com/Comfy-Org/ComfyUI/archive/refs/tags/${COMFYUI_VERSION}.tar.gz /tmp/comfyui.tar.gz
RUN mkdir /opt/comfyui \
 && tar -xzf /tmp/comfyui.tar.gz -C /opt/comfyui --strip-components=1 \
 && rm /tmp/comfyui.tar.gz \
 && pip install --no-cache-dir torch torchvision --index-url https://download.pytorch.org/whl/cpu \
 && pip install --no-cache-dir -r /opt/comfyui/requirements.txt \
 && chown -R 1024:1024 /opt/comfyui

COPY entrypoint.sh /entrypoint.sh

# podUser in the chart's values. The volumes are handed to this uid by the
# chart's init container, so running as anyone else would hide a broken chown.
USER 1024:1024
ENV HOME=/tmp
WORKDIR /opt/comfyui
EXPOSE 8188
ENTRYPOINT ["/entrypoint.sh"]
