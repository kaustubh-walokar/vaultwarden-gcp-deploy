# Vaultwarden on Google Cloud

This repo deploys a single Vaultwarden instance on Google Cloud with Terraform, Secret Manager, Container-Optimized OS, automatic HTTPS, Cloudflare-backed DDNS, fail2ban, country-based ingress filtering, and GCS backups.

It is designed for a first deployment, not a hand-built VM. The normal workflow is:

1. Create secrets.
2. Review Terraform variables.
3. Apply Terraform.
4. Wait for first boot.
5. Finish onboarding in Vaultwarden.

You will need:

1. A GCP project with billing enabled.
2. Cloud Shell access in that project.
3. A domain managed in Cloudflare DNS.
4. A mailbox you can use for Vaultwarden SMTP.

## Why this is secure

- Secrets are stored in Google Secret Manager and fetched on boot instead of being stored on a local disk.
- The VM runs Container-Optimized OS and is recreated from Terraform-managed configuration.
- Caddy handles HTTPS automatically.
- Fail2ban blocks repeated login abuse.
- Country blocking reduces unsolicited public traffic on `80/443`.
- Backups are pushed to GCS instead of living only on the VM disk.
- Public signups are disabled by default.
- SSH access is blocked by default, and the operating model does not assume routine SSH access for administration.

## 1. Clone the repo in Cloud Shell

Open Cloud Shell in the target GCP project and run:

```bash
git clone https://github.com/samschurter/vaultwarden-gcp-deploy.git
cd vaultwarden-gcp-deploy
```

## 2. Create the required secrets

Run:

```bash
bash utilities/create-gcp-secrets.sh
```

This helper does the first-run setup work for you:

1. Enables the required Google Cloud APIs.
2. Creates or updates the `vwgc-env` and `vwgc-ddclient` secrets.
3. Writes `infra/terraform.tfvars` with your project ID and backup bucket settings.
4. Writes `infra/backend.hcl` so Terraform state lives in GCS.

Have these values ready when prompted:

1. Your Vaultwarden hostname, for example `vw.example.com`.
2. Your Cloudflare zone, for example `example.com`.
3. Your Cloudflare API token.
4. Your Let's Encrypt e-mail address.
5. Your timezone.
6. Your SMTP sender address and password.

Use Cloudflare in DNS-only mode for the Vaultwarden hostname. Do not enable the Cloudflare proxy.

The script prints a bootstrap `ADMIN_TOKEN`. Save it before you continue.

## 3. Review Terraform variables

Open `infra/terraform.tfvars` and confirm the values you want to keep.

The main settings are:

- `project_id`
    - Your GCP project ID, for example `my-gcp-project`.
- `region`
    - The region to deploy to, for example `us-west1`.
- `zone`
    - The zone to deploy to, for example `us-west1-a`.
- `reboot_timezone`
    - The timezone to use for automatic reboots when COS updates require one, for example `America/Chicago`.
- `reboot_time`
    - The time to schedule automatic reboots, in 24-hour `HH:MM` format, for example `03:00`.
- `backup_bucket_name`
    - The GCS bucket name to use for Vaultwarden backups, for example `vw-backups`. Leave blank to use the default `<project_id>-vaultwarden-backups`.
- `restore_backup_path`
    - If you are recovering from a backup, set this to the object path in the managed backup bucket, for example `vaultwarden/vw_backup_2026-06-08-000002.tar.gz`. Otherwise leave it blank.

If you are unsure, keep the default region and zone values already written by the repo.

## 4. Deploy

From the repo root, run:

```bash
cd infra
terraform init -backend-config=backend.hcl
terraform apply
```

If you are attaching to an existing deployment from a new Cloud Shell session or a different machine, use:

```bash
terraform init -reconfigure -backend-config=backend.hcl
```

## 5. Wait for first boot

After `terraform apply` completes, give the VM a few minutes to finish bootstrapping.

On first boot, the VM:

1. Clones this repo onto the stateful partition.
2. Fetches the env and ddclient secrets from Secret Manager.
3. Starts the compose stack.
4. Builds the local backup and countryblock images.
5. Schedules automatic reboots when COS updates require one.

The proxy waits for the hostname to resolve to the VM before Caddy starts, which prevents early certificate requests before DDNS is in place.

## 6. Confirm the site is live

Open `https://your-hostname`.

The deployment is ready when:

1. The hostname exists in Cloudflare DNS.
2. The hostname resolves to the VM external IP.
3. The site loads over HTTPS without a certificate warning.

If it is not ready yet, check the VM logs in Google Cloud Console under Compute Engine -> VM instances -> your instance -> Logs.

## 7. Finish the initial Vaultwarden setup

Use the bootstrap `ADMIN_TOKEN` from the secret helper to access the admin page at `https://your-hostname/admin` and finish onboarding.

Recommended first-run checklist:

1. Confirm SMTP works before allowing any signup flow.
2. Keep `SIGNUPS_ALLOWED=false` unless you have a specific reason to open it.
3. If you later allow signups, keep `SIGNUPS_VERIFY=true` and set `SIGNUPS_DOMAINS_WHITELIST`.
4. Create your accounts and organization.
5. Clear the bootstrap admin token when you are done:

```bash
bash utilities/create-gcp-secrets.sh --clear-admin-token
cd infra
terraform apply
```

At that point the admin page is disabled again.

## Backups and restore

Backups are configured for GCS by default.

To restore from a backup:

1. Find the object path you want to restore from the managed backup bucket.
2. Set `restore_backup_path` in `infra/terraform.tfvars`.
3. Run `terraform apply`.
4. Wait for the VM to boot and complete the restore.
5. Clear `restore_backup_path` back to `""` and apply again.

Restores are boot-time operations. This repo does not assume routine SSH access or manual in-place recovery steps.

## Day-two operations

Use [ADMINISTRATOR.md](ADMINISTRATOR.md) for routine administration: keeping the deployment current, updating settings, checking logs, and restoring backups.
