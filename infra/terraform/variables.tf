variable "aws_region" {
  description = "AWS region containing the existing ECR repository and EKS cluster."
  type        = string
  default     = "us-east-1"
}

variable "github_repository" {
  description = "GitHub owner/repository allowed to publish and deploy the Journal API."
  type        = string
  default     = "ammar0101/journal-starter"
}

variable "github_owner_id" {
  description = "GitHub account ID included in the repository's OIDC subject."
  type        = string
  default     = "92120099"
}

variable "github_repository_id" {
  description = "GitHub repository ID included in the repository's OIDC subject."
  type        = string
  default     = "1333986993"
}
