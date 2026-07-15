output "app_server_public_ip" {
  description = "EC2 Elastic IP — use this for nip.io subdomains"
  value       = aws_eip.app_server.public_ip
}

output "crud_api_url" {
  description = "Public URL for App 1 (FastAPI CRUD API)"
  value       = "http://api.${aws_eip.app_server.public_ip}.nip.io"
}

output "multiauth_url" {
  description = "Public URL for App 2 (Multi-Auth MERN)"
  value       = "http://app.${aws_eip.app_server.public_ip}.nip.io"
}

output "jenkins_url" {
  description = "Jenkins UI — only accessible from your ops IP"
  value       = "http://${aws_eip.app_server.public_ip}:9090"
}

output "rds_endpoint" {
  description = "RDS host:port — use in DATABASE_URL env var"
  value       = aws_db_instance.main.endpoint
}

output "rds_host" {
  description = "RDS hostname only (without port)"
  value       = aws_db_instance.main.address
}

output "ssh_command" {
  description = "SSH command to connect to the server"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_eip.app_server.public_ip}"
}

output "configure_nginx_command" {
  description = "Run this on the server after provisioning to configure Nginx"
  value       = "sudo bash /opt/crud-api/current/infra/scripts/configure-nginx.sh ${aws_eip.app_server.public_ip}"
}
