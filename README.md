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
3. A domain you control, using one of the two DNS routing paths below.
4. A mailbox you can use for Vaultwarden SMTP.

## DNS routing

Caddy provisions HTTPS for your Vaultwarden hostname (for example `vw.example.com`),
so that hostname must resolve to the VM's public IP. The VM uses an ephemeral IP by
default, so a DDNS updater (`ddclient`) keeps DNS pointed at it. Choose the path that
matches where your domain is managed:

- **Cloudflare** — your domain is managed in Cloudflare DNS. `ddclient` updates the
  `vw.example.com` record directly. Use Cloudflare in DNS-only mode for that hostname;
  do not enable the Cloudflare proxy. You need a Cloudflare API token scoped to the
  zone with `Zone:DNS:Edit` and `Zone:Zone:Read`.
- **DuckDNS + CNAME** — your domain is on a host without DDNS support (for example
  Wix). `ddclient` updates a free DuckDNS record instead, and you add a CNAME at your
  domain host so `vw.example.com` follows it. One-time manual setup:
    1. Register a DuckDNS subdomain at [duckdns.org](https://www.duckdns.org), for
       example `vw-example-com` (becomes `vw-example-com.duckdns.org`), and copy your
       DuckDNS token.
    2. Run the secrets helper and choose the DuckDNS path with that subdomain and token.
    3. At your domain host, add a CNAME record: `vw.example.com` ->
       `vw-example-com.duckdns.org`.

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
2. Your DNS routing choice (see [DNS routing](#dns-routing) above):
   - Cloudflare: your Cloudflare zone (for example `example.com`) and API token.
   - DuckDNS: your DuckDNS subdomain (for example `vw-example-com`) and token.
3. Your Let's Encrypt e-mail address.
4. Your timezone.
5. Your SMTP sender address and password.

If you chose DuckDNS, add the CNAME at your domain host after running the helper.

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

1. The hostname resolves to the VM external IP (directly via Cloudflare, or through the DuckDNS CNAME).
2. The site loads over HTTPS without a certificate warning.

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

## Optional: Enable Google Workspace SSO

Vaultwarden supports SSO through OpenID Connect (OIDC). Google Workspace does **not**
expose an OIDC endpoint for SSO — it only offers SAML, which Vaultwarden does not
support. The supported path is to use Google's standard OAuth 2.0 / OIDC provider
(`https://accounts.google.com`) with an OAuth client created in the Google Cloud
Console. Restricting that OAuth client's consent screen to **Internal** limits sign-in
to members of your Workspace organization, which gives you Workspace-gated SSO.

This is the upstream Vaultwarden guidance; see the
[Vaultwarden SSO wiki](https://github.com/dani-garcia/vaultwarden/wiki/Enabling-SSO-support-using-OpenId-Connect)
and its Google Auth section for reference.

### How SSO behaves here

- A master password is still required after SSO; SSO controls *who* may authenticate,
  not the vault encryption. This is expected Vaultwarden behavior.
- The web vault has no automatic "Log in with SSO" button. When `SSO_ENABLED=true`,
  the Caddy proxy redirects the bare site root to the SSO flow so users are not stuck
  on the password screen. `/admin`, the API, and the OAuth callback are not redirected.
- `SSO_IDENTIFIER` is cosmetic. Vaultwarden uses a single server-wide SSO config, so
  any non-empty value works; it is not a per-organization identifier.

### Important: the OAuth client is independent of this deployment

The OAuth client and this Vaultwarden deployment do **not** need to be in the same
Google Cloud project, and do not even need to be in the same organization. This repo
manages only the Vaultwarden deployment; it intentionally does not create or manage
the OAuth client with Terraform.

### Workspace admin handoff: create the OAuth client

Perform these steps in the [Google Cloud Console](https://console.cloud.google.com)
for the organization whose Workspace users should be allowed to sign in. This can be
a brand new, otherwise-empty project used only for the OAuth client.

1. Create or select a project.
2. Go to **APIs & Services → OAuth consent screen**.
   - User type: **Internal** (restricts sign-in to your Workspace organization).
     Use **External** only if you intentionally need accounts outside the org.
   - App name, user support email, and developer contact email: fill in.
   - Authorized domains: add the registrable domain of your Vaultwarden hostname
     (for example `example.com` for `vw.example.com`).
   - Save.
3. Go to **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
   - Application type: **Web application**.
   - Authorized redirect URI:
     `https://<your-vaultwarden-host>/identity/connect/oidc-signin`
     (for example `https://vw.example.com/identity/connect/oidc-signin`).
     This path is fixed by Vaultwarden and derived from `DOMAIN`.
   - (Optional) Authorized JavaScript origin: `https://<your-vaultwarden-host>`.
   - Create, then copy the **Client ID** and **Client secret**.

Hand the Client ID and Client secret back to whoever runs the secrets helper. Treat
the client secret like any other credential.

### Enable SSO in the deployment

Run the secrets helper and answer **yes** to the SSO prompt:

```bash
bash utilities/create-gcp-secrets.sh
```

When prompted it collects:

1. SSO authority — keep the default `https://accounts.google.com` for Google.
2. SSO client ID — from the OAuth client above.
3. SSO client secret — from the OAuth client above.
4. SSO identifier — cosmetic; press Enter to accept the default.
5. SSO-only — answer **yes** to disable master-password-only login and require SSO,
   or **no** to allow both.

These map to the following env settings (also documented in `.env.template`):

- `SSO_ENABLED=true`
- `SSO_ONLY` — `true` to require SSO, `false` to also allow password login.
- `SSO_AUTHORITY=https://accounts.google.com`
- `SSO_AUTHORIZE_EXTRA_PARAMS="access_type=offline&prompt=consent"` — requests a
  refresh token so sessions are not limited to one hour.
- `SSO_AUTH_ONLY_NOT_SESSION=true` — use SSO for authentication while keeping
  Vaultwarden's normal session handling.
- `SSO_CLIENT_ID` / `SSO_CLIENT_SECRET` — from the OAuth client.
- `SSO_IDENTIFIER` — cosmetic value used only in the login redirect.

After applying Terraform (or redeploying), confirm `https://your-hostname` redirects
into the Google sign-in flow and returns you to the master-password unlock.

> First-time users with `SSO_ONLY=true`: because the root redirect points at the SSO
> flow, invite users via the admin page so they can set a master password, or
> temporarily set `SSO_ONLY=false` while onboarding.

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
