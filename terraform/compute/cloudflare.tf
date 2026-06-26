# Cloudflare DNS — points gairelab.uk at the master's current public IP.
# Uses local.public_ip_address (same value fed to the Ansible inventory), so
# DNS always follows the live IP on every apply / rebuild.
# NOTE: the cloudflare provider is declared in main.tf's required_providers block.

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# Wildcard: every subdomain (hello., grafana., ...) -> master public IP
resource "cloudflare_dns_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*"
  content = local.public_ip_address
  type    = "A"
  ttl     = 300
  proxied = false   # grey cloud / DNS-only — TLS is handled by Traefik + cert-manager
  comment = "gaire-platform master (wildcard); managed by Terraform"
}

# Apex: bare gairelab.uk -> master public IP
resource "cloudflare_dns_record" "apex" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  content = local.public_ip_address
  type    = "A"
  ttl     = 300
  proxied = false
  comment = "gaire-platform master (apex); managed by Terraform"
}
