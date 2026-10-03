# GitLab source and GitLab CI execution

Choose this path when GitLab owns both your private code and CI jobs. GitHub remains the reviewed public example source; GitHub Actions, `gh` configuration and GitHub runners are not used for deployment in this path.

## Bootstrap the Git server before asking it to run CI

For self-managed GitLab, first use the local workstation Terraform and verified SSH instructions in the [GitLab VM example](https://github.com/RayEvelyn/gitlab-proxmox-terraform#readme), or its bare-metal route. Confirm DNS, HTTPS trust, startup and backup/restore access. Keep recovery outside GitLab. The first GitLab installation cannot depend on a pipeline hosted by the GitLab instance that does not yet exist. A healthy existing GitLab instance can instead host these projects immediately.

## Create the private source project with the CLI

The commands below are examples for your own instance and account. They create a private project only when you run them. Keep the public upstream remote for reference; do not overwrite it.

```bash
export GITLAB_HOST=gitlab.example.test
glab auth login --hostname "$GITLAB_HOST"
glab auth status --hostname "$GITLAB_HOST"
git clone https://github.com/RayEvelyn/vault-proxmox-lab.git
cd vault-proxmox-lab
# Use an existing writable namespace; create the group separately if needed.
export GITLAB_PROJECT=homelab/REPLACE_WITH_PROJECT
# Run once for a new project; existing private projects do not need recreation.
glab repo create "$GITLAB_PROJECT" --private --defaultBranch main --skipGitInit
git remote add homelab "ssh://git@$GITLAB_HOST/$GITLAB_PROJECT.git"
# Review staged files AND history for secrets before the first push.
git push homelab HEAD:main
project_id=$(glab api --hostname "$GITLAB_HOST" "projects/${GITLAB_PROJECT//\//%2F}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
# Inspect existing branch protection; preserve stronger rules.
glab api --hostname "$GITLAB_HOST" "projects/$project_id/protected_branches"
# Only if main has no protection yet: Maintainer pushes/merges, no force push.
glab api --hostname "$GITLAB_HOST" --method POST "projects/$project_id/protected_branches" -f name=main -F push_access_level=40 -F merge_access_level=40 --silent
```

Adjust the SSH port to the one your installation advertises and verify its host key independently. Use a scoped/expiring GitLab API token with `glab`; never embed it in a remote URL. Source import does not transfer runners, variables, cluster permissions or Terraform state.

## Own the execution host and credentials

Register a dedicated project-scoped protected GitLab runner tagged `homelab` (the guide's containerized cluster job uses `protected-deploy`). Runner tags route jobs; protection, project scope and reviewed default-branch changes control access. Do not share the deployment runner with untrusted merge requests. Keep an isolated unprivileged runner tagged `validation` for validation jobs. Use the [runner creation API](https://docs.gitlab.com/api/users/#create-a-runner) and [authentication-token registration flow](https://docs.gitlab.com/runner/register/#register-with-a-runner-authentication-token); create the runner with `access_level=ref_protected` and `run_untagged=false`. Capture the returned runner authentication token into a mode0600 local file and feed it through the registration tool's protected environment, not command history or logs. Review actual runner settings before enabling jobs. A shell runner executes repository code on its host; a Docker socket also grants host control.

Keep `DEPLOY_ENABLED=false` until source, runner, state and credentials have been reviewed. Configure protected variables in the `homelab` environment scope for VM jobs; the guide uses scope `lab`. GitLab's masked values have format restrictions: multiline SSH/CA material uses protected **file-type** variables; do not claim it is masked just because it is protected. Never enable debug shell/HTTP tracing around credentials. The helper reads file inputs into private runtime files without printing them.

Install Terraform 1.16.5, Python 3, Bash, OpenSSH, CA certificates and `flock` on one permanent Linux **shell** deployment runner. It must reach the trusted Proxmox API and guest SSH endpoint. Before CI ownership, create a runner-owned mode0700 directory outside checkout/temp, e.g. `/var/lib/homelab-terraform`. Set `TF_STATE_ROOT` to that path. State defaults to `gitlab-<project_id>`; `HOMELAB_STATE_ID` can explicitly retain an existing origin-prefixed ID during a reviewed migration. Migrate/back up existing local bootstrap state before the first CI plan. An empty new state for an already-existing VM is a stop signal, not permission to duplicate it. Keep one runner/path; back up state privately off-host, test recovery and never cache/upload state or plans. Terraform backend locking, the helper's whole-run `flock`, and GitLab `resource_group` serialize this project's operations. `prevent_destroy` remains enabled.

The JSON variable contains only reviewed public Terraform settings from `./terraform.tfvars.example` (Postgres also supplies `terraform/ci-inputs.example.json`). The helper derives the cloud-init public key from the dedicated CI private key. Do not put tokens, private keys or database passwords in JSON. API token is an environment secret; optional public CA certificate augments a private copy of the system CA bundle, without changing system trust.

```bash
glab variable set DEPLOY_ENABLED false --repo "$GITLAB_PROJECT" --protected --scope homelab
glab variable set TF_STATE_ROOT /var/lib/homelab-terraform --repo "$GITLAB_PROJECT" --protected --scope homelab
glab variable set HOMELAB_TFVARS_JSON --repo "$GITLAB_PROJECT" --protected --raw --scope homelab < /protected/path/ci-inputs.json
glab variable set PROXMOX_VE_ENDPOINT https://proxmox.example.test:8006/ --repo "$GITLAB_PROJECT" --protected --scope homelab
glab variable set PROXMOX_VE_API_TOKEN --repo "$GITLAB_PROJECT" --protected --masked --raw --scope homelab < /protected/path/api-token
glab variable set SSH_PRIVATE_KEY_FILE --repo "$GITLAB_PROJECT" --protected --raw --type file --scope homelab < /protected/path/deploy-key
# Optional CA, supplied only if your API needs this trusted private CA:
glab variable set PROXMOX_CA_PEM_FILE --repo "$GITLAB_PROJECT" --protected --raw --type file --scope homelab < /protected/path/proxmox-ca.pem
glab variable set LAB_HOSTNAME service.example.test --repo "$GITLAB_PROJECT" --protected --scope homelab
glab variable set IMAGE YOUR_REVIEWED_IMAGE_PIN --repo "$GITLAB_PROJECT" --protected --scope homelab
```

The dedicated automation key must be unencrypted for noninteractive use. The target bootstrap user requires the narrowly reviewed passwordless sudo policy described in the README. Set the actual service hostname/image from that repo's version policy, not the placeholder above.

## Run, inspect, then play the selected manual phase

Pipeline creation and manual job execution are separate operations. GitLab pipeline variables override the job's default `HOMELAB_ACTION=plan`; use a new pipeline for each reviewed phase and retain the same commit/state. Do not set deployment inputs on a public/mixed-platform job.

```bash
glab variable set DEPLOY_ENABLED true --repo "$GITLAB_PROJECT" --protected --scope homelab
glab ci run --repo "$GITLAB_PROJECT" --branch main --variables-env HOMELAB_ACTION:plan
glab ci list --repo "$GITLAB_PROJECT"
# Copy the exact pipeline ID from the response; do not select a different run.
export PIPELINE_ID=REPLACE_WITH_PIPELINE_ID
glab api --hostname "$GITLAB_HOST" "projects/$project_id/pipelines/$PIPELINE_ID/jobs"
glab ci trigger manual_deploy --repo "$GITLAB_PROJECT" --pipeline-id "$PIPELINE_ID"
glab ci trace manual_deploy --repo "$GITLAB_PROJECT" --pipeline-id "$PIPELINE_ID"
```

A `manual`/blocked pipeline has not deployed. `pending` means waiting for a matching available runner; `running` is not success. Inspect the exact job's terminal `success`/`failed`/`canceled` status via `glab api projects/$project_id/jobs/JOB_ID`. A successful plan never applies. After review, create a new pipeline with `HOMELAB_ACTION:provision`, inspect its exact ID and play the same manual job. Provision applies its saved plan and stops before SSH. Verify the new guest's fingerprint using trusted Proxmox guest-agent/console access, compare the candidate from `ssh-keyscan`, then configure the independently verified known-host lines:

```bash
glab variable set SSH_KNOWN_HOSTS_FILE --repo "$GITLAB_PROJECT" --protected --raw --type file --scope homelab < /protected/path/verified-known-hosts
glab ci run --repo "$GITLAB_PROJECT" --branch main --variables-env HOMELAB_ACTION:deploy
# Inspect the new pipeline ID and trigger/trace its manual job as above.
```

Deploy checks host-trust inputs before applying, saves/applies a fresh plan, waits for authenticated SSH/cloud-init, then performs the service bootstrap. VM readiness, application health, SQL migration validation and backup restoration are separate checks; follow this repo's acceptance steps. A manual apply is an explicit authorization for that run, not a guarantee that the preceding plan is harmless.

Official references: [project API](https://docs.gitlab.com/api/projects/), [variables](https://docs.gitlab.com/ci/variables/), [manual job API](https://docs.gitlab.com/api/jobs/), [protected/manual jobs](https://docs.gitlab.com/ci/jobs/job_control/). Commands/configuration were checked offline; no reader account, runner, token, infrastructure or cluster was changed.

## Register the GitLab execution runner with CLI tools

Install the reviewed official GitLab Runner package on the dedicated Linux host first. The following creates a project runner and captures its token privately. Keep a separate configuration file; do not overwrite an existing runner's global `config.toml`. Run this as the dedicated execution account with the appropriate GitLab project API permission:

```bash
umask 077
runner_setup=$(mktemp -d)
export project_id
python3 - <<'PYRUNNER'
import json,os
from pathlib import Path
v={'runner_type':'project_type','project_id':int(os.environ['project_id']),
   'description':'homelab-fixed','tag_list':['homelab'],'run_untagged':False,
   'locked':True,'access_level':'ref_protected'}
Path('runner-request.local.json').write_text(json.dumps(v))
PYRUNNER
glab api --hostname "$GITLAB_HOST" --method POST user/runners --input runner-request.local.json > "$runner_setup/response.json"
rm -f runner-request.local.json
export CI_SERVER_TOKEN
CI_SERVER_TOKEN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "$runner_setup/response.json")
mkdir -p "$HOME/.config/gitlab-runner"
chmod 700 "$HOME/.config/gitlab-runner"
gitlab-runner register --non-interactive --url "https://$GITLAB_HOST" --executor shell --config "$HOME/.config/gitlab-runner/homelab.toml" --description homelab-fixed
unset CI_SERVER_TOKEN
rm -rf -- "$runner_setup"
gitlab-runner run --config "$HOME/.config/gitlab-runner/homelab.toml"
```

For the guide's KAS deployment use a separate protected runner with API tag `protected-deploy` and the Docker executor; its reviewed kubectl image comes from `KUBECTL_IMAGE`. The shell-runner example above is for VM labs. Do not route container-image jobs to a shell executor expecting that `image:` will isolate execution. Register the `validation` runner separately with an isolated Docker executor and without provider/SSH credentials. `CI_SERVER_TOKEN` is the runner authentication input, not a KAS token or provider API token. Keep its persistent runner configuration private, verify project/protection/tag settings through the API, and deliberately configure the runner's service after testing it. [Runner authentication input](https://gitlab.com/gitlab-org/gitlab-runner/-/blob/main/common/config.go), [create-runner API](https://docs.gitlab.com/api/users/#create-a-runner).
