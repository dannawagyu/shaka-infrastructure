locals {
  name_prefix = "shaka-${var.environment}"
  common_tags = {
    Project     = "shaka"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_vpc" "shaka" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-vpc"
  })
}

resource "aws_internet_gateway" "shaka" {
  vpc_id = aws_vpc.shaka.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-igw"
  })
}

resource "aws_subnet" "app_public" {
  vpc_id                  = aws_vpc.shaka.id
  cidr_block              = var.public_subnet_cidr
  availability_zone       = var.availability_zones[0]
  map_public_ip_on_launch = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public-app"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.shaka.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.shaka.id
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-public"
  })
}

resource "aws_route_table_association" "app_public" {
  subnet_id      = aws_subnet.app_public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "rds_private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.shaka.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-rds-${count.index + 1}"
    Tier = "private"
  })
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.shaka.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private"
  })
}

resource "aws_route_table_association" "rds_private" {
  count          = length(aws_subnet.rds_private)
  subnet_id      = aws_subnet.rds_private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app"
  description = "Shaka production app host security group"
  vpc_id      = aws_vpc.shaka.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-app"
  })
}

resource "aws_security_group_rule" "app_ingress_ssh" {
  type              = "ingress"
  description       = "SSH from operator CIDR only"
  security_group_id = aws_security_group.app.id
  cidr_blocks       = [var.operator_ssh_cidr]
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
}

resource "aws_security_group_rule" "app_ingress_http" {
  type              = "ingress"
  description       = "HTTP for Lets Encrypt challenge and redirect"
  security_group_id = aws_security_group.app.id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
}

resource "aws_security_group_rule" "app_ingress_https" {
  type              = "ingress"
  description       = "HTTPS public API traffic through Nginx"
  security_group_id = aws_security_group.app.id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
}

resource "aws_security_group_rule" "app_egress_all" {
  type              = "egress"
  description       = "Outbound updates, TLS, Grafana remote_write, and RDS client traffic"
  security_group_id = aws_security_group.app.id
  cidr_blocks       = ["0.0.0.0/0"]
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
}

resource "aws_instance" "app" {
  ami                         = var.app_ami_id
  instance_type               = var.app_instance_type
  subnet_id                   = aws_subnet.app_public.id
  vpc_security_group_ids      = [aws_security_group.app.id]
  key_name                    = var.ssh_key_name
  associate_public_ip_address = true

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    environment = var.environment
  })

  root_block_device {
    volume_size           = var.app_root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-app"
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "Allow Shaka app EC2 access to the production RDS database"
  vpc_id      = aws_vpc.shaka.id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds"
  })
}

resource "aws_security_group_rule" "rds_ingress_from_app_ec2" {
  type                     = "ingress"
  description              = "MySQL from Terraform-managed Shaka app EC2 security group"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.app.id
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
}

resource "aws_db_subnet_group" "shaka" {
  name        = "${local.name_prefix}-rds"
  description = "Terraform-managed private subnets for Shaka production RDS"
  subnet_ids  = aws_subnet.rds_private[*].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds"
  })
}

resource "aws_db_instance" "shaka" {
  identifier = "${local.name_prefix}-mysql"

  engine         = "mysql"
  engine_version = "8.0.35"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.database_name
  username = var.db_username
  password = var.db_password
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.shaka.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = false
  availability_zone      = var.availability_zones[0]

  backup_retention_period   = 7
  copy_tags_to_snapshot     = true
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-mysql-final"

  auto_minor_version_upgrade = true
  apply_immediately          = false

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-mysql"
  })

  lifecycle {
    prevent_destroy = true
  }
}
