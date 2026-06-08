# Vaultwarden on Google Cloud

---

An opinionated, secure-by-default, easy-to-deploy Vaultwarden stack for GCP's free e2-micro tier.

This repository packages Vaultwarden with automatic HTTPS, Cloudflare-managed DNS updates, required GCS backups, and a hardened deployment baseline built around Terraform, Secret Manager, and Container-Optimized OS.

You will need a registered domain name.

## Why this repo

- Opinionated defaults that favor a small, understandable deployment surface.
- Secure-by-default infrastructure and runtime choices, including managed secrets, HTTPS termination, and defensive network controls.
- A deployment flow designed for Cloud Shell so you can provision and bootstrap Vaultwarden with minimal local setup.

## Quick start (Terraform in Cloud Shell)

This workflow provisions an e2‑micro VM (Container‑Optimized OS), firewall rules, a service account, and Secret Manager secrets. The VM bootstraps the repo and starts the stack automatically.

### Prerequisites

1. A GCP project with billing enabled.
2. Cloud Shell access in that project.
3. A domain already managed in Cloudflare DNS.
4. An app password for a Google Workspace account to use as the SMTP sender.

This deployment path assumes the repo's default operating model: Terraform provisions the VM and supporting resources, the instance pulls secrets from Secret Manager on boot, and the stack comes up with the bundled security controls enabled.

For this deployment, Cloudflare is used as the DNS provider and ddclient manages a single hostname such as `vw.example.com` after the VM is created.

- Add your domain to Cloudflare DNS at the domain level, for example `example.com`, not the Vaultwarden hostname.
- If you bought the domain through Cloudflare Registrar and it already appears in your Cloudflare dashboard, you do not need to add it again.
- Choose the Vaultwarden hostname you want to use under that domain, for example `vw.example.com`.
- If first-boot DDNS does not create the hostname successfully, create a DNS-only `A` record for the Vaultwarden hostname that points at the VM external IPv4 address, then let ddclient maintain it afterward.
- When the hostname appears in Cloudflare, keep it in DNS-only mode. Do not enable the Cloudflare proxy for this setup.

Terraform and gcloud are preinstalled and authenticated in Cloud Shell, so no local setup is required.

### 1) Clone the repo in Cloud Shell

Open Cloud Shell in the GCP Console, then run:

1. `git clone https://github.com/samschurter/vaultwarden-gcp-deploy.git`
2. `cd vaultwarden-gcp-deploy`

### 2) Create secrets

Run the interactive helper from Cloud Shell:

```bash
bash utilities/create-gcp-secrets.sh
```

Before prompting for secrets, the helper also enables the Google Cloud APIs this deployment needs in a new project: Cloud Resource Manager, IAM, Compute Engine, Secret Manager, and Cloud Storage.

You must already be logged in to the `gcloud` CLI and have permission to create or update Secret Manager secrets in the target project.

The script uses the active Cloud Shell project automatically. It does not ask for a project ID.

The script creates or updates the two secrets Terraform expects by default:

1. `vwgc-env`
2. `vwgc-ddclient`

It prompts for the values that beginners usually need to change, including:

1. Your Vaultwarden hostname such as `vw.example.com`
2. Your Cloudflare zone such as `example.com`
3. Your Cloudflare API token
4. Your Let's Encrypt email address
5. Your timezone
6. Your GCS backup destination
7. Your SMTP settings (from address and app password)

The generated secret contents are based on [`.env.template`](.env.template) and [`ddns/ddclient.conf.template`](ddns/ddclient.conf.template), but the script fills in the required values for the managed GCP deployment so you do not need to create those files manually.

The script always configures the deployment to sync backups to GCS. It also finds or creates [infra/terraform.tfvars](infra/terraform.tfvars) and seeds it with the active `project_id` and the matching `backup_bucket_name`.

The same helper also prepares Terraform remote state for the Cloud Shell-first workflow. It creates or reuses a dedicated GCS bucket named `PROJECT_ID-vaultwarden-tfstate` by default and writes a local `infra/backend.hcl` file that points Terraform at that shared state bucket.

`backend.hcl` is kept separate from `terraform.tfvars` because Terraform initializes the backend before it loads input variables.

You do not need to know the VM IP yet. ddclient updates the hostname after Terraform creates the VM and the startup script finishes.

The DNS flow for the managed deployment is:

1. Put the parent domain under Cloudflare DNS.
2. Run the secret helper and enter the hostname you want.
3. Run `terraform apply`.
4. Wait for first boot to finish and let ddclient create or update the hostname in Cloudflare.

### 3) Create terraform.tfvars and backend config

The helper script can create or update [infra/terraform.tfvars](infra/terraform.tfvars) for you. It always seeds `project_id` and `backup_bucket_name`.

It also creates or updates a local `infra/backend.hcl` file for Terraform remote state. That file is not committed.

Open [infra/terraform.tfvars](infra/terraform.tfvars) and make sure these values are set the way you want:

- `project_id` (your GCP project ID)
- `region` (keep the default unless you know you want a different free‑tier region)
- `zone` (must be in the same region)
- `reboot_timezone` (timezone for scheduled reboots after COS updates)
- `reboot_time` (local time for scheduled reboots after COS updates, HH:MM)
- `backup_bucket_name` (optional override for the backup bucket; leave empty to use `project_id-instance_name-backups`)

Example:
```tfvars
project_id = "your-project-id"
region     = "us-central1"
zone       = "us-central1-a"
reboot_timezone = "Etc/UTC"
reboot_time     = "06:00"
backup_bucket_name   = "your-project-id-vaultwarden-backups"
```

If you are not sure, keep the defaults for region and zone above.

The generated backend config points Terraform at the shared GCS state bucket, so a new Cloud Shell session or a local machine can reattach to the same deployment state instead of starting from an empty local `terraform.tfstate`.

### 4) Deploy

From the repo root in Cloud Shell, run these commands in order:

1. `cd infra`
2. `terraform init -backend-config=backend.hcl`
3. `terraform apply`

Terraform also declares those required project APIs, so a direct `apply` in an already-authorized project can reconcile them if they were not enabled yet. The helper script is still the smoother first-run path because API enablement can take a short time to propagate.

After apply completes, the output includes the VM’s external IP address.

If you are re-running this from a different machine or a fresh Cloud Shell home directory, use `terraform init -reconfigure -backend-config=backend.hcl`.

### Reattach Terraform state from a new environment

If your original Cloud Shell home directory has expired or you want to switch from Cloud Shell to a local machine, do not run Terraform against a fresh local state file.

From the repo root in the new environment:

1. Authenticate `gcloud` to the same project.
2. Run `bash utilities/create-gcp-secrets.sh --prepare-terraform`.
3. `cd infra`
4. `terraform init -reconfigure -backend-config=backend.hcl`

The `--prepare-terraform` mode recreates `infra/backend.hcl` locally if needed, seeds `project_id` into [infra/terraform.tfvars](infra/terraform.tfvars), and creates the remote state bucket if it does not already exist.

### What happens after deploy

The VM automatically runs a startup script that:

1. Uses Docker that ships with COS.
2. Clones this repo into `/mnt/stateful_partition/vaultwarden-gcp-deploy`.
3. Pulls secrets from Secret Manager into runtime files under `/mnt/stateful_partition/run/vaultwarden-gcp-deploy` and starts the stack from them using a pinned Docker CLI image to run `docker compose` against the COS Docker daemon.
4. Builds the local backup and countryblock images, then starts the stack.
5. Schedules a reboot when COS updates require it.

The proxy service bind-mounts a small startup wrapper that delays Caddy until the configured hostname resolves to the VM's current external IPv4, so ACME does not race ahead of ddclient after first boot or an ephemeral-IP reboot.

The Terraform-managed VM also enables Container-Optimized OS Cloud Logging and serial port logging so Google Cloud Logging is the primary operator view for first boot and runtime troubleshooting. See [ADMINISTRATOR.md](ADMINISTRATOR.md) for the operator-focused logging notes.

### Runtime updates and recovery

The managed deployment is intentionally non-interactive. The normal operating model assumes you change repo-managed configuration, apply Terraform, and reboot or replace the VM when you need to converge on a new desired state.

Runtime image updates are split into two categories:

1. Third-party runtime containers are Watchtower-managed on a delayed cadence.
2. Local repo images stay on `:local` tags and are updated only through repo changes and the bootstrapping flow.

By default, Watchtower checks once per week using `WATCHTOWER_SCHEDULE`, enforces `WATCHTOWER_COOLDOWN_DELAY=48h`, and is scoped to the explicit third-party containers in [docker-compose.yml](docker-compose.yml). That keeps automatic updates in place while avoiding immediate uptake of freshly published images.

If an upstream image or update policy needs to change urgently, make the change in the repo or the generated env secret, apply Terraform, and let startup automation recreate the intended compose state. Do not assume shell access to the VM as part of routine remediation.

### First login checklist

1. Wait 2–5 minutes after `apply` finishes.
2. Open `https://<your-domain>` in a browser.
3. The deployment is ready when the hostname record appears in Cloudflare DNS, resolves to the VM external IP, and the site loads over HTTPS without a certificate warning.
4. If the page does not load yet, give DNS a little longer and then check the VM’s logs in the GCP Console → Compute Engine → your instance → Logs.

### Post-deploy checklist

Start with the default onboarding flow from [`.env.template`](.env.template): public signups are closed on first boot, a bootstrap admin token is generated into the env secret, and any later signup flow is restricted by e-mail verification plus `SIGNUPS_DOMAINS_WHITELIST`.

1. Run [utilities/create-gcp-secrets.sh](utilities/create-gcp-secrets.sh) and save the generated bootstrap `ADMIN_TOKEN` shown in the summary. The script also prompts for SMTP settings — configure them now if possible.
2. Deploy and confirm the site loads over HTTPS.
3. Confirm SMTP is working before enabling any signup flow. `SIGNUPS_VERIFY=true` is enforced, so e-mail delivery must work before self-signup can succeed. For Google Workspace, the script pre-fills `smtp.gmail.com:587` (STARTTLS); you only need to supply your sending address and an app password. App passwords require 2-Step Verification on the sending account — generate one at https://myaccount.google.com/apppasswords.
4. After onboarding, run `bash utilities/create-gcp-secrets.sh --clear-admin-token` and redeploy so the admin page is disabled.
5. With SMTP configured and signups disabled, invite users from inside Vaultwarden instead of opening public signups.

This checklist is intentionally incomplete for now and will grow as the deployment flow is tightened further.

### Troubleshooting (minimal)

- If the domain does not resolve, verify the hostname in your ddclient secret matches your chosen hostname and that Cloudflare DNS is set to DNS-only.
- If HTTPS fails, ensure ports 80 and 443 are open (this is handled by Terraform).
- If HTTPS fails immediately after a reboot or first boot, check whether the proxy logs are still waiting for DNS to move the hostname to the VM's current external IP before Caddy starts.
- If ddclient is not updating, confirm the API token permissions, that the secret value matches your ddclient config, and that the Cloudflare zone in the secret is the parent zone such as `example.com` rather than the full hostname.
- If the hostname is still missing after first boot, create a DNS-only `A` record for the hostname once, then rerun ddclient and confirm it can update the record.

### Cloudflare DDNS (API token)
Do not wait for the container to create `ddns/ddclient.conf`. Create the `vwgc-ddclient` Secret Manager secret before deployment, then let the VM write the file during first boot. Keep the hostname in DNS-only mode rather than proxied mode. If first-boot DDNS does not establish the hostname record, create the `A` record once in Cloudflare and let ddclient maintain it after that.
For the managed GCP flow, the VM keeps the fetched env and ddclient secrets in runtime files on the stateful partition instead of persisting them in the repo checkout. This allows Docker's reboot-time container restarts to see the last fetched config before the startup script refreshes those files from Secret Manager.

### Local builds for bundled images
This repo builds the backup and countryblock images locally from the Dockerfiles under [docker](docker). The proxy service stays on a third-party upstream image and binds in a repo-managed startup wrapper at runtime.

### One‑click GCP provisioning
See the Quick start section above for a Terraform Cloud Shell deployment that provisions the VM and bootstraps the stack.

## Stack overview

### Features

* Vaultwarden self-hosted on Google Cloud 'always free' e2-micro tier
* Opinionated Terraform deployment with Cloud Shell-friendly bootstrap
* Secure-by-default secret handling through GCP Secret Manager
* Automatic HTTPS certificate management through Caddy 2 proxy
* Dynamic DNS updates through ddclient
* Blocking brute-force attempts with fail2ban
* Country-wide blocking through iptables and ipset as a defense-in-depth ingress filter
* Automatic GCS backups

### Backups to GCS with rclone

The managed deployment always syncs backups to Google Cloud Storage with rclone.

1. In your `.env`, set `BACKUP=rclone` and keep `BACKUP_RCLONE_CONF=/data/rclone/rclone.conf`.
2. Set `BACKUP_RCLONE_DEST` to the bucket/path inside the configured remote (for example: `your-project-id-vaultwarden-backups/vaultwarden`). Do not include `gcs:` here.
3. Terraform creates the bucket with uniform bucket-level access enabled, and the startup script creates an rclone remote named `gcs` automatically using the VM service account in bucket-policy-only mode, so the backup script prefixes the remote name for you.

This materially improves recoverability compared with keeping backups only on the VM disk, but it is still not a fully independent offsite backup. The bucket lives in the same GCP project, the same GCP account, and the same cloud provider as the VM.

Treat the GCS bucket as the required durable backup target for this deployment, not as your final disaster-isolation layer. If you need protection against project compromise, account loss, or provider-wide failures, copy backups into a second administrative boundary as well.

### Fail2ban status

Fail2ban runs automatically with the bundled config in [fail2ban](fail2ban). No extra steps are required for basic protection.

### Country blocking scope

The country allowlist is an extra network-layer filter on public `80/443` ingress. It reduces exposure to unsolicited traffic, but it is not the primary security boundary for the deployment. Vaultwarden authentication, HTTPS, secret management, minimal service exposure, and host/container hardening remain the primary controls.

The allowlist data is refreshed from ipdeny. The bundled updater checks ipdeny's published MD5 manifest to detect accidental corruption or incomplete downloads from that same feed. That check is for integrity within the feed, not an independent authenticity guarantee against a compromised upstream.

