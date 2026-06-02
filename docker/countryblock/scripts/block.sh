#!/usr/bin/env bash

# countryblock script for docker
# <scriptname> start will set up iptables and download the specified country ipsets and wait
# until it receives a INT, TERM, or KILL signal, at which time it will clean up iptables
# <scriptname> update will update the ipsets, good for a cron job
# Copyright (C) 2020 Bradford Law
# Licensed under the terms of MIT

LOG=/var/log/block.log
CHAIN=countryblock
COUNTRIES="${COUNTRIES:-US}"
INGRESS_CHAIN=DOCKER-USER
PUBLIC_IFACE="${PUBLIC_IFACE:-eth0}"
PUBLISHED_TCP_PORTS="${PUBLISHED_TCP_PORTS:-80,443}"

# The list of country codes is provided as an environment variable or below
#COUNTRIES=""

printf "Starting country allowlist construction for countries: %b\n" "$COUNTRIES" >> $LOG

detect_iptables() {
    local candidate

    for candidate in iptables iptables-legacy; do
        if ! command -v "$candidate" >/dev/null 2>&1; then
            continue
        fi

        if "$candidate" -nL "$INGRESS_CHAIN" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    for candidate in iptables iptables-legacy; do
        if command -v "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

IPTABLES="$(detect_iptables)" || {
    echo "Error: No supported iptables binary was found" >> $LOG
    exit 1
}

ensure_ingress_chain() {
    if ! $IPTABLES -nL "$INGRESS_CHAIN" >/dev/null 2>&1; then
        echo "Error: Expected Docker ingress chain $INGRESS_CHAIN was not found via $IPTABLES" >> $LOG
        echo "Managed deployment requires Docker published ports to traverse $INGRESS_CHAIN" >> $LOG
        return 1
    fi
}

validate_ip_range() {
    local ip_range="$1"
    # Validate CIDR notation (IPv4)
    if [[ "$ip_range" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}\/[0-9]{1,2}$ ]]; then
        # Further validate IP address portions
        local ip_addr cidr
        local -a octets
        IFS='/' read -r ip_addr cidr <<< "$ip_range"
        IFS='.' read -r -a octets <<< "$ip_addr"

        # Validate each octet is between 0 and 255
        for octet in "${octets[@]}"; do
            if [[ "$octet" -lt 0 || "$octet" -gt 255 ]]; then
                return 1
            fi
        done

        # Validate CIDR is between 0 and 32
        if [[ "$cidr" -lt 0 || "$cidr" -gt 32 ]]; then
            return 1
        fi

        return 0
    fi
    return 1
}

process_zone_file() {
    local zonefile="$1"
    local country="$2"

    # Check if file exists and is readable
    if [[ ! -f "$zonefile" ]] || [[ ! -r "$zonefile" ]]; then
        echo "Error: Cannot read zonefile $zonefile" >> $LOG
        return 1
    fi

    # Process file line by line
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Remove leading/trailing whitespace
        line="${line##*( )}"
        line="${line%%*( )}"

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if validate_ip_range "$line"; then
            ipset -exist -A "$country" "$line" || {
                echo "Error adding IP range $line to set $country" >> $LOG
                continue
            }
        else
            echo "Invalid IP range found: $line" >> $LOG
            continue
        fi
    done < "$zonefile"
}

setup() {
    # In the managed deployment, Docker published ports traverse DOCKER-USER because
    # the VM bootstrap disables the userland proxy and keeps ingress on the kernel NAT path.
    ensure_ingress_chain || return 1

    $IPTABLES -N $CHAIN
    $IPTABLES -I "$INGRESS_CHAIN" 1 -i "$PUBLIC_IFACE" -p tcp -m multiport --dports "$PUBLISHED_TCP_PORTS" -j $CHAIN

    # Apply the public allowlist only to forwarded ingress for the published HTTPS/HTTP ports.
    $IPTABLES -A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN

    for country in $COUNTRIES; do
        # Create ipset for each allowed country.
        ipset -exist create $country hash:net

        # Return to INPUT processing when the source IP is from an allowed country.
        $IPTABLES -A $CHAIN -m set --match-set $country src -j RETURN

        printf "Created allow rule for country %b\n" "$country" >> $LOG
    done

    # Drop any other public source that reached this chain.
    $IPTABLES -A $CHAIN -j DROP
}

cleanup() {
    # Clean up old rules
    $IPTABLES -D "$INGRESS_CHAIN" -i "$PUBLIC_IFACE" -p tcp -m multiport --dports "$PUBLISHED_TCP_PORTS" -j $CHAIN >/dev/null 2>&1
    $IPTABLES -F $CHAIN >/dev/null 2>&1
    $IPTABLES -X $CHAIN >/dev/null 2>&1

    # Flush ipsets
    for country in $COUNTRIES; do
        # Flush ipset for each country
        ipset -! destroy $country
        ipset -! destroy ${country,,} # include old lower-case ipset name format
        printf "Destroyed ipsets for %b\n" "$country" >> $LOG
    done
}

update() {
    local md5sum_file="/tmp/ipdeny-aggregated.MD5SUM"
    local update_failed=0

    # This manifest check is only for transfer/integrity failures within ipdeny's feed.
    # It is not an independent security control because the manifest and zone files come
    # from the same origin.
    if ! curl -fsSL "https://www.ipdeny.com/ipblocks/data/aggregated/MD5SUM" -o "$md5sum_file"; then
        echo "Error: Failed to download checksum manifest from ipdeny" >> $LOG
        return 1
    fi

    # For each country, download a list of subnets and add to its respective ipset
    # https://askubuntu.com/a/931153/56882 was useful
    for country in $COUNTRIES; do
        # Pull the latest IP set for country
        local zonefile_name="${country,,}-aggregated.zone"
        local zonefile_remote="https://www.ipdeny.com/ipblocks/data/aggregated/${zonefile_name}"
        local zonefile="/tmp/${zonefile_name}"
        local expected_md5
        local actual_md5

        expected_md5=$(awk -v zonefile_name="$zonefile_name" '$2 == zonefile_name { print $1; exit }' "$md5sum_file")
        if [[ -z "$expected_md5" ]]; then
            echo "Error: No checksum found for $zonefile_name in ipdeny manifest" >> $LOG
            update_failed=1
            continue
        fi

        if ! curl -fsSL "$zonefile_remote" -o "$zonefile" -z "$zonefile"; then
            echo "Error: Failed to download $zonefile_remote" >> $LOG
            update_failed=1
            continue
        fi

        # This detects accidental corruption or partial downloads, not a malicious ipdeny origin.
        actual_md5=$(md5sum "$zonefile" | awk '{print $1}')
        if [[ "$expected_md5" != "$actual_md5" ]]; then
            echo "Error: MD5 checksum mismatch for $zonefile_name" >> $LOG
            echo "Expected: $expected_md5, got: $actual_md5" >> $LOG
            rm -f "$zonefile"
            update_failed=1
            continue
        fi

        printf "Downloaded %b zone file %b to %b\n" "$country" "$zonefile_remote" "$zonefile" >> $LOG

        # Add each IP address from the downloaded list into the ipset
        if [[ -f "$zonefile" ]]; then
            process_zone_file "$zonefile" "$country"
            printf "Added %b subnets to %b ipset\n" "$(wc -l < "$zonefile")" "$country" >> $LOG
        else
            echo "Error: Zone file $zonefile not found" >> $LOG
            update_failed=1
        fi
    done

    rm -f "$md5sum_file"
    return $update_failed
}

if [ "$1" == "start" ]; then
    # Clean up old rules if they exist in case last run crashed
    cleanup
    setup || exit 1
    if ! update; then
        # If update fails during startup the ipsets are empty, which means the DROP rule
        # at the end of the countryblock chain blocks all traffic. Remove the rules so
        # the container fails open (traffic passes) rather than silently blocking everything.
        echo "Error: Failed to populate IP sets during startup, removing firewall rules to fail open" >> $LOG
        cleanup
        exit 1
    fi

    # Sleep indefinitely waiting for SIGTERM
    printf "$0: waiting for SIGINT SIGTERM or SIGKILL to clean up\n" >> $LOG
    trap "cleanup && exit 0" SIGINT SIGTERM SIGKILL
    sleep inf &
    wait

elif [ "$1" == "update" ]; then
    # Update the ipsets and exit
    update || exit 1
fi
