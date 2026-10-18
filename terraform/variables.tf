variable "region" {
  description = "Main AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "project" {
  description = "Project name, first part of every resource name"
  type        = string
  default     = "cloudops"
}

variable "environment" {
  description = "Environment name, second part of every resource name. Must differ from the console-built 'dev' system so both can run side by side."
  type        = string
  default     = "prod"
}

variable "alert_email" {
  description = "Email address that receives P1 escalations. Set in terraform.tfvars (not in Git)."
  type        = string
}

variable "log_retention_days" {
  description = "How long every log group keeps its logs"
  type        = number
  default     = 30
}

variable "escalation_wait_seconds" {
  description = "How long a P1 may stay unacknowledged before the email escalation (decision 8: 5 minutes)"
  type        = number
  default     = 300
}
