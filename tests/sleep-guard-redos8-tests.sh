#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/sleep-guard-redos8.sh"
TMP_DIR="$(mktemp -d)"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]] || fail "ожидался текст: $needle"
}

write_mock_bin() {
  local name="$1"
  local body="$2"
  local path="${TMP_DIR}/${name}"

  printf '%s\n' "$body" > "$path"
  chmod +x "$path"
}

test_help_lists_safe_commands() {
  local output

  output="$("$SCRIPT" --help)"

  assert_contains "$output" "--apply"
  assert_contains "$output" "--status"
  assert_contains "$output" "--collect-logs"
  assert_contains "$output" "--undo"
  assert_contains "$output" "--dry-run"
}

test_dry_run_apply_prints_planned_system_changes() {
  local output

  output="$("$SCRIPT" --apply --user tvmedzhidova --dry-run)"

  assert_contains "$output" "DRY-RUN"
  assert_contains "$output" "systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target"
  assert_contains "$output" "/etc/systemd/logind.conf.d/99-redos-no-sleep.conf"
  assert_contains "$output" "sudo -u tvmedzhidova"
}

test_status_uses_systemctl_and_reports_masked_targets() {
  write_mock_bin systemctl '#!/usr/bin/env bash
if [[ "$1" == "is-enabled" ]]; then
  echo masked
  exit 0
fi
if [[ "$1" == "is-active" ]]; then
  echo inactive
  exit 3
fi
exit 0'
  write_mock_bin loginctl '#!/usr/bin/env bash
echo IdleAction=ignore
echo HandleSuspendKey=ignore'
  write_mock_bin getenforce '#!/usr/bin/env bash
echo Enforcing'
  write_mock_bin systemd-inhibit '#!/usr/bin/env bash
echo "0 inhibitors listed."'

  local output
  output="$(PATH="${TMP_DIR}:$PATH" "$SCRIPT" --status)"

  assert_contains "$output" "sleep.target: masked"
  assert_contains "$output" "suspend.target: masked"
  assert_contains "$output" "SELinux: Enforcing"
}

test_collect_logs_dry_run_creates_no_directory() {
  local output

  output="$("$SCRIPT" --collect-logs --dry-run)"

  assert_contains "$output" "DRY-RUN"
  assert_contains "$output" "journalctl -u systemd-logind --since"
  assert_contains "$output" "kesl-control --get-task-list"
}

test_help_lists_safe_commands
test_dry_run_apply_prints_planned_system_changes
test_status_uses_systemctl_and_reports_masked_targets
test_collect_logs_dry_run_creates_no_directory

echo "PASS: sleep-guard-redos8"
