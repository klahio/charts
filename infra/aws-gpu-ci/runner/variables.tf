variable "region" {
  description = "Must match the region the bootstrap role is scoped to."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = <<-EOT
    One NVIDIA GPU is all the single-GPU profile needs. g4dn.xlarge is a 16 GB
    T4 at about $0.53/hour; g6.xlarge is a 24 GB L4 at about $0.80/hour. Must be
    in the bootstrap's allowed_instance_types.
  EOT
  type        = string
  default     = "g4dn.xlarge"
}

variable "ami_ssm_parameter" {
  description = <<-EOT
    Public SSM parameter naming the AMI. The Deep Learning Base OSS Nvidia
    Driver AMI ships the driver, Docker and the NVIDIA container toolkit, which
    is everything k3s needs to find the nvidia runtime on its own.
  EOT
  type        = string
  default     = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-ubuntu-24.04/latest/ami-id"
}

variable "root_volume_gb" {
  description = "The DLAMI, the ComfyUI image and its first-boot virtualenv together need well over 100 GB."
  type        = number
  default     = 150
}

variable "ssh_public_key" {
  description = "Public half of a key the workflow generates for this run and throws away after it."
  type        = string
}

variable "ssh_ingress_cidr" {
  description = "The only address allowed to reach port 22: the runner's own, as a /32."
  type        = string

  validation {
    condition     = can(cidrhost(var.ssh_ingress_cidr, 0)) && endswith(var.ssh_ingress_cidr, "/32")
    error_message = "ssh_ingress_cidr must be a single address in /32 form, not a range."
  }
}

variable "max_lifetime_minutes" {
  description = <<-EOT
    The instance shuts itself down this long after boot, and shutdown means
    terminate. This is the backstop for a cancelled job or a runner that died
    before terraform destroy: the most a lost instance can cost is this many
    minutes.
  EOT
  type        = number
  default     = 120
}

variable "k3s_version" {
  description = "k3s release installed on the instance."
  type        = string
  default     = "v1.33.1+k3s1"
}

variable "helm_version" {
  description = "Kept equal to the version the other workflows pin."
  type        = string
  default     = "v3.16.3"
}

variable "device_plugin_version" {
  description = "Chart version of nvdp/nvidia-device-plugin."
  type        = string
  default     = "0.17.1"
}

variable "gpu_replicas" {
  description = <<-EOT
    How many nvidia.com/gpu the one card is advertised as, through
    time-slicing. Ollama and ComfyUI each hold one, and each component's GPU
    test pod asks for another while they do.
  EOT
  type        = number
  default     = 8
}

variable "run_id" {
  description = "Tagged onto every resource, so a leftover can be traced to the run that made it."
  type        = string
  default     = "manual"
}
