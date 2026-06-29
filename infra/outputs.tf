output "instance_name" {
  # Handy for quick lookups in the console.
  value = google_compute_instance.vaultwarden.name
}

output "instance_external_ip" {
  # Use this for your DNS A record.
  value = var.use_static_ip ? google_compute_address.vaultwarden[0].address : google_compute_instance.vaultwarden.network_interface[0].access_config[0].nat_ip
}

output "service_account_email" {
  # Useful for auditing IAM bindings.
  value = google_service_account.vaultwarden.email
}

output "snapshot_schedule_name" {
  # Name of the snapshot schedule policy, when enabled.
  value = var.enable_disk_snapshots ? google_compute_resource_policy.snapshot[0].name : null
}
