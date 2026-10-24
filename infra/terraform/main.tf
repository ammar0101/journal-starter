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
    host                   = aws_eks_cluster.journal.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.journal.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.journal.name, "--region", var.aws_region]
    }
  }
}

data "aws_iam_role" "eks_cluster" {
  name = "eksctl-journal-cluster-cluster-ServiceRole-vQcwEl8OrvGu"
}

data "aws_iam_role" "eks_nodegroup" {
  name = "eksctl-journal-cluster-nodegroup-n-NodeInstanceRole-WX7ls8D9SWts"
}

data "aws_security_group" "eks_nodes" {
  id = "sg-0b2f8450365fd8aef"
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

resource "aws_eks_cluster" "journal" {
  name     = "journal-cluster"
  role_arn = data.aws_iam_role.eks_cluster.arn
  version  = "1.34"
  tags = {
    Name                                          = "eksctl-journal-cluster-cluster/ControlPlane"
    "alpha.eksctl.io/cluster-name"                = "journal-cluster"
    "alpha.eksctl.io/cluster-oidc-enabled"        = "false"
    "eksctl.cluster.k8s.io/v1alpha1/cluster-name" = "journal-cluster"
    "alpha.eksctl.io/eksctl-version"              = "0.231.0"
  }

  vpc_config {
    subnet_ids = [
      "subnet-05718365d405c6861",
      "subnet-0fff35569a6bfb846",
      "subnet-0c7504ea8d5c2dac5",
      "subnet-0aa44dfb5c66b38e1",
    ]
    security_group_ids      = ["sg-0c39947bd91527fbc"]
    endpoint_public_access  = true
    endpoint_private_access = false
    public_access_cidrs     = ["0.0.0.0/0"]
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  control_plane_scaling_config {
    tier = "standard"
  }

  kube_api_server_config {
    event_ttl = "60m"

    service_node_port_range {
      min_port = 30000
      max_port = 32767
    }
  }

  kube_controller_manager_config {
    horizontal_pod_autoscaler_controller_config {
      horizontal_pod_autoscaler_sync_period = "15s"
    }

    pod_gc_controller_config {
      terminated_pod_gc_threshold = 12500
    }
  }

  kube_scheduler_config {
    node_resources_fit {
      scoring_strategy {
        type = "LeastAllocated"

        resource {
          name   = "cpu"
          weight = 1
        }

        resource {
          name   = "memory"
          weight = 1
        }
      }
    }
  }

  kubernetes_network_config {
    ip_family         = "ipv4"
    service_ipv4_cidr = "10.100.0.0/16"

    elastic_load_balancing {
      enabled = false
    }
  }

  upgrade_policy {
    support_type = "EXTENDED"
  }

  enabled_cluster_log_types = []
}

resource "aws_eks_node_group" "journal" {
  cluster_name    = aws_eks_cluster.journal.name
  node_group_name = "ng-814ac263"
  node_role_arn   = data.aws_iam_role.eks_nodegroup.arn
  subnet_ids      = ["subnet-05718365d405c6861", "subnet-0fff35569a6bfb846"]
  version         = "1.34"
  release_version = "1.34.11-20261012"
  capacity_type   = "ON_DEMAND"
  instance_types  = ["t3.micro"]
  ami_type        = "AL2023_x86_64_STANDARD"
  labels = {
    "alpha.eksctl.io/cluster-name"   = "journal-cluster"
    "alpha.eksctl.io/nodegroup-name" = "ng-814ac263"
  }
  tags = {
    "alpha.eksctl.io/cluster-name"                = "journal-cluster"
    "alpha.eksctl.io/eksctl-version"              = "0.231.0"
    "alpha.eksctl.io/nodegroup-name"              = "ng-814ac263"
    "alpha.eksctl.io/nodegroup-type"              = "managed"
    "eksctl.cluster.k8s.io/v1alpha1/cluster-name" = "journal-cluster"
  }

  scaling_config {
    min_size     = 2
    max_size     = 9
    desired_size = 9
  }

  update_config {
    max_unavailable = 1
  }

  launch_template {
    id      = "lt-0e0a79e1fe76d8a14"
    version = "1"
  }
}

resource "aws_security_group" "journal_db" {
  name_prefix = "journal-api-db-"
  description = "Allow PostgreSQL from the existing EKS worker nodes"
  vpc_id      = "vpc-0df814fc7fc2dc6f0"

  ingress {
    description     = "PostgreSQL from EKS worker nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [data.aws_security_group.eks_nodes.id]
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
  subnet_ids = [
    "subnet-0aa44dfb5c66b38e1",
    "subnet-0c7504ea8d5c2dac5",
  ]

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

data "aws_secretsmanager_secret" "journal_runtime" {
  name = "journal-api/runtime"
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name  = aws_eks_cluster.journal.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = "v1.4.1-eksbuild.2"
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
      Resource = data.aws_secretsmanager_secret.journal_runtime.arn
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
        data.aws_secretsmanager_secret.journal_runtime.arn,
      ]
    }]
  })
}

resource "aws_eks_pod_identity_association" "journal_runtime" {
  cluster_name    = aws_eks_cluster.journal.name
  namespace       = "default"
  service_account = "journal-api"
  role_arn        = aws_iam_role.journal_runtime_secrets.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy.journal_runtime_secrets,
  ]
}

resource "aws_eks_pod_identity_association" "journal_db_bootstrap" {
  cluster_name    = aws_eks_cluster.journal.name
  namespace       = "default"
  service_account = "journal-db-bootstrap"
  role_arn        = aws_iam_role.journal_db_bootstrap.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy.journal_db_bootstrap,
  ]
}
