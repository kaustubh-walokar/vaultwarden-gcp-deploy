# ADMINISTRATOR.md

This is an operator-focused stub for managing a running instance after deployment.

It is intentionally incomplete for now.

## Runtime operations

The intended operating model for this deployment is non-interactive. Day-to-day changes and remediation should happen through repo-managed configuration, Terraform apply, and VM reboot or replacement rather than shell access into the instance.

Watchtower remains enabled, but it is intentionally constrained:

1. It checks for updates on the configured weekly schedule.
2. It enforces a global `WATCHTOWER_COOLDOWN_DELAY=48h` before applying a detected image update.
3. It only touches the explicit third-party containers listed in [docker-compose.yml](docker-compose.yml).

The local `vwgc_backup:local` and `vwgc_countryblock:local` images are not Watchtower-managed. They change only when the repo-managed build inputs change and startup automation rebuilds them.

If an upstream image or Watchtower policy needs to be corrected, update the repo or env secret, apply Terraform, and reboot if needed so the VM re-converges on the new desired state.

## Logging

### Primary operator view

For the managed Google Compute Engine deployment, the intended single pane of glass is Google Cloud Logging.

Terraform enables the Container-Optimized OS logging agent and serial port logging on the VM, so the first place to check during normal operations and bootstrap failures is Logs Explorer for the instance.

Practical entry points:

1. Google Cloud Console -> Compute Engine -> VM instances -> your instance -> Logs
2. Google Cloud Console -> Logging -> Logs Explorer, filtered to the target VM instance

### What should appear in Cloud Logging

When the VM is deployed from Terraform in this repo, Cloud Logging is expected to contain at least these categories:

1. Container stdout and stderr from the Docker services on the VM, including:
   - Vaultwarden container output
   - Caddy access and error output
   - ddclient output
   - fail2ban container output
   - backup job output
   - countryblock output
   - watchtower output
2. Selected COS system logs collected by the built-in logging agent
3. Serial console output for boot and startup-script troubleshooting
4. Google Cloud control-plane logs such as audit logs for Compute Engine, Secret Manager access, and optional GCS backup activity

### Important local log locations on the VM

Cloud Logging is the preferred operator surface, but these are the underlying local paths and sources:

1. Vaultwarden application log:
   - `/mnt/stateful_partition/vaultwarden-gcp-deploy/vaultwarden/vaultwarden.log`
   - Used by fail2ban for login and admin-path detection
2. Docker container json logs for each container:
   - `/var/lib/docker/containers/<container-id>/<container-id>-json.log`
   - Backing store for `docker logs`
3. Backup container internal log target:
   - `/var/log/backup.log`
   - Symlinked to container stdout, so it should also surface in Docker logs and Cloud Logging
4. Countryblock container internal log target:
   - `/var/log/block.log`
   - Symlinked to container stdout, so it should also surface in Docker logs and Cloud Logging
5. Host logs mounted into fail2ban:
   - `/var/log`
   - `/run/systemd/journal`

### Current logging behavior by destination

1. Cloud Logging:
   - Intended main operator destination on GCE
   - Best for non-SSH troubleshooting and first-boot diagnosis
2. Host local logs:
   - COS system logs and Docker json logs remain on the VM filesystem
   - Useful for deep inspection if there is ever a break-glass path
3. Application-specific file logs:
   - Vaultwarden writes a persistent file log under the mounted data directory
4. Google Cloud audit logs:
   - Separate from guest logs
   - Useful for confirming secret access, instance actions, and storage access

### What maps to Cloud Logging and what does not

The most important distinction is between container stdout and stderr, Docker's local json log files, and application logs written directly to files.

1. Container stdout and stderr:
   - This is the main stream Cloud Logging is expected to collect from the COS logging agent
   - If a service writes a line to stdout or stderr, expect it to appear both in `docker logs` and in Cloud Logging during normal operation
2. Docker json logs:
   - These are Docker's local on-disk record of container stdout and stderr
   - Path: `/var/lib/docker/containers/<container-id>/<container-id>-json.log`
   - In normal operation, Cloud Logging should reflect the same underlying stdout and stderr events, but it is not a byte-for-byte archival guarantee
3. File-only application logs:
   - A log file written directly by an application is not automatically forwarded just because it exists on disk
   - It appears in Cloud Logging only if something also emits that content to stdout or stderr, or if a separate log collector is configured to read the file

For this repo specifically:

1. Caddy logs to stderr, so its runtime logs should appear in both Docker logs and Cloud Logging
2. The backup container writes to `/var/log/backup.log`, but that path is symlinked to container stdout, so those entries should also appear in Docker logs and Cloud Logging
3. The countryblock container writes to `/var/log/block.log`, but that path is symlinked to container stdout, so those entries should also appear in Docker logs and Cloud Logging
4. Vaultwarden also writes a persistent file log at `/mnt/stateful_partition/vaultwarden-gcp-deploy/vaultwarden/vaultwarden.log`; that file exists for local persistence and fail2ban input, and should not be assumed to be the same thing as the container stdout stream

Operationally, treat Cloud Logging as the primary view for container output, but do not assume it is a perfect mirror of every local file-based log on the VM.

### Gaps to document later

Future revisions should add:

1. Recommended Logs Explorer queries
2. Expected log names and resource filters
3. Common failure signatures for first boot, DNS, TLS, and backup issues
4. Escalation and recovery procedures when Cloud Logging is missing or incomplete