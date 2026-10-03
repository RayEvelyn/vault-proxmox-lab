# GitHub source and Actions execution

This path needs GitHub and its runner only. GitLab is the service being provisioned in the GitLab VM example, not the CI platform for this path. No KAS is involved.

## Real CI: validation publicly, deployment in your private copy

The committed [`.github/workflows/lab.yml`](../.github/workflows/lab.yml) validates Terraform/Bash/Compose on GitHub-hosted runners without deployment credentials. Its separate `workflow_dispatch` job actually initializes a persistent backend, offers separate **plan**, **provision**, and **deploy** actions (default: plan). Provision applies a saved plan without SSH; deploy applies its saved plan, waits for guest readiness and runs SSH bootstrap. It is gated to a **private repository owned by someone other than RayEvelyn**, `DEPLOY_ENABLED=true`, the actual default branch, environment `homelab`, and a dedicated runner with labels `self-hosted,linux,homelab`. Canonical public teaching repositories cannot deploy through this job. A provision/deploy dispatch authorizes that selected apply/bootstrap phase; this is not a separate post-plan approval gate. Review a plan independently before enabling credentials for consequential targets.

To make your own private copy (these commands create/push only when you run them):

```bash
# Clone the public teaching repo, inspect it, then create your own PRIVATE copy.
gh repo clone RayEvelyn/vault-proxmox-lab
cd vault-proxmox-lab
gh repo create YOUR_USER/vault-proxmox-lab --private --source . --remote deployment --push
```

Do not run a self-hosted runner for public/untrusted PR jobs. [GitHub recommends private repositories for self-hosted runners](https://docs.github.com/en/actions/reference/security/secure-use). Runner labels are routing, not security: restrict registration and repository access, review workflow changes, configure supported environment/ref protections, and give the OS runner account only the needed permissions. Keep the runner outside the GitLab VM it bootstraps; rebuilding GitLab must not depend on its own unavailable pipeline. For public examples, hosted validation is the default.

### Persistent state contract

Install Terraform **1.16.5**, Python 3, OpenSSH client, `flock` (util-linux), and CA certificates on one dedicated permanent Linux runner. Pre-create a runner-owned directory with mode0700, for example `/var/lib/homelab-terraform`. Set `TF_STATE_ROOT` to this absolute path **outside checkouts and temporary directories**. Each repository keeps local state under `github-<repository_id>` . Terraform local backend locking plus a whole-run `flock` and per-repository CI concurrency serialize access on that host. [Terraform local backend](https://developer.hashicorp.com/terraform/language/backend/local)

**Always use the same permanent runner and state path.** A fresh host or changing the GitHub state ID starts a different empty state and can duplicate/conflict with resources. Do not register a pool of interchangeable runners for this local-state design. Back up state encrypted off-host with ownership/permissions preserved, test restoration, and record which platform/repository ID owns it. State and plans are never CI caches or artifacts. For teams/multiple hosts, deliberately migrate to a locking remote backend; do not improvise state copying between jobs.

If you already created the VM through local Terraform bootstrap, migrate its existing state to the intended runner/backend **before** enabling CI. Inspect lineage and resource IDs; back up first and use Terraform's supported backend migration/import procedures. Losing the state file does not delete the VM. A plan that proposes recreating an existing GitLab/Vault VM is a stop-and-investigate signal.

### Variables and secrets

Set non-secret repository/environment variables:

| Name | Value |
|---|---|
| `DEPLOY_ENABLED` | `true` only after private-copy/runner/state review |
| `TF_STATE_ROOT` | `/var/lib/homelab-terraform` on the permanent runner |
| `HOMELAB_TFVARS_JSON` | JSON object matching `../terraform.tfvars.example`, public values only |
| `PROXMOX_VE_ENDPOINT` | Verified HTTPS API endpoint |
| `LAB_HOSTNAME` | Service DNS name resolving to its VM |
| `IMAGE` | Exact stable patch image or immutable digest |

Set separate protected secrets `PROXMOX_VE_API_TOKEN`, `SSH_PRIVATE_KEY`; `SSH_KNOWN_HOSTS`, `LAB_HOSTNAME` and `IMAGE` are required only for the deploy phase; optional `PROXMOX_CA_PEM` contains the CA PEM to append to the runner's system trust bundle. Do not put credentials in the JSON variable. `ci/deploy.sh` writes temporary mode0600 files, starts an SSH agent, derives only the public key for cloud-init, and cleans temporary material/generated tfvars on exit. Strict host-key checking and noninteractive SSH are enforced. The target Ubuntu bootstrap account needs narrowly reviewed **passwordless sudo** for this automated path; interactive/manual deployment can use its own sudo policy.

A new VM's SSH host key must be verified through the Proxmox console/another trusted channel and pinned before bootstrap. Use provision first, verify the actual guest host key, set `SSH_KNOWN_HOSTS`, then dispatch deploy against the same preserved state. It deliberately does not use unchecked `ssh-keyscan` as trust. This workflow does not prove application readiness or backup restoration; follow the service acceptance steps above.

Use your CLI to set variables/secrets in your own private copy, without putting secret values in command arguments:

```bash
gh variable set DEPLOY_ENABLED --body true --repo YOUR_USER/vault-proxmox-lab
gh variable set TF_STATE_ROOT --body /var/lib/homelab-terraform --repo YOUR_USER/vault-proxmox-lab
# Secret read from a protected file; no value printed or committed.
gh secret set SSH_PRIVATE_KEY --repo YOUR_USER/vault-proxmox-lab < /protected/path/deploy-key
# Complete remaining variables/secrets, then dispatch on your default branch:
gh workflow run lab.yml --repo YOUR_USER/vault-proxmox-lab --ref main -f action=plan
# Review, then run action=provision. Pin the verified host key, then action=deploy.
```

### First provision, host trust, and replacement protection

On your Proxmox node, inspect the newly created VM's fingerprint through its guest-agent channel:

```bash
qm guest exec YOUR_VM_ID -- ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
# On your workstation collect a CANDIDATE, then compare its fingerprint manually:
ssh-keyscan -t ed25519 YOUR_VM_IP > candidate-known-hosts
ssh-keygen -lf candidate-known-hosts
# Only after an exact match to the trusted Proxmox result:
gh secret set SSH_KNOWN_HOSTS --repo YOUR_USER/REPO < candidate-known-hosts
```

`ssh-keyscan` alone is not verification. Preserve the initial state across plan/provision/deploy. The VM has `prevent_destroy=true`: Terraform replacements/deletion fail rather than deleting your GitLab/Vault data. If intentional retirement is required, back up and test restoration, explicitly review removing this protection in a separate change, then review the destroy plan. It does not protect against deletion outside Terraform. GitHub dispatch selects `action=plan`, `provision` or `deploy`.

## Complete GitHub input setup

The settings below belong to the private GitHub repository and Actions runner, not GitLab variables. Prepare reviewed nonsecret JSON matching the Terraform example and configure all inputs before dispatch:

```bash
export DEPLOY_REPO=YOUR_USER/REPLACE_REPO
gh variable set HOMELAB_TFVARS_JSON --repo "$DEPLOY_REPO" --body "$(cat /protected/path/ci-inputs.json)"
gh variable set PROXMOX_VE_ENDPOINT --repo "$DEPLOY_REPO" --body https://proxmox.example.test:8006/
gh variable set LAB_HOSTNAME --repo "$DEPLOY_REPO" --body service.example.test
gh variable set IMAGE --repo "$DEPLOY_REPO" --body YOUR_REVIEWED_SERVICE_IMAGE
gh secret set PROXMOX_VE_API_TOKEN --repo "$DEPLOY_REPO" < /protected/path/api-token
gh secret set PROXMOX_CA_PEM --repo "$DEPLOY_REPO" < /protected/path/proxmox-ca.pem
gh run list --repo "$DEPLOY_REPO" --workflow lab.yml
gh run watch RUN_ID --repo "$DEPLOY_REPO" --exit-status
```

Use the actual pinned service image in the README; the placeholder does not select a release. Supply the CA only when needed. Runner registration uses the official Actions runner distribution/configuration tool and GitHub registration API; `gh` has no built-in `runner register` command. Keep its short-lived token out of logs/history and register only this private repository. The runner must execute on the fixed state host described above. GitHub does not use KAS or a GitLab Runner in this path.

## Register the GitHub execution runner with CLI tools

Install a reviewed official Actions runner distribution on the dedicated Linux host first and run as its dedicated account. Keep that directory private; preserve an existing registration instead of replacing it. The current runner accepts `ACTIONS_RUNNER_INPUT_TOKEN`, avoiding token arguments/history. This setup belongs only to the private GitHub repository:

```bash
# On the dedicated host, with gh authenticated for your private repository:
umask 077
cd /path/to/reviewed/actions-runner
registration_file=$(mktemp)
gh api --method POST "repos/$DEPLOY_REPO/actions/runners/registration-token" > "$registration_file"
export ACTIONS_RUNNER_INPUT_TOKEN
ACTIONS_RUNNER_INPUT_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$registration_file")
./config.sh --unattended --url "https://github.com/$DEPLOY_REPO" --labels homelab --name homelab-fixed --work _work
unset ACTIONS_RUNNER_INPUT_TOKEN
rm -f -- "$registration_file"
./run.sh
```

The final command runs the registered runner in the foreground; configure its service with the official `svc.sh` tool when you deliberately want persistence. Do not run it as root or accept public jobs. The CLI example creates a runner registration when you execute it; validation of this repository does not register anything. [Official runner input implementation](https://github.com/actions/runner/blob/main/src/Runner.Listener/CommandSettings.cs).
