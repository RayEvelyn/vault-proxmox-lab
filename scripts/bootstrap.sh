#!/usr/bin/env bash
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ $# -eq 3 ]] || { echo 'Usage: bootstrap.sh hostname pinned-image compose-path' >&2; exit 2; }
hostname=$1
image=$2
compose=$3
[[ "$hostname" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]] || exit 2
[[ "$image" =~ ^[a-zA-Z0-9./:@_-]+$ && "$image" != *:latest ]] || exit 2
[[ "$image" =~ ^hashicorp/vault:([0-9]+\.){2}[0-9]+$ || "$image" =~ ^hashicorp/vault@sha256:[a-f0-9]{64}$ ]] || { echo 'Use an exact stable patch tag or SHA256 digest.' >&2; exit 2; }
source /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || { echo 'Requires Ubuntu 24.04.' >&2; exit 2; }
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y docker.io docker-compose-v2 openssl ca-certificates
systemctl enable --now docker
umask 077
[[ "$image" == hashicorp/vault:* || "$image" == hashicorp/vault@sha256:* ]] || exit 2
install -d -m 0755 /srv/vault /srv/vault/config
install -d -o 100 -g 100 -m 0700 /srv/vault/tls /srv/vault/data
cert=/srv/vault/tls/server.crt
key=/srv/vault/tls/server.key
if [[ ! -e "$cert" && ! -e "$key" ]]; then
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 30 \
    -keyout "$key" -out "$cert" -subj "/CN=$hostname" \
    -addext "subjectAltName=DNS:$hostname" -addext 'extendedKeyUsage=serverAuth'
fi
[[ -s "$cert" && -s "$key" ]] || { echo 'Incomplete existing TLS pair; refusing overwrite.' >&2; exit 1; }
chown 100:100 "$cert" "$key"
chmod 0400 "$key"
chmod 0444 "$cert"
# Back up existing config before a deliberate rerun; data and TLS are preserved.
if [[ -f /srv/vault/config/vault.hcl ]]; then
  cp -p /srv/vault/config/vault.hcl "/srv/vault/config/vault.hcl.bak.$(date +%s)"
fi
cat > /srv/vault/config/vault.hcl <<CONFIG
ui = true
api_addr = "https://$hostname:8200"
cluster_addr = "https://$hostname:8201"
disable_mlock = true
storage "raft" {
  path = "/vault/data"
  node_id = "vault-lab-1"
}
listener "tcp" {
  address = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_cert_file = "/vault/tls/server.crt"
  tls_key_file = "/vault/tls/server.key"
  tls_min_version = "tls12"
}
CONFIG
chmod 0644 /srv/vault/config/vault.hcl
for existing in /srv/vault/compose.yaml /srv/vault/.env; do
  if [[ -f "$existing" ]]; then cp -p "$existing" "$existing.bak.$(date +%s)"; fi
done
install -m 0600 "$compose" /srv/vault/compose.yaml
printf 'IMAGE=%s\n' "$image" > /srv/vault/.env
chmod 0600 /srv/vault/.env
cd /srv/vault
docker compose config --quiet
docker compose up -d
printf 'Vault started at https://%s:8200; initialize/unseal manually.\n' "$hostname"
