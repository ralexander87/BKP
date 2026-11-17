#!/usr/bin/env bash
set -Eeuo pipefail

PROFILE="FeedMe-6+"
ADDRESS="192.168.8.15/24"
GATEWAY="192.168.8.1"

die() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

field() {
  nmcli -g "$1" connection show "$PROFILE"
}

expect_field() {
  local property="$1"
  local expected="$2"
  local actual

  actual="$(field "$property")" || die "could not read $property"
  [[ "$actual" == "$expected" ]] || die "$property is '${actual:-unset}', expected '$expected'"
}

check_profile() {
  local device="$1"
  local actual

  expect_field connection.autoconnect yes
  expect_field 802-11-wireless.ssid "$PROFILE"
  expect_field 802-11-wireless.mode infrastructure
  expect_field 802-11-wireless.mac-address ""
  expect_field 802-11-wireless.cloned-mac-address ""
  actual="$(field 802-11-wireless.mtu)" || die "could not read WiFi MTU"
  [[ "$actual" == "auto" || "$actual" == "0" ]] || die "WiFi MTU is not automatic: $actual"
  expect_field 802-11-wireless-security.psk-flags 0
  expect_field ipv4.method manual
  expect_field ipv4.addresses "$ADDRESS"
  expect_field ipv4.gateway "$GATEWAY"
  expect_field ipv4.dns "$GATEWAY"
  expect_field ipv6.method disabled
  expect_field proxy.method none

  actual="$(nmcli -g GENERAL.CONNECTION device show "$device")" || die "could not read active connection"
  [[ "$actual" == "$PROFILE" ]] || die "$PROFILE is not active on $device"
  actual="$(nmcli -g IP4.ADDRESS device show "$device")" || die "could not read active IPv4 address"
  [[ "$actual" == "$ADDRESS" ]] || die "active IPv4 address is $actual, expected $ADDRESS"
  actual="$(nmcli -g IP4.GATEWAY device show "$device")" || die "could not read active gateway"
  [[ "$actual" == "$GATEWAY" ]] || die "active gateway is $actual, expected $GATEWAY"
  actual="$(nmcli -g IP4.DNS device show "$device")" || die "could not read active DNS"
  [[ "$actual" == "$GATEWAY" ]] || die "active DNS is $actual, expected $GATEWAY"

  if ! nmcli --show-secrets -g 802-11-wireless-security.psk connection show "$PROFILE" |
    awk 'NF { found = 1 } END { exit !found }'; then
    die "no saved WiFi password is available to NetworkManager"
  fi
  printf '[OK] %s is active on %s with the expected profile, IP settings, and saved password\n' "$PROFILE" "$device"
}

wait_for_active_ip() {
  local device="$1"
  local attempt address gateway dns

  for ((attempt = 1; attempt <= 20; attempt++)); do
    address="$(nmcli -g IP4.ADDRESS device show "$device")" || return 1
    gateway="$(nmcli -g IP4.GATEWAY device show "$device")" || return 1
    dns="$(nmcli -g IP4.DNS device show "$device")" || return 1
    if [[ "$address" == "$ADDRESS" && "$gateway" == "$GATEWAY" && "$dns" == "$GATEWAY" ]]; then
      return 0
    fi
    sleep 1
  done
  return 1
}

usage() {
  cat <<'EOF'
Usage: ./tools/check-wifi-live.sh [--reconnect]

Check the live FeedMe-6+ profile without displaying its password.
--reconnect briefly disconnects and reconnects WiFi without prompting for a password.
NetworkManager checkpoints the interface and rolls it back unless the result is confirmed.
EOF
}

case "${1:-}" in
-h | --help)
  usage
  exit 0
  ;;
"" | --reconnect | --activate) ;;
*)
  usage >&2
  exit 2
  ;;
esac

command -v nmcli >/dev/null 2>&1 || die "nmcli is required"
device="$(nmcli -g GENERAL.DEVICES connection show "$PROFILE")" || die "connection profile $PROFILE was not found"
device="${device%%,*}"
[[ -n "$device" && "$device" != "--" ]] || die "connection profile $PROFILE is not active"

case "${1:-}" in
--activate)
  [[ "${BKP_WIFI_CHECKPOINT_ACTIVE:-}" == "1" ]] || die "reconnect requires a NetworkManager checkpoint"
  nmcli connection down "$PROFILE" || die "could not disconnect $PROFILE"
  nmcli --wait 30 connection up "$PROFILE" ifname "$device" || die "could not reconnect $PROFILE without a password prompt"
  wait_for_active_ip "$device" || die "IPv4 settings did not become ready after reconnect"
  check_profile "$device"
  ;;
--reconnect)
  check_profile "$device"
  printf 'Reconnecting %s on %s inside a 60-second NetworkManager checkpoint.\n' "$PROFILE" "$device"
  BKP_WIFI_CHECKPOINT_ACTIVE=1 nmcli device checkpoint --timeout 60 "$device" -- "$0" --activate
  ;;
*)
  check_profile "$device"
  ;;
esac
