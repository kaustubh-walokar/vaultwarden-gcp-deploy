# Vaultwarden on Google Cloud Docker Image - Caddy

This is the proxy container repository for the [Vaultwarden on Google Cloud](https://github.com/samschurter/vaultwarden-gcp-deploy) project.

## Changes

Base Image: `serfriz/caddy-ratelimit-dockerproxy-sablier:2.11.4`

Changes to Base Image: Add `bind-tools` for `dig` in the startup gate, add `tzdata` so timezone is set using `TZ`, and keep the bundled `rate_limit` directive available by starting from a pinned prebuilt Caddy image that already includes `github.com/mholt/caddy-ratelimit`
