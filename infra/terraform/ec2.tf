# ── Security Group — Application Server ───────────────────────────────────────
resource "aws_security_group" "app_server" {
  name        = "${var.project_name}-app-server"
  description = "Controls inbound traffic to the application server"
  vpc_id      = data.aws_vpc.default.id

  # SSH — ops IP only, never 0.0.0.0/0
  ingress {
    description = "SSH from ops IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ops_ip_cidr]
  }

  # HTTP — public (needed for Let's Encrypt ACME challenge + redirect to HTTPS)
  ingress {
    description = "HTTP public (Nginx)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS — public (both apps served via Nginx)
  ingress {
    description = "HTTPS public (Nginx)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Jenkins — ops IP only (non-default port 9090)
  ingress {
    description = "Jenkins UI from ops IP"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.ops_ip_cidr]
  }

  # All outbound allowed (apt updates, GitHub pulls, RDS connections)
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-app-server-sg"
    Project = var.project_name
  }
}

# ── EC2 Instance — t3.micro (smallest, free-tier eligible) ────────────────────
resource "aws_instance" "app_server" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type   # t3.micro default
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.app_server.id]

  # 20 GB gp3 — free tier limit; Jenkins workspace + two apps need the space
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
  }

  # cloud-init runs on first boot: sets up 2 GB swap + calls server-setup.sh
  user_data = base64encode(file("${path.module}/../scripts/user-data.sh"))

  # Prevent accidental replacement when user_data changes after first boot
  lifecycle {
    ignore_changes = [user_data]
  }

  tags = {
    Name    = "${var.project_name}-app-server"
    Project = var.project_name
  }
}

# ── Elastic IP — keeps the IP stable across stop/start cycles ─────────────────
resource "aws_eip" "app_server" {
  instance = aws_instance.app_server.id
  domain   = "vpc"

  tags = {
    Name    = "${var.project_name}-app-server-eip"
    Project = var.project_name
  }
}
