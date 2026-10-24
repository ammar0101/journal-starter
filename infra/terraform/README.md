# Import existing Journal API infrastructure

This Terraform configuration describes the existing `journal-api` ECR
repository, `journal-cluster` EKS cluster, and its managed node group. It does
not create the VPC, subnets, security groups, or IAM roles; it looks up the two
EKS roles by name and references the existing network resources.

The EKS API endpoint currently permits connections from `0.0.0.0/0`. This
configuration preserves the current setting so an import does not silently
change access. Restrict `public_access_cidrs` to your trusted IP before making
any future apply.

## PostgreSQL database

The configuration provisions a single-AZ PostgreSQL 16.13 `db.t4g.micro`
instance with 20 GiB gp3 storage, encryption, one day of automated backups,
deletion protection, and an RDS-managed master password in AWS Secrets Manager.
It is private in the two existing private subnets. Its security group allows
PostgreSQL only from the EKS worker-node security group. The password is not
written into Terraform configuration.

RDS, Secrets Manager, the existing NAT gateway, EKS, and related AWS resources
can incur charges. The database is not guaranteed to be covered by Free Tier or
credits. Check AWS Billing and the Pricing Calculator. The Terraform outputs
provide the DB endpoint and Secrets Manager ARN.

## Public HTTPS and GitHub Actions

The configuration increases the existing `t3.micro` node group to nine nodes
to make room for the AWS Load Balancer Controller, Traefik, cert-manager, the
API, and Kubernetes system pods. It keeps the existing instance type, but the
additional worker nodes are billable. It also allocates one static public IPv4
address and provisions a single-AZ internet-facing Network Load Balancer.
These resources incur ongoing charges and are not guaranteed to be Free Tier
eligible. The single-AZ endpoint is intentionally the least-complex option for
this project, not a highly available production design.
The Network Load Balancer and Traefik run in the same enabled availability
zone so its single static-IP endpoint can reach the Traefik pod.

Traefik serves the Kubernetes Ingress. cert-manager obtains and renews a
Let's Encrypt certificate for the load balancer's address-based
`<public-ip>.sslip.io` hostname. The public URL is available after Terraform
applies the networking and Helm releases:

```powershell
terraform output -raw journal_api_production_url
terraform output -raw github_actions_build_role_arn
terraform output -raw github_actions_deploy_role_arn
```

Set these repository Actions variables in GitHub:

| Variable | Value |
| --- | --- |
| `AWS_BUILD_ROLE_ARN` | Terraform output `github_actions_build_role_arn` |
| `AWS_DEPLOY_ROLE_ARN` | Terraform output `github_actions_deploy_role_arn` |
| `PRODUCTION_API_URL` | Terraform output `journal_api_production_url` |
| `PRODUCTION_API_HOST` | The hostname portion of `journal_api_production_url` |

The build role can push images only to the `journal-api` ECR repository. The
deploy role can describe the cluster and has the EKS edit policy scoped to
the `default` namespace so it can manage application resources. A
namespace-scoped Kubernetes Role grants the additional cert-manager
custom-resource permissions required by the workflow. Both roles trust only
GitHub Actions for the configured
repository's `main` branch through OIDC. The trust policy matches the
owner/repository IDs included in this repository's customized GitHub OIDC
subject; update `github_owner_id` or `github_repository_id` if applying this
configuration to a different GitHub repository. No long-lived AWS keys belong
in GitHub.

The CI/CD workflow runs one `test` job for pushes and pull requests. On pushes
to `main`, `build` publishes an image tagged with the commit SHA and `deploy`
runs the database bootstrap Job, applies the Deployment and HTTPS Ingress,
waits for the rollout and certificate, then smoke-tests `/version` and entry
creation/deletion over HTTPS.

Before the first push to `main`, apply Terraform, wait for the ingress
controller and certificate to become ready, and set the four repository
variables above. After Terraform creates the deploy access entry, apply
`../kubernetes/deploy-rbac.yaml` once using a cluster administrator context.
The workflow also requires the API configuration secret already provisioned
in AWS Secrets Manager.

## Remote state and importing existing resources

The remote state bucket is `journal-api-tfstate-098567766079-f876924a` in
`us-east-1`. It has versioning, default AES-256 encryption, S3 public-access
blocking, bucket-owner-enforced object ownership, and a bucket policy that
requires HTTPS. The S3 backend uses native lock files, so use Terraform 1.10 or
newer.

Run these commands from this directory with AWS credentials configured for
account `098567766079`:

```powershell
terraform init -reconfigure
terraform import aws_ecr_repository.journal_api journal-api
terraform import aws_eks_cluster.journal journal-cluster
terraform import aws_eks_node_group.journal journal-cluster:ng-814ac263
terraform plan
```

`terraform import` reads the existing resources and records them in remote
Terraform state; it does not create or update AWS resources. Review the plan
carefully. Do not run `terraform apply` until every proposed change is
understood and approved. In particular, this cluster and node group were
created by `eksctl`/CloudFormation, so managing the same resources from
Terraform requires care to avoid conflicting changes.

Terraform state is ignored by Git because it can contain sensitive resource
details. AWS access to the state bucket should remain limited to the people and
automation that need to manage this infrastructure. S3 storage, requests, and
versioned state copies may incur small AWS charges.
