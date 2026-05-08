#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/usb-guard.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]] || fail "ожидался текст: $needle"
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" != *"$needle"* ]] || fail "не ожидался текст: $needle"
}

test_udisks_whitelist_generates_separate_allow_rules() {
  local output

  output="$(source <(sed '/^main "\$@"/d' "$SCRIPT"); generate_whitelist_udisks "37438318" "USB_0114" "200mA")"

  assert_contains "$output" 'ENV{ID_USB_DRIVER}=="usb-storage",ENV{UDISKS_IGNORE}="1"'
  assert_contains "$output" 'ENV{ID_USB_DRIVER}=="uas",ENV{UDISKS_IGNORE}="1"'
  assert_contains "$output" 'ATTRS{serial}=="37438318",ENV{UDISKS_IGNORE}="0"'
  assert_contains "$output" 'ATTRS{product}=="USB_0114",ENV{UDISKS_IGNORE}="0"'
  assert_contains "$output" 'ATTRS{bMaxPower}=="200mA",ENV{UDISKS_IGNORE}="0"'
  assert_not_contains "$output" 'ATTRS{serial}=="37438318",ATTRS{product}=="USB_0114",ATTRS{bMaxPower}=="200mA",ENV{UDISKS_IGNORE}="0"'
}

test_udisks_whitelist_generates_separate_allow_rules

echo "PASS: usb-guard"
