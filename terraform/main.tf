terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    force_path_style            = true
  }
}

variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "public_key" {
  description = "SSH public key content"
  type        = string
}

variable "pvt_key" {
  description = "Path to SSH private key"
  type        = string
  default     = "~/.ssh/id_rsa"
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "nyc3"
}

variable "droplet_size" {
  description = "Droplet size slug"
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "app_name" {
  description = "Application name"
  type        = string
  default     = "python"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "digitalocantest1"
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "appdb"
}

variable "db_user" {
  description = "Database user"
  type        = string
  default     = "appuser"
}

variable "db_password" {
  description = "Database password"
  type        = string
  sensitive   = true
  default     = "changeme"
}

variable "secret_key" {
  description = "Application secret key"
  type        = string
  sensitive   = true
  default     = "changeme-secret"
}

variable "allowed_hosts" {
  description = "Allowed hosts"
  type        = string
  default     = "*"
}

variable "debug" {
  description = "Debug mode"
  type        = string
  default     = "false"
}

locals {
  app_slug = lower(replace(replace(var.app_name, "_", "-"), " ", "-"))
  proj_slug = lower(replace(replace(var.project_name, "_", "-"), " ", "-"))
  name_prefix = "${local.proj_slug}-${local.app_slug}"
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_ssh_key" "app_key" {
  name       = "${local.name_prefix}-key"
  public_key = var.public_key

  lifecycle {
    ignore_changes = [public_key]
  }
}

resource "digitalocean_droplet" "app" {
  name     = "${local.name_prefix}-droplet"
  image    = "ubuntu-22-04-x64"
  region   = var.region
  size     = var.droplet_size
  ssh_keys = [digitalocean_ssh_key.app_key.fingerprint]

  tags = [local.proj_slug, local.app_slug]
}

resource "digitalocean_firewall" "app_fw" {
  name        = "${local.name_prefix}-fw"
  droplet_ids = [digitalocean_droplet.app.id]

  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }

  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "local_file" "ansible_inventory" {
  content = templatefile("${path.module}/../ansible/inventory.tpl", {
    droplet_ip = digitalocean_droplet.app.ipv4_address
    pvt_key    = var.pvt_key
  })
  filename = "${path.module}/../ansible/inventory.ini"
}

resource "null_resource" "ansible_provision" {
  depends_on = [
    digitalocean_droplet.app,
    digitalocean_firewall.app_fw,
    local_file.ansible_inventory,
  ]

  triggers = {
    droplet_id = digitalocean_droplet.app.id
  }

  connection {
    type        = "ssh"
    user        = "root"
    host        = digitalocean_droplet.app.ipv4_address
    private_key = file(var.pvt_key)
    timeout     = "5m"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait || true",
      "echo 'Droplet is ready'",
    ]
  }

  provisioner "local-exec" {
    command = <<-EOT
      sleep 15
      ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
        -i ${path.module}/../ansible/inventory.ini \
        ${path.module}/../ansible/playbook.yml \
        --private-key=${var.pvt_key} \
        -u root \
        -e "app_dir=/opt/app" \
        -e "app_name=${var.app_name}" \
        -e "project_name=${var.project_name}" \
        -e "db_name=${var.db_name}" \
        -e "db_user=${var.db_user}" \
        -e "db_password=${var.db_password}" \
        -e "secret_key=${var.secret_key}" \
        -e "allowed_hosts=${var.allowed_hosts}" \
        -e "debug=${var.debug}" \
        -e "droplet_ip=${digitalocean_droplet.app.ipv4_address}" \
        -e "python_version=3.11" \
        -e "app_entrypoint=app.main:app" \
        -e "app_port=8000"
    EOT
  }
}

output "droplet_ip" {
  description = "Public IP address of the droplet"
  value       = digitalocean_droplet.app.ipv4_address
}

output "droplet_id" {
  description = "ID of the droplet"
  value       = digitalocean_droplet.app.id
}

output "app_url" {
  description = "Application URL"
  value       = "http://${digitalocean_droplet.app.ipv4_address}"
}

output "health_url" {
  description = "Health check URL"
  value       = "http://${digitalocean_droplet.app.ipv4_address}/health"
}