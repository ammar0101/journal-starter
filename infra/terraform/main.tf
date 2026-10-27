terraform {
  required_version = ">= 1.10.0"

  backend "s3" {
    bucket       = "journal-api-tfstate-098567766079-f876924a"
    key          = "journal-api/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6, < 4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0, < 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.journal.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.journal.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", data.aws_eks_cluster.journal.name, "--region", var.aws_region]
    }
  }
}

data "aws_eks_cluster" "journal" {
  name = "journal-cluster"
}

data "aws_vpc" "journal" {
  id = data.aws_eks_cluster.journal.vpc_config[0].vpc_id
}

data "aws_subnet" "journal_cluster" {
  for_each = toset(data.aws_eks_cluster.journal.vpc_config[0].subnet_ids)

  id = each.value
}

locals {
  cluster_subnets = {
    for subnet_id, subnet in data.aws_subnet.journal_cluster :
    subnet_id => subnet
  }
  private_subnet_ids = [
    for subnet_id, subnet in local.cluster_subnets : subnet_id
    if !subnet.map_public_ip_on_launch
  ]
  public_subnet_ids = [
    for subnet_id, subnet in local.cluster_subnets : subnet_id
    if subnet.map_public_ip_on_launch
  ]
  ingress_subnet_id = sort([
    for subnet_id, subnet in local.cluster_subnets : subnet_id
    if subnet.map_public_ip_on_launch && subnet.availability_zone == "us-east-1d"
  ])[0]
}

resource "aws_ecr_repository" "journal_api" {
  name                 = "journal-api"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = false
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_security_group" "journal_db" {
  name_prefix = "journal-api-db-"
  description = "Allow PostgreSQL from the EKS VPC"
  vpc_id      = data.aws_vpc.journal.id

  ingress {
    description = "PostgreSQL from the EKS VPC"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.journal.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "journal-api-db"
  }
}

resource "aws_db_subnet_group" "journal" {
  name        = "journal-api-db-subnets"
  description = "Private subnets for the Journal API PostgreSQL database"
  subnet_ids  = local.private_subnet_ids

  tags = {
    Name = "journal-api-db-subnets"
  }
}

resource "aws_db_instance" "journal" {
  identifier                  = "journal-api-db"
  engine                      = "postgres"
  engine_version              = "16.13"
  instance_class              = "db.t4g.micro"
  allocated_storage           = 20
  storage_type                = "gp3"
  storage_encrypted           = true
  db_name                     = "career_journal"
  username                    = "journal_admin"
  manage_master_user_password = true
  port                        = 5432

  db_subnet_group_name   = aws_db_subnet_group.journal.name
  vpc_security_group_ids = [aws_security_group.journal_db.id]
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period    = 1
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  deletion_protection        = true
  skip_final_snapshot        = false
  final_snapshot_identifier  = "journal-api-db-final"

  tags = {
    Name = "journal-api-db"
  }
}

resource "aws_secretsmanager_secret" "journal_runtime" {
  name = "journal-api/runtime"
}

resource "random_password" "journal_db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret_version" "journal_runtime" {
  secret_id = aws_secretsmanager_secret.journal_runtime.id
  secret_string = jsonencode({
    DATABASE_URL    = "postgresql://journal_api:${random_password.journal_db.result}@${aws_db_instance.journal.address}:${aws_db_instance.journal.port}/${aws_db_instance.journal.db_name}"
    APP_DB_PASSWORD = random_password.journal_db.result
    OPENAI_API_KEY  = "placeholder"
    OPENAI_BASE_URL = "https://api.openai.com/v1"
    OPENAI_MODEL    = "gpt-4o-mini"
  })
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = data.aws_eks_cluster.journal.name
  addon_name   = "eks-pod-identity-agent"
}

resource "aws_iam_role" "journal_runtime_secrets" {
  name = "journal-api-runtime-secrets"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "journal_runtime_secrets" {
  name = "read-journal-api-runtime-secret"
  role = aws_iam_role.journal_runtime_secrets.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
      ]
      Resource = aws_secretsmanager_secret.journal_runtime.arn
    }]
  })
}

resource "aws_iam_role" "journal_db_bootstrap" {
  name = "journal-api-db-bootstrap"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession",
      ]
    }]
  })
}

resource "aws_iam_role_policy" "journal_db_bootstrap" {
  name = "read-journal-api-rds-master-secret"
  role = aws_iam_role.journal_db_bootstrap.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue",
      ]
      Resource = [
        aws_db_instance.journal.master_user_secret[0].secret_arn,
        aws_secretsmanager_secret.journal_runtime.arn,
      ]
    }]
  })
}

resource "aws_eks_pod_identity_association" "journal_runtime" {
  cluster_name    = data.aws_eks_cluster.journal.name
  namespace       = "default"
  service_account = "journal-api"
  role_arn        = aws_iam_role.journal_runtime_secrets.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy.journal_runtime_secrets,
  ]
}

resource "aws_eks_pod_identity_association" "journal_db_bootstrap" {
  cluster_name    = data.aws_eks_cluster.journal.name
  namespace       = "default"
  service_account = "journal-db-bootstrap"
  role_arn        = aws_iam_role.journal_db_bootstrap.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy.journal_db_bootstrap,
  ]
}
