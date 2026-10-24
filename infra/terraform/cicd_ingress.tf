locals {
  github_oidc_url = "https://token.actions.githubusercontent.com"
  github_owner    = split("/", var.github_repository)[0]
  github_repo     = split("/", var.github_repository)[1]
  github_subject_prefix = join("", [
    "repo:${local.github_owner}@${var.github_owner_id}/",
    "${local.github_repo}@${var.github_repository_id}",
  ])
  github_oidc_host = trimprefix(
    local.github_oidc_url,
    "https://",
  )
}

resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = local.github_oidc_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_build_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = ["${local.github_subject_prefix}:ref:refs/heads/main"]
    }
  }
}

data "aws_iam_policy_document" "github_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = ["${local.github_subject_prefix}:environment:production"]
    }
  }
}

resource "aws_iam_role" "github_build" {
  name               = "journal-api-github-build"
  assume_role_policy = data.aws_iam_policy_document.github_build_trust.json
}

resource "aws_iam_role_policy" "github_build_ecr" {
  name = "push-journal-api-images"
  role = aws_iam_role.github_build.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = aws_ecr_repository.journal_api.arn
      },
    ]
  })
}

resource "aws_iam_role" "github_deploy" {
  name               = "journal-api-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_deploy_trust.json
}

resource "aws_iam_role_policy" "github_deploy_eks" {
  name = "describe-journal-cluster"
  role = aws_iam_role.github_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["eks:DescribeCluster"]
      Resource = aws_eks_cluster.journal.arn
    }]
  })
}

resource "aws_eks_access_entry" "github_deploy" {
  cluster_name  = aws_eks_cluster.journal.name
  principal_arn = aws_iam_role.github_deploy.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_deploy" {
  cluster_name  = aws_eks_cluster.journal.name
  principal_arn = aws_iam_role.github_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["default"]
  }

  depends_on = [aws_eks_access_entry.github_deploy]
}

resource "aws_eip" "journal_api_ingress" {
  domain = "vpc"

  tags = {
    Name = "journal-api-ingress"
  }
}

data "aws_subnet" "journal_api_ingress" {
  id = "subnet-0fff35569a6bfb846"
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name = "journal-api-aws-load-balancer-controller"

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

resource "aws_iam_role_policy" "aws_load_balancer_controller" {
  name = "manage-journal-cluster-load-balancers"
  role = aws_iam_role.aws_load_balancer_controller.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeVpcPeeringConnections",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeTags",
          "ec2:GetSecurityGroupsForVpc",
          "ec2:DescribeRouteTables",
          "elasticloadbalancing:DescribeLoadBalancers",
          "elasticloadbalancing:DescribeLoadBalancerAttributes",
          "elasticloadbalancing:DescribeListeners",
          "elasticloadbalancing:DescribeListenerCertificates",
          "elasticloadbalancing:DescribeSSLPolicies",
          "elasticloadbalancing:DescribeRules",
          "elasticloadbalancing:DescribeTargetGroups",
          "elasticloadbalancing:DescribeTargetGroupAttributes",
          "elasticloadbalancing:DescribeTargetHealth",
          "elasticloadbalancing:DescribeTags",
          "elasticloadbalancing:DescribeListenerAttributes",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "iam:AWSServiceName" = "elasticloadbalancing.amazonaws.com"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DeleteSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteTags",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:CreateLoadBalancer",
          "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:CreateListener",
          "elasticloadbalancing:DeleteListener",
          "elasticloadbalancing:ModifyLoadBalancerAttributes",
          "elasticloadbalancing:SetIpAddressType",
          "elasticloadbalancing:SetSecurityGroups",
          "elasticloadbalancing:SetSubnets",
          "elasticloadbalancing:DeleteLoadBalancer",
          "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes",
          "elasticloadbalancing:DeleteTargetGroup",
          "elasticloadbalancing:RegisterTargets",
          "elasticloadbalancing:DeregisterTargets",
          "elasticloadbalancing:AddTags",
          "elasticloadbalancing:RemoveTags",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "aws_load_balancer_controller" {
  cluster_name    = aws_eks_cluster.journal.name
  namespace       = "kube-system"
  service_account = "aws-load-balancer-controller"
  role_arn        = aws_iam_role.aws_load_balancer_controller.arn

  depends_on = [
    aws_eks_addon.pod_identity_agent,
    aws_iam_role_policy.aws_load_balancer_controller,
  ]
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.14.0"
  namespace  = "kube-system"
  timeout    = 600
  wait       = true

  values = [yamlencode({
    clusterName  = aws_eks_cluster.journal.name
    region       = var.aws_region
    vpcId        = "vpc-0df814fc7fc2dc6f0"
    replicaCount = 1
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
    enableShield = false
    enableWaf    = false
    enableWafv2  = false
    resources = {
      requests = {
        cpu    = "50m"
        memory = "128Mi"
      }
      limits = {
        cpu    = "250m"
        memory = "256Mi"
      }
    }
  })]

  depends_on = [
    aws_eks_node_group.journal,
    aws_eks_pod_identity_association.aws_load_balancer_controller,
  ]
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "oci://quay.io/jetstack/charts"
  chart            = "cert-manager"
  version          = "v1.21.3"
  namespace        = "cert-manager"
  create_namespace = true
  timeout          = 600
  wait             = true

  values = [yamlencode({
    crds = {
      enabled = true
    }
    prometheus = {
      enabled = false
    }
    replicaCount = 1
    webhook = {
      replicaCount = 1
    }
    cainjector = {
      replicaCount = 1
    }
    resources = {
      requests = {
        cpu    = "25m"
        memory = "64Mi"
      }
      limits = {
        cpu    = "150m"
        memory = "128Mi"
      }
    }
  })]

  depends_on = [aws_eks_node_group.journal]
}

resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = "42.1.3"
  namespace  = "kube-system"
  timeout    = 600
  wait       = true

  values = [yamlencode({
    deployment = {
      replicas = 1
    }
    nodeSelector = {
      "topology.kubernetes.io/zone" = data.aws_subnet.journal_api_ingress.availability_zone
    }
    ingressClass = {
      enabled        = true
      isDefaultClass = false
      name           = "traefik"
    }
    providers = {
      kubernetesIngress = {
        enabled                   = true
        ingressClass              = "traefik"
        allowExternalNameServices = false
      }
    }
    service = {
      enabled = true
      type    = "LoadBalancer"
      annotations = {
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
        "service.beta.kubernetes.io/aws-load-balancer-subnets"         = "subnet-0fff35569a6bfb846"
        "service.beta.kubernetes.io/aws-load-balancer-eip-allocations" = aws_eip.journal_api_ingress.id
        "service.beta.kubernetes.io/aws-load-balancer-attributes"      = "load_balancing.cross_zone.enabled=true"
      }
    }
    resources = {
      requests = {
        cpu    = "50m"
        memory = "64Mi"
      }
      limits = {
        cpu    = "250m"
        memory = "256Mi"
      }
    }
  })]

  depends_on = [
    aws_eks_node_group.journal,
    helm_release.aws_load_balancer_controller,
  ]
}
