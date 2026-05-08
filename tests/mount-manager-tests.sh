#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/mount-manager.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equals() {
  local expected="$1"
  local actual="$2"

  [[ "$actual" == "$expected" ]] || fail "ожидалось: ${expected}; получено: ${actual}"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]] || fail "ожидался текст: $needle"
}

test_kerberos_mount_options_use_current_user_uid() {
  local output

  output="$(MOUNT_MANAGER_TESTING=1 source "$SCRIPT"; build_kerberos_mount_options 1000)"

  assert_contains "$output" "sec=krb5"
  assert_contains "$output" "cruid=1000"
  assert_contains "$output" "multiuser"
  [[ "$output" != *"credentials="* ]] || fail "Kerberos-режим не должен использовать credentials-файл"
}

test_domain_mode_detects_realm_membership() {
  realm() {
    if [[ "$1" == "list" ]]; then
      echo "example.local"
      return 0
    fi
    return 1
  }

  MOUNT_MANAGER_TESTING=1 source "$SCRIPT"
  is_domain_joined || fail "ожидалась успешная проверка домена через realm list"
}

test_kerberos_principal_uses_domain_suffix() {
  local principal

  MOUNT_MANAGER_TESTING=1 source "$SCRIPT"
  principal="$(build_kerberos_principal "ivan" "example.local")"

  assert_equals "ivan@EXAMPLE.LOCAL" "$principal"
}

test_kerberos_mount_options_use_current_user_uid
test_domain_mode_detects_realm_membership
test_kerberos_principal_uses_domain_suffix

echo "PASS: mount-manager"
