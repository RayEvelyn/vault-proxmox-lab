#!/usr/bin/env bash
set -euo pipefail
: "${TARGET:?Set TARGET=ubuntu@192.0.2.50}"
: "${LAB_HOSTNAME:?Set LAB_HOSTNAME to a DNS name}"
: "${IMAGE:?Set IMAGE to a pinned image tag or digest}"
[[ "$TARGET" =~ ^[a-z_][a-z0-9_-]*@[a-zA-Z0-9.-]+$ ]] || exit 2
[[ "$LAB_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]] || exit 2
[[ "$IMAGE" =~ ^[a-zA-Z0-9./:@_-]+$ ]] || exit 2
ssh_args=()
sudo_flag=
tty_args=(-t)
if [[ -n "${HOMELAB_SSH_CONFIG:-}" ]]; then ssh_args=(-F "$HOMELAB_SSH_CONFIG"); sudo_flag=-n; tty_args=(); fi
# Preserve host-key checking; verify the fingerprint out of band before accepting.
remote=$(ssh "${ssh_args[@]}" "$TARGET" 'mktemp -d /tmp/homelab.XXXXXXXXXX')
[[ "$remote" =~ ^/tmp/homelab\.[a-zA-Z0-9]{10}$ ]] || { echo 'Unexpected temporary path from target; refusing cleanup/deployment.' >&2; exit 1; }
trap 'ssh "${ssh_args[@]}" "$TARGET" "rm -rf -- $remote"' EXIT
scp "${ssh_args[@]}" scripts/bootstrap.sh compose.yaml "$TARGET:$remote/"
ssh "${ssh_args[@]}" "${tty_args[@]}" "$TARGET" "sudo $sudo_flag bash '$remote/bootstrap.sh' '$LAB_HOSTNAME' '$IMAGE' '$remote/compose.yaml'"
