#!/bin/sh
set -eu

write_sso_redirect_snippet() {
  # When SSO is enabled, redirect only the bare root into the SSO flow; otherwise
  # leave the snippet empty so the site behaves like a normal password login.
  snippet="/data/sso-redirect.conf"
  identifier="${SSO_IDENTIFIER:-sso}"

  case "$(printf '%s' "${SSO_ENABLED:-false}" | tr '[:upper:]' '[:lower:]')" in
    true|1|yes)
      cat > "$snippet" <<EOF
@root path /
redir @root /#/sso?identifier=${identifier}
EOF
      echo "proxy-start: SSO redirect enabled (identifier=${identifier})" >&2
      ;;
    *)
      : > "$snippet"
      echo "proxy-start: SSO redirect disabled" >&2
      ;;
  esac
}

wait_for_dns() {
  domain="${DOMAIN:-}"
  timeout="${PROXY_DNS_WAIT_TIMEOUT:-300}"
  interval="${PROXY_DNS_WAIT_INTERVAL:-5}"

  if [ -z "$domain" ]; then
    echo "proxy-start: DOMAIN is empty, exiting" >&2
    exit 1
  fi

  expected_ip="$(wget -qO- --header='Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip 2>/dev/null || true)"

  if [ -z "$expected_ip" ]; then
    echo "proxy-start: could not determine VM external IPv4 from metadata, exiting" >&2
    exit 1
  fi

  elapsed=0
  while [ "$elapsed" -lt "$timeout" ]; do
    resolved_ips="$(nslookup "$domain" 1.1.1.1 2>/dev/null |
      awk '/^Address([[:space:]][0-9]+)?: / { print $NF }' |
      tr '\n' ' ')"
    for candidate in $resolved_ips; do
      case "$candidate" in
        *:*)
          continue
          ;;
      esac

      if [ "$candidate" = "$expected_ip" ]; then
        echo "proxy-start: DNS ready for $domain -> $expected_ip" >&2
        return 0
      fi
    done

    echo "proxy-start: waiting for DNS $domain -> $expected_ip, current: ${resolved_ips:-<none>}" >&2
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo "proxy-start: timed out waiting for DNS $domain -> $expected_ip, dying" >&2
  exit 1
}

wait_for_dns
write_sso_redirect_snippet
exec "$@"