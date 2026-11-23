provider "aws" {
  region = var.aws_region
}

# Networking comes from the default VPC in the configured region.
# The subnet id is selected here so it is never left as an empty variable.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Course RHEL 9 image. The name filter is exact, so this stays on
# Redhat-9-DevOps-Practice from the course account rather than a public RHEL AMI.
data "aws_ami" "rhel" {
  most_recent = true
  owners      = [var.ami_owner]

  filter {
    name   = "name"
    values = [var.ami_name]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  subnet_id   = sort(data.aws_subnets.default.ids)[0]
  script_path = "/home/${var.ssh_user}/bootstrap.sh"
}

resource "aws_security_group" "kind" {
  name        = "kind-cluster"
  description = "SSH access for the Kind lab instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "ssh"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  # Terraform drops the AWS default outbound rule, so add it back.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "kind-cluster"
  }
}

resource "aws_instance" "kind" {
  ami                         = data.aws_ami.rhel.id
  instance_type               = var.instance_type
  subnet_id                   = local.subnet_id
  vpc_security_group_ids      = [aws_security_group.kind.id]
  associate_public_ip_address = true

  # One-time Spot request for a temporary lab. Interruption terminates the
  # instance instead of stopping it. No max price is set, so the ceiling is
  # the On-Demand price and the request can still be fulfilled.
  instance_market_options {
    market_type = "spot"

    spot_options {
      spot_instance_type             = "one-time"
      instance_interruption_behavior = "terminate"
    }
  }

  root_block_device {
    volume_size           = var.root_volume_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name = "kind-cluster"
  }

  lifecycle {
    precondition {
      condition     = local.subnet_id != ""
      error_message = "subnet_id is undefined. The default VPC needs a default subnet in ${var.aws_region}."
    }
  }
}

# Provisioners on the instance run once and a failure taints the instance.
# A null_resource can be replaced without destroying the Spot instance.
# The four provisioners below stay as sibling blocks and run in this order:
# upload the script, run phase1, sleep 60, then run phase2.
# Phase2 keeps a 15 minute SSH timeout so it can reconnect after the reboot.
resource "null_resource" "bootstrap" {
  triggers = {
    instance_id   = aws_instance.kind.id
    bootstrap_sha = filemd5("${path.module}/scripts/bootstrap.sh")
    cluster_name  = var.kind_cluster_name
  }

  provisioner "file" {
    source      = "${path.module}/scripts/bootstrap.sh"
    destination = local.script_path

    connection {
      type     = "ssh"
      host     = aws_instance.kind.public_ip
      user     = var.ssh_user
      password = var.ssh_password
      timeout  = "15m"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sed -i $'s/\\r$//' ${local.script_path}",
      "chmod 0755 ${local.script_path}",
      "sudo -n ${local.script_path} phase1",
    ]

    connection {
      type     = "ssh"
      host     = aws_instance.kind.public_ip
      user     = var.ssh_user
      password = var.ssh_password
      timeout  = "15m"
    }
  }

  provisioner "local-exec" {
    command = "sleep 60"
  }

  provisioner "remote-exec" {
    inline = [
      "test -f ${local.script_path}",
      "CLUSTER_NAME=${var.kind_cluster_name} ${local.script_path} phase2",
    ]

    connection {
      type     = "ssh"
      host     = aws_instance.kind.public_ip
      user     = var.ssh_user
      password = var.ssh_password
      timeout  = "15m"
    }
  }
}
