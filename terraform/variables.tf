variable "tenancy_ocid" {
  description = "OCID of the Oracle Cloud tenancy (root account)."
  type        = string
}

variable "user_ocid" {
  description = "OCID of the user that owns the API key."
  type        = string
}

variable "fingerprint" {
  description = "Fingerprint of the API key registered in the OCI console."
  type        = string
}

variable "private_key_path" {
  description = "Local path to the API key's .pem private key."
  type        = string
  default     = "~/.oci/oci_api_key.pem"
}

variable "region" {
  description = "OCI region to deploy into. Always Free only works in the tenancy home region."
  type        = string
  default     = "sa-saopaulo-1"

  validation {
    condition     = var.region == "sa-saopaulo-1"
    error_message = "This tenancy's home region is sa-saopaulo-1. Always Free resources only exist there."
  }
}

variable "compartment_ocid" {
  description = "Compartment OCID. Leave empty to use the tenancy root."
  type        = string
  default     = ""
}

variable "ssh_public_key" {
  description = "Contents of the SSH public key granted access to the VM."
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR range allowed to reach SSH. Prefer YOUR_IP/32 over 0.0.0.0/0."
  type        = string
  default     = "0.0.0.0/0"
}

variable "instance_name" {
  description = "VM display name in the Oracle console."
  type        = string
  default     = "pterodactyl"
}

variable "instance_ocpus" {
  description = "ARM cores (Ampere A1). Always Free cap: 4."
  type        = number
  default     = 2

  validation {
    condition     = var.instance_ocpus >= 1 && var.instance_ocpus <= 4
    error_message = "Always Free allows at most 4 Ampere A1 OCPUs in total. More than that is billed."
  }
}

variable "instance_memory_gb" {
  description = "Memory in GB. Always Free cap: 24. The panel stack itself needs about 1.5."
  type        = number
  default     = 12

  validation {
    condition     = var.instance_memory_gb >= 1 && var.instance_memory_gb <= 24
    error_message = "Always Free allows at most 24 GB of Ampere A1 memory in total. More than that is billed."
  }
}

variable "boot_volume_gb" {
  description = "Disk size in GB. Always Free grants 200 GB total; minimum per VM is 50."
  type        = number
  default     = 100

  validation {
    condition     = var.boot_volume_gb >= 50 && var.boot_volume_gb <= 200
    error_message = "Always Free block storage is 200 GB in total (boot volumes included). More than that is billed."
  }
}

variable "ubuntu_version" {
  description = "Ubuntu release used as the base image."
  type        = string
  default     = "24.04"
}

variable "availability_domain_index" {
  description = "Availability domain to use (0, 1, 2...). Only meaningful in multi-AD regions."
  type        = number
  default     = 0
}

variable "timezone" {
  description = "Timezone used by the panel and the game containers."
  type        = string
  default     = "America/Sao_Paulo"
}

variable "panel_domain" {
  description = <<-EOT
    Domain pointing at the VM, without subdomain (e.g. example.com). The panel is
    served at panel.<domain> and the daemon at node.<domain>. Leave empty to use
    sslip.io, which resolves any <ip>-based name straight to the instance IP and
    needs no DNS setup at all.
  EOT
  type        = string
  default     = ""
}

variable "panel_version" {
  description = <<-EOT
    Pterodactyl version, as a tag of ghcr.io/blueprintframework/blueprint (the
    official panel image with the Blueprint extension framework added). Only
    move it forward: the database migrates with the panel and cannot go back.
  EOT
  type        = string
  default     = "v1.15.1"

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.panel_version))
    error_message = "Use a release tag such as v1.15.1. A floating tag like latest could jump the panel ahead of its database."
  }
}

variable "panel_admin_email" {
  description = "Email of the panel's first admin user. Also used for Let's Encrypt."
  type        = string
}

variable "panel_admin_username" {
  description = "Username of the panel's first admin user."
  type        = string
  default     = "admin"
}

variable "panel_admin_first_name" {
  description = "First name of the panel's first admin user."
  type        = string
  default     = "Server"
}

variable "panel_admin_last_name" {
  description = "Last name of the panel's first admin user."
  type        = string
  default     = "Admin"
}

variable "panel_admin_password" {
  description = "Password of the panel's first admin user. Empty generates a strong one."
  type        = string
  default     = ""
  sensitive   = true
}

variable "game_port_min" {
  description = "First port of the range Wings hands out to game servers."
  type        = number
  default     = 25565
}

variable "game_port_max" {
  description = "Last port of the range Wings hands out to game servers."
  type        = number
  default     = 25585
}

variable "budget_alert_email" {
  description = "Email notified when spend reaches the budget. Required: the budget is the safety net."
  type        = string

  validation {
    condition     = can(regex("^[^@ ]+@[^@ ]+$", var.budget_alert_email))
    error_message = "Set budget_alert_email so the 1 USD spend alert is always created."
  }
}

variable "budget_amount" {
  description = "Monthly budget in USD. Kept at 1 on purpose: this deployment should never be billed."
  type        = number
  default     = 1

  validation {
    condition     = var.budget_amount > 0 && var.budget_amount <= 5
    error_message = "Keep the budget tiny (1 to 5 USD) so any spend at all triggers the alert."
  }
}
