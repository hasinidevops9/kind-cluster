provider "aws" {
  region = var.aws_region
}

# Networking comes from the default VPC. Prefer the default subnets
# in us-east-1a, us-east-1b, us-east-1d, and us-east-1f, in that order.
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

data "aws_subnet" "candidate" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

data "aws_route_tables" "default" {
  vpc_id = data.aws_vpc.default.id
}

data "aws_route_table" "default" {
  for_each       = toset(data.aws_route_tables.default.ids)
  route_table_id = each.value
}

data "aws_subnet" "selected" {
  id = local.subnet_id

  lifecycle {
    precondition {
      condition     = local.subnet_id != null && local.subnet_id != ""
      error_message = "No default subnet in ${join(", ", local.preferred_azs)} assigns a public IPv4 address and has a route to an Internet Gateway."
    }
  }
}

# Default subnets use the VPC main route table through the implicit association.
# A subnet_id lookup returns no results in that case, so resolve an explicit
# association when one exists and otherwise use the main route table.
data "aws_route_table" "selected" {
  route_table_id = local.selected_route_table_id

  lifecycle {
    precondition {
      condition     = local.selected_route_table_id != null && local.selected_route_table_id != ""
      error_message = "The selected subnet has no explicit route table and the VPC has no main route table."
    }
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
  preferred_azs = [
    "${var.aws_region}a",
    "${var.aws_region}b",
    "${var.aws_region}d",
    "${var.aws_region}f",
  ]

  script_path = "/home/${var.ssh_user}/bootstrap.sh"

  main_route_table_id = one([
    for route_table in data.aws_route_table.default : route_table.id
    if anytrue([for association in route_table.associations : association.main])
  ])

  # The trailing empty map keeps merge() valid when every association is implicit.
  explicit_route_table_ids = merge(concat([
    for route_table in data.aws_route_table.default : {
      for association in route_table.associations :
      association.subnet_id => route_table.id
      if association.subnet_id != null && association.subnet_id != ""
    }
  ], [{}])...)

  subnet_route_table_ids = {
    for subnet_id, subnet in data.aws_subnet.candidate :
    subnet_id => lookup(local.explicit_route_table_ids, subnet_id, local.main_route_table_id)
  }

  route_table_has_igw = {
    for route_table_id, route_table in data.aws_route_table.default :
    route_table_id => anytrue([
      for route in route_table.routes :
      route.cidr_block == "0.0.0.0/0" && try(startswith(route.gateway_id, "igw-"), false)
    ])
  }

  # Preference order is the AZ list order. sort() only breaks ties inside one AZ.
  eligible_subnet_ids = flatten([
    for az in local.preferred_azs : sort([
      for subnet_id, subnet in data.aws_subnet.candidate : subnet_id
      if subnet.availability_zone == az &&
      subnet.vpc_id == data.aws_vpc.default.id &&
      subnet.map_public_ip_on_launch &&
      local.route_table_has_igw[local.subnet_route_table_ids[subnet_id]]
    ])
  ])

  subnet_id               = try(local.eligible_subnet_ids[0], null)
  selected_route_table_id = try(local.subnet_route_table_ids[local.subnet_id], null)

  igw_route = anytrue([
    for route in data.aws_route_table.selected.routes :
    route.cidr_block == "0.0.0.0/0" && try(startswith(route.gateway_id, "igw-"), false)
  ])
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
      condition     = local.subnet_id != "" && local.subnet_id != null
      error_message = "subnet_id is undefined. The default VPC needs a default subnet in ${join(", ", local.preferred_azs)} with public IPv4 assignment and an Internet Gateway route."
    }

    precondition {
      condition     = data.aws_subnet.selected.vpc_id == aws_security_group.kind.vpc_id
      error_message = "The selected subnet is not in the same VPC as the Kind security group."
    }

    precondition {
      condition     = contains(local.preferred_azs, data.aws_subnet.selected.availability_zone)
      error_message = "The selected subnet is not in ${join(", ", local.preferred_azs)}."
    }

    precondition {
      condition     = data.aws_subnet.selected.map_public_ip_on_launch
      error_message = "The selected default subnet does not assign public IPv4 addresses, so SSH would not be reachable."
    }

    precondition {
      condition     = local.igw_route
      error_message = "The selected subnet route table has no 0.0.0.0/0 route to an Internet Gateway."
    }
  }
}

# Provisioners on the instance run once and a failure taints the instance.
# A null_resource can be replaced without destroying the instance.
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
