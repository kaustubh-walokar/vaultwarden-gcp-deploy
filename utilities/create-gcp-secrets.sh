#!/usr/bin/env bash
set -euo pipefail

# Detect the root directory, probably /home on Google Cloud Shell, and create a temporary directory for intermediate files.
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"

# Ensure temporary files are cleaned up on exit
trap 'rm -rf "$TMP_DIR"' EXIT

ENV_SECRET_NAME="${ENV_SECRET_NAME:-vwgc-env}"
DDCLIENT_SECRET_NAME="${DDCLIENT_SECRET_NAME:-vwgc-ddclient}"
TFVARS_FILE="$ROOT_DIR/infra/terraform.tfvars"
BACKEND_CONFIG_FILE="$ROOT_DIR/infra/backend.hcl"
ENV_TEMPLATE_FILE="$ROOT_DIR/.env.template"
DDCLIENT_CLOUDFLARE_TEMPLATE_FILE="$ROOT_DIR/ddns/ddclient.cloudflare.conf.template"
DDCLIENT_DUCKDNS_TEMPLATE_FILE="$ROOT_DIR/ddns/ddclient.duckdns.conf.template"
SCRIPT_MODE="${1:-create}"
TFSTATE_BUCKET_NAME="${TFSTATE_BUCKET_NAME:-}"
TFSTATE_BUCKET_LOCATION="${TFSTATE_BUCKET_LOCATION:-us-central1}"
TFSTATE_PREFIX="${TFSTATE_PREFIX:-vaultwarden}"
CONFIG_FILE="${CONFIG_FILE:-}"

# Parse --config-file argument
while [ $# -gt 0 ]; do
  case "$1" in
    --config-file|-f)
      CONFIG_FILE="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ -n "$CONFIG_FILE" ]; then
  parse_config_file "$CONFIG_FILE"
fi

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
}

require_file() {
  local file_path="$1"

  if [ ! -f "$file_path" ]; then
    printf 'Error: required file not found: %s\n' "$file_path" >&2
    exit 1
  fi
}

parse_config_file() {
  local config_file="$1"

  if [ ! -f "$config_file" ]; then
    printf 'Error: config file not found: %s\n' "$config_file" >&2
    exit 1
  fi

  while IFS='=' read -r key value; do
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    value="$(printf '%s' "$value" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$key" in
      \#*) continue ;;
      '') continue ;;
      project_id) PROJECT_ID="$value" ;;
      hostname) HOSTNAME="$value" ;;
      dns_provider) DNS_PROVIDER="$value" ;;
      zone) ZONE="$value" ;;
      duckdns_subdomain) DUCKDNS_SUBDOMAIN="$value" ;;
      acme_email) ACME_EMAIL="$value" ;;
      timezone) TIMEZONE="$value" ;;
      signup_domains_whitelist) SIGNUP_DOMAINS_WHITELIST="$value" ;;
      cloudflare_token) CLOUDFLARE_TOKEN="$value" ;;
      duckdns_token) DUCKDNS_TOKEN="$value" ;;
      backup_bucket_name) BACKUP_BUCKET_NAME="$value" ;;
      backup_path) BACKUP_PATH="$value" ;;
      smtp_host) SMTP_HOST="$value" ;;
      smtp_port) SMTP_PORT="$value" ;;
      smtp_security) SMTP_SECURITY="$value" ;;
      smtp_from) SMTP_FROM="$value" ;;
      smtp_password) SMTP_PASSWORD="$value" ;;
      sso_enabled) SSO_ENABLED="$value" ;;
      sso_only) SSO_ONLY="$value" ;;
      sso_authority) SSO_AUTHORITY="$value" ;;
      sso_client_id) SSO_CLIENT_ID="$value" ;;
      sso_client_secret) SSO_CLIENT_SECRET="$value" ;;
      sso_identifier) SSO_IDENTIFIER="$value" ;;
      env_secret_name) ENV_SECRET_NAME="$value" ;;
      ddclient_secret_name) DDCLIENT_SECRET_NAME="$value" ;;
      tfstate_bucket_name) TFSTATE_BUCKET_NAME="$value" ;;
      tfstate_bucket_location) TFSTATE_BUCKET_LOCATION="$value" ;;
      tfstate_prefix) TFSTATE_PREFIX="$value" ;;
      *) printf 'Warning: unknown config key: %s\n' "$key" >&2 ;;
    esac
  done < "$config_file"
}

str_replace_all() {
  # Literal find/replace using prefix/suffix removal only. Unlike sed or bash
  # ${var//pat/rep}, this never gives special meaning to characters such as &,
  # \, or / in the replacement, so secret tokens are substituted verbatim.
  local haystack="$1"
  local needle="$2"
  local replacement="$3"
  local result=""

  while [ -n "$haystack" ]; do
    case "$haystack" in
      *"$needle"*)
        result+="${haystack%%"$needle"*}"
        result+="$replacement"
        haystack="${haystack#*"$needle"}"
        ;;
      *)
        result+="$haystack"
        haystack=""
        ;;
    esac
  done

  printf '%s' "$result"
}

render_ddclient_template() {
  local template_path="$1"
  local output_path="$2"
  local line

  require_file "$template_path"

  : > "$output_path"
  while IFS= read -r line || [ -n "$line" ]; do
    line="$(str_replace_all "$line" "__ZONE__" "$zone")"
    line="$(str_replace_all "$line" "__HOSTNAME__" "$hostname")"
    line="$(str_replace_all "$line" "__CLOUDFLARE_TOKEN__" "$cloudflare_token")"
    line="$(str_replace_all "$line" "__DUCKDNS_SUBDOMAIN__" "$duckdns_subdomain")"
    line="$(str_replace_all "$line" "__DUCKDNS_TOKEN__" "$duckdns_token")"
    printf '%s\n' "$line" >> "$output_path"
  done < "$template_path"
}

prompt_value() {
  local prompt_text="$1"
  local default_value="${2:-}"
  local var_name="${3:-}"
  local response

  if [ -n "$var_name" ] && [ -n "${!var_name:-}" ]; then
    printf '%s\n' "${!var_name}"
    return
  fi

  if [ -n "$default_value" ]; then
    read -r -p "$prompt_text [$default_value]: " response
    if [ -z "$response" ]; then
      response="$default_value"
    fi
  else
    read -r -p "$prompt_text: " response
  fi

  printf '%s' "$response"
}

prompt_secret() {
  local prompt_text="$1"
  local var_name="${2:-}"
  local response

  if [ -n "$var_name" ] && [ -n "${!var_name:-}" ]; then
    printf '%s' "${!var_name}"
    return
  fi

  read -r -s -p "$prompt_text: " response
  printf '\n' >&2
  printf '%s' "$response"
}

prompt_yes_no() {
  local prompt_text="$1"
  local default_answer="$2"
  local response

  while true; do
    read -r -p "$prompt_text [$default_answer]: " response
    response="${response:-$default_answer}"

    case "${response,,}" in
      y|yes)
        return 0
        ;;
      n|no)
        return 1
        ;;
      *)
        printf 'Please answer y or n.\n' >&2
        ;;
    esac
  done
}

generate_admin_token() {
  openssl rand -hex 32
}

print_admin_token_notice() {
  local admin_token="$1"

  printf '\n'
  printf '============================================================\n'
  printf 'BOOTSTRAP ADMIN TOKEN - COPY THIS NOW\n'
  printf '============================================================\n'
  printf '%s\n' "$admin_token"
  printf '\n'
  printf 'Save this token somewhere safe before you continue.\n'
  printf 'You can recover it later from Secret Manager by reading the\n'
  printf 'latest version of the env secret.\n'
  printf '============================================================\n'
}

require_non_empty() {
  local field_name="$1"
  local field_value="$2"

  if [ -z "$field_value" ]; then
    printf 'Error: %s is required.\n' "$field_name" >&2
    exit 1
  fi
}

validate_cloudflare_token() {
  local token="$1"

  if [[ ! "$token" =~ ^cfat_[^[:space:]]{48}$ ]]; then
    printf 'Error: Cloudflare API token must begin with cfat_ and be 53 characters long.\n' >&2
    exit 1
  fi
}

ensure_project_services_enabled() {
  printf 'Ensuring required Google Cloud APIs are enabled...\n'

  gcloud services enable \
    cloudresourcemanager.googleapis.com \
    iam.googleapis.com \
    compute.googleapis.com \
    secretmanager.googleapis.com \
    storage.googleapis.com \
    --project="$project_id" >/dev/null

  printf 'Required Google Cloud APIs are enabled for project %s\n' "$project_id"
}

validate_hostname() {
  local hostname="$1"

  if [[ "$hostname" == http://* || "$hostname" == https://* || "$hostname" == */* ]]; then
    printf 'Error: hostname must be a bare host such as vw.example.com.\n' >&2
    exit 1
  fi
}

validate_zone() {
  local zone="$1"

  if [[ "$zone" == http://* || "$zone" == https://* || "$zone" == */* ]]; then
    printf 'Error: zone must be a bare domain such as example.com.\n' >&2
    exit 1
  fi
}

ensure_hostname_matches_zone() {
  local hostname="$1"
  local zone="$2"

  if [[ "$hostname" != "$zone" && "$hostname" != *."$zone" ]]; then
    printf 'Error: hostname "%s" is not inside zone "%s".\n' "$hostname" "$zone" >&2
    exit 1
  fi
}

normalize_duckdns_subdomain() {
  local value="$1"

  value="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
  value="${value%.duckdns.org}"
  printf '%s' "$value"
}

validate_duckdns_subdomain() {
  local value="$1"

  if [[ ! "$value" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
    printf 'Error: DuckDNS subdomain must be a single label such as vw-example-com.\n' >&2
    exit 1
  fi
}

validate_duckdns_token() {
  local token="$1"

  if [[ ! "$token" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    printf 'Error: DuckDNS token must be a UUID.\n' >&2
    exit 1
  fi
}

derive_parent_domain() {
  local host="$1"

  case "$host" in
    *.*.*)
      printf '%s' "${host#*.}"
      ;;
    *)
      printf '%s' "$host"
      ;;
  esac
}

normalize_backup_path() {
  local path_value="$1"

  path_value="${path_value#/}"
  path_value="${path_value%/}"
  printf '%s' "$path_value"
}

normalize_domain_whitelist() {
  local whitelist_value="$1"

  whitelist_value="$(printf '%s' "$whitelist_value" | tr '[:space:]' ',' )"
  whitelist_value="$(printf '%s' "$whitelist_value" | sed 's/,,*/,/g; s/^,//; s/,$//')"
  printf '%s' "$whitelist_value"
}

read_env_setting() {
  local file_path="$1"
  local key="$2"

  awk -F= -v key="$key" '
    $0 ~ "^[[:space:]]*" key "=" {
      sub(/^[[:space:]]*/, "", $0)
      sub("^[[:space:]]*" key "=", "", $0)
      print
      exit
    }
  ' "$file_path"
}

template_env_setting() {
  local key="$1"

  read_env_setting "$ENV_TEMPLATE_FILE" "$key"
}

upsert_env_setting() {
  local file_path="$1"
  local key="$2"
  local value="$3"
  local temp_file="$TMP_DIR/env.$key.tmp"

  awk -v key="$key" -v value="$value" '
    $0 ~ "^[[:space:]]*" key "=" {
      print key "=" value
      updated = 1
      next
    }

    {
      print
    }

    END {
      if (!updated) {
        print key "=" value
      }
    }
  ' "$file_path" > "$temp_file"

  mv "$temp_file" "$file_path"
}

upsert_secret() {
  local project_id="$1"
  local secret_name="$2"
  local data_file="$3"

  if gcloud secrets describe "$secret_name" --project="$project_id" >/dev/null 2>&1; then
    gcloud secrets versions add "$secret_name" --project="$project_id" --data-file="$data_file" >/dev/null
    printf 'Updated secret %s\n' "$secret_name"
  else
    gcloud secrets create "$secret_name" \
      --project="$project_id" \
      --replication-policy="automatic" \
      --data-file="$data_file" >/dev/null
    printf 'Created secret %s\n' "$secret_name"
  fi
}

tfvars_string() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

upsert_tfvars_entry() {
  local key="$1"
  local rendered_value="$2"
  local temp_file="$TMP_DIR/terraform.tfvars.$key.tmp"

  if [ -f "$TFVARS_FILE" ]; then
    awk -v key="$key" -v value="$rendered_value" '
      $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        print key " = " value
        updated = 1
        next
      }

      {
        print
      }

      END {
        if (!updated) {
          print key " = " value
        }
      }
    ' "$TFVARS_FILE" > "$temp_file"
  else
    {
      printf '# Generated in part by utilities/create-gcp-secrets.sh\n'
      printf '%s = %s\n' "$key" "$rendered_value"
    } > "$temp_file"
  fi

  mv "$temp_file" "$TFVARS_FILE"
}

seed_project_tfvars_file() {
  upsert_tfvars_entry "project_id" "$(tfvars_string "$project_id")"
}

seed_tfvars_file() {
  seed_project_tfvars_file
  upsert_tfvars_entry "backup_bucket_name" "$(tfvars_string "$backup_bucket_name")"
}

write_backend_config() {
  local bucket_name="$1"
  local prefix="$2"

  cat > "$BACKEND_CONFIG_FILE" <<EOF
bucket = "$bucket_name"
prefix = "$prefix"
EOF
}

ensure_terraform_backend_ready() {
  local bucket_name

  bucket_name="${TFSTATE_BUCKET_NAME:-${project_id}-vaultwarden-tfstate}"

  printf '\nPreparing Terraform remote state...\n'
  gcloud services enable storage.googleapis.com --project="$project_id" >/dev/null

  if gcloud storage buckets describe "gs://$bucket_name" --project="$project_id" >/dev/null 2>&1; then
    printf 'Terraform state bucket already exists: %s\n' "$bucket_name"
  else
    gcloud storage buckets create "gs://$bucket_name" \
      --project="$project_id" \
      --location="$TFSTATE_BUCKET_LOCATION" \
      --uniform-bucket-level-access >/dev/null
    printf 'Created Terraform state bucket %s in %s\n' "$bucket_name" "$TFSTATE_BUCKET_LOCATION"
  fi

  write_backend_config "$bucket_name" "$TFSTATE_PREFIX"
  printf 'Wrote Terraform backend config %s\n' "$BACKEND_CONFIG_FILE"
}

prepare_terraform_mode() {
  local bucket_name

  bucket_name="${TFSTATE_BUCKET_NAME:-${project_id}-vaultwarden-tfstate}"

  printf 'Prepare Terraform remote state and local backend config.\n\n'
  printf 'Using active gcloud project: %s\n\n' "$project_id"

  printf 'Summary\n'
  printf '  Project: %s\n' "$project_id"
  printf '  terraform.tfvars: %s\n' "$TFVARS_FILE"
  printf '  Terraform state bucket: %s\n' "$bucket_name"
  printf '  Terraform state bucket location: %s\n' "$TFSTATE_BUCKET_LOCATION"
  printf '  Terraform backend prefix: %s\n' "$TFSTATE_PREFIX"
  printf '  Terraform backend config: %s\n' "$BACKEND_CONFIG_FILE"

  if ! prompt_yes_no 'Create or update the Terraform backend config now?' 'Y'; then
    printf 'Aborted without changing Terraform backend configuration.\n'
    exit 0
  fi

  printf '\nUpdating terraform.tfvars...\n'
  seed_project_tfvars_file
  ensure_terraform_backend_ready

  printf '\nDone. Run terraform init -backend-config=backend.hcl from infra/ to attach to the shared remote state.\n'
  exit 0
}

clear_admin_token_mode() {
  local env_secret_name
  local env_file

  printf 'Clear bootstrap ADMIN_TOKEN from the env secret and disable the admin page.\n\n'
  printf 'Using active gcloud project: %s\n\n' "$project_id"

  env_secret_name="$(prompt_value 'Env secret name' "$ENV_SECRET_NAME")"
  env_file="$TMP_DIR/.env"

  printf 'Fetching latest env secret version...\n'
  gcloud secrets versions access latest --secret="$env_secret_name" --project="$project_id" > "$env_file"

  upsert_env_setting "$env_file" "ADMIN_TOKEN" ""

  printf '\nSummary\n'
  printf '  Project: %s\n' "$project_id"
  printf '  Env secret: %s\n' "$env_secret_name"
  printf '  ADMIN_TOKEN: cleared\n'

  if ! prompt_yes_no 'Update the env secret now?' 'Y'; then
    printf 'Aborted without changing any secrets.\n'
    exit 0
  fi

  printf '\nEnsuring Secret Manager API is enabled...\n'
  gcloud services enable secretmanager.googleapis.com --project="$project_id" >/dev/null

  printf 'Uploading updated env secret...\n'
  upsert_secret "$project_id" "$env_secret_name" "$env_file"

  printf '\nDone. ADMIN_TOKEN is cleared in %s for project %s.\n' "$env_secret_name" "$project_id"
  exit 0
}

case "$SCRIPT_MODE" in
  create|--create)
    ;;
  --prepare-terraform)
    ;;
  --clear-admin-token)
    ;;
  --config-file=*)
    CONFIG_FILE="${SCRIPT_MODE#*=}"
    ;;
  *)
    if [[ "$SCRIPT_MODE" == --config-file=* ]]; then
      CONFIG_FILE="${SCRIPT_MODE#*=}"
    else
      printf 'Usage: %s [--prepare-terraform|--clear-admin-token|--config-file=FILE]\n' "${0##*/}" >&2
      exit 1
    fi
    ;;
esac

if [ -n "$CONFIG_FILE" ]; then
  parse_config_file "$CONFIG_FILE"
fi

require_command gcloud
require_file "$ENV_TEMPLATE_FILE"

if [ "$SCRIPT_MODE" = 'create' ] || [ "$SCRIPT_MODE" = '--create' ]; then
  require_command openssl
fi

active_account="$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -n 1)"
if [ -z "$active_account" ]; then
  printf 'Error: gcloud is not authenticated. Run this from an authenticated Cloud Shell session.\n' >&2
  exit 1
fi

if ! project_id="$(gcloud config list --format='value(core.project)' 2>/dev/null | tr -d '\r')"; then
  printf 'Error: could not read the active gcloud project. Create a project, enable billing, and activate it in Cloud Shell before running this script.\n' >&2
  printf 'Hint: gcloud config set project YOUR_PROJECT_ID\n' >&2
  exit 1
fi

if [ -z "$project_id" ]; then
  printf 'Error: no active gcloud project is set for this Cloud Shell session. Create a project, enable billing, and activate it before running this script.\n' >&2
  printf 'Hint: gcloud config set project YOUR_PROJECT_ID\n' >&2
  exit 1
fi

if [ "$SCRIPT_MODE" = '--clear-admin-token' ]; then
  clear_admin_token_mode
fi

if [ "$SCRIPT_MODE" = '--prepare-terraform' ]; then
  ensure_project_services_enabled
  prepare_terraform_mode
fi

printf 'This script creates or updates the Secret Manager secrets used by the Terraform deployment.\n\n'
printf 'Templates: %s and %s\n\n' "$ROOT_DIR/.env.template" "$ROOT_DIR/ddns/ddclient.{cloudflare,duckdns}.conf.template"

printf 'Using active gcloud project: %s\n\n' "$project_id"
printf 'Terraform variables file: %s\n\n' "$TFVARS_FILE"

ensure_project_services_enabled

env_secret_name="$(prompt_value 'Env secret name' "$ENV_SECRET_NAME" 'ENV_SECRET_NAME')"
ddclient_secret_name="$(prompt_value 'ddclient secret name' "$DDCLIENT_SECRET_NAME" 'DDCLIENT_SECRET_NAME')"

hostname="$(prompt_value 'Vaultwarden hostname (for example vw.example.com)' '' 'HOSTNAME')"
require_non_empty 'Vaultwarden hostname' "$hostname"
validate_hostname "$hostname"

# DNS routing path; see README for the Cloudflare vs DuckDNS explanation.
printf '\nDNS routing: 1) Cloudflare DDNS  2) DuckDNS + CNAME\n'
dns_provider=''
while [ -z "$dns_provider" ]; do
  case "$(prompt_value 'Choose 1 or 2' '1' 'DNS_PROVIDER')" in
    1|cloudflare)
      dns_provider='cloudflare'
      ;;
    2|duckdns)
      dns_provider='duckdns'
      ;;
    *)
      printf 'Please enter 1 or 2.\n' >&2
      ;;
  esac
done

zone=''
duckdns_subdomain=''
signup_domains_fallback=''

if [ "$dns_provider" = 'cloudflare' ]; then
  zone="$(prompt_value 'Cloudflare zone (for example example.com)' '' 'ZONE')"
  require_non_empty 'Cloudflare zone' "$zone"
  validate_zone "$zone"
  ensure_hostname_matches_zone "$hostname" "$zone"
  signup_domains_fallback="$zone"
else
  duckdns_subdomain="$(prompt_value 'DuckDNS subdomain (the label before .duckdns.org)' '' 'DUCKDNS_SUBDOMAIN')"
  require_non_empty 'DuckDNS subdomain' "$duckdns_subdomain"
  duckdns_subdomain="$(normalize_duckdns_subdomain "$duckdns_subdomain")"
  validate_duckdns_subdomain "$duckdns_subdomain"
  signup_domains_fallback="$(derive_parent_domain "$hostname")"
fi

acme_email="$(prompt_value "Let's Encrypt email address" '' 'ACME_EMAIL')"
require_non_empty "Let's Encrypt email address" "$acme_email"

timezone_default="$(template_env_setting 'TZ')"
timezone_default="${timezone_default:-Etc/UTC}"
timezone="$(prompt_value 'Timezone (TZ database name, for example Etc/UTC, America/New_York, America/Chicago, America/Denver, America/Los_Angeles)' "$timezone_default" 'TIMEZONE')"
require_non_empty 'Timezone' "$timezone"

signup_domains_default="$(template_env_setting 'SIGNUPS_DOMAINS_WHITELIST')"
signup_domains_default="${signup_domains_default:-$signup_domains_fallback}"
signup_domains_whitelist="$(prompt_value 'Allowed signup e-mail domains (comma or space separated)' "$signup_domains_default" 'SIGNUP_DOMAINS_WHITELIST')"
signup_domains_whitelist="$(normalize_domain_whitelist "$signup_domains_whitelist")"
require_non_empty 'Allowed signup e-mail domains' "$signup_domains_whitelist"

bootstrap_admin_token="$(generate_admin_token)"

cloudflare_token=''
duckdns_token=''
if [ "$dns_provider" = 'cloudflare' ]; then
  cloudflare_token="$(prompt_secret 'Cloudflare API token' 'CLOUDFLARE_TOKEN')"
  require_non_empty 'Cloudflare API token' "$cloudflare_token"
  validate_cloudflare_token "$cloudflare_token"
else
  duckdns_token="$(prompt_secret 'DuckDNS token' 'DUCKDNS_TOKEN')"
  require_non_empty 'DuckDNS token' "$duckdns_token"
  validate_duckdns_token "$duckdns_token"
fi

backup_bucket_name=''
backup_path='vaultwarden'
backup_rclone_dest=''

backup_bucket_name="$(prompt_value 'Backup bucket name' "${project_id}-vaultwarden-backups" 'BACKUP_BUCKET_NAME')"
require_non_empty 'Backup bucket name' "$backup_bucket_name"

backup_path="$(prompt_value 'Backup path inside the bucket' 'vaultwarden' 'BACKUP_PATH')"
backup_path="$(normalize_backup_path "$backup_path")"

backup_rclone_dest="${backup_bucket_name}"
if [ -n "$backup_path" ]; then
  backup_rclone_dest="$backup_rclone_dest/$backup_path"
fi

# SMTP configuration (Google Workspace recommended)
# App passwords require 2-Step Verification: https://myaccount.google.com/apppasswords
smtp_from=""
smtp_password=""
smtp_host="${SMTP_HOST:-$(template_env_setting 'SMTP_HOST')}"
smtp_port="${SMTP_PORT:-$(template_env_setting 'SMTP_PORT')}"
smtp_security="${SMTP_SECURITY:-$(template_env_setting 'SMTP_SECURITY')}"

smtp_host="${smtp_host:-smtp.gmail.com}"
smtp_port="${smtp_port:-587}"
smtp_security="${smtp_security:-starttls}"

printf '\nSMTP configuration (used by Vaultwarden for invites/verification and the backup container for notifications).\n'
printf 'For Google Workspace: generate an app password at https://myaccount.google.com/apppasswords\n'
printf '(2-Step Verification must be enabled on the sending account.)\n\n'

smtp_from_default="$(template_env_setting 'SMTP_FROM')"
smtp_from="$(prompt_value 'SMTP from address and username (your Google Workspace email)' "$smtp_from_default" 'SMTP_FROM')"
require_non_empty 'SMTP from address' "$smtp_from"
smtp_password="$(prompt_secret 'SMTP app password' 'SMTP_PASSWORD')"
require_non_empty 'SMTP app password' "$smtp_password"

# SSO / OpenID Connect (optional)
sso_enabled="${SSO_ENABLED:-false}"
sso_only="${SSO_ONLY:-false}"
sso_client_id="${SSO_CLIENT_ID:-}"
sso_client_secret="${SSO_CLIENT_SECRET:-}"
sso_identifier="$(template_env_setting 'SSO_IDENTIFIER')"
sso_identifier="${sso_identifier:-sso}"
sso_authority_default="$(template_env_setting 'SSO_AUTHORITY')"
sso_authority="${SSO_AUTHORITY:-${sso_authority_default:-https://accounts.google.com}}"

printf '\nSingle Sign-On (SSO) is optional. When enabled, the proxy sends users straight\n'
printf 'into the SSO flow and a master password is still required. Leave disabled for\n'
printf 'normal password login.\n\n'
if [ "$sso_enabled" = 'true' ] || prompt_yes_no 'Enable SSO?' 'N'; then
  sso_enabled='true'
  sso_authority="$(prompt_value 'SSO authority (OpenID Connect issuer URL)' "$sso_authority" 'SSO_AUTHORITY')"
  sso_client_id="$(prompt_value 'SSO client ID' "$sso_client_id" 'SSO_CLIENT_ID')"
  require_non_empty 'SSO client ID' "$sso_client_id"
  sso_client_secret="$(prompt_secret 'SSO client secret' 'SSO_CLIENT_SECRET')"
  require_non_empty 'SSO client secret' "$sso_client_secret"
  sso_identifier="$(prompt_value 'SSO identifier (cosmetic, used in the login redirect)' "$sso_identifier" 'SSO_IDENTIFIER')"
  if prompt_yes_no 'Disable master-password login and require SSO only?' 'Y'; then
    sso_only='true'
  fi
fi
if [ "$sso_enabled" = 'true' ]; then
  sso_authority="$(prompt_value 'SSO authority (OpenID Connect issuer URL)' "$sso_authority" 'SSO_AUTHORITY')"
  sso_client_id="$(prompt_value 'SSO client ID' '' 'SSO_CLIENT_ID')"
  require_non_empty 'SSO client ID' "$sso_client_id"
  sso_client_secret="$(prompt_secret 'SSO client secret' 'SSO_CLIENT_SECRET')"
  require_non_empty 'SSO client secret' "$sso_client_secret"
  sso_identifier="$(prompt_value 'SSO identifier (cosmetic, used in the login redirect)' "$sso_identifier" 'SSO_IDENTIFIER')"
  if [ -n "${SSO_ONLY:-}" ]; then
    sso_only="${SSO_ONLY}"
  elif prompt_yes_no 'Disable master-password login and require SSO only?' 'Y'; then
    sso_only='true'
  fi
fi

env_file="$TMP_DIR/.env"
ddclient_file="$TMP_DIR/ddclient.conf"

cp "$ENV_TEMPLATE_FILE" "$env_file"

upsert_env_setting "$env_file" "DOMAIN" "$hostname"
upsert_env_setting "$env_file" "TZ" "$timezone"
upsert_env_setting "$env_file" "EMAIL" "$acme_email"
upsert_env_setting "$env_file" "SMTP_HOST" "$smtp_host"
upsert_env_setting "$env_file" "SMTP_FROM" "$smtp_from"
upsert_env_setting "$env_file" "SMTP_PORT" "$smtp_port"
upsert_env_setting "$env_file" "SMTP_SECURITY" "$smtp_security"
upsert_env_setting "$env_file" "SMTP_USERNAME" "$smtp_from"
upsert_env_setting "$env_file" "SMTP_PASSWORD" "$smtp_password"
upsert_env_setting "$env_file" "SIGNUPS_ALLOWED" "false"
upsert_env_setting "$env_file" "SIGNUPS_VERIFY" "true"
upsert_env_setting "$env_file" "SIGNUPS_DOMAINS_WHITELIST" "$signup_domains_whitelist"
upsert_env_setting "$env_file" "ADMIN_TOKEN" "$bootstrap_admin_token"
upsert_env_setting "$env_file" "ORG_CREATION_USERS" ""
upsert_env_setting "$env_file" "SSO_ENABLED" "$sso_enabled"
upsert_env_setting "$env_file" "SSO_ONLY" "$sso_only"
upsert_env_setting "$env_file" "SSO_AUTHORITY" "$sso_authority"
upsert_env_setting "$env_file" "SSO_CLIENT_ID" "$sso_client_id"
upsert_env_setting "$env_file" "SSO_CLIENT_SECRET" "$sso_client_secret"
upsert_env_setting "$env_file" "SSO_IDENTIFIER" "$sso_identifier"
upsert_env_setting "$env_file" "BACKUP" "rclone"
upsert_env_setting "$env_file" "BACKUP_EMAIL_TO" "$smtp_from"
upsert_env_setting "$env_file" "BACKUP_RCLONE_CONF" "/data/rclone/rclone.conf"
upsert_env_setting "$env_file" "BACKUP_RCLONE_DEST" "$backup_rclone_dest"
upsert_env_setting "$env_file" "VWGC_DDCLIENT_CONF" "/mnt/stateful_partition/run/vaultwarden-gcp-deploy/ddclient.conf"
upsert_env_setting "$env_file" "PUID" "0"
upsert_env_setting "$env_file" "PGID" "0"

if [ "$dns_provider" = 'cloudflare' ]; then
  render_ddclient_template "$DDCLIENT_CLOUDFLARE_TEMPLATE_FILE" "$ddclient_file"
else
  render_ddclient_template "$DDCLIENT_DUCKDNS_TEMPLATE_FILE" "$ddclient_file"
fi

printf '\nSummary\n'
printf '  Project: %s\n' "$project_id"
printf '  Active gcloud account: %s\n' "$active_account"
printf '  Hostname: %s\n' "$hostname"
printf '  DNS routing: %s\n' "$dns_provider"
if [ "$dns_provider" = 'cloudflare' ]; then
  printf '  Cloudflare zone: %s\n' "$zone"
else
  printf '  DuckDNS domain: %s.duckdns.org\n' "$duckdns_subdomain"
  printf '  Required CNAME: %s -> %s.duckdns.org\n' "$hostname" "$duckdns_subdomain"
fi
printf '  Env secret: %s\n' "$env_secret_name"
printf '  ddclient secret: %s\n' "$ddclient_secret_name"
printf '  terraform.tfvars: %s\n' "$TFVARS_FILE"
printf '  Terraform state bucket: %s\n' "${TFSTATE_BUCKET_NAME:-${project_id}-vaultwarden-tfstate}"
printf '  Terraform backend config: %s\n' "$BACKEND_CONFIG_FILE"
printf '  Signup domain whitelist: %s\n' "$signup_domains_whitelist"
printf '  SSO enabled: %s\n' "$sso_enabled"
printf '  Backup destination: %s\n' "$backup_rclone_dest"
printf '  Terraform backup bucket: %s\n' "$backup_bucket_name"
printf '  Bootstrap admin token: %s\n' "$bootstrap_admin_token"
printf '  SMTP from: %s\n' "$smtp_from"

print_admin_token_notice "$bootstrap_admin_token"

if ! prompt_yes_no 'Have you copied the bootstrap admin token?' 'Y'; then
  printf 'Aborted so you can copy the bootstrap admin token first.\n'
  exit 0
fi

if ! prompt_yes_no 'Create or update these secrets, seed infra/terraform.tfvars, and prepare remote Terraform state now?' 'Y'; then
  printf 'Aborted without changing any secrets.\n'
  exit 0
fi

printf '\nUpdating terraform.tfvars...\n'
seed_tfvars_file

ensure_terraform_backend_ready

printf '\nEnsuring Secret Manager API is enabled...\n'
gcloud services enable secretmanager.googleapis.com --project="$project_id" >/dev/null

printf 'Uploading secrets...\n'
upsert_secret "$project_id" "$env_secret_name" "$env_file"
upsert_secret "$project_id" "$ddclient_secret_name" "$ddclient_file"

print_admin_token_notice "$bootstrap_admin_token"

printf '\nDone. Terraform can now use %s and %s in project %s.\n' "$env_secret_name" "$ddclient_secret_name" "$project_id"