variable "region" {
  description = "AWS region to build in"
  type        = string
  default     = "us-east-1"
}

variable "repo_url" {
  description = "HTTPS URL of YOUR GitHub copy of this project (must be public), e.g. https://github.com/you/sre-quotes-project.git"
  type        = string
}

variable "branch" {
  description = "Git branch the server runs"
  type        = string
  default     = "main"
}

variable "my_ip_cidr" {
  description = "Your public IP with /32 (find it with: curl -s https://checkip.amazonaws.com). Only this IP can open Grafana/Prometheus."
  type        = string
}

variable "alert_email" {
  description = "Email address for alarms and budget warnings"
  type        = string
}

variable "instance_type" {
  description = "Server size. t3.micro is the cheapest; use t3.small if the site feels slow."
  type        = string
  default     = "t3.micro"
}

variable "monthly_budget_usd" {
  description = "Email me when monthly AWS spend (excluding credits) passes 50% of this, or is forecast to pass 100%"
  type        = number
  default     = 10
}
