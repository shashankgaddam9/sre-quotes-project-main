variable "subscription_id" {
  description = "Your Azure subscription ID (find it with: az account show --query id -o tsv)"
  type        = string
}

variable "location" {
  description = "Azure region. Azure for Students only allows some regions — if apply fails with a policy error, pick one listed in the error."
  type        = string
  default     = "eastus"
}

variable "repo_url" {
  description = "HTTPS URL of YOUR GitHub copy of this project (must be public)"
  type        = string
}

variable "branch" {
  description = "Git branch the server runs"
  type        = string
  default     = "main"
}

variable "my_ip_cidr" {
  description = "Your public IP with /32 (curl -s https://checkip.amazonaws.com). Only this IP can open Grafana, Prometheus and SSH."
  type        = string
}

variable "alert_email" {
  description = "Email address for alerts"
  type        = string
}

variable "ssh_public_key_path" {
  description = "Your SSH public key (create one with: ssh-keygen -t ed25519)"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "vm_size" {
  description = "Server size. Standard_B1s is the cheapest; use Standard_B1ms or Standard_B2s if the site feels slow."
  type        = string
  default     = "Standard_B1s"
}
