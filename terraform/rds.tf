resource "aws_db_subnet_group" "main" {
  name       = "steam-infra"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]

  tags = {
    Name = "steam-infra"
  }
}

resource "aws_security_group" "rds" {
  name        = "steam-infra-rds"
  description = "Allow Postgres from the bastion and generator only"
  vpc_id      = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "steam-infra-rds"
  }
}

data "aws_rds_engine_version" "postgres" {
  engine       = "postgres"
  default_only = true
}

resource "random_password" "db" {
  length  = 20
  special = false
}

# rds.logical_replication is a static parameter (requires reboot) that turns on
# wal_level=logical, needed for Debezium's pgoutput plugin to read the WAL.
resource "aws_db_parameter_group" "main" {
  name   = "steam-infra"
  family = data.aws_rds_engine_version.postgres.parameter_group_family

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "steam-infra"
  }
}

resource "aws_db_instance" "main" {
  identifier             = "steam-infra"
  engine                 = "postgres"
  engine_version         = data.aws_rds_engine_version.postgres.version
  instance_class         = "db.t4g.micro"
  allocated_storage      = 20
  storage_type           = "gp3"
  db_name                = "steam"
  username               = "steam_proj_admin"
  password               = random_password.db.result
  db_subnet_group_name   = aws_db_subnet_group.main.name
  parameter_group_name   = aws_db_parameter_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false

  tags = {
    Name = "steam-infra"
  }
}

resource "aws_security_group_rule" "rds_from_bastion" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.bastion.id
  description              = "Postgres from the bastion"
}

resource "aws_security_group_rule" "rds_from_generator" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.generator.id
  description              = "Postgres from the generator"
}
