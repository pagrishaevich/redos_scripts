#!/usr/bin/env bash
##############################################################################
# sleep-guard-redos8.sh — запрет спящего режима на РЕД ОС 8 / MATE
#
# Описание:
#   Скрипт отключает системный suspend/hibernate через systemd, настраивает
#   systemd-logind на игнорирование событий сна и, при указании пользователя,
#   выключает таймеры сна/гашения экрана в MATE.
#
# Использование:
#   sudo ./sleep-guard-redos8.sh --apply --user ИМЯ
#   sudo ./sleep-guard-redos8.sh --status
#   sudo ./sleep-guard-redos8.sh --collect-logs
#   sudo ./sleep-guard-redos8.sh --undo
##############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOGIND_DROPIN_DIR="/etc/systemd/logind.conf.d"
LOGIND_DROPIN="${LOGIND_DROPIN_DIR}/99-redos-no-sleep.conf"
TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)

ACTION=""
TARGET_USER=""
DRY_RUN=0
SELINUX_PERMISSIVE=0

print_info() {
    echo -e "${BLUE}$*${NC}"
}

print_ok() {
    echo -e "${GREEN}$*${NC}"
}

print_warn() {
    echo -e "${YELLOW}$*${NC}"
}

print_error() {
    echo -e "${RED}$*${NC}" >&2
}

run_cmd() {
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN: $*"
        return 0
    fi

    "$@"
}

require_root() {
    if [[ "$DRY_RUN" == "1" ]]; then
        return 0
    fi

    if [[ "${EUID}" -ne 0 ]]; then
        print_error "Ошибка: для этой операции нужны права root."
        echo "Запустите: sudo $0 $ACTION" >&2
        exit 1
    fi
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    local cmd="$1"

    if [[ "$DRY_RUN" == "1" ]]; then
        return 0
    fi

    if ! command_exists "$cmd"; then
        print_error "Ошибка: команда не найдена: $cmd"
        exit 1
    fi
}

check_core_dependencies() {
    require_command systemctl
    require_command journalctl
    require_command grep
    require_command sed
    require_command mktemp
    require_command install
    require_command cp
    require_command id
}

backup_file() {
    local path="$1"

    [[ -e "$path" ]] || return 0
    run_cmd cp -a "$path" "${path}.bak.$(date +%Y%m%d_%H%M%S)"
}

write_logind_dropin() {
    local tmp_file
    tmp_file="$(mktemp)"

    cat > "$tmp_file" <<'EOF'
[Login]
IdleAction=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN: mkdir -p ${LOGIND_DROPIN_DIR}"
        echo "DRY-RUN: write ${LOGIND_DROPIN}"
        rm -f "$tmp_file"
        return 0
    fi

    mkdir -p "$LOGIND_DROPIN_DIR"
    backup_file "$LOGIND_DROPIN"
    install -m 0644 "$tmp_file" "$LOGIND_DROPIN"
    rm -f "$tmp_file"
}

mask_sleep_targets() {
    run_cmd systemctl mask "${TARGETS[@]}"
}

unmask_sleep_targets() {
    run_cmd systemctl unmask "${TARGETS[@]}"
}

restart_logind() {
    run_cmd systemctl restart systemd-logind
}

user_uid() {
    local user="$1"

    id -u "$user" 2>/dev/null || true
}

run_gsettings_for_user() {
    local user="$1"
    shift

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN: sudo -u ${user} DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u ${user})/bus gsettings $*"
        return 0
    fi

    local uid
    uid="$(user_uid "$user")"

    if [[ -z "$uid" ]]; then
        print_warn "Пользователь не найден, настройки MATE пропущены: $user"
        return 0
    fi

    local bus="DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus"

    if [[ ! -S "/run/user/${uid}/bus" ]]; then
        print_warn "D-Bus сессия пользователя ${user} не найдена, настройки MATE пропущены."
        print_warn "Пользователь может выполнить эти команды после входа в графическую сессию."
        return 0
    fi

    if command_exists runuser; then
        runuser -u "$user" -- env "$bus" gsettings "$@"
    elif command_exists sudo; then
        sudo -u "$user" env "$bus" gsettings "$@"
    else
        print_warn "Не найден runuser/sudo, настройки MATE для ${user} пропущены."
    fi
}

apply_mate_settings() {
    local user="$1"

    [[ -n "$user" ]] || return 0

    if ! command_exists gsettings && [[ "$DRY_RUN" != "1" ]]; then
        print_warn "gsettings не найден, настройки MATE пропущены."
        return 0
    fi

    run_gsettings_for_user "$user" set org.mate.power-manager sleep-computer-ac 0
    run_gsettings_for_user "$user" set org.mate.power-manager sleep-computer-battery 0
    run_gsettings_for_user "$user" set org.mate.power-manager sleep-display-ac 0
    run_gsettings_for_user "$user" set org.mate.power-manager sleep-display-battery 0
    run_gsettings_for_user "$user" set org.mate.screensaver idle-activation-enabled false
}

maybe_set_selinux_permissive() {
    if [[ "$SELINUX_PERMISSIVE" != "1" ]]; then
        return 0
    fi

    if ! command_exists setenforce; then
        print_warn "setenforce не найден, SELinux не изменён."
        return 0
    fi

    run_cmd setenforce 0
}

apply_changes() {
    require_root
    check_core_dependencies

    print_info "Отключение системного сна через systemd targets..."
    mask_sleep_targets

    print_info "Настройка systemd-logind..."
    write_logind_dropin
    restart_logind

    if [[ -n "$TARGET_USER" ]]; then
        print_info "Отключение таймеров MATE для пользователя ${TARGET_USER}..."
        apply_mate_settings "$TARGET_USER"
    else
        print_warn "Пользователь не указан: настройки MATE не применялись."
        print_warn "Пример: sudo $0 --apply --user tvmedzhidova"
    fi

    maybe_set_selinux_permissive
    print_ok "Применение завершено. Проверьте статус командой: $0 --status"
}

undo_changes() {
    require_root
    require_command systemctl

    print_info "Разблокировка системных целей сна..."
    unmask_sleep_targets

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN: rm -f ${LOGIND_DROPIN}"
    else
        if [[ -e "$LOGIND_DROPIN" ]]; then
            backup_file "$LOGIND_DROPIN"
            rm -f "$LOGIND_DROPIN"
        fi
    fi

    restart_logind
    print_ok "Откат системных изменений завершён."
}

target_enabled_state() {
    local target="$1"
    local state

    state="$(systemctl is-enabled "$target" 2>/dev/null || true)"
    [[ -n "$state" ]] || state="unknown"
    echo "$state"
}

show_status() {
    require_command systemctl

    echo "Статус целей сна:"
    local target
    for target in "${TARGETS[@]}"; do
        echo "  ${target}: $(target_enabled_state "$target")"
    done

    if command_exists loginctl; then
        echo
        echo "Параметры logind:"
        loginctl show-logind -p IdleAction -p HandleLidSwitch -p HandleSuspendKey -p HandleHibernateKey 2>/dev/null || true
    fi

    if command_exists getenforce; then
        echo
        echo "SELinux: $(getenforce 2>/dev/null || true)"
    fi

    if command_exists systemd-inhibit; then
        echo
        echo "Inhibitors:"
        systemd-inhibit --list 2>/dev/null || true
    fi
}

collect_logs() {
    local since="${1:-24 hours ago}"
    local stamp out_dir
    stamp="$(date +%Y%m%d_%H%M%S)"
    out_dir="./sleep-guard-logs-${stamp}"

    if [[ "$DRY_RUN" == "1" ]]; then
        echo "DRY-RUN: mkdir -p ${out_dir}"
        echo "DRY-RUN: journalctl -u systemd-logind --since \"${since}\" > ${out_dir}/systemd-logind.log"
        echo "DRY-RUN: journalctl -b | grep -iE 'sleep|suspend|hibernate|systemd-sleep|NetworkManager|kesl|selinux' > ${out_dir}/sleep-events.log"
        echo "DRY-RUN: systemd-inhibit --list > ${out_dir}/inhibitors.log"
        echo "DRY-RUN: systemctl status ${TARGETS[*]} > ${out_dir}/targets-status.log"
        echo "DRY-RUN: kesl-control --get-task-list > ${out_dir}/kesl-task-list.log"
        return 0
    fi

    mkdir -p "$out_dir"
    journalctl -u systemd-logind --since "$since" > "${out_dir}/systemd-logind.log" 2>&1 || true
    journalctl -b | grep -iE 'sleep|suspend|hibernate|systemd-sleep|NetworkManager|kesl|selinux' > "${out_dir}/sleep-events.log" 2>&1 || true
    systemctl status "${TARGETS[@]}" > "${out_dir}/targets-status.log" 2>&1 || true

    if command_exists systemd-inhibit; then
        systemd-inhibit --list > "${out_dir}/inhibitors.log" 2>&1 || true
    fi

    if command_exists getenforce; then
        getenforce > "${out_dir}/selinux-status.log" 2>&1 || true
    fi

    if command_exists kesl-control; then
        kesl-control --get-task-list > "${out_dir}/kesl-task-list.log" 2>&1 || true
    fi

    print_ok "Логи собраны в каталог: ${out_dir}"
}

show_help() {
    cat <<'EOF'
sleep-guard-redos8.sh — запрет спящего режима на РЕД ОС 8 / MATE

Использование:
  sudo ./sleep-guard-redos8.sh --apply --user ИМЯ
  sudo ./sleep-guard-redos8.sh --status
  sudo ./sleep-guard-redos8.sh --collect-logs
  sudo ./sleep-guard-redos8.sh --undo

Команды:
  --apply              Замаскировать sleep/suspend/hibernate targets и настроить logind.
  --status             Показать текущий статус targets, logind, SELinux и inhibitors.
  --collect-logs       Собрать диагностические логи в локальный каталог.
  --undo               Откатить системную часть изменений.

Опции:
  --user ИМЯ           Пользователь MATE, которому отключаются таймеры сна.
  --dry-run            Показать действия без изменения системы.
  --selinux-permissive Временно выполнить setenforce 0 при --apply.
  -h, --help           Показать эту справку.

Примеры:
  sudo ./sleep-guard-redos8.sh --apply --user tvmedzhidova
  ./sleep-guard-redos8.sh --collect-logs
  ./sleep-guard-redos8.sh --apply --user tvmedzhidova --dry-run
EOF
}

parse_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --apply|--status|--collect-logs|--undo)
                ACTION="$1"
                ;;
            --user)
                shift
                [[ "$#" -gt 0 ]] || {
                    print_error "Ошибка: после --user нужно указать имя пользователя."
                    exit 1
                }
                TARGET_USER="$1"
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --selinux-permissive)
                SELINUX_PERMISSIVE=1
                ;;
            -h|--help)
                ACTION="--help"
                ;;
            *)
                print_error "Неизвестная опция: $1"
                echo
                show_help
                exit 1
                ;;
        esac
        shift
    done
}

main() {
    parse_args "$@"

    case "$ACTION" in
        --apply)
            apply_changes
            ;;
        --status)
            show_status
            ;;
        --collect-logs)
            collect_logs
            ;;
        --undo)
            undo_changes
            ;;
        --help|"")
            show_help
            ;;
    esac
}

main "$@"
