# One GPU instance running single-node k3s, created for a workflow run and
# destroyed after it. The network is its own small VPC with a public subnet and
# no NAT gateway: a NAT gateway bills by the hour whether anything runs or not,
# and the instance only needs a public address to reach image registries and
# the runner to reach it.

locals {
  name = "ai-stack-lite-gpu-ci"
}

# Not every zone carries every GPU type. Placing the subnet by looking this up
# avoids an apply that fails with "Unsupported" in whichever zone came first.
data "aws_ec2_instance_type_offerings" "gpu" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

resource "aws_vpc" "this" {
  cidr_block           = "10.200.0.0/24"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = local.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = local.name }
}

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = aws_vpc.this.cidr_block
  availability_zone       = sort(data.aws_ec2_instance_type_offerings.gpu.locations)[0]
  map_public_ip_on_launch = true
  tags                    = { Name = local.name }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = local.name }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

resource "aws_security_group" "this" {
  name        = local.name
  description = "SSH from the workflow runner only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "ssh from the runner"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    description = "image registries, model downloads, package mirrors"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = local.name }
}

resource "aws_key_pair" "this" {
  key_name   = local.name
  public_key = var.ssh_public_key
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.this.id
  vpc_security_group_ids = [aws_security_group.this.id]
  key_name               = aws_key_pair.this.key_name

  # With this, the shutdown timer in user data ends billing rather than parking
  # a stopped instance whose volume keeps costing.
  instance_initiated_shutdown_behavior = "terminate"

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    max_lifetime_minutes  = var.max_lifetime_minutes
    k3s_version           = var.k3s_version
    helm_version          = var.helm_version
    device_plugin_version = var.device_plugin_version
    gpu_replicas          = var.gpu_replicas
  })
  # A changed script means a different machine; never leave one that was set up
  # by the old script in place.
  user_data_replace_on_change = true

  tags = { Name = local.name }

  depends_on = [aws_route_table_association.this]
}
