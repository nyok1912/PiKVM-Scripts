#!/bin/bash

# ZeroTier on PiKVM Automated Installation Script by N&oOk

set -euo pipefail
IFS=$'\n\t'

readonly PERSIST_DIR="/var/lib/kvmd/pst/data/zerotier-one"
readonly RUNTIME_DIR="/var/lib/zerotier-one"
readonly SERVICE="zerotier-one.service"

STEP=0
RW_ENGAGED=0
ZEROTIER_ADDRESS=""
NETWORK_ID=""
UNATTENDED=0
PACMAN_DB_REFRESHED=0
NETWORK_ARG=""
FORCE_DNS=0
ENABLE_IP_FORWARD=0
WAIT_FOR_APPROVAL=1
ZT_INTERFACE=""

print_banner() {
    printf '==========================================\n'
    printf 'ZeroTier on PiKVM Automated Setup by N&oOk\n'
	printf 'https://github.com/nyok1912/PiKVM-Scripts\n'
    printf '==========================================\n\n'
}

info() {
    printf '%s\n' "$1"
}

success() {
    printf '✓ %s\n' "$1"
}

warn() {
    printf 'WARN: %s\n' "$1" >&2
}

require_root() {
    if [[ ${EUID:-} -ne 0 ]]; then
        printf 'ERROR: This script must be run as root.\n' >&2
        exit 1
    fi
}

print_usage() {
    cat <<'EOF'
Usage: setup.sh [OPTIONS]

Options:
    --network-id <ID>     Network ID (16 hex characters). Required with --unattended.
    --force-dns           Enable DNS without prompting.
    --ip-forward          Enable net.ipv4.ip_forward=1 and persist it.
    --unattended          Run in unattended mode (requires --network-id).
    --no-wait-approval    Skip the final approval wait.
    --help, -h            Show this help and exit.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --network-id=*)
                NETWORK_ARG="${1#*=}"
                ;;
            --network-id)
                shift || {
                    printf 'ERROR: --network-id requires a value.\n' >&2
                    exit 1
                }
                NETWORK_ARG="$1"
                ;;
            --force-dns)
                FORCE_DNS=1
                ;;
            --ip-forward)
                ENABLE_IP_FORWARD=1
                ;;
            --no-wait-approval)
                WAIT_FOR_APPROVAL=0
                ;;
            --unattended)
                UNATTENDED=1
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                printf 'ERROR: Unknown argument "%s". Use --network-id <ID>.\n' "$1" >&2
                print_usage >&2
                exit 1
                ;;
        esac
        shift
    done
}

prompt_yes_no() {
    local prompt="$1"
    local default_choice="${2:-Y}"
    local default_upper
    default_upper=$(printf '%s' "$default_choice" | tr '[:lower:]' '[:upper:]')
    local options
    local reply=""
    local normalized=""

    if (( UNATTENDED )); then
        info "Unattended mode active; skipping prompt '$prompt'."
        return 1
    fi

    case "$default_upper" in
        Y) options='Y/n' ;;
        N) options='y/N' ;;
        *) options='y/n'
             default_upper='' ;;
    esac

    while true; do
        printf '%s (%s): ' "$prompt" "$options" > /dev/tty
        if ! read -r reply < /dev/tty; then
            reply=""
        fi

        normalized=$(printf '%s' "$reply" | tr -d ' \t\r\n' | tr '[:upper:]' '[:lower:]')

        if [[ -z "$normalized" && -n "$default_upper" ]]; then
            normalized=$(printf '%s' "$default_upper" | tr '[:upper:]' '[:lower:]')
        fi

        case "$normalized" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) printf 'Please answer Y or N.\n' > /dev/tty ;;
        esac
    done
}

prompt_confirmed_input() {
    local prompt="$1"
    local __resultvar="$2"
    local value=""

    while true; do
        printf '%s: ' "$prompt" > /dev/tty
        if ! read -r value < /dev/tty; then
            value=""
        fi
        printf 'You entered: %s\n' "$value" > /dev/tty
        if prompt_yes_no 'Is this correct?' 'Y'; then
            printf -v "$__resultvar" '%s' "$value"
            return 0
        fi
    done
}

step() {
    STEP=$((STEP + 1))
    printf '\nStep %d: %s\n' "$STEP" "$1"
}

generate_interface_name() {
    local net_id="${1,,}"
    local prefix="zt"
    local suffix="${net_id:0:10}"
    printf '%s%s' "$prefix" "$suffix"
}

cleanup() {
    if [[ ${RW_ENGAGED:-0} -eq 1 ]] && command -v ro >/dev/null 2>&1; then
        ro || warn 'Failed to switch filesystem back to read-only mode.'
    fi
}

trap cleanup EXIT

ensure_iptables_installed() {
    if pacman -Q iptables >/dev/null 2>&1; then
        return
    fi

    info 'Installing iptables package...'
    refresh_package_db
    pacman -S --noconfirm iptables
    success 'iptables installed.'
}

detect_default_interface() {
    ip -o route get 1.1.1.1 2>/dev/null |
        awk '{ for (i = 1; i <= NF; ++i) if ($i == "dev") { print $(i + 1); exit } }'
}

detect_zerotier_interface() {
    local zt_iface=""
    local target

    if command -v zerotier-cli >/dev/null 2>&1; then
        target=$(printf '%s' "$NETWORK_ID" | tr '[:upper:]' '[:lower:]')
        local line
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            local -a tokens=()
            local token lower found dev guess
            read -ra tokens <<<"$line"

            found=0
            dev=""
            guess=""

            for token in "${tokens[@]}"; do
                lower=${token,,}
                if [[ "$lower" == "$target" ]]; then
                    found=1
                elif [[ "$token" == dev=* ]]; then
                    local value="${token#dev=}"
                    if [[ -n "$value" ]]; then
                        dev="$value"
                    fi
                elif [[ "$token" == zt[0-9a-f]* ]]; then
                    guess="$token"
                fi
            done

            if (( found )); then
                if [[ -n "$dev" ]]; then
                    zt_iface="$dev"
                elif [[ -n "$guess" ]]; then
                    zt_iface="$guess"
                fi
                break
            fi
        done < <(zerotier-cli listnetworks 2>/dev/null || true)
    fi

    if [[ -z "$zt_iface" ]]; then
        local link_line iface
        while IFS= read -r link_line; do
            [[ -z "$link_line" ]] && continue
            link_line=${link_line#*: }
            iface=${link_line%%:*}
            iface=${iface%% *}
            iface=${iface# }  # trim leading space if any
            if [[ "$iface" == zt[0-9a-f]* ]]; then
                zt_iface="$iface"
                break
            fi
        done < <(ip -o link show 2>/dev/null || true)
    fi

    printf '%s' "$zt_iface"
}

ensure_iptables_rule() {
    local table="$1"
    local chain="$2"
    shift 2
    local -a args=("$@")
    local -a table_flag=()

    if [[ -n "$table" ]]; then
        table_flag=(-t "$table")
    fi

    if iptables "${table_flag[@]}" -C "$chain" "${args[@]}" >/dev/null 2>&1; then
        info "iptables rule already present in $chain chain."
        return
    fi

    if iptables "${table_flag[@]}" -A "$chain" "${args[@]}"; then
        success "Added iptables rule to $chain chain."
    else
        warn "Failed to add iptables rule to $chain chain."
    fi
}

configure_nat_rules() {
    if (( ENABLE_IP_FORWARD == 0 )); then
        info 'Skipping NAT/firewall configuration (no --ip-forward flag).'
        return
    fi

    step 'Configuring NAT and forwarding rules...'

    ensure_iptables_installed

    local phy_iface
    phy_iface=$(detect_default_interface)
    if [[ -z "$phy_iface" ]]; then
        warn 'Unable to detect the primary network interface; skipping NAT configuration.'
        return
    fi
    info "Detected uplink interface: $phy_iface"

    local zt_iface="$ZT_INTERFACE"

    if [[ -z "$zt_iface" ]]; then
        zt_iface=$(detect_zerotier_interface)
    fi

    if [[ -z "$zt_iface" ]]; then
        warn "Unable to detect the ZeroTier interface for network $NETWORK_ID; skipping NAT configuration."
        return
    fi
    if [[ -n "$ZT_INTERFACE" && "$zt_iface" != "$ZT_INTERFACE" ]]; then
        warn "Expected ZeroTier interface $ZT_INTERFACE but detected $zt_iface; proceeding with detected value."
    fi
    info "Using ZeroTier interface: $zt_iface"

    ensure_iptables_rule nat POSTROUTING -o "$phy_iface" -j MASQUERADE
    ensure_iptables_rule filter FORWARD -i "$phy_iface" -o "$zt_iface" -m state --state RELATED,ESTABLISHED -j ACCEPT
    ensure_iptables_rule filter FORWARD -i "$zt_iface" -o "$phy_iface" -j ACCEPT

    mkdir -p /etc/iptables
    if iptables-save > /etc/iptables/iptables.rules; then
        success 'Persisted iptables rules to /etc/iptables/iptables.rules.'
    else
        warn 'Failed to persist iptables rules.'
    fi

    if systemctl enable --now iptables >/dev/null 2>&1; then
        success 'iptables service enabled to restore rules on boot.'
    else
        warn 'Failed to enable iptables service; please enable it manually.'
    fi
}
update_system() {
    if ! command -v pikvm-update; then
        warn "'pikvm-update' not found; skipping system update."
        return
    fi

    info 'Updating PiKVM system...'
    set +e
    pikvm-update
    local rc=$?
    set -e

    if (( rc == 0 )); then
        success 'System updated successfully.'
    else
        warn "pikvm-update exited with status $rc. Continuing with installation."
    fi
}

refresh_package_db() {
    if (( PACMAN_DB_REFRESHED )); then
        return
    fi
    info 'Refreshing pacman package database...'
	rw
    pacman -Sy --noconfirm
    PACMAN_DB_REFRESHED=1
    success 'Package database refreshed.'
}

install_zerotier() {
    step 'Installing ZeroTier and generating identity...'

    if pacman -Q zerotier-one; then
        info 'ZeroTier is already installed; skipping package installation.'
    else
        info 'Installing zerotier-one package...'
        pacman -S --noconfirm zerotier-one
    fi

    info 'Enabling and starting ZeroTier service...'
    systemctl enable --now "$SERVICE"

    info 'Waiting for identity generation...'
    sleep 5

    info 'Stopping ZeroTier service so the identity can be persisted.'
    systemctl stop "$SERVICE"
    success 'ZeroTier service prepared.'
}

retrieve_identity() {
    step 'Retrieving ZeroTier address...'

    local identity_file="$RUNTIME_DIR/identity.public"
    if [[ -f "$identity_file" ]]; then
        ZEROTIER_ADDRESS=$(cut -d: -f1 < "$identity_file")
        info "ZeroTier address: $ZEROTIER_ADDRESS"
        success 'Identity retrieved.'
    else
        printf 'ERROR: ZeroTier identity file not found at %s.\n' "$identity_file" >&2
        exit 1
    fi
}

find_existing_network() {
    local dir="$PERSIST_DIR/networks.d"
    if [[ ! -d "$dir" ]]; then
        return 1
    fi

    shopt -s nullglob
    local configs=("$dir"/*.conf)
    shopt -u nullglob

    for conf in "${configs[@]}"; do
        [[ $conf == *.local.conf ]] && continue
        basename "$conf" .conf
        return 0
    done

    return 1
}

choose_network_id() {
    step 'Network ID configuration...'

    if [[ -n "$NETWORK_ID" ]]; then
        NETWORK_ID=$(printf '%s' "$NETWORK_ID" | tr '[:upper:]' '[:lower:]')
        ZT_INTERFACE=$(generate_interface_name "$NETWORK_ID")
        info "Using provided network ID: $NETWORK_ID"
        printf '\nNOTE: As soon as this PiKVM connects, it will appear in ZeroTier Central as a pending member if your network is Private.\n\n'
        return
    fi

    local existing_network=""
    if existing_network=$(find_existing_network); then
        info "Found existing ZeroTier network configuration: $existing_network"
        if prompt_yes_no 'Do you want to use this existing network?' 'Y'; then
            NETWORK_ID=$(printf '%s' "$existing_network" | tr '[:upper:]' '[:lower:]')
            ZT_INTERFACE=$(generate_interface_name "$NETWORK_ID")
            info "Using existing network ID: $NETWORK_ID"
            return
        fi
    fi

    prompt_confirmed_input 'Please enter your ZeroTier Network ID' NETWORK_ID
    NETWORK_ID=$(printf '%s' "$NETWORK_ID" | tr '[:upper:]' '[:lower:]')
    ZT_INTERFACE=$(generate_interface_name "$NETWORK_ID")
    info "Using provided network ID: $NETWORK_ID"
    printf '\nNOTE: As soon as this PiKVM connects, it will appear in ZeroTier Central as a pending member if your network is Private.\n\n'
}

persist_identity() {
    step 'Moving ZeroTier identity files to persistent storage...'

    info 'Creating persistent storage directory if needed...'
    kvmd-pstrun -- mkdir -p "$PERSIST_DIR"

    if [[ -f "$PERSIST_DIR/identity.public" && -f "$PERSIST_DIR/identity.secret" ]]; then
        info 'Identity files already exist in persistent storage; skipping copy.'
    else
        info 'Copying identity files to persistent storage...'
        kvmd-pstrun -- cp -a "$RUNTIME_DIR"/*.public "$PERSIST_DIR"/
        kvmd-pstrun -- cp -a "$RUNTIME_DIR"/*.secret "$PERSIST_DIR"/
    fi

    success 'Identity persisted.'
}

configure_network() {
    step 'Creating network configuration...'

    kvmd-pstrun -- mkdir -p "$PERSIST_DIR/networks.d"
    local config_file="$PERSIST_DIR/networks.d/$NETWORK_ID.conf"
    local dns_file="$PERSIST_DIR/networks.d/$NETWORK_ID.local.conf"

    if [[ -f "$config_file" ]]; then
        info "Network configuration for $NETWORK_ID already exists."
    else
        kvmd-pstrun -- touch "$config_file"
        info "Created configuration stub for network $NETWORK_ID."
    fi

    if (( FORCE_DNS )); then
        kvmd-pstrun -- sh -c "echo 'allowDNS=1' > '$dns_file'"
        success "DNS enabled for network $NETWORK_ID."
    else
        if (( UNATTENDED )); then
            info 'DNS configuration left unchanged (no --force-dns flag supplied).'
        else
            if [[ -f "$dns_file" ]]; then
                info "DNS configuration for $NETWORK_ID already exists; skipping."
            else
                if prompt_yes_no 'Do you want to enable DNS for this network?' 'N'; then
                    kvmd-pstrun -- sh -c "echo 'allowDNS=1' > '$dns_file'"
                    success "DNS enabled for network $NETWORK_ID."
                else
                    info 'DNS remains disabled; you can enable it later by editing the .local.conf file or by using --force-dns.'
                fi
            fi
        fi
    fi

    success 'Network configuration ensured.'
}

configure_devicemap() {
    if [[ -z "$ZT_INTERFACE" ]]; then
        warn 'Interface name not determined; skipping devicemap configuration.'
        return
    fi

    step 'Configuring stable ZeroTier interface name...'

    kvmd-pstrun -- mkdir -p "$PERSIST_DIR"

    kvmd-pstrun -- sh -c "tmp='$PERSIST_DIR/devicemap.tmp'; (grep -v '^$NETWORK_ID=' '$PERSIST_DIR/devicemap' 2>/dev/null || true) >\"\$tmp\"; printf '%s=%s\n' '$NETWORK_ID' '$ZT_INTERFACE' >>\"\$tmp\"; mv \"\$tmp\" '$PERSIST_DIR/devicemap'; chmod 0644 '$PERSIST_DIR/devicemap'"

    mkdir -p "$RUNTIME_DIR"
    if cp "$PERSIST_DIR/devicemap" "$RUNTIME_DIR/devicemap" 2>/dev/null; then
        success "Device map set to $ZT_INTERFACE for network $NETWORK_ID."
    else
        warn 'Failed to copy devicemap to runtime directory; ZeroTier may need to re-read it on restart.'
    fi
}

configure_ip_forwarding() {
    if (( ENABLE_IP_FORWARD == 0 )); then
        if (( UNATTENDED )); then
            info 'Skipping IPv4 forwarding configuration (no --ip-forward flag).'
            return
        fi

        if prompt_yes_no 'Do you want to enable IPv4 forwarding and configure NAT for ZeroTier?' 'Y'; then
            ENABLE_IP_FORWARD=1
            info 'IPv4 forwarding/NAT will be enabled.'
        else
            info 'IPv4 forwarding will remain disabled.'
            return
        fi
    fi

    step 'Enabling IPv4 forwarding...'

    if ! sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        warn 'Failed to set net.ipv4.ip_forward=1.'
    fi
    kvmd-pstrun -- sh -c "mkdir -p /etc/sysctl.d && echo 'net.ipv4.ip_forward=1' > /etc/sysctl.d/99-zerotier.conf"
    success 'IPv4 forwarding enabled and persisted.'
}
setup_tmpfs_mount() {
    step 'Setting up tmpfs mount for ZeroTier runtime directory...'

    if mountpoint -q "$RUNTIME_DIR"; then
        info 'tmpfs already mounted; skipping setup.'
        success 'tmpfs configuration verified.'
        return
    fi

    if [[ -d "$RUNTIME_DIR" ]] && ! mountpoint -q "$RUNTIME_DIR"; then
        rm -rf "$RUNTIME_DIR"
    fi

    mkdir -p "$RUNTIME_DIR"

    if ! grep -Eq '^\s*tmpfs\s+/var/lib/zerotier-one\s+tmpfs\b' /etc/fstab; then
        echo 'tmpfs /var/lib/zerotier-one  tmpfs  mode=0755  0  0' >> /etc/fstab
        info 'Added tmpfs entry to /etc/fstab.'
    else
        info 'tmpfs entry already present in /etc/fstab.'
    fi

    mount -a
    success 'tmpfs mount configured.'
}

configure_systemd_override() {
    step 'Creating systemd service override...'

    local override_dir="/etc/systemd/system/${SERVICE}.d"
    local override_file="$override_dir/override.conf"

    if [[ -f "$override_file" ]]; then
        info 'Systemd override already exists; skipping creation.'
        return
    fi

    mkdir -p "$override_dir"
    cat > "$override_file" <<'EOF'
[Unit]
Requires=var-lib-zerotier\x2done.mount
ConditionPathIsReadWrite=/var/lib/zerotier-one

[Service]
ExecStartPre=-/usr/bin/find /var/lib/zerotier-one -mindepth 1 -delete
ExecStartPre=/usr/bin/cp -a /var/lib/kvmd/pst/data/zerotier-one /var/lib/
EOF

    systemctl daemon-reload
    success 'Systemd override created.'
}

make_read_only() {
    step 'Switching filesystem to read-only mode...'

    if command -v ro >/dev/null 2>&1; then
        ro
        RW_ENGAGED=0
        success 'Filesystem set to read-only.'
    else
        warn "'ro' command not found; please ensure the filesystem is restored manually."
    fi
}

wait_for_service_ready() {
    local port_file="$1"
    local total_wait="${2:-30}"
    local interval="${3:-2}"
    local remaining=$total_wait

    while (( remaining > 0 )); do
        if [[ -f "$port_file" ]]; then
            return 0
        fi
        printf 'Waiting for ZeroTier to initialize... (%d seconds remaining)\n' "$remaining"
        sleep "$interval"
        remaining=$((remaining - interval))
    done

    return 1
}

start_and_join_network() {
    step 'Starting ZeroTier service and joining network...'

    systemctl start "$SERVICE"

    if wait_for_service_ready "$RUNTIME_DIR/zerotier-one.port" 30 2; then
        success 'ZeroTier service is ready.'
    else
        printf 'ERROR: ZeroTier service failed to initialize properly.\n' >&2
        exit 1
    fi

    info "Joining ZeroTier network $NETWORK_ID..."
    if ! zerotier-cli join "$NETWORK_ID"; then
        printf 'ERROR: Failed to join network %s.\n' "$NETWORK_ID" >&2
        zerotier-cli listnetworks || true
        exit 1
    fi

    success "Joined network $NETWORK_ID. Waiting 10 seconds for stabilization..."
    sleep 10

    systemctl status "$SERVICE" --no-pager -l
    printf '\n'
    zerotier-cli listnetworks
    printf '\n'

    printf 'ZeroTier interfaces (if any):\n'
    if ! ip -o addr show | grep ' zt'; then
        info 'No ZeroTier interface found yet. Please wait and check again.'
    fi
}

print_summary() {
    printf '\n========================================\n'
    printf 'ZeroTier Installation Complete!\n'
    printf '========================================\n\n'
    printf 'Your ZeroTier address: %s\n' "$ZEROTIER_ADDRESS"
    printf 'Network ID used: %s\n\n' "$NETWORK_ID"
    printf 'If you see a ZeroTier interface above, you can now access your PiKVM using that IP.\n'
    printf 'If no IP appears, approve the device in ZeroTier Central or verify the network configuration.\n\n'
    printf 'Useful troubleshooting commands:\n'
    printf '%s\n' "- systemctl status $SERVICE"
    printf '%s\n' '- zerotier-cli listnetworks'
    printf '%s\n\n' "- journalctl -u $SERVICE -f"
}

wait_for_approval() {
    if (( WAIT_FOR_APPROVAL == 0 )); then
        info 'Skipping approval wait (--no-wait-approval flag supplied).'
        return
    fi

    printf 'Open https://my.zerotier.com, select network %s, and approve the member with address %s.\n' "$NETWORK_ID" "$ZEROTIER_ADDRESS"
    printf 'Monitoring status every 2 seconds. Press Ctrl+C to stop.\n'

    local start_ts
    start_ts=$(date +%s)

    while true; do
        local line
        line=$(zerotier-cli listnetworks 2>/dev/null | grep "$NETWORK_ID" || true)

        if [[ -n "$line" ]] && grep -qw 'OK' <<<"$line"; then
            break
        fi

        local elapsed=$(( $(date +%s) - start_ts ))
        printf '\rWaiting for approval... %02d:%02d' $((elapsed / 60)) $((elapsed % 60))
        sleep 2
    done

    printf '\nApproved! Status is OK.\n'
    printf 'Network status after approval:\n'
    zerotier-cli listnetworks | grep "$NETWORK_ID" || true

    printf '\nZeroTier interfaces and current addresses:\n'
    ip -o addr show | grep ' zt' || true

    info 'All set. If your network assigns a ZeroTier IP, it should appear above.'
}

main() {
    print_banner
    require_root

    parse_args "$@"

    if [[ -n "$NETWORK_ARG" ]]; then
        NETWORK_ID="$NETWORK_ARG"
        if [[ ! "$NETWORK_ID" =~ ^[0-9a-fA-F]{16}$ ]]; then
            printf 'ERROR: Invalid ZeroTier network ID "%s". Expected 16 hex characters.\n' "$NETWORK_ID" >&2
            exit 1
        fi
        NETWORK_ID=$(printf '%s' "$NETWORK_ID" | tr '[:upper:]' '[:lower:]')
        ZT_INTERFACE=$(generate_interface_name "$NETWORK_ID")
    fi

    if (( UNATTENDED )); then
        if [[ -z "$NETWORK_ID" ]]; then
            printf 'ERROR: --unattended requires --network-id <ID>.\n' >&2
            exit 1
        fi
        info "Unattended mode enabled. Network ID: $NETWORK_ID"
        refresh_package_db
    elif prompt_yes_no 'Update the PiKVM system before installing ZeroTier?' 'Y'; then
        update_system
    else
        info 'Skipping system update.'
        refresh_package_db
    fi

    info 'Switching filesystem to read-write mode...'
    if command -v rw >/dev/null 2>&1; then
        rw
        RW_ENGAGED=1
    else
        warn "'rw' command not found; ensure the filesystem is writable."
    fi

    install_zerotier
    retrieve_identity
    choose_network_id
    persist_identity
    configure_network
    configure_devicemap
    configure_ip_forwarding
    setup_tmpfs_mount
    configure_systemd_override
    start_and_join_network
    configure_nat_rules
    make_read_only
    print_summary

    wait_for_approval
    
}

main "$@"