#!/usr/bin/env bash
set -euo pipefail
: "${TARGET:?Set TARGET=ubuntu@192.0.2.50}"
: "${LAB_HOSTNAME:?Set LAB_HOSTNAME to a DNS name}"
: "${IMAGE:?Set IMAGE to a pinned image tag or digest}"
[[ "$TARGET" =~ ^[a-z_][a-z0-9_-]*@[a-zA-Z0-9.-]+$ ]] || exit 2
[[ "$LAB_HOSTNAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+$ ]] || exit 2
[[ "$IMAGE" =~ ^[a-zA-Z0-9./:@_-]+$ ]] || exit 2
# Preserve host-key checking; verify the fingerprint out of band before accepting.
remote=$(ssh "$TARGET" 'mktemp -d /tmp/homelab.XXXXXXXXXX')
[[ "$remote" =~ ^/tmp/homelab\.[a-zA-Z0-9]{10}$ ]] || { echo 'Unexpected temporary path from target; refusing cleanup/deployment.' >&2; exit 1; }
trap 'ssh "$TARGET" "rm -rf -- $remote"' EXIT
scp scripts/bootstrap.sh compose.yaml "$TARGET:$remote/"
ssh -t "$TARGET" "sudo bash '$remote/bootstrap.sh' '$LAB_HOSTNAME' '$IMAGE' '$remote/compose.yaml'"
