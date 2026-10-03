terraform {
  required_version = ">= 1.6, < 2.0"
  required_providers {
    proxmox = { source = "bpg/proxmox", version = "0.115.0" }
  }
}
# PROXMOX_VE_ENDPOINT and PROXMOX_VE_API_TOKEN come from your environment.
# Trust the Proxmox CA using the system trust store; do not disable verification.
provider "proxmox" {}

resource "proxmox_virtual_environment_vm" "lab" {
  name      = var.vm_name
  node_name = var.node_name
  vm_id     = var.vm_id
  clone {
    vm_id        = var.template_id
    full         = true
    datastore_id = var.datastore_id
  }
  cpu { cores = var.cores }
  memory { dedicated = var.memory_mb }
  agent { enabled = true }
  network_device { bridge = var.bridge }
  initialization {
    datastore_id = var.datastore_id
    ip_config {
      ipv4 {
        address = var.ip_cidr
        gateway = var.gateway
      }
    }
    dns { servers = var.dns_servers }
    user_account {
      username = "ubuntu"
      keys     = [trimspace(file(var.ssh_public_key_path))]
    }
  }
}
output "ssh_host" { value = split("/", var.ip_cidr)[0] }
