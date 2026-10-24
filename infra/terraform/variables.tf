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
