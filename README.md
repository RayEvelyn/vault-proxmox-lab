# Vault on Proxmox — TLS and persistent Raft, not dev mode

Start with [GitOps, the bootstrap order, and why the repos are separate](docs/START-HERE.md).

This beginner lab creates an Ubuntu VM, then runs a **single-node persistent Vault server** using Raft integrated storage and TLS. SSH bootstrap is also usable on dedicated Ubuntu bare metal. The lab generates its own short-lived TLS certificate on the host; no private keys, Vault root tokens or unseal shares go into Terraform. **Review locally before deploying; real manual CI is opt-in in your private copy.**

## Choose one source and execution platform

| Choice | Private source of truth | Deployment execution | Cluster access |
|---|---|---|---|
| [GitHub path](docs/GITHUB-CI.md) | Your private GitHub repository | GitHub Actions and its dedicated runner | Direct scoped kubeconfig for cluster jobs; no GitLab/KAS prerequisite |
| [GitLab path](docs/GITLAB-CI.md) | Your private GitLab project | GitLab CI and its dedicated runner | Optional GitLab agent/KAS for cluster jobs |

The canonical public GitHub repository distributes examples and runs unprivileged validation. Choose one private source and runner platform for each real target; do not combine a GitHub source checkout with instructions for a GitLab runner, or let both pipelines manage the same resource. GitLab-first bootstrap applies only when you select self-managed GitLab. GitHub can bootstrap the GitLab VM as a service without depending on that service's CI. KAS is a GitLab integration, not a universal prerequisite for Kubernetes or GitOps. Flux or another chosen reconciler can use either supported Git source.


## What Vault gives you — and what it does not

Vault centralizes secret access behind identities and explicit policies, records audited access, and can issue leased credentials through configured database/cloud secrets engines. Revocation and short TTLs reduce long-lived credential sprawl. It does not automatically make your applications secure: the Vault host, auth methods, policy design, audit delivery, backups and recovery keys still need protection. This lab demonstrates KV read policies; it does **not** configure dynamic database credentials. A single Raft node has persistent storage but no HA quorum; production needs a reviewed multi-node design and recovery process.

```text
Workstation → Terraform → Ubuntu VM
Clients → TLS 8200 → Vault policy/auth → encrypted Raft data
Operators → manual init/unseal → custody outside Git/Terraform
```

## Start Vault and initialize it yourself

Follow the common VM/token setup below, then:

```bash
export LAB_HOSTNAME=vault.example.test
export IMAGE=hashicorp/vault:2.1.1
chmod +x scripts/*.sh
./scripts/deploy.sh
ssh "$TARGET" 'sudo cat /srv/vault/tls/server.crt' > lab.crt
export VAULT_ADDR=https://vault.example.test:8200
export VAULT_CACERT="$PWD/lab.crt"
# Install matching Vault CLI from official HashiCorp distribution.
vault status
```

`vault status` exits **2 when sealed**; this is expected before initialization, not a startup failure. The server is NOT `vault server -dev` and has no preconfigured root token. A 30-day self-signed certificate is lab-only; replace with CA-issued TLS for shared use. The pinned **2.1.1** release was observed in the official HashiCorp Vault release API on 2026-10-03; review changelog/security notices before deployment.

Initialize once from your private terminal:

```bash
vault operator init -key-shares=3 -key-threshold=2
# This displays SENSITIVE recovery material. Store shares separately with
# trusted custodians/password-manager protection, never Git/state/logs.
vault operator unseal
vault operator unseal
# Enter two DISTINCT unseal shares at the hidden prompts.
vault login
# Enter initial root token at prompt; CLI token cache is sensitive.
vault status
vault audit enable file file_path=stdout
vault secrets enable -path=secret kv-v2
vault policy write demo-reader example-policy.hcl
```

Do not pipe unseal shares/root tokens through command arguments or Terraform. Never initialize a server a second time to fix an ordinary sealed state. After a restart, manually unseal with two distinct shares again. `vault login` caches a token in `~/.vault-token`; protect your workstation and delete this cache when done. Stop using the initial root token after establishing appropriate administrator identities and policies; revoke it with `vault token revoke -self` only after verifying your alternate access/recovery path.

For a disposable learning exercise only, write a non-secret demo value and create a short-lived reader token from an authorized admin terminal:

```bash
vault kv put secret/demo/example value=hello-lab
vault token create -policy=demo-reader -ttl=15m
# Token output is sensitive; use 'vault login' prompt in a separate terminal.
vault kv get secret/demo/example
```

Audit output goes to container stdout; configure centralized log collection and retention with your chosen CLI/IaC before relying on it. Audit records are sensitive even when fields are hashed. This lab sets `disable_mlock=true` as recommended for integrated storage; disable host swap for a reviewed real deployment to avoid sensitive memory swapping. Raft cluster port **8201 is not published** because this is single-node; multi-node deployment needs private reachability and separate peer TLS design.

## Vault backups and recovery

After authenticating with an appropriately privileged operator token:

```bash
umask 077
vault operator raft snapshot save vault-lab.snap
vault operator raft snapshot inspect vault-lab.snap
```

Encrypt and transfer snapshots off-host; snapshot contents and unseal shares must not be committed. Store TLS keys/config backups securely too. Test restoration on an isolated matching-version Vault instance using the official Raft recovery procedure. `vault operator raft snapshot restore` changes stored data and seal context; do not experiment on a live server. Preserve the original unseal shares for recovery. A snapshot file existing is not proof it can be restored.

Official guides: [integrated storage](https://developer.hashicorp.com/vault/docs/configuration/storage/raft), [Raft deployment](https://developer.hashicorp.com/vault/tutorials/day-one-raft/raft-deployment-guide), [initialization](https://developer.hashicorp.com/vault/docs/commands/operator/init), [unseal](https://developer.hashicorp.com/vault/docs/commands/operator/unseal), [Raft snapshots](https://developer.hashicorp.com/vault/docs/commands/operator/raft), [policies](https://developer.hashicorp.com/vault/docs/concepts/policies), [Docker image](https://hub.docker.com/r/hashicorp/vault).

## What you need

Use a disposable Ubuntu 24.04 x86_64 lab, working DNS, SSH public-key login, and passwordless sudo for the bootstrap account (or enter sudo interactively). Your workstation needs Terraform 1.6+, Git and OpenSSH. Proxmox must have a bridge, storage that supports VM disks/cloud-init, and an existing Ubuntu cloud-init template with QEMU guest agent installed. The script installs Ubuntu-packaged Docker and Compose; it does not repartition disks, change SSH, DNS, firewall or existing application services. Use a dedicated empty VM or bare-metal machine.

Example IPs below are documentation addresses, **not routable lab values**. Replace all IPs, DNS names, node/storage IDs and public-key paths. Match your LAN CIDR and gateway; reserve addresses outside the DHCP allocation pool. Do not expose this first lab directly to the Internet.

## Prepare a Proxmox template with CLI

On a Linux workstation with `curl`, `sha256sum` and `virt-customize` (`sudo apt-get install libguestfs-tools`):

```bash
curl -fLO https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
curl -fLO https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
sha256sum --ignore-missing -c SHA256SUMS
# Stop if verification fails. For stronger provenance verify Ubuntu's signed
# SHA256SUMS.gpg with the independently trusted Ubuntu cloud-image signing key.
virt-customize -a noble-server-cloudimg-amd64.img --install qemu-guest-agent
# Modification changes the image hash; keep a record of original verification.
scp noble-server-cloudimg-amd64.img root@pve.example.test:/var/lib/vz/template/iso/
```

On your **lab Proxmox node** as administrator, choose an unused template ID and storage. You can run the reviewed `scripts/create-template.sh 9000 local-lvm vmbr0 /path/to/prepared.img` to create an 80 GiB template; it refuses existing VM IDs. Equivalent explicit steps:

```bash
qm create 9000 --name ubuntu-noble-template --memory 2048 --cores 2 --net0 virtio,bridge=vmbr0
qm importdisk 9000 /var/lib/vz/template/iso/noble-server-cloudimg-amd64.img local-lvm
qm set 9000 --scsihw virtio-scsi-pci --scsi0 local-lvm:vm-9000-disk-0
qm resize 9000 scsi0 80G
qm set 9000 --ide2 local-lvm:cloudinit --boot order=scsi0 --serial0 socket --vga serial0 --agent enabled=1
qm template 9000
```

Check `qm config 9000`: actual imported disk names vary by storage; use the `unused0` value if it differs. Do not boot or modify a template in use. This example clones on the same node. Choose storage with enough space for a **full clone** and the application's data. Resize the template disk *before* templating if the cloud image default is too small; GitLab needs substantially more disk than a base cloud image (start around 80 GiB). Inside Ubuntu confirm the filesystem grew with `lsblk` and `df -h`.

## Create an API token without putting it in Terraform

Run on the Proxmox lab node. The custom role avoids full administrator privileges but is granted at `/` for a simple single-node lab. Before sharing a cluster, scope VM/storage permissions to the intended pool/template/storage and check provider requirements. Token permissions are the intersection of user and token ACLs with privilege separation enabled.

```bash
pveum user add terraform-lab@pve --comment 'Disposable Terraform lab'
pveum role add LabTerraform --privs 'Datastore.AllocateSpace Datastore.Audit Sys.Audit VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.CPU VM.Config.Cloudinit VM.Config.Disk VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.PowerMgmt SDN.Use'
pveum acl modify / --user terraform-lab@pve --role LabTerraform
pveum user token add terraform-lab@pve lab --privsep 1
pveum acl modify / --token 'terraform-lab@pve!lab' --role LabTerraform
```

The token secret is shown once. Save it in your password manager; never paste it into Git, a screenshot, CI output or `terraform.tfvars`. On your workstation:

```bash
export PROXMOX_VE_ENDPOINT='https://pve.example.test:8006/'
read -rsp 'Proxmox API token secret: ' LAB_TOKEN; printf '\n'
export PROXMOX_VE_API_TOKEN='terraform-lab@pve!lab='"$LAB_TOKEN"
unset LAB_TOKEN
cp terraform.tfvars.example terraform.tfvars
# Edit only non-secret settings in terraform.tfvars.
terraform init
terraform fmt -check
terraform validate
terraform plan -out=lab.tfplan
# Inspect the full plan, then (only in your own lab):
terraform apply lab.tfplan
unset PROXMOX_VE_API_TOKEN
```

Trust your Proxmox CA in your workstation's operating-system certificate store. Keep TLS verification on; `PROXMOX_VE_INSECURE=true` is not the normal path. API authentication is environment-only; VM cloud-init contains a **public** SSH key, not a password/private key. Terraform state still contains infrastructure inventory; `.gitignore` does not encrypt it. Protect state/plan files with `umask 077`, encrypted disk and access controls, or an encrypted locking remote backend. Commit `.terraform.lock.hcl` to keep provider selections reproducible.

## Bootstrap the VM, or use bare metal

After Terraform completes, check guest readiness:

```bash
export TARGET="ubuntu@$(terraform output -raw ssh_host)"
ssh "$TARGET" 'cloud-init status --wait; systemctl is-active qemu-guest-agent'
```

Verify the SSH fingerprint through the Proxmox console or an independent trusted channel before accepting it. Never disable host-key checking. For bare metal, install Ubuntu 24.04 yourself with SSH/sudo and set `TARGET=ubuntu@your-host`; skip Terraform and use the **same** deployment command below. Hardware installation/storage/firmware are deliberately outside Terraform's VM scope.

## Networking, TLS and operations

Create your DNS A/AAAA record using your DNS CLI/IaC, or a temporary client hosts entry managed by CLI. DNS must resolve to the VM/metal host from your client. No router/firewall changes are automated. Docker published ports can bypass UFW's usual input rules: restrict at the upstream router/Proxmox firewall or a reviewed DOCKER-USER policy, including IPv6. Keep host SSH port 22 allowed from your administration subnet.

The bootstrap generates a **30-day self-signed lab certificate on the target only**, preserves existing certificate files, and never sends a private key through Terraform. Copy the public certificate to your client over verified SSH and use it with `curl --cacert`; for browsers install the lab CA/certificate via OS tooling. Replace it with an appropriate CA-issued SAN certificate before any real shared use. Do not use `curl -k` as acceptance evidence. Certificates expire: replacement and renewal are your responsibility.

Before upgrading, back up application data/config, verify backup restoration on a separate target, then select an explicit patch tag or immutable digest and rerun bootstrap. Never assume an old container image can read a newly migrated database. VM snapshots are useful rollback aids but are not a substitute for application-consistent, encrypted, off-host backups. Never `terraform destroy` until you have exported data and proven restoration: it deletes the VM. Revoke the lab token when finished:

```bash
pveum user token remove terraform-lab@pve lab
```

## Troubleshooting and validation limits

- API 401: token format is `user@realm!token=secret`; verify realm and expiry. API 403: inspect both token and user ACLs, template access and storage rights.
- Clone/cloud-init failures: verify free VM ID, node, storage, `qm config`, bridge and template cloud-init disk. Guest-agent timeout: install/start the agent in the template; inspect via console instead of disabling readiness checks blindly.
- SSH timeout: check subnet/gateway, bridge VLAN, DHCP collisions and firewall; inspect `cloud-init status --long` and `ip addr` in the VM console.
- TLS errors: check DNS SAN, trust anchor, system clock and certificate expiry. Do not bypass validation.
- Scripts are deliberately repeatable for a dedicated host; they preserve data/TLS and run `docker compose up -d`. They install packages and can recreate containers; review before execution.
- Locally checked with `terraform init -backend=false`, `terraform validate`, `terraform fmt -check` and `bash -n`. No real Proxmox apply, SSH bootstrap, container startup, backup restore, or service acceptance is claimed by this repository.

## Sources and version policy

Provider is pinned to **bpg/proxmox 0.115.0**, observed from the official Terraform Registry on 2026-10-03. Terraform requirements permit 1.6–1.x; lock providers and review changelogs before upgrades. Service images must be explicitly pinned; no `latest` deployment.

- [bpg VM resource documentation](https://github.com/bpg/terraform-provider-proxmox/blob/v0.115.0/docs/resources/virtual_environment_vm.md)
- [bpg provider authentication and permissions](https://registry.terraform.io/providers/bpg/proxmox/latest/docs)
- [Proxmox cloud-init](https://pve.proxmox.com/wiki/Cloud-Init_Support)
- [Ubuntu cloud images](https://cloud-images.ubuntu.com/)

## Deployment instructions

Follow the selected [GitHub path](docs/GITHUB-CI.md) or [GitLab path](docs/GITLAB-CI.md). Each page supplies its own source, runner, inputs and manual execution commands. Local workstation Terraform/SSH instructions above remain available for first bootstrap and recovery.
