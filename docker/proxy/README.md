# Vaultwarden on Google Cloud Proxy Notes

This directory contains the repo-managed startup wrapper for the proxy service used by [Vaultwarden on Google Cloud](https://github.com/samschurter/vaultwarden-gcp-deploy).

## Changes

Upstream Image: `serfriz/caddy-ratelimit-dockerproxy-sablier:2.11`

Repo-managed runtime change: bind in `scripts/start-caddy.sh` so the upstream image waits for DNS to resolve the configured hostname to the VM before starting Caddy. This keeps the proxy on a third-party image while preserving the DNS startup gate needed by the managed deployment.
