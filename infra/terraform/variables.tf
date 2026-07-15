variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-2"
}

variable "ops_ip_cidr" {
  description = "Your public IP in CIDR notation — SSH and Jenkins are restricted to this. Example: 203.0.113.5/32"
  type        = string
}

variable "key_name" {
  description = "Name of an existing EC2 key pair for SSH access"
  type        = string
}

variable "db_password" {
  description = "Master password for the RDS PostgreSQL instance — never commit a real value"
  type        = string
  sensitive   = true
}

variable "instance_type" {
  description = "EC2 instance type — t3.micro is smallest, free-tier eligible for 12 months"
  type        = string
  default     = "t3.micro"
}

variable "rds_instance_class" {
  description = "RDS instance class — db.t3.micro is smallest available for PostgreSQL"
  type        = string
  default     = "db.t3.micro"
}

variable "project_name" {
  description = "Tag applied to all resources for easy identification"
  type        = string
  default     = "serviots-task"
}
