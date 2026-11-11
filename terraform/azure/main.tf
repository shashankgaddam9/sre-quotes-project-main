# Terraform = "infrastructure as code". You describe what you want here, run
# `terraform apply`, and Azure builds it. `terraform destroy` deletes all of it.
#
# What gets created (all inside ONE resource group, so it's easy to see and delete):
#   1. A network + firewall: website open to everyone; Grafana, Prometheus and SSH only to you
#   2. A small Linux server (VM) that runs the site with Docker Compose
#   3. A Log Analytics workspace + Azure Monitor Agent: every request and error is searchable
#   4. Alerts that email you when the site throws errors or the server goes down

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

locals {
  tags = { project = "sre-quotes" }
}

resource "random_password" "grafana" {
  length  = 20
  special = false
}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

resource "azurerm_resource_group" "rg" {
  name     = "sre-quotes-rg"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# 1. Network + firewall
# ---------------------------------------------------------------------------
resource "azurerm_virtual_network" "vnet" {
  name                = "sre-quotes-vnet"
  address_space       = ["10.10.0.0/16"]
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags
}

resource "azurerm_subnet" "web" {
  name                 = "web"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.vnet.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_public_ip" "web" {
  name                = "sre-quotes-ip"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  allocation_method   = "Static"
  sku                 = "Standard"
  domain_name_label   = "sre-quotes-${random_string.suffix.result}" # gives you a friendly DNS name
  tags                = local.tags
}

# Network Security Group = Azure's firewall
resource "azurerm_network_security_group" "web" {
  name                = "sre-quotes-nsg"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags

  security_rule {
    name                       = "website-http-everyone"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "grafana-only-you"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = var.my_ip_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "prometheus-only-you"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "9090"
    source_address_prefix      = var.my_ip_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "ssh-only-you"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.my_ip_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "web" {
  name                = "sre-quotes-nic"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.web.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.web.id
  }
}

resource "azurerm_network_interface_security_group_association" "web" {
  network_interface_id      = azurerm_network_interface.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}

# ---------------------------------------------------------------------------
# 2. The server
# ---------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine" "web" {
  name                  = "sre-quotes-vm"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  size                  = var.vm_size
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.web.id]
  tags                  = local.tags

  # Log in with your SSH key only — no passwords
  disable_password_authentication = true
  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand(var.ssh_public_key_path))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
    disk_size_gb         = 30
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # Script that runs once on first boot: installs Docker, downloads your repo, starts the site
  custom_data = base64encode(templatefile("${path.module}/cloud-init.sh.tftpl", {
    repo_url         = var.repo_url
    branch           = var.branch
    grafana_password = random_password.grafana.result
  }))

  # Identity the monitoring agent uses to send logs to Log Analytics
  identity {
    type = "SystemAssigned"
  }

  # Enables the Serial Console and boot screenshots in the portal (useful when the VM won't boot)
  boot_diagnostics {}
}

# ---------------------------------------------------------------------------
# 3. Logs: Log Analytics workspace + agent + "collect syslog local0" rule
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "logs" {
  name                = "sre-quotes-logs-${random_string.suffix.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  daily_quota_gb      = 0.5 # safety cap: stop ingesting after 0.5 GB/day
  tags                = local.tags
}

resource "azurerm_virtual_machine_extension" "monitor_agent" {
  name                       = "AzureMonitorLinuxAgent"
  virtual_machine_id         = azurerm_linux_virtual_machine.web.id
  publisher                  = "Microsoft.Azure.Monitor"
  type                       = "AzureMonitorLinuxAgent"
  type_handler_version       = "1.0"
  auto_upgrade_minor_version = true
  automatic_upgrade_enabled  = true
}

resource "azurerm_monitor_data_collection_rule" "app_logs" {
  name                = "sre-quotes-app-logs"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = local.tags

  destinations {
    log_analytics {
      name                  = "workspace"
      workspace_resource_id = azurerm_log_analytics_workspace.logs.id
    }
  }

  data_flow {
    streams      = ["Microsoft-Syslog"]
    destinations = ["workspace"]
  }

  data_sources {
    syslog {
      name           = "container-logs"
      facility_names = ["local0"] # Docker sends container logs here (see docker-compose.azure.yml)
      log_levels     = ["*"]
      streams        = ["Microsoft-Syslog"]
    }
  }
}

resource "azurerm_monitor_data_collection_rule_association" "vm" {
  name                    = "sre-quotes-vm-app-logs"
  target_resource_id      = azurerm_linux_virtual_machine.web.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.app_logs.id
}

# ---------------------------------------------------------------------------
# 4. Alerts (email)
# ---------------------------------------------------------------------------
resource "azurerm_monitor_action_group" "email" {
  name                = "sre-quotes-alerts"
  resource_group_name = azurerm_resource_group.rg.name
  short_name          = "srequotes"
  tags                = local.tags

  email_receiver {
    name                    = "owner"
    email_address           = var.alert_email
    use_common_alert_schema = true
  }
}

# Counts log lines with "status" >= 500 every 5 minutes; emails you at 5 or more
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "errors_5xx" {
  name                  = "sre-quotes-high-5xx"
  description           = "5 or more server errors in 5 minutes. Runbook: docs/runbooks/high-error-rate.md"
  location              = azurerm_resource_group.rg.location
  resource_group_name   = azurerm_resource_group.rg.name
  scopes                = [azurerm_log_analytics_workspace.logs.id]
  severity              = 1
  evaluation_frequency  = "PT5M"
  window_duration       = "PT5M"
  auto_mitigation_enabled = true
  skip_query_validation = true # the Syslog table doesn't exist until the first logs arrive
  tags                  = local.tags

  criteria {
    query                   = <<-KQL
      Syslog
      | where Facility == "local0"
      | extend log = parse_json(extract(@"(\{.*\})", 1, SyslogMessage))
      | where toint(log.status) >= 500
    KQL
    time_aggregation_method = "Count"
    threshold               = 5
    operator                = "GreaterThanOrEqual"

    failing_periods {
      minimum_failing_periods_to_trigger_alert = 1
      number_of_evaluation_periods             = 1
    }
  }

  action {
    action_groups = [azurerm_monitor_action_group.email.id]
  }
}

# Emails you if the VM itself becomes unavailable
resource "azurerm_monitor_metric_alert" "vm_down" {
  name                = "sre-quotes-vm-unavailable"
  description         = "The server is not available"
  resource_group_name = azurerm_resource_group.rg.name
  scopes              = [azurerm_linux_virtual_machine.web.id]
  severity            = 0
  frequency           = "PT1M"
  window_size         = "PT5M"
  tags                = local.tags

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"
    metric_name      = "VmAvailabilityMetric"
    aggregation      = "Average"
    operator         = "LessThan"
    threshold        = 1
  }

  action {
    action_group_id = azurerm_monitor_action_group.email.id
  }
}
