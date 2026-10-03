#!/usr/bin/env bash
set -euo pipefail
# Run on a LAB Proxmox node after independently verifying/preparing the image.
[[ $# -eq 4 ]] || { echo 'Usage: create-template.sh unused-id storage bridge prepared-image-path' >&2; exit 2; }
id=$1; storage=$2; bridge=$3; image=$4
[[ "$id" =~ ^[0-9]+$ && "$storage" =~ ^[a-zA-Z0-9_-]+$ && "$bridge" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 2
[[ -f "$image" ]] || exit 2
if qm status "$id" >/dev/null 2>&1; then echo 'VM ID exists; refusing to overwrite.' >&2; exit 1; fi
qm create "$id" --name ubuntu-noble-template --memory 2048 --cores 2 --net0 "virtio,bridge=$bridge"
qm importdisk "$id" "$image" "$storage"
disk=$(qm config "$id" | awk '/^unused0:/ {print $2}')
[[ -n "$disk" ]] || { echo 'No imported disk; inspect VM before continuing.' >&2; exit 1; }
qm set "$id" --scsihw virtio-scsi-pci --scsi0 "$disk"
qm resize "$id" scsi0 80G
qm set "$id" --ide2 "$storage:cloudinit" --boot order=scsi0 --serial0 socket --vga serial0 --agent enabled=1
qm template "$id"
echo 'Template created. Test a clone before relying on it.'
