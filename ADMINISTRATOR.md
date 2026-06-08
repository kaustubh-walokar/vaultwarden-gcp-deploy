# ADMINISTRATOR.md

This guide covers normal administrative tasks for a running deployment.

The operating model is repo-managed and non-interactive: change configuration in this repo or in Secret Manager, apply Terraform, and let the VM re-converge on boot. Do not treat SSH access as part of the normal workflow.

## Keep the deployment current

There are multiple update paths:

1. Third-party containers are updated by Watchtower on the configured schedule.
2. The VM OS checks for updates and reboots daily if updates are available.
3. Repo-built images and repo-managed configuration are updated when you change this repo and redeploy.

Watchtower only manages the named third-party containers in `docker-compose.yml`. It does not update the local `vwgc_backup:local` or `vwgc_countryblock:local` images.

When you want to roll out repo changes:

1. Pull the latest repo changes into your working copy.
2. Review any changes to secrets or Terraform variables.
3. Run `terraform apply` from `infra/`.
4. Reboot or replace the VM if the change requires startup-time re-convergence.

## Change application settings

Most runtime settings live in the `vwgc-env` secret created by `utilities/create-gcp-secrets.sh`.

Use this when you need to change values such as:

1. Vaultwarden domain or SMTP settings.
2. Signup policy.
3. Backup schedule or destination.
4. Country allowlist.
5. Watchtower schedule.

Update flow:

1. Run `bash utilities/create-gcp-secrets.sh`.
2. Update the prompted values.
3. Run `terraform apply`.

For Terraform-controlled settings such as region, zone, reboot schedule, backup bucket, or restore path, edit `infra/terraform.tfvars` and then apply Terraform.

## Check logs

Google Cloud Logging is the primary operator view.

Use either of these entry points:

1. Google Cloud Console -> Compute Engine -> VM instances -> your instance -> Logs
2. Google Cloud Console -> Logging -> Logs Explorer, filtered to the VM

These logs should cover normal administration needs:

1. Container stdout and stderr for Vaultwarden, Caddy, ddclient, fail2ban, backup, countryblock, and Watchtower.
2. COS system logs.
3. Serial console output during boot.

Important local paths, if you ever need them for deeper inspection:

1. Vaultwarden file log: `/mnt/stateful_partition/vaultwarden-gcp-deploy/vaultwarden/vaultwarden.log`
2. Docker container logs: `/var/lib/docker/containers/<container-id>/<container-id>-json.log`

## Manage backups

The managed deployment stores backups in GCS by default.

Routine checks:

1. Confirm backup jobs are still appearing in Cloud Logging.
2. Confirm recent backup objects exist in the configured GCS bucket.
3. Confirm the current env secret still contains the expected backup destination and encryption settings.

If you change the backup bucket name, update `infra/terraform.tfvars` and apply Terraform.

If you change backup behavior such as schedule, retention, or notification settings, update the env secret and apply Terraform.

## Restore from backup

Restore is handled at boot, using `restore_backup_path` in Terraform.

Procedure:

1. Identify the object path in the managed backup bucket.
2. Set `restore_backup_path` in `infra/terraform.tfvars` to that object path.
3. Run `terraform apply`.
4. Wait for the VM to boot and the restore to complete.
5. Validate the site and logs.
6. Clear `restore_backup_path` back to `""`.
7. Run `terraform apply` again.

The restore uses the current backup encryption key from the env secret when the archive is encrypted.

## Reattach Terraform state in a new environment

If you need to administer the deployment from a new Cloud Shell session or another machine:

1. Authenticate `gcloud` to the same project.
2. Run `bash utilities/create-gcp-secrets.sh --prepare-terraform`.
3. Change into `infra/`.
4. Run `terraform init -reconfigure -backend-config=backend.hcl`.

That recreates the local backend config and reconnects Terraform to the existing remote state.
