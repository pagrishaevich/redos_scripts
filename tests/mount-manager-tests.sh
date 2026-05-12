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

  output="$(MOUNT_MANAGER_TESTING=1 source "$SCRIPT"; build_kerberos_mount_options 1000 1001)"

  assert_contains "$output" "sec=krb5"
  assert_contains "$output" "cruid=1000"
  assert_contains "$output" "uid=1000"
  assert_contains "$output" "gid=1001"
  assert_contains "$output" "forceuid"
  assert_contains "$output" "forcegid"
  assert_contains "$output" "multiuser"
  [[ "$output" != *"credentials="* ]] || fail "Kerberos-режим не должен использовать credentials-файл"
}

test_credentials_mount_options_use_login_user_owner() {
  local output

  output="$(MOUNT_MANAGER_TESTING=1 source "$SCRIPT"; build_credentials_mount_options "/root/.smbuser_test" 1000 1001)"

  assert_contains "$output" "credentials=/root/.smbuser_test"
  assert_contains "$output" "uid=1000"
  assert_contains "$output" "gid=1001"
  assert_contains "$output" "forceuid"
  assert_contains "$output" "forcegid"
  assert_contains "$output" "file_mode=0770"
  assert_contains "$output" "dir_mode=0770"
}

test_mount_owner_prompts_when_running_as_root() {
  local output

  output="$(MOUNT_MANAGER_TESTING=1 source "$SCRIPT";
    get_login_user() { echo root; }
    id() {
      if [[ "$1" == "-u" && "$2" == "ivan" ]]; then echo 1000; return 0; fi
      if [[ "$1" == "-g" && "$2" == "ivan" ]]; then echo 1001; return 0; fi
      if [[ "$1" == "-u" && "$2" == "root" ]]; then echo 0; return 0; fi
      if [[ "$1" == "-g" && "$2" == "root" ]]; then echo 0; return 0; fi
      return 1
    }
    read() {
      local var_name="${@: -1}"
      printf -v "$var_name" '%s' 'ivan'
    }
    resolve_mount_owner)"

  assert_contains "$output" "ivan:1000:1001"
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

test_kerberos_server_ip_resolves_to_fqdn() {
  getent() {
    if [[ "$1" == "hosts" && "$2" == "10.31.8.166" ]]; then
      echo "10.31.8.166 fs01.yg.loc fs01"
      return 0
    fi
    return 1
  }

  local server

  MOUNT_MANAGER_TESTING=1 source "$SCRIPT"
  server="$(resolve_kerberos_server_name "10.31.8.166")"

  assert_equals "fs01.yg.loc" "$server"
}

test_kerberos_server_name_keeps_hostname() {
  local server

  MOUNT_MANAGER_TESTING=1 source "$SCRIPT"
  server="$(resolve_kerberos_server_name "fs01.yg.loc")"

  assert_equals "fs01.yg.loc" "$server"
}

test_kerberos_server_ip_prompts_for_fqdn_when_reverse_dns_missing() {
  getent() {
    return 1
  }

  read() {
    local var_name="${@: -1}"
    printf -v "$var_name" '%s' 'scan.yg.loc'
  }

  local server

  MOUNT_MANAGER_TESTING=1 source "$SCRIPT"
  server="$(select_kerberos_server_name "10.82.101.211" 2>/dev/null)"

  assert_equals "scan.yg.loc" "$server"
}

test_fstab_entry_is_updated_when_share_already_exists() {
  local tmp_fstab
  tmp_fstab="$(mktemp)"

  printf '%s\n' '//srv/share /mnt/share/ cifs credentials=/old,iocharset=utf8 0 0' > "$tmp_fstab"

  MOUNT_MANAGER_TESTING=1 source "$SCRIPT"
  FSTAB="$tmp_fstab"
  MOUNT_BASE="/mnt"
  backup_fstab() { :; }

  add_to_fstab_entry "srv" "share" "share" "/root/.smbuser_test" "0" "credentials" "1000" "1001" >/dev/null

  local content
  content="$(cat "$tmp_fstab")"

  assert_contains "$content" "uid=1000"
  assert_contains "$content" "gid=1001"
  [[ "$(grep -c '^//srv/share /mnt/share/ cifs' "$tmp_fstab")" -eq 1 ]] || fail "запись fstab должна быть одна"

  rm -f "$tmp_fstab"
}

test_busy_mount_point_is_unmounted_before_mounting() {
  local calls=""

  mountpoint() {
    [[ "$1" == "-q" && "$2" == "/mnt/scan" ]]
  }
  findmnt() {
    echo "//old/server"
  }
  read() {
    local var_name="${@: -1}"
    printf -v "$var_name" '%s' 'y'
  }
  umount() {
    calls="${calls} umount:$1"
  }

  MOUNT_MANAGER_TESTING=1 source "$SCRIPT"
  ensure_mount_point_available "/mnt/scan" >/dev/null

  assert_contains "$calls" "umount:/mnt/scan"
}

test_fstab_update_reloads_systemd_daemon() {
  local tmp_fstab
  tmp_fstab="$(mktemp)"
  local calls=""

  printf '%s\n' '//srv/share /mnt/share/ cifs credentials=/old,iocharset=utf8 0 0' > "$tmp_fstab"

  MOUNT_MANAGER_TESTING=1 source "$SCRIPT"
  FSTAB="$tmp_fstab"
  MOUNT_BASE="/mnt"
  backup_fstab() { :; }
  command() {
    [[ "$1" == "-v" && "$2" == "systemctl" ]]
  }
  systemctl() {
    calls="${calls} systemctl:$*"
  }

  add_to_fstab_entry "srv" "share" "share" "/root/.smbuser_test" "0" "credentials" "1000" "1001" >/dev/null

  assert_contains "$calls" "systemctl:daemon-reload"

  rm -f "$tmp_fstab"
}

test_kerberos_mount_options_use_current_user_uid
test_credentials_mount_options_use_login_user_owner
test_mount_owner_prompts_when_running_as_root
test_domain_mode_detects_realm_membership
test_kerberos_principal_uses_domain_suffix
test_kerberos_server_ip_resolves_to_fqdn
test_kerberos_server_name_keeps_hostname
test_kerberos_server_ip_prompts_for_fqdn_when_reverse_dns_missing
test_fstab_entry_is_updated_when_share_already_exists
test_busy_mount_point_is_unmounted_before_mounting
test_fstab_update_reloads_systemd_daemon

echo "PASS: mount-manager"
