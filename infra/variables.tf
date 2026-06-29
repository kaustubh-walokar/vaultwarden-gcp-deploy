variable "project_id" {
  # Target GCP project for all resources.
  description = "GCP project ID"
  type        = string
}

variable "region" {
  # Free tier regions are limited; keep defaults unless you know otherwise.
  description = "GCP region"
  type        = string
  default     = "us-central1"
}

variable "zone" {
  # Must match the chosen region.
  description = "GCP zone"
  type        = string
  default     = "us-central1-a"
}

variable "instance_name" {
  # Used for VM name, tags, and service account.
  description = "Compute Engine instance name"
  type        = string
  default     = "vaultwarden"
}

variable "machine_type" {
  # Free tier machine type.
  description = "Compute Engine machine type"
  type        = string
  default     = "e2-micro"
}

variable "boot_disk_gb" {
  # 30GB is the free tier allowance in eligible regions. You may use more or less.
  description = "Boot disk size in GB"
  type        = number
  default     = 30
}

variable "image_family" {
  # COS keeps footprint small and is optimized for containers.
  description = "Boot image family"
  type        = string
  default     = "cos-stable"
}

variable "image_project" {
  # COS images are published under cos-cloud.
  description = "Boot image project"
  type        = string
  default     = "cos-cloud"
}

variable "use_static_ip" {
  # Static IPs are paid; default to ephemeral and use ddclient DDNS.
  # If you enable static IP, you can point DNS directly and skip ddclient.
  description = "Reserve and attach a static external IP"
  type        = bool
  default     = false
}

variable "repo_url" {
  # Repo cloned by the startup script.
  description = "Git repo URL for the deployment"
  type        = string
  default     = "https://github.com/samschurter/vaultwarden-gcp-deploy.git"
}

variable "repo_ref" {
  # Pin to a branch/tag/commit for reproducible deploys.
  description = "Git ref (branch/tag/commit) to checkout"
  type        = string
  default     = "master"
}

variable "env_secret_name" {
  # Holds the full .env content for the stack.
  description = "Secret Manager secret name containing the .env file content"
  type        = string
  default     = "vwgc-env"
}

variable "ddclient_secret_name" {
  # Holds the ddclient.conf content for DDNS.
  description = "Secret Manager secret name containing ddclient.conf"
  type        = string
  default     = "vwgc-ddclient"
}

variable "backup_bucket_name" {
  # Leave empty to use the default <project_id>-<instance_name>-backups name.
  description = "Optional override for the Cloud Storage backup bucket name"
  type        = string
  default     = ""
}

variable "restore_backup_path" {
  # One-shot recovery input: object path inside the managed backup bucket.
  description = "Optional GCS object path inside the managed backup bucket to restore on boot"
  type        = string
  default     = ""
}

variable "reboot_timezone" {
  # Timezone for scheduled reboot after COS updates.
  description = "Timezone for reboot scheduling"
  type        = string
  default     = "Etc/UTC"
}

variable "reboot_time" {
  # Local time for scheduled reboot after COS updates.
  description = "Time of day for reboot scheduling (HH:MM)"
  type        = string
  default     = "06:00"
}

variable "enable_disk_snapshots" {
  # Scheduled boot-disk snapshots for whole-VM disaster recovery.
  description = "Enable scheduled Compute Engine snapshots of the boot disk"
  type        = bool
  default     = true
}

variable "snapshot_start_time" {
  # UTC start time for the daily snapshot, on the hour (HH:MM).
  description = "UTC start time for the daily snapshot schedule (HH:MM)"
  type        = string
  default     = "06:00"
}

variable "snapshot_retention_days" {
  # Snapshots older than this are auto-deleted.
  description = "Number of days to retain scheduled snapshots"
  type        = number
  default     = 30
}

variable "snapshot_storage_location" {
  # Leave empty to store snapshots in the deployment region (single-region).
  description = "Optional override for snapshot storage location (region or multi-region)"
  type        = string
  default     = ""
}
