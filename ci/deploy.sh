#!/usr/bin/env bash
set -euo pipefail
# Trusted manual deployment only. Never enable on public PR execution hosts.
umask 077
# GitLab file-type variables arrive as paths; GitHub secrets arrive as values.
for name in SSH_PRIVATE_KEY SSH_KNOWN_HOSTS PROXMOX_CA_PEM; do
  file_name="${name}_FILE"
  if [[ -n ${!file_name:-} ]]; then
    [[ -f ${!file_name} && ! -L ${!file_name} ]] || { echo 'Protected CI file input is invalid.' >&2; exit 2; }
    printf -v "$name" '%s' "$(cat -- "${!file_name}")"
    export "${name?}"
  fi
done
[[ ! -e terraform.tfvars.json && ! -e terraform.tfvars ]] || { echo 'Refusing to overwrite local Terraform inputs; use clean CI checkout.' >&2; exit 2; }
: "${TF_STATE_ROOT:?Persistent absolute directory required}"
: "${HOMELAB_STATE_ID:?Platform-prefixed numeric repository ID required}"
: "${HOMELAB_TFVARS_JSON:?Non-secret Terraform inputs required}"
: "${PROXMOX_VE_ENDPOINT:?Provider endpoint required}"
: "${PROXMOX_VE_API_TOKEN:?Provider token secret required}"
: "${SSH_PRIVATE_KEY:?Bootstrap key secret required}"
HOMELAB_ACTION=${HOMELAB_ACTION:-plan}
case "$HOMELAB_ACTION" in plan|provision|deploy) ;; *) echo 'Action must be plan, provision or deploy'; exit 2 ;; esac
if [[ "$HOMELAB_ACTION" == deploy ]]; then
  : "${SSH_KNOWN_HOSTS:?Verified known-host entries required for deploy}"
  : "${LAB_HOSTNAME:?Service DNS hostname required for deploy}"
  : "${IMAGE:?Pinned service image required for deploy}"
fi
[[ "$HOMELAB_STATE_ID" =~ ^(github|gitlab)-[0-9]+$ ]] || exit 2
[[ "$TF_STATE_ROOT" == /* && "$TF_STATE_ROOT" != / ]] || exit 2
[[ -d "$TF_STATE_ROOT" ]] || { echo 'Pre-create protected persistent state directory on the dedicated runner.' >&2; exit 2; }
export TF_STATE_ROOT
python3 - <<'PY'
import os
from pathlib import Path
root=Path(os.environ['TF_STATE_ROOT']).resolve(); checkout=Path.cwd().resolve()
for unsafe in [checkout,Path('/tmp'),Path('/var/tmp'),Path(os.environ.get('RUNNER_TEMP','/tmp'))]:
 if root==unsafe or unsafe in root.parents: raise SystemExit('State directory must be permanent and outside checkout/temp.')
PY
state_dir="$TF_STATE_ROOT/$HOMELAB_STATE_ID"
install -d -m 0700 "$state_dir"
# Serialize deployment invocations on the SAME permanent host.
exec 9>"$state_dir/workflow.lock"
flock -n 9 || { echo 'Another deployment owns this state; retry after review.' >&2; exit 1; }
work=$(mktemp -d)
cleanup() {
  rm -rf -- "$work"
  rm -f -- terraform.tfvars.json
  if [[ -n "${SSH_AGENT_PID:-}" ]]; then ssh-agent -k >/dev/null; fi
}
trap cleanup EXIT
export HOMELAB_SSH_CONFIG="$work/ssh_config"
printf '%s\n' "$SSH_PRIVATE_KEY" > "$work/key"
printf '%s\n' "${SSH_KNOWN_HOSTS:-}" > "$work/known_hosts"
chmod 0600 "$work/key" "$work/known_hosts"
unset SSH_PRIVATE_KEY SSH_KNOWN_HOSTS
cat > "$HOMELAB_SSH_CONFIG" <<CONFIG
Host *
  IdentityFile $work/key
  IdentitiesOnly yes
  UserKnownHostsFile $work/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes
  ConnectTimeout 10
  ServerAliveInterval 15
  ServerAliveCountMax 2
CONFIG
eval "$(ssh-agent -s)" >/dev/null
ssh-add "$work/key" >/dev/null 2>&1
# Terraform cloud-init needs only this derived PUBLIC key, not a committed private key.
ssh-keygen -y -f "$work/key" > "$work/key.pub"
export HOMELAB_PUBLIC_KEY="$work/key.pub"
python3 - <<'PY'
import json,os,re
from pathlib import Path
v=json.loads(os.environ['HOMELAB_TFVARS_JSON'])
if not isinstance(v,dict): raise SystemExit('Terraform input must be an object')
allowed=set()
for f in Path('.').glob('*.tf'): allowed.update(re.findall(r'variable\s+"([^\"]+)"',f.read_text()))
if set(v)-allowed: raise SystemExit('Unexpected Terraform input names')
# Override workstation key path with derived public key, never private key material.
v['ssh_public_key_path']=os.environ['HOMELAB_PUBLIC_KEY']
Path('terraform.tfvars.json').write_text(json.dumps(v))
PY
unset HOMELAB_TFVARS_JSON
if [[ -n "${PROXMOX_CA_PEM:-}" ]]; then
  cat /etc/ssl/certs/ca-certificates.crt > "$work/ca.pem"
  printf '\n%s\n' "$PROXMOX_CA_PEM" >> "$work/ca.pem"
  export SSL_CERT_FILE="$work/ca.pem"
  unset PROXMOX_CA_PEM
fi
export TF_IN_AUTOMATION=1 TF_INPUT=0
terraform init -input=false -reconfigure -backend-config="path=$state_dir/terraform.tfstate" -backend-config="workspace_dir=$state_dir/workspaces"
terraform validate
terraform plan -input=false -lock-timeout=60s -out="$work/reviewed.tfplan"
# Dispatch/manual job authorizes this run. Inspect changes in advance with a
# separate plan-only run before enabling production-like apply authority.
if [[ "$HOMELAB_ACTION" == plan ]]; then exit 0; fi
terraform apply -input=false -lock-timeout=60s "$work/reviewed.tfplan"
if [[ "$HOMELAB_ACTION" == provision ]]; then exit 0; fi
TARGET="ubuntu@$(terraform output -raw ssh_host)"
export TARGET
# VM agent readiness is not necessarily cloud-init completion. Poll SSH without
# bypassing pinned host keys; template SSH keys must be obtained out of band.
for attempt in $(seq 1 30); do
  if ssh -F "$HOMELAB_SSH_CONFIG" "$TARGET" 'timeout 30 cloud-init status --wait' >/dev/null 2>&1; then break; fi
  if [[ "$attempt" == 30 ]]; then echo 'Guest SSH/cloud-init readiness failed'; exit 1; fi
  sleep 10
done
./scripts/deploy.sh
