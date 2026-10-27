# Cloud Deployment Guide

This guide documents the Journal API's AWS deployment and the steps needed to
reproduce its CI/CD workflow. The EKS cluster is created with `eksctl`, and
Terraform provisions the application-specific AWS resources and Kubernetes
add-ons. The cluster, database, NAT gateway, and public load balancer incur
ongoing charges; review AWS pricing and clean them up when no longer needed.
See the [Terraform notes](../infra/terraform/README.md) for infrastructure
details.

## Architecture

```text
GitHub Actions
  test: Ruff + Pyright + pytest with temporary PostgreSQL
  build: GitHub OIDC -> build IAM role -> Docker image -> ECR
  deploy: GitHub OIDC -> deploy IAM role -> kubectl -> EKS
                                              |
EKS: API Deployment -> ClusterIP Service -> Traefik Ingress -> NLB/EIP
          |                                      |
          +-> Secrets Manager                    +-> cert-manager / Let's Encrypt
          +-> private RDS PostgreSQL
```

The deploy workflow runs the database bootstrap Job before applying the API
Deployment and HTTPS Ingress. Kubernetes Pod Identity lets the API and
bootstrap Job retrieve only their required Secrets Manager values. GitHub
Actions uses short-lived AWS credentials via OIDC; do not store AWS access
keys in GitHub.

## Prerequisites

- An AWS account with permissions to create EKS, networking, IAM, RDS, ECR,
  and S3 resources in `us-east-1`.
- AWS CLI configured locally for that account, with permissions to manage the
  resources in the Terraform configuration.
- Terraform 1.10 or newer and `kubectl`.
- Administrator access to the EKS cluster for the one-time deployer RBAC
  setup.
- Admin access to the GitHub repository's Actions variables and environments.

Confirm the AWS identity before running Terraform:

```powershell
aws sts get-caller-identity
```

## 1. Create EKS and prepare Terraform state

Create the cluster and managed node group with `eksctl`:

```powershell
eksctl create cluster --name journal-cluster --region us-east-1 --version 1.34 `
  --nodes 9 --nodes-min 9 --nodes-max 9 --node-type t3.micro `
  --node-volume-size 20 --managed --node-private-networking `
  --vpc-nat-mode Single --with-oidc
```

Then initialize Terraform from `infra/terraform`:

```powershell
Set-Location infra\terraform
terraform init -reconfigure
```

The S3 backend is configured in `main.tf`. Terraform creates the ECR
repository, database, secret, IAM roles, and Kubernetes add-ons, while reading
the EKS cluster's VPC and subnet configuration.

Terraform also looks up `journal-api/runtime` by name. If the secret does not
exist, create it with valid JSON before planning. It can contain placeholders
until the database endpoint is available; update it with real values before
the first deployment. See the required keys below.

Once the existing resources are represented in state and the secret exists,
review the plan:

```powershell
terraform plan
```

Review the plan for unexpected replacement or deletion, especially for EKS,
the node group, RDS, and networking. These resources can incur charges. Only
after reviewing the plan and confirming it is safe, apply the intended
infrastructure changes:

```powershell
terraform apply
```

After Terraform creates or identifies the database, populate the secret with
the application settings below. In `DATABASE_URL`, use the same password as
`APP_DB_PASSWORD`. Use the AWS Secrets Manager console or AWS CLI with a local
JSON file kept outside version control.

| Secret key | Purpose |
|---|---|
| `DATABASE_URL` | PostgreSQL URL for the `journal_api` application role and `career_journal` database. |
| `APP_DB_PASSWORD` | Password for the `journal_api` database role; the bootstrap Job creates or updates this role. |
| `OPENAI_API_KEY` | Provider credential used by the analysis endpoint. |
| `OPENAI_BASE_URL` | Provider's OpenAI-compatible Responses API endpoint. |
| `OPENAI_MODEL` | Provider model ID or deployment name. |

For example, the secret JSON has this shape (replace every placeholder; these
values are examples only):

```json
{
  "DATABASE_URL": "postgresql://journal_api:REPLACE_ME@DB_ENDPOINT:5432/career_journal",
  "APP_DB_PASSWORD": "REPLACE_ME",
  "OPENAI_API_KEY": "REPLACE_ME",
  "OPENAI_BASE_URL": "https://YOUR_PROVIDER/v1/",
  "OPENAI_MODEL": "YOUR_MODEL_OR_DEPLOYMENT"
}
```

Never commit this JSON, `.env`, credentials, or generated Terraform state.
The current API analysis feature requires a provider endpoint that supports
the OpenAI Responses API. The GitHub deployment smoke test deliberately does
not call analysis; it verifies the version endpoint and entry create/delete.

## 2. Configure GitHub Actions

Read the Terraform outputs from `infra/terraform`:

```powershell
terraform output -raw github_actions_build_role_arn
terraform output -raw github_actions_deploy_role_arn
terraform output -raw journal_api_production_url
```

In the GitHub repository, add these **Actions variables** under
**Settings → Secrets and variables → Actions → Variables**:

| Variable | Value |
|---|---|
| `AWS_BUILD_ROLE_ARN` | `github_actions_build_role_arn` Terraform output |
| `AWS_DEPLOY_ROLE_ARN` | `github_actions_deploy_role_arn` Terraform output |
| `PRODUCTION_API_URL` | `journal_api_production_url` Terraform output |
| `PRODUCTION_API_HOST` | Hostname portion of `journal_api_production_url`, without `https://` |

The deploy job uses the GitHub environment named `production`; the Terraform
deploy role trust policy expects that environment. The build and deploy IAM
roles trust the configured repository and branch/environment through OIDC.
For a different GitHub repository, update `github_repository`,
`github_owner_id`, and `github_repository_id` in Terraform to match its
customized OIDC subject before applying.

Enable GitHub Actions for the repository if GitHub prompts you to do so.

## 3. Configure Kubernetes deployment access

After Terraform has created the GitHub deploy access entry, connect `kubectl`
to the cluster using an administrator identity:

```powershell
aws eks update-kubeconfig --name journal-cluster --region us-east-1
kubectl config current-context
kubectl apply -f infra\kubernetes\deploy-rbac.yaml
```

The manifest binds the EKS access-entry group `journal-api-deployer` to a
Role in namespace `default`. It grants the deploy workflow the Kubernetes
permissions needed for its Job, Deployment, Service, Ingress, and cert-manager
resources; it is not cluster-wide. This is a one-time cluster-admin action
unless the RoleBinding is removed or the namespace/group changes.

## 4. Deploy and verify

Push a change to `main` to start the workflow. Pull requests run only `test`;
the `build` and `deploy` jobs are restricted to pushes to `main`.

The workflow performs these steps in order:

1. Run Ruff, Pyright, and pytest using a temporary PostgreSQL service.
2. Build the Docker image with the commit SHA and push it to ECR.
3. Use the commit-tagged image to run the database bootstrap Job.
4. Apply the API Deployment, Service, and Ingress; wait for the rollout and
   cert-manager TLS certificate.
5. Verify `/version` returns the pushed commit SHA, then create and delete a
   smoke-test entry through the public HTTPS endpoint.

Check the Actions run for green `test`, `build`, and `deploy` jobs. The public
API URL is shown by:

```powershell
Set-Location infra\terraform
terraform output -raw journal_api_production_url
```

You can manually verify the deployed commit:

```powershell
curl.exe --fail --silent --show-error https://YOUR_HOST/version
```

Check the Kubernetes rollout and certificate:

```powershell
kubectl rollout status deployment/journal-api -n default
kubectl get issuer,certificate,ingress -n default
```

The certificate should be `READY=True`, and the Ingress should have the
configured public hostname.

## Troubleshooting

- **AWS OIDC assume-role fails:** Check that the four GitHub variables match
  Terraform outputs and the deploy job uses the `production` environment.
  Confirm the Terraform OIDC subject IDs/repository match the GitHub
  repository.
- **Database bootstrap times out:** Verify the runtime secret's database URL,
  `APP_DB_PASSWORD`, RDS endpoint, and that the RDS security group allows
  PostgreSQL from the EKS worker-node security group.
- **Deploy gets Kubernetes `Forbidden`:** Confirm the access entry maps to
  `journal-api-deployer` and that the namespace Role and RoleBinding were
  applied by a cluster administrator.
- **Certificate does not become Ready:** Inspect
  `kubectl describe certificate journal-api-tls -n default` and
  `kubectl describe issuer letsencrypt-production -n default`. Check that the
  public hostname matches the Ingress and that the HTTP-01 challenge is
  reachable.
- **HTTPS version check fails:** Check the Deployment, Service, Ingress,
  certificate, and Traefik/NLB target health before rerunning deployment.

## Operational and cost notes

This setup is a learning deployment, not a highly available production
architecture. It uses a single-AZ public ingress and a single-AZ RDS instance.
The EKS nodes, load balancer, public IPv4 address, NAT gateway, RDS, CloudWatch,
and other AWS resources may incur ongoing charges. Review AWS billing and
restrict the EKS public API endpoint CIDR before using this setup for a
production workload.
