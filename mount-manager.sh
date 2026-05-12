#!/bin/bash
##############################################################################
# mount-manager.sh — Управление монтированием сетевых шар (CIFS/SMB)
#
# Автор: pagrishaevich
#
# Описание:
#   Скрипт для управления монтированием пользовательских директорий
#   по протоколу CIFS/SMB. Поддерживает интерактивное меню, командные
#   аргументы, сохранение пресетов и автоматическое добавление в fstab.
#
# Использование:
#   sudo ./mount-manager.sh [ОПЦИИ]
#
# Опции:
#   -h, --help        Справка
#   -l, --list        Список смонтированных шар
#   -a, --add         Добавить новую шару (интерактивно)
#   -r, --remove      Размонтировать шару (интерактивно)
#       --load        Загрузить пресет из конфига
#       --mount-all   Монтировать все шары из fstab
#
# Зависимости: bash, coreutils, mount, cifs-utils (mount.cifs), grep, sed
# Опционально: smbclient (диагностика SMB)
#
# Совместимость: РЕД ОС 7.x ✅, РЕД ОС 8.x ✅
##############################################################################

set -e

# ─── Цвета ────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ─── Константы ────────────────────────────────────────────────────────────
MOUNT_BASE="/mnt"
FSTAB="/etc/fstab"
CREDENTIALS_DIR="/root"
CONFIG_FILE="/etc/mount-manager.conf"

# ─── Вспомогательные функции ──────────────────────────────────────────────
backup_fstab() {
    local backup="${FSTAB}.bak.$(date +%Y%m%d_%H%M%S)"

    cp -a "$FSTAB" "$backup"
    echo -e "${YELLOW}Резервная копия /etc/fstab: ${backup}${NC}"
}

sanitize_name() {
    local value="$1"

    value=$(echo "$value" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/_/g')
    # Удаляем ведущие/хвостовые подчёркивания от замены спецсимволов
    value=$(echo "$value" | sed 's/^_+//;s/_+$//')
    echo "$value"
}

validate_mount_name() {
    local mount_name="$1"

    [[ -n "$mount_name" && "$mount_name" != "." && "$mount_name" != ".." && "$mount_name" =~ ^[A-Za-z0-9._-]+$ ]]
}

# ─── Проверка прав root ──────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Ошибка: скрипт требует прав root${NC}"
        echo "Запустите: sudo $0"
        exit 1
    fi
}

# ─── Проверка зависимостей ───────────────────────────────────────────────
check_dependencies() {
    command -v mount.cifs &>/dev/null || {
        echo -e "${RED}Ошибка: не установлен cifs-utils${NC}"
        echo "Установите: dnf install cifs-utils"
        exit 1
    }

    if ! command -v smbclient &>/dev/null; then
        echo -e "${YELLOW}Предупреждение: smbclient не найден (для диагностики может потребоваться)${NC}"
    fi

    if ! command -v klist &>/dev/null; then
        echo -e "${YELLOW}Предупреждение: klist не найден (для доменной Kerberos-авторизации может потребоваться krb5-workstation)${NC}"
    fi

    if ! command -v cifs.upcall &>/dev/null; then
        echo -e "${YELLOW}Предупреждение: cifs.upcall не найден (для sec=krb5 может потребоваться пакет keyutils)${NC}"
    fi
}

# ─── Доменная авторизация текущего пользователя ─────────────────────────
get_login_user() {
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        echo "$SUDO_USER"
    else
        id -un
    fi
}

get_login_uid() {
    id -u "$(get_login_user)"
}

get_login_gid() {
    id -g "$(get_login_user)"
}

resolve_mount_owner() {
    local owner="${1:-}"

    if [[ -z "$owner" ]]; then
        owner=$(get_login_user)
    fi

    if [[ "$owner" == "root" || -z "$owner" ]]; then
        read -rp "Локальный пользователь, которому дать доступ к mount-point: " owner
    fi

    if [[ -z "$owner" || "$owner" == "root" ]]; then
        echo -e "${RED}Нужно указать обычного локального пользователя, не root${NC}" >&2
        return 1
    fi

    local owner_uid
    if ! owner_uid=$(id -u "$owner" 2>/dev/null); then
        echo -e "${RED}Пользователь не найден: ${owner}${NC}" >&2
        return 1
    fi

    local owner_gid
    if ! owner_gid=$(id -g "$owner" 2>/dev/null); then
        echo -e "${RED}Не удалось определить группу пользователя: ${owner}${NC}" >&2
        return 1
    fi

    echo "${owner}:${owner_uid}:${owner_gid}"
}

is_domain_joined() {
    if command -v realm &>/dev/null && realm list 2>/dev/null | grep -q .; then
        return 0
    fi

    if command -v wbinfo &>/dev/null && wbinfo -t &>/dev/null; then
        return 0
    fi

    return 1
}

detect_domain_name() {
    local domain=""

    if command -v realm &>/dev/null; then
        domain=$(realm list 2>/dev/null | awk 'NF {print $1; exit}')
    fi

    if [[ -z "$domain" ]] && command -v dnsdomainname &>/dev/null; then
        domain=$(dnsdomainname 2>/dev/null || true)
    fi

    if [[ -z "$domain" ]] && command -v hostname &>/dev/null; then
        domain=$(hostname -d 2>/dev/null || true)
    fi

    echo "$domain"
}

build_kerberos_principal() {
    local username="$1"
    local domain="$2"

    echo "${username}@${domain^^}"
}

run_as_login_user() {
    local username="$1"
    shift

    if [[ "$(id -un)" == "$username" ]]; then
        "$@"
    elif command -v sudo &>/dev/null; then
        sudo -u "$username" "$@"
    elif command -v runuser &>/dev/null; then
        runuser -u "$username" -- "$@"
    else
        echo -e "${YELLOW}Не найден sudo или runuser, выполняю команду от текущего пользователя${NC}" >&2
        "$@"
    fi
}

ensure_kerberos_ticket() {
    local username="$1"
    local domain="$2"
    local principal
    principal=$(build_kerberos_principal "$username" "$domain")

    if ! command -v klist &>/dev/null; then
        echo -e "${YELLOW}klist не найден, пропускаю проверку Kerberos-билета${NC}"
        return 0
    fi

    if run_as_login_user "$username" klist -s; then
        echo -e "${GREEN}Kerberos-билет найден для пользователя ${username}${NC}"
        return 0
    fi

    echo -e "${YELLOW}Kerberos-билет для ${username} не найден${NC}"
    read -rp "Получить билет через kinit ${principal}? (y/n): " kinit_answer
    if [[ "$kinit_answer" == "y" || "$kinit_answer" == "Y" ]]; then
        run_as_login_user "$username" kinit "$principal"
        return $?
    fi

    echo -e "${RED}Без Kerberos-билета доменное монтирование может не выполниться${NC}"
    return 1
}

build_common_mount_options() {
    local user_uid="$1"
    local user_gid="$2"

    echo "uid=${user_uid},gid=${user_gid},forceuid,forcegid,nobrl,iocharset=utf8,file_mode=0770,dir_mode=0770"
}

build_credentials_mount_options() {
    local cred_file="$1"
    local user_uid="$2"
    local user_gid="$3"

    echo "credentials=${cred_file},$(build_common_mount_options "$user_uid" "$user_gid")"
}

build_kerberos_mount_options() {
    local user_uid="$1"
    local user_gid="$2"

    echo "sec=krb5,cruid=${user_uid},multiuser,$(build_common_mount_options "$user_uid" "$user_gid")"
}

is_ipv4_address() {
    local value="$1"

    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

resolve_kerberos_server_name() {
    local server="$1"

    if ! is_ipv4_address "$server"; then
        echo "$server"
        return 0
    fi

    local resolved=""
    if command -v getent &>/dev/null; then
        resolved=$(getent hosts "$server" 2>/dev/null | awk '{
            for (i = 2; i <= NF; i++) {
                if ($i ~ /\./) {
                    print $i
                    exit
                }
            }
            if (NF >= 2) {
                print $2
            }
        }')
    fi

    if [[ -z "$resolved" ]]; then
        echo -e "${RED}Kerberos-монтирование по IP-адресу невозможно без DNS-имени сервера${NC}" >&2
        echo "Укажите имя сервера/FQDN вместо ${server} или настройте обратное DNS-разрешение" >&2
        return 1
    fi

    echo "$resolved"
}

select_kerberos_server_name() {
    local server="$1"
    local resolved=""

    if resolved=$(resolve_kerberos_server_name "$server"); then
        echo "$resolved"
        return 0
    fi

    local manual_server=""
    read -rp "DNS-имя/FQDN SMB-сервера для Kerberos: " manual_server

    if [[ -z "$manual_server" ]] || is_ipv4_address "$manual_server"; then
        echo -e "${RED}Для Kerberos нужно указать DNS-имя или FQDN, не IP-адрес${NC}" >&2
        return 1
    fi

    echo "$manual_server"
}

# ─── Создание файла учётных данных ───────────────────────────────────────
create_credentials_file() {
    local username="$1"
    local password="$2"
    local domain="${3:-}"
    local cred_file="${4:-}"

    if [[ -z "$cred_file" ]]; then
        local safe_username
        safe_username=$(sanitize_name "$username")
        cred_file="${CREDENTIALS_DIR}/.smbuser_${safe_username}"
    fi

    if [[ "$password" == *$'\n'* || "$username" == *$'\n'* || "$domain" == *$'\n'* ]]; then
        echo -e "${RED}Ошибка: имя пользователя, пароль и домен не должны содержать перевод строки${NC}" >&2
        return 1
    fi

    cat > "$cred_file" <<EOF
username=${username}
password=${password}
EOF

    if [[ -n "$domain" ]]; then
        echo "domain=${domain}" >> "$cred_file"
    fi

    chmod 600 "$cred_file"
    echo "$cred_file"
}

# ─── Монтирование шары ───────────────────────────────────────────────────
mount_share() {
    local server="$1"
    local share="$2"
    local mount_name="$3"
    local cred_file="$4"
    local is_domain="$5"
    local add_to_fstab="$6"
    local user_uid="${7:-}"
    local user_gid="${8:-}"

    local mount_point="${MOUNT_BASE}/${mount_name}"
    if [[ -z "$user_uid" || -z "$user_gid" ]]; then
        local owner_info
        local owner_user
        if ! owner_info=$(resolve_mount_owner); then
            return 1
        fi
        IFS=':' read -r owner_user user_uid user_gid <<< "$owner_info"
        echo -e "${BLUE}Локальный владелец mount-point: ${owner_user} (${user_uid}:${user_gid})${NC}"
    fi

    local mount_opts
    mount_opts="$(build_credentials_mount_options "$cred_file" "$user_uid" "$user_gid")"

    if ! validate_mount_name "$mount_name"; then
        echo -e "${RED}Ошибка: неверное имя точки монтирования: ${mount_name}${NC}"
        echo "Разрешены только буквы, цифры, точка, подчёркивание и дефис"
        return 1
    fi

    if [[ "$is_domain" == "1" ]]; then
        mount_opts="${mount_opts},nofail"
    fi

    mkdir -p "$mount_point"

    echo -e "${BLUE}Монтирование //${server}/${share} -> ${mount_point}${NC}"

    if mount -t cifs "//${server}/${share}" "$mount_point" -o "$mount_opts"; then
        echo -e "${GREEN}Успешно смонтировано: ${mount_point}${NC}"

        if [[ "$add_to_fstab" == "1" ]]; then
            add_to_fstab_entry "$server" "$share" "$mount_name" "$cred_file" "$is_domain" "credentials" "$user_uid" "$user_gid"
        fi
    else
        echo -e "${RED}Ошибка монтирования! Проверьте:${NC}"
        echo "  - Доступность сервера: ping ${server}"
        echo "  - Учётные данные в: ${cred_file}"
        echo "  - Сетевое соединение"
        return 1
    fi
}

# ─── Добавление записи в fstab ───────────────────────────────────────────
add_to_fstab_entry() {
    local server="$1"
    local share="$2"
    local mount_name="$3"
    local cred_file="$4"
    local is_domain="$5"
    local auth_mode="${6:-credentials}"
    local user_uid="${7:-}"
    local user_gid="${8:-}"

    local mount_point="${MOUNT_BASE}/${mount_name}/"
    local fstab_opts=""

    if [[ -z "$user_uid" || -z "$user_gid" ]]; then
        local owner_info
        local owner_user
        if ! owner_info=$(resolve_mount_owner); then
            return 1
        fi
        IFS=':' read -r owner_user user_uid user_gid <<< "$owner_info"
    fi

    if [[ "$auth_mode" == "kerberos" ]]; then
        fstab_opts="$(build_kerberos_mount_options "$user_uid" "$user_gid")"
    else
        fstab_opts="$(build_credentials_mount_options "$cred_file" "$user_uid" "$user_gid")"
    fi

    if [[ "$is_domain" == "1" ]]; then
        fstab_opts="${fstab_opts},nofail"
    fi

    local fstab_entry="//${server}/${share} ${mount_point} cifs ${fstab_opts} 0 0"

    if grep -Fq "//${server}/${share} ${mount_point} cifs" "$FSTAB" 2>/dev/null; then
        backup_fstab
        sed -i "\|//${server}/${share} ${mount_point} cifs|d" "$FSTAB"
        echo "$fstab_entry" >> "$FSTAB"
        echo -e "${GREEN}Запись обновлена в /etc/fstab${NC}"
        return 0
    fi

    backup_fstab
    echo "$fstab_entry" >> "$FSTAB"
    echo -e "${GREEN}Запись добавлена в /etc/fstab${NC}"
}

mount_share_kerberos() {
    local server="$1"
    local share="$2"
    local mount_name="$3"
    local user_uid="$4"
    local user_gid="$5"
    local add_to_fstab="$6"

    local mount_point="${MOUNT_BASE}/${mount_name}"
    local mount_opts
    mount_opts="$(build_kerberos_mount_options "$user_uid" "$user_gid")"

    if ! validate_mount_name "$mount_name"; then
        echo -e "${RED}Ошибка: неверное имя точки монтирования: ${mount_name}${NC}"
        echo "Разрешены только буквы, цифры, точка, подчёркивание и дефис"
        return 1
    fi

    mkdir -p "$mount_point"

    echo -e "${BLUE}Монтирование //${server}/${share} -> ${mount_point} через Kerberos${NC}"

    if mount -t cifs "//${server}/${share}" "$mount_point" -o "$mount_opts"; then
        echo -e "${GREEN}Успешно смонтировано: ${mount_point}${NC}"

        if [[ "$add_to_fstab" == "1" ]]; then
            add_to_fstab_entry "$server" "$share" "$mount_name" "" "1" "kerberos" "$user_uid" "$user_gid"
        fi
    else
        echo -e "${RED}Ошибка монтирования! Проверьте:${NC}"
        echo "  - Доступность сервера: ping ${server}"
        echo "  - Kerberos-билет пользователя: klist"
        echo "  - Ввод компьютера в домен: realm list"
        echo "  - Сетевое соединение"
        return 1
    fi
}

# ─── Размонтирование ─────────────────────────────────────────────────────
unmount_share() {
    local mount_name="$1"
    local mount_point="${MOUNT_BASE}/${mount_name}"

    if ! validate_mount_name "$mount_name"; then
        echo -e "${RED}Ошибка: неверное имя точки монтирования: ${mount_name}${NC}"
        return 1
    fi

    if [[ ! -d "$mount_point" ]]; then
        echo -e "${RED}Точка монтирования не найдена: ${mount_point}${NC}"
        return 1
    fi

    if ! mountpoint -q "$mount_point"; then
        echo -e "${YELLOW}Не смонтировано: ${mount_point}${NC}"
        read -rp "Удалить директорию ${mount_point}? (y/n): " confirm_rm
        if [[ "$confirm_rm" == "y" || "$confirm_rm" == "Y" ]]; then
            rmdir "$mount_point" 2>/dev/null && echo -e "${GREEN}Директория удалена: ${mount_point}${NC}" || {
                echo -e "${YELLOW}Директория не пуста, пропускаю удаление${NC}"
            }
        fi
        return 0
    fi

    echo -e "${BLUE}Размонтирование: ${mount_point}${NC}"

    if umount "$mount_point"; then
        echo -e "${GREEN}Успешно размонтировано: ${mount_point}${NC}"
    else
        echo -e "${RED}Ошибка размонтирования. Попытка принудительного...${NC}"
        umount -l "$mount_point" 2>/dev/null && echo -e "${GREEN}Принудительно размонтировано${NC}" || {
            echo -e "${RED}Не удалось размонтировать${NC}"
            return 1
        }
    fi

    if [[ -d "$mount_point" ]]; then
        rmdir "$mount_point" 2>/dev/null && echo -e "${GREEN}Директория удалена: ${mount_point}${NC}" || {
            echo -e "${YELLOW}Директория не пуста, оставлена без удаления: ${mount_point}${NC}"
        }
    fi
}

# ─── Список смонтированных шар ────────────────────────────────────────────
list_mounts() {
    echo -e "${BLUE}=== Смонтированные CIFS шары ===${NC}"
    echo ""

    local count=0
    while IFS= read -r line; do
        if echo "$line" | grep -q "type cifs"; then
            echo -e "  ${GREEN}●${NC} $line"
            ((count++)) || true
        fi
    done < <(mount | grep cifs || true)

    if [[ $count -eq 0 ]]; then
        echo -e "  ${YELLOW}Нет смонтированных CIFS шар${NC}"
    fi

    echo ""
    echo -e "${BLUE}=== Записи из /etc/fstab (CIFS) ===${NC}"
    echo ""

    if [[ -f "$FSTAB" ]]; then
        local fstab_count=0
        while IFS= read -r line; do
            if echo "$line" | grep -q "^//.*cifs"; then
                echo -e "  ${GREEN}●${NC} $line"
                ((fstab_count++)) || true
            fi
        done < "$FSTAB"

        if [[ $fstab_count -eq 0 ]]; then
            echo -e "  ${YELLOW}Нет записей CIFS в /etc/fstab${NC}"
        fi
    else
        echo -e "  ${RED}/etc/fstab не найден${NC}"
    fi

    echo ""
}

# ─── Монтирование всех шар из fstab ──────────────────────────────────────
mount_all_fstab() {
    echo -e "${BLUE}Монтирование всех шар из /etc/fstab...${NC}"
    mount -a -t cifs
    echo -e "${GREEN}Готово${NC}"
}

# ─── Удаление записи из fstab ────────────────────────────────────────────
remove_from_fstab() {
    local mount_name="$1"
    local mount_point="${MOUNT_BASE}/${mount_name}/"

    if [[ ! -f "$FSTAB" ]]; then
        echo -e "${RED}/etc/fstab не найден${NC}"
        return 1
    fi

    if grep -Fq " ${mount_point} cifs " "$FSTAB"; then
        backup_fstab
        sed -i "\|${mount_point}|d" "$FSTAB"
        echo -e "${GREEN}Запись удалена из /etc/fstab${NC}"
    else
        echo -e "${YELLOW}Запись не найдена в /etc/fstab${NC}"
    fi
}

# ─── Сохранение в конфиг-файл ────────────────────────────────────────────
save_to_config() {
    local name="$1"
    local server="$2"
    local share="$3"
    local username="$4"
    local password="$5"
    local domain="$6"
    local is_domain="$7"

    cat >> "$CONFIG_FILE" <<EOF
[${name}]
server=${server}
share=${share}
username=${username}
password=${password}
domain=${domain}
is_domain=${is_domain}

EOF

    chmod 600 "$CONFIG_FILE"
    echo -e "${GREEN}Конфигурация сохранена: ${CONFIG_FILE}${NC}"
}

# ─── Загрузка из конфиг-файла ────────────────────────────────────────────
load_from_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo -e "${YELLOW}Конфиг-файл не найден: ${CONFIG_FILE}${NC}"
        return 0
    fi

    echo -e "${BLUE}=== Доступные пресеты ===${NC}"
    echo ""

    grep '^\[' "$CONFIG_FILE" | sed 's/\[//;s/\]//' | nl -w2 -s') '
    echo ""

    read -rp "Выберите пресет (номер): " preset_num
    local total
    total=$(grep -c '^\[' "$CONFIG_FILE")

    if [[ ! "$preset_num" =~ ^[0-9]+$ || "$preset_num" -lt 1 || "$preset_num" -gt "$total" ]]; then
        echo -e "${RED}Неверный номер${NC}"
        return 0
    fi

    local preset_name
    preset_name=$(grep '^\[' "$CONFIG_FILE" | sed -n "${preset_num}p" | sed 's/\[//;s/\]//')

    local in_section=0
    local server="" share="" username="" password="" domain="" is_domain="0"

    while IFS= read -r line; do
        if [[ "$line" == "[${preset_name}]" ]]; then
            in_section=1
            continue
        fi

        if [[ $in_section -eq 1 ]]; then
            if [[ "$line" == "["* ]]; then
                break
            fi

            local key
            key=$(echo "$line" | cut -d'=' -f1)
            local value
            value=$(echo "$line" | cut -d'=' -f2-)

            case "$key" in
                server) server="$value" ;;
                share) share="$value" ;;
                username) username="$value" ;;
                password) password="$value" ;;
                domain) domain="$value" ;;
                is_domain) is_domain="$value" ;;
            esac
        fi
    done < "$CONFIG_FILE"

    if [[ -z "$server" ]]; then
        echo -e "${RED}Не удалось загрузить пресет${NC}"
        return 0
    fi

    echo -e "${GREEN}Загружен пресет: ${preset_name}${NC}"

    local cred_file
    cred_file=$(create_credentials_file "$username" "$password" "$domain")

    read -rp "Смонтировать? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        mount_share "$server" "$share" "$preset_name" "$cred_file" "$is_domain" "1"
    fi
}

# ─── Интерактивный режим — добавление новой шары ─────────────────────────
interactive_add() {
    echo -e "${BLUE}=== Добавление новой шары ===${NC}"
    echo ""

    read -rp "IP/имя сервера: " server
    read -rp "Имя шары: " share
    read -rp "Имя точки монтирования (будет в /mnt/): " mount_name
    if ! validate_mount_name "$mount_name"; then
        echo -e "${RED}Ошибка: неверное имя точки монтирования${NC}"
        echo "Разрешены только буквы, цифры, точка, подчёркивание и дефис"
        return 1
    fi

    local owner_info owner_user user_uid user_gid
    if ! owner_info=$(resolve_mount_owner); then
        return 1
    fi
    IFS=':' read -r owner_user user_uid user_gid <<< "$owner_info"
    echo -e "${BLUE}Локальный владелец mount-point: ${owner_user} (${user_uid}:${user_gid})${NC}"

    read -rp "Использовать доменную авторизацию текущего пользователя (Kerberos)? (y/n): " kerberos_answer
    if [[ "$kerberos_answer" == "y" || "$kerberos_answer" == "Y" ]]; then
        if ! is_domain_joined; then
            echo -e "${RED}Компьютер не найден в домене. Проверьте: realm list или wbinfo -t${NC}"
            return 1
        fi

        local domain
        domain=$(detect_domain_name)

        if [[ -z "$domain" ]]; then
            read -rp "Домен Kerberos (например, example.local): " domain
        else
            read -rp "Домен Kerberos [${domain}]: " domain_answer
            domain="${domain_answer:-$domain}"
        fi

        if [[ -z "$domain" ]]; then
            echo -e "${RED}Домен не указан${NC}"
            return 1
        fi

        if ! ensure_kerberos_ticket "$owner_user" "$domain"; then
            return 1
        fi

        local kerberos_server
        if ! kerberos_server=$(select_kerberos_server_name "$server"); then
            return 1
        fi

        if [[ "$kerberos_server" != "$server" ]]; then
            echo -e "${YELLOW}Для Kerberos использую DNS-имя сервера: ${kerberos_server} вместо ${server}${NC}"
            server="$kerberos_server"
        fi

        read -rp "Добавить в /etc/fstab? (y/n): " add_fstab_answer
        local add_to_fstab="0"
        if [[ "$add_fstab_answer" == "y" || "$add_fstab_answer" == "Y" ]]; then
            add_to_fstab="1"
            echo -e "${YELLOW}Важно: запись с sec=krb5 требует Kerberos-билет пользователя после входа в систему${NC}"
        fi

        mount_share_kerberos "$server" "$share" "$mount_name" "$user_uid" "$user_gid" "$add_to_fstab"
        return $?
    fi

    read -rp "Имя пользователя: " username
    read -rsp "Пароль: " password
    echo ""
    read -rp "Доменная шара? (y/n): " is_domain_answer

    local is_domain="0"
    local domain=""
    if [[ "$is_domain_answer" == "y" || "$is_domain_answer" == "Y" ]]; then
        is_domain="1"
        read -rp "Домен (необязательно, Enter для пропуска): " domain
    fi

    read -rp "Добавить в /etc/fstab? (y/n): " add_fstab_answer
    local add_to_fstab="0"
    if [[ "$add_fstab_answer" == "y" || "$add_fstab_answer" == "Y" ]]; then
        add_to_fstab="1"
    fi

    read -rp "Сохранить в конфиг-файл? (y/n): " save_config_answer

    local cred_file
    cred_file=$(create_credentials_file "$username" "$password" "$domain")

    mount_share "$server" "$share" "$mount_name" "$cred_file" "$is_domain" "$add_to_fstab" "$user_uid" "$user_gid"

    if [[ "$save_config_answer" == "y" || "$save_config_answer" == "Y" ]]; then
        save_to_config "$mount_name" "$server" "$share" "$username" "$password" "$domain" "$is_domain"
    fi
}

# ─── Интерактивный режим — удаление шары ─────────────────────────────────
interactive_remove() {
    echo -e "${BLUE}=== Удаление шары ===${NC}"
    echo ""

    local mounts=()
    while IFS= read -r line; do
        if echo "$line" | grep -q "type cifs"; then
            local mp
            mp=$(echo "$line" | awk '{print $3}')
            local name
            name=$(basename "$mp")
            mounts+=("$name")
        fi
    done < <(mount | grep cifs || true)

    if [[ ${#mounts[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Нет смонтированных шар${NC}"
        return 0
    fi

    echo "Смонтированные шары:"
    for i in "${!mounts[@]}"; do
        echo "  $((i+1))) ${mounts[$i]}"
    done
    echo ""

    read -rp "Выберите для размонтирования (номер): " num
    if [[ "$num" =~ ^[0-9]+$ && $num -ge 1 && $num -le ${#mounts[@]} ]]; then
        local selected="${mounts[$((num-1))]}"

        read -rp "Размонтировать '${selected}'? (y/n): " confirm
        if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
            unmount_share "$selected"

            read -rp "Удалить из /etc/fstab? (y/n): " fstab_confirm
            if [[ "$fstab_confirm" == "y" || "$fstab_confirm" == "Y" ]]; then
                remove_from_fstab "$selected"
            fi
        fi
    else
        echo -e "${RED}Неверный номер${NC}"
    fi
}

# ─── Главное меню ─────────────────────────────────────────────────────────
main_menu() {
    while true; do
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║     Управление монтированием шар         ║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
        echo ""
        echo "  1) Добавить и смонтировать новую шару"
        echo "  2) Загрузить из конфиг-файла"
        echo "  3) Размонтировать шару"
        echo "  4) Список смонтированных"
        echo "  5) Монтировать все из fstab"
        echo "  6) Выход"
        echo ""
        read -rp "Выбор: " choice

        case $choice in
            1) interactive_add ;;
            2) load_from_config ;;
            3) interactive_remove ;;
            4) list_mounts ;;
            5) mount_all_fstab ;;
            6) echo "Выход..."; exit 0 ;;
            *) echo -e "${RED}Неверный выбор${NC}" ;;
        esac
    done
}

# ─── Справка ──────────────────────────────────────────────────────────────
show_help() {
    echo "Использование: $0 [опции]"
    echo ""
    echo "Опции:"
    echo "  --list, -l      Список смонтированных шар"
    echo "  --add, -a       Добавить новую шару (интерактивно)"
    echo "  --remove, -r    Размонтировать шару (интерактивно)"
    echo "  --load          Загрузить пресет из конфига"
    echo "  --mount-all     Монтировать все шары из fstab"
    echo "  --help, -h      Эта справка"
    echo ""
    echo "Без опций запускается интерактивное меню"
}

# ─── Основная логика ─────────────────────────────────────────────────────
main() {
    if [[ "${MOUNT_MANAGER_TESTING:-0}" == "1" ]]; then
        return 0
    fi

    check_root
    check_dependencies

    if [[ $# -gt 0 ]]; then
        case "$1" in
            --list|-l)      list_mounts ;;
            --add|-a)       interactive_add ;;
            --remove|-r)    interactive_remove ;;
            --load)         load_from_config ;;
            --mount-all)    mount_all_fstab ;;
            --help|-h)      show_help ;;
            *)
                echo -e "${RED}Неизвестная опция: $1${NC}"
                echo "Используйте --help для справки"
                exit 1
                ;;
        esac
    else
        main_menu
    fi
}

main "$@"
