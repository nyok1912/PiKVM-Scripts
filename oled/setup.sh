#!/bin/bash

set -euo pipefail
IFS=$'\n\t'

readonly CONFIG_TXT="/boot/config.txt"
readonly MODULES_CONF="/etc/modules-load.d/raspberrypi.conf"

STEP=0
RW_ENGAGED=0
PACMAN_DB_REFRESHED=0

print_banner() {
	printf '==========================================\n'
	printf 'PiKVM OLED Setup Helper\n'
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

fatal() {
	printf 'ERROR: %s\n' "$1" >&2
	exit 1
}

require_root() {
	if [[ ${EUID:-} -ne 0 ]]; then
		fatal 'This script must be run as root.'
	fi
}

print_usage() {
	cat <<'EOF'
Usage: setup.sh
EOF
}

prompt_yes_no() {
	local prompt="$1"
	local default_choice="${2:-Y}"
	local default_upper
	default_upper=$(printf '%s' "$default_choice" | tr '[:lower:]' '[:upper:]')
	local options
	local reply=""
	local normalized=""

	case "$default_upper" in
		Y) options='Y/n' ;;
		N) options='y/N' ;;
		*) options='y/n'
		   default_upper=''
		   ;;
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

step() {
	STEP=$((STEP + 1))
	printf '\nStep %d: %s\n' "$STEP" "$1"
}

cleanup() {
	if [[ ${RW_ENGAGED:-0} -eq 1 ]] && command -v ro >/dev/null 2>&1; then
		ro || warn 'Failed to switch filesystem back to read-only mode.'
	fi
}

trap cleanup EXIT

switch_to_rw() {
	info 'Switching filesystem to read-write mode...'
	if command -v rw >/dev/null 2>&1; then
		rw
		RW_ENGAGED=1
	else
		warn "'rw' command not found; ensure the filesystem is writable."
	fi
}

make_read_only() {
	if [[ ${RW_ENGAGED:-0} -eq 0 ]]; then
		return
	fi

	step 'Restoring filesystem to read-only mode...'
	if command -v ro >/dev/null 2>&1; then
		ro
		RW_ENGAGED=0
		success 'Filesystem set to read-only.'
	else
		warn "'ro' command not found; please set the filesystem to read-only manually."
	fi
}

update_system() {
	if ! command -v pikvm-update >/dev/null 2>&1; then
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
		warn "pikvm-update exited with status $rc. Continuing with OLED setup."
	fi
}

refresh_package_db() {
	if (( PACMAN_DB_REFRESHED )); then
		return
	fi
	info 'Refreshing pacman package database...'
	if command -v rw >/dev/null 2>&1; then
		rw
		RW_ENGAGED=1
	fi
	pacman -Sy --noconfirm
	PACMAN_DB_REFRESHED=1
	success 'Package database refreshed.'
}

append_line_if_missing() {
	local file="$1"
	local line="$2"

	if grep -Fxq -- "$line" "$file" 2>/dev/null; then
		return
	fi

	printf '%s\n' "$line" >> "$file"
	success "Added '$line' to $file."
}

enable_i2c_in_config_txt() {
	step 'Enabling I²C overlays in /boot/config.txt...'

	if [[ ! -f "$CONFIG_TXT" ]]; then
		fatal "File $CONFIG_TXT not found."
	fi

	append_line_if_missing "$CONFIG_TXT" 'dtparam=i2c1=on'
	append_line_if_missing "$CONFIG_TXT" 'dtparam=i2c_arm=on'
}

ensure_modules_conf() {
	step 'Ensuring i2c-dev module loads at boot...'

	mkdir -p "$(dirname "$MODULES_CONF")"
	touch "$MODULES_CONF"

	append_line_if_missing "$MODULES_CONF" 'i2c-dev'
}

install_dependencies() {
	step 'Installing OLED dependencies...'

	if pacman -Q i2c-tools >/dev/null 2>&1; then
		info 'i2c-tools already installed; skipping.'
		return
	fi

	pacman -S --noconfirm i2c-tools
	success 'Installed i2c-tools.'
}

enable_oled_services() {
	step 'Enabling OLED services...'
	systemctl enable --now kvmd-oled
	systemctl enable kvmd-oled-reboot kvmd-oled-shutdown
	success 'OLED services enabled and running.'
}

request_reboot() {
	if prompt_yes_no 'Reboot now to apply OLED changes?' 'Y'; then
		info 'Rebooting now...'
		reboot now
	else
		info 'Reboot skipped. Reboot manually to finalize OLED support.'
	fi
}

print_summary() {
	printf '\n========================================\n'
	printf 'PiKVM OLED Setup Complete\n'
	printf '========================================\n\n'
	printf 'Changes applied:\n'
	printf ' - Enabled I²C overlays in /boot/config.txt\n'
	printf ' - Ensured i2c-dev module loads on boot\n'
	printf ' - Installed i2c-tools package\n'
	printf ' - Enabled kvmd-oled service suite\n'
	printf '\nRemember to reboot if you have not done so yet.\n'
}

main() {
	print_banner
	require_root

	if (( $# > 0 )); then
		print_usage
		exit 1
	fi

	if prompt_yes_no 'Update the PiKVM system before configuring the OLED?' 'Y'; then
		update_system
	else
		info 'Skipping system update.'
	fi

	refresh_package_db

	switch_to_rw

	enable_i2c_in_config_txt
	ensure_modules_conf
	install_dependencies
	enable_oled_services

	make_read_only

	print_summary
	request_reboot
}

main "$@"
