output "aws_region" {
  description = "Region the instance was created in."
  value       = var.aws_region
}

output "subnet_id" {
  description = "Default subnet selected for the instance."
  value       = local.subnet_id
}

output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.kind.id
}

output "spot_instance_request_id" {
  description = "Spot request that launched the instance."
  value       = aws_instance.kind.spot_instance_request_id
}

output "ami_id" {
  description = "RHEL practice AMI ID."
  value       = aws_instance.kind.ami
}

output "public_ip" {
  description = "Public IP used for SSH."
  value       = aws_instance.kind.public_ip
}

output "ssh_command" {
  description = "SSH command. The password is the ssh_password variable."
  value       = "ssh ${var.ssh_user}@${aws_instance.kind.public_ip}"
}
