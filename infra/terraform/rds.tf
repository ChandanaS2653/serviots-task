# ── Security Group — RDS (allows PostgreSQL from app server ONLY) ──────────────
resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds"
  description = "Allows PostgreSQL only from the application server security group"
  vpc_id      = data.aws_vpc.default.id

  # Port 5432 open only to the EC2 security group — not to the internet
  ingress {
    description     = "PostgreSQL from app server only"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app_server.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-rds-sg"
    Project = var.project_name
  }
}

# ── DB Subnet Group — required by RDS, uses all default subnets ───────────────
resource "aws_db_subnet_group" "main" {
  name        = "${var.project_name}-db-subnet-group"
  subnet_ids  = data.aws_subnets.default.ids
  description = "Subnet group for serviots PostgreSQL RDS"

  tags = {
    Name    = "${var.project_name}-db-subnet-group"
    Project = var.project_name
  }
}

# ── RDS PostgreSQL — db.t3.micro (smallest available for PostgreSQL) ──────────
resource "aws_db_instance" "main" {
  identifier        = "${var.project_name}-postgres"
  engine            = "postgres"
  engine_version    = "15"
  instance_class    = var.rds_instance_class  # db.t3.micro default

  # 20 GB gp2 — minimum for RDS; free-tier includes 20 GB
  allocated_storage     = 20
  max_allocated_storage = 20   # disable autoscaling — keep cost predictable
  storage_type          = "gp2"
  storage_encrypted     = true

  # Master credentials — password injected from terraform.tfvars (never committed)
  db_name  = "postgres"   # default DB; crud_api_db and multiauth_db created via init script
  username = "postgres"
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Not publicly accessible — only reachable from inside the VPC
  publicly_accessible = false

  # Single AZ — not a production HA system; saves cost for a hiring task
  multi_az = false

  # Automated backups — 7-day retention, 03:00–04:00 UTC backup window
  backup_retention_period   = 7
  backup_window             = "03:00-04:00"
  maintenance_window        = "Mon:04:00-Mon:05:00"
  delete_automated_backups  = false

  # Snapshot on destroy — safety net before terraform destroy
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.project_name}-postgres-final-snapshot"

  # Don't apply changes immediately — wait for maintenance window
  apply_immediately = false

  tags = {
    Name    = "${var.project_name}-postgres"
    Project = var.project_name
  }
}

# ── Create the two application databases after RDS is up ─────────────────────
# This null_resource runs an SQL script via the EC2 instance to create:
#   - crud_api_db  (Application 1)
#   - multiauth_db (Application 2)
# It uses the EC2 as a bastion since RDS is not publicly accessible.
resource "null_resource" "create_databases" {
  depends_on = [aws_instance.app_server, aws_db_instance.main, aws_eip.app_server]

  provisioner "remote-exec" {
    inline = [
      "until pg_isready -h ${aws_db_instance.main.address} -p 5432 -U postgres; do sleep 5; done",
      "PGPASSWORD='${var.db_password}' psql -h ${aws_db_instance.main.address} -U postgres -c \"CREATE DATABASE crud_api_db;\" 2>/dev/null || echo 'crud_api_db already exists'",
      "PGPASSWORD='${var.db_password}' psql -h ${aws_db_instance.main.address} -U postgres -c \"CREATE DATABASE multiauth_db;\" 2>/dev/null || echo 'multiauth_db already exists'",
      "echo 'Databases ready.'"
    ]

    connection {
      type        = "ssh"
      host        = aws_eip.app_server.public_ip
      user        = "ubuntu"
      private_key = file("~/.ssh/${var.key_name}.pem")
    }
  }

  triggers = {
    rds_endpoint = aws_db_instance.main.endpoint
  }
}
