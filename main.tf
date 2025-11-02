variable "hcloud_token" {
  type      = string
  sensitive = true
}

variable "client_name" {
  type    = string
  default = "admin"
}

variable "vpc_cidr" {
  type    = string
  default = "10.3.0.0/16"
}

variable "vpc_name" {
  type    = string
  default = "vpc"
}

# versions.tf
terraform {
  required_providers {
    hcloud = {
      source  = "opentofu/hcloud"
      version = "1.54.0"
    }
  }
}

provider "hcloud" {
  token = var.hcloud_token
}

resource "hcloud_network" "main" {
  name     = var.vpc_name
  ip_range = var.vpc_cidr
}

resource "hcloud_network_subnet" "wireguard" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = cidrsubnet(var.vpc_cidr, 8, 1) 
}

data "hcloud_ssh_keys" "all" {
}

resource "hcloud_server" "wireguard" {
  name        = "wireguard"
  image       = "ubuntu-24.04"
  server_type = "cx23"
  location    = "hel1"
  ssh_keys    = data.hcloud_ssh_keys.all.ssh_keys[*].id

  public_net {
    ipv4_enabled = true
    ipv6_enabled = false
  }

  user_data = <<-EOT
#cloud-config
package_update: true
packages:
  - wireguard
  - iptables-persistent
  - curl

write_files:
  - path: /etc/wireguard/setup.sh
    permissions: '0700'
    content: |
      #!/bin/bash
      cd /etc/wireguard
      umask 077
      wg genkey | tee server_private.key | wg pubkey > server_public.key
      wg genkey | tee client_private.key | wg pubkey > client_public.key
      
      SERVER_PUBLIC_KEY=$(cat server_public.key)
      CLIENT_PRIVATE_KEY=$(cat client_private.key)
      SERVER_IP=$(curl -s ifconfig.me)
      
      cat > wg0.conf << WGEOF
      [Interface]
      PrivateKey = $(cat server_private.key)
      Address = 10.0.1.1/24
      ListenPort = 51820
      PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
      PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
      
      [Peer]
      PublicKey = $(cat client_public.key)
      AllowedIPs = 10.0.1.2/32
      WGEOF
      
      cat > client.conf << CLIENTEOF
      [Interface]
      PrivateKey = $CLIENT_PRIVATE_KEY
      Address = 10.0.1.2/24
      DNS = 1.1.1.1
      
      [Peer]
      PublicKey = $SERVER_PUBLIC_KEY
      Endpoint = $SERVER_IP:51820
      AllowedIPs = 0.0.0.0/0
      CLIENTEOF
      
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
      sysctl -p
      systemctl enable wg-quick@wg0
      systemctl start wg-quick@wg0

runcmd:
  - /etc/wireguard/setup.sh

final_message: "WireGuard setup completed successfully!"
EOT
}

resource "hcloud_server_network" "wireguard" {
  server_id  = hcloud_server.wireguard.id
  subnet_id  = hcloud_network_subnet.wireguard.id
}

output "server_ip" {
  value = hcloud_server.wireguard.ipv4_address
}

output "connect_command" {
  value = "ssh root@${hcloud_server.wireguard.ipv4_address} 'cat /etc/wireguard/client.conf'"
}

output "vpc_network_name" {
  value = hcloud_network.main.name
}

output "ssh_key_names" {
  value = [for key in data.hcloud_ssh_keys.all.ssh_keys : key.name]
}