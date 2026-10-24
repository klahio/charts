output "public_ip" {
  value = aws_instance.this.public_ip
}

output "instance_id" {
  value = aws_instance.this.id
}

# The Deep Learning AMIs on Ubuntu log in as ubuntu.
output "ssh_user" {
  value = "ubuntu"
}

output "availability_zone" {
  value = aws_subnet.this.availability_zone
}
