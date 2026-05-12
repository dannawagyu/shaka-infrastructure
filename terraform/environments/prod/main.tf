locals {
  name_prefix = "shaka-${var.environment}"
  common_tags = {
    Project     = "shaka"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "Allow Shaka app EC2 access to the production RDS database"
  vpc_id      = var.vpc_id

  egress {
    description = "Allow outbound responses"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds"
  })
}

resource "aws_security_group_rule" "rds_ingress_from_app_ec2" {
  type                     = "ingress"
  description              = "MySQL from existing Shaka app EC2 security group"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = var.app_security_group_id
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
}

resource "aws_db_subnet_group" "shaka" {
  name        = "${local.name_prefix}-rds"
  description = "Existing private subnets for Shaka production RDS"
  subnet_ids  = var.private_subnet_ids

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds"
  })
}

resource "aws_db_instance" "shaka" {
  identifier = "${local.name_prefix}-mysql"

  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 20
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
