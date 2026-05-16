locals {
  name_prefix = "shaka-${var.environment}"
  common_tags = {
    Project     = "shaka"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

resource "aws_subnet" "rds_private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = data.aws_subnet.existing_public.vpc_id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private-rds-${count.index + 1}"
    Tier = "private"
  })
}

resource "aws_route_table" "private" {
  vpc_id = data.aws_subnet.existing_public.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-private"
  })
}

resource "aws_route_table_association" "rds_private" {
  count          = length(aws_subnet.rds_private)
  subnet_id      = aws_subnet.rds_private[count.index].id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds"
  description = "Allow the existing Shaka app EC2 host to access the production RDS database"
  vpc_id      = data.aws_subnet.existing_public.vpc_id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds"
  })
}

resource "aws_security_group_rule" "rds_ingress_from_existing_app_ec2" {
  type                     = "ingress"
  description              = "MySQL from the existing Shaka app EC2 security group"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = var.existing_app_security_group_id
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
}

resource "aws_db_subnet_group" "shaka" {
  name        = "${local.name_prefix}-rds"
  description = "Terraform-managed private subnets for Shaka production RDS in the existing app VPC"
  subnet_ids  = aws_subnet.rds_private[*].id

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-rds"
  })
}

resource "aws_db_instance" "shaka" {
  identifier = "${local.name_prefix}-mysql"

  engine         = "mysql"
  engine_version = var.db_engine_version
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

  backup_retention_period   = var.db_backup_retention_period
  copy_tags_to_snapshot     = true
  deletion_protection       = true
  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-mysql-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-mysql"
  })

  lifecycle {
    prevent_destroy = true
  }
}
