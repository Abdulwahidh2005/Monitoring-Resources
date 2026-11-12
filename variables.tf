variable "subscription_id" {
  description = "Azure subscription ID. If null, the AzureRM provider uses the active Azure CLI subscription."
  type        = string
  default     = null
  nullable    = true
}

variable "location" {
  description = "Azure region for the VM, network, and monitoring resources."
  type        = string
  default     = "uksouth"
}

variable "vm_resource_group_name" {
  description = "Name of the resource group to create for the VM and network."
  type        = string
  default     = "VMalert"
}

variable "vms" {
  description = "Explicit list of VMs to create and monitor. Only VMs listed here are included; add a VM here to reuse the workspace and OS-specific DCR and create its alerts."
  type = map(object({
    os   = string
    size = string
  }))
  default = {
    linux-vm = {
      os   = "Linux"
      size = "Standard_B1s"
    }
    windows-vm = {
      os   = "Windows"
      size = "Standard_B2s"
    }
  }

  validation {
    condition     = length(var.vms) > 0 && alltrue([for vm in values(var.vms) : contains(["Linux", "Windows"], vm.os)])
    error_message = "vms must contain at least one VM, and each VM os must be Linux or Windows."
  }
}

variable "admin_username" {
  description = "Administrator username for the new VM."
  type        = string
  default     = "linuxadmin"
}

variable "admin_password" {
  description = "Administrator password required for VM access. Use at least 12 characters."
  type        = string
  sensitive   = true
  default     = null
  nullable    = true
}

variable "admin_source_cidr" {
  description = "Source CIDR allowed to SSH/RDP to the VMs. Use * to allow access from anywhere."
  type        = string
  default     = "*"
}

variable "vnet_address_space" {
  description = "Address space for the new virtual network."
  type        = list(string)
  default     = ["10.42.0.0/24"]
}

variable "subnet_address_prefixes" {
  description = "Subnet prefixes for the VM NIC. The subnet must be contained in the VNet address space."
  type        = list(string)
  default     = ["10.42.0.0/24"]
}

variable "log_analytics_workspace_name" {
  description = "Name of the Log Analytics workspace."
  type        = string
  default     = "la-customvm-uks-001"
}

variable "log_analytics_retention_days" {
  description = "Log Analytics data retention period in days."
  type        = number
  default     = 30

  validation {
    condition     = var.log_analytics_retention_days >= 30 && var.log_analytics_retention_days <= 730
    error_message = "Log Analytics retention must be between 30 and 730 days."
  }
}

variable "dcr_name" {
  description = "Base name for the OS-specific Data Collection Rules."
  type        = string
  default     = "dcr-customvm-uks-001"
}

variable "cpu_alert_name" {
  description = "Name of the resource-group-scoped high CPU metric alert."
  type        = string
  default     = "customvm-high-cpu"
}

variable "availability_alert_name" {
  description = "Name prefix for per-VM availability / missing heartbeat log alerts."
  type        = string
  default     = "vm-missing-heartbeat"
}

variable "guest_errors_alert_name" {
  description = "Name of the guest OS system/application or Syslog error alert."
  type        = string
  default     = "customvm-guest-errors"
}

variable "low_memory_alert_name" {
  description = "Name of the low available memory alert."
  type        = string
  default     = "customvm-low-memory"
}

variable "low_disk_alert_name" {
  description = "Name of the low disk free space alert."
  type        = string
  default     = "customvm-low-disk-space"
}

variable "cpu_threshold_percent" {
  description = "Average CPU percentage above which the CPU alert fires."
  type        = number
  default     = 80

  validation {
    condition     = var.cpu_threshold_percent > 0 && var.cpu_threshold_percent <= 100
    error_message = "cpu_threshold_percent must be greater than 0 and no greater than 100."
  }
}

variable "disk_free_space_threshold_percent" {
  description = "Disk free percentage below which the low-disk alert fires."
  type        = number
  default     = 10

  validation {
    condition     = var.disk_free_space_threshold_percent > 0 && var.disk_free_space_threshold_percent <= 100
    error_message = "disk_free_space_threshold_percent must be greater than 0 and no greater than 100."
  }
}

variable "memory_used_percent_threshold" {
  description = "Linux memory-used percentage above which the low-memory alert fires."
  type        = number
  default     = 90

  validation {
    condition     = var.memory_used_percent_threshold > 0 && var.memory_used_percent_threshold <= 100
    error_message = "memory_used_percent_threshold must be greater than 0 and no greater than 100."
  }
}

variable "available_memory_mb_threshold" {
  description = "Windows available-memory threshold in megabytes."
  type        = number
  default     = 500

  validation {
    condition     = var.available_memory_mb_threshold > 0
    error_message = "available_memory_mb_threshold must be greater than 0."
  }
}

variable "evaluation_frequency" {
  description = "CPU metric alert evaluation frequency in ISO 8601 duration format."
  type        = string
  default     = "PT1M"

  validation {
    condition     = contains(["PT1M", "PT5M", "PT15M", "PT30M", "PT1H"], var.evaluation_frequency)
    error_message = "evaluation_frequency must be PT1M, PT5M, PT15M, PT30M, or PT1H."
  }
}

variable "log_alert_evaluation_frequency" {
  description = "Scheduled log alert evaluation frequency in ISO 8601 duration format."
  type        = string
  default     = "PT5M"

  validation {
    condition     = contains(["PT1M", "PT5M", "PT10M", "PT15M", "PT30M", "PT45M", "PT1H"], var.log_alert_evaluation_frequency)
    error_message = "log_alert_evaluation_frequency must be a supported Azure Monitor frequency from PT1M through PT1H."
  }
}

variable "tags" {
  description = "Tags applied to created Azure resources."
  type        = map(string)
  default     = {}
}
