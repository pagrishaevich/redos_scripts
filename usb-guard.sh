#!/bin/bash
##############################################################################
# usb-guard.sh — Управление блокировкой USB-накопителей
#
# Автор: pagrishaevich
#
# Описание:
#   Скрипт для управления блокировкой USB-накопителей на РЕД ОС.
#   Реализует два метода: UDISKS_IGNORE (запрет автомонтирования) и
#   authorized (полное отключение на уровне шины USB).
#   Поддерживает создание белого списка доверенных устройств.
#
# Использование:
#   sudo ./usb-guard.sh [ОПЦИИ]
#
# Опции:
#   -h, --help            Справка
#       --scan            Сканировать USB-устройства
#       --whitelist       Добавить устройство в белый список (UDISKS_IGNORE)
#       --whitelist-auth  Добавить устройство в белый список (authorized)
#       --block-whitelist Блокировать все USB-накопители, кроме белого списка (UDISKS_IGNORE)
#       --block-all       Блокировать все USB-накопители без исключений (UDISKS_IGNORE)
#       --unblock         Разблокировать все USB-накопители
#       --show            Показать текущие правила и статус
#
# Зависимости: bash, udev (udevadm), coreutils, grep, sed, mktemp
# Опционально: lsusb / usbutils (автоопределение USB 3.0)
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
UDEV_RULES_DIR="/etc/udev/rules.d"
UDEV_RULE_FILE="${UDEV_RULES_DIR}/99-usb.rules"
REMOVE_USB_SCRIPT="/usr/bin/remove_usb.sh"

# ─── Глобальные переменные для отсканированных устройств ──────────────────
declare -a SCANNED_DEVS=()
declare -a SCANNED_SERIALS=()
declare -a SCANNED_PRODUCTS=()
declare -a SCANNED_MAXPOWERS=()
SCAN_DONE=0

# ─── Проверка прав root ──────────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}Ошибка: требуются права root${NC}"
        echo "Запустите: sudo $0"
        exit 1
    fi
}

# ─── Проверка зависимостей ───────────────────────────────────────────────
check_dependencies() {
    command -v udevadm &>/dev/null || {
        echo -e "${RED}Ошибка: udevadm не найден${NC}"
        exit 1
    }

    command -v mktemp &>/dev/null || {
        echo -e "${RED}Ошибка: mktemp не найден${NC}"
        exit 1
    }

    command -v sed &>/dev/null || {
        echo -e "${RED}Ошибка: sed не найден${NC}"
        exit 1
    }

    command -v readlink &>/dev/null || {
        echo -e "${RED}Ошибка: readlink не найден${NC}"
        exit 1
    }

    if ! command -v lsusb &>/dev/null; then
        echo -e "${YELLOW}Предупреждение: lsusb не найден (usbutils). USB 3.0 автоопределение будет пропущено${NC}"
    fi

    if [[ ! -d "$UDEV_RULES_DIR" ]]; then
        echo -e "${BLUE}Создание директории: ${UDEV_RULES_DIR}${NC}"
        mkdir -p "$UDEV_RULES_DIR"
    fi
}

# ─── Проверка поддержки USB 3.0 ──────────────────────────────────────────
detect_usb3() {
    if lsusb -t 2>/dev/null | grep -Fq "xhci"; then
        echo "1"
    else
        echo "0"
    fi
}

# ─── Проверка, что блочное устройство находится на USB-шине ───────────────
is_usb_block_device() {
    local dev="$1"
    local dev_path

    dev_path=$(readlink -f "/sys/block/${dev}/device" 2>/dev/null || true)
    [[ "$dev_path" == *"/usb"* || "$dev_path" == *"/usb"[0-9]*/* ]]
}

# ─── Генерация одного правила udev с выбранными атрибутами ────────────────
build_attr_rule() {
    local action="$1"
    local serial="$2"
    local product="$3"
    local maxpower="${4:-}"
    local rule=""

    [[ -n "$serial" ]] && rule+="ATTRS{serial}==\"${serial}\","
    [[ -n "$product" ]] && rule+="ATTRS{product}==\"${product}\","
    [[ -n "$maxpower" ]] && rule+="ATTRS{bMaxPower}==\"${maxpower}\","

    [[ -n "$rule" ]] || return 1
    # Удаляем trailing comma перед action
    rule=${rule%,}
    echo "${rule},${action}"
}

# ─── Безопасное чтение атрибута udev ─────────────────────────────────────
get_udev_attr() {
    local dev="$1"
    local attr="$2"

    udevadm info -a -p "/sys/block/${dev}" 2>/dev/null \
        | grep -m1 "ATTRS{${attr}}" \
        | sed "s/.*ATTRS{${attr}}==\"\([^\"]*\)\".*/\1/" \
        || true
}

# ─── Сканирование USB-накопителей ────────────────────────────────────────
scan_usb_devices() {
    SCANNED_DEVS=()
    SCANNED_SERIALS=()
    SCANNED_PRODUCTS=()
    SCANNED_MAXPOWERS=()
    SCAN_DONE=0

    echo -e "${BLUE}=== Сканирование USB-накопителей ===${NC}"
    echo ""

    local devices=()
    local block_path devname
    for block_path in /sys/block/sd*; do
        [[ -e "$block_path" ]] || continue
        devname=$(basename "$block_path")
        if is_usb_block_device "$devname"; then
            devices+=("$devname")
        fi
    done

    if [[ ${#devices[@]} -eq 0 ]]; then
        echo -e "  ${YELLOW}USB-накопители не обнаружены${NC}"
        echo ""
        echo -e "${YELLOW}Подключите USB-накопитель и попробуйте снова${NC}"
        echo ""
        return 0
    fi

    for i in "${!devices[@]}"; do
        local dev="${devices[$i]}"
        SCANNED_DEVS+=("$dev")

        echo -e "  ${GREEN}$((i+1))) ${dev}${NC}"

        local serial product maxpower vendor idVendor idProduct

        serial=$(get_udev_attr "$dev" "serial")
        product=$(get_udev_attr "$dev" "product")
        maxpower=$(get_udev_attr "$dev" "bMaxPower")
        vendor=$(get_udev_attr "$dev" "vendor")
        idVendor=$(get_udev_attr "$dev" "idVendor")
        idProduct=$(get_udev_attr "$dev" "idProduct")

        SCANNED_SERIALS+=("${serial:-}")
        SCANNED_PRODUCTS+=("${product:-}")
        SCANNED_MAXPOWERS+=("${maxpower:-}")

        echo -e "      Serial:    ${serial:-(не определён)}"
        echo -e "      Product:   ${product:-(не определён)}"
        echo -e "      MaxPower:  ${maxpower:-(не определён)}"
        [[ -n "$vendor" ]] && echo -e "      Vendor:    ${vendor}"
        [[ -n "$idVendor" ]] && echo -e "      idVendor:  ${idVendor}"
        [[ -n "$idProduct" ]] && echo -e "      idProduct: ${idProduct}"
        echo ""
    done

    SCAN_DONE=1
    echo -e "${GREEN}Сканирование завершено. Найдено устройств: ${#devices[@]}${NC}"
    echo ""
}

# ─── Создание скрипта remove_usb.sh ──────────────────────────────────────
create_remove_script() {
    if [[ -f "$REMOVE_USB_SCRIPT" ]]; then
        local backup="${REMOVE_USB_SCRIPT}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$REMOVE_USB_SCRIPT" "$backup"
        echo -e "${YELLOW}Текущий скрипт сохранён: ${backup}${NC}"
    fi

    cat > "$REMOVE_USB_SCRIPT" <<'SCRIPT'
#!/bin/bash
devpath="$1"
sys_path="/sys${devpath}"

while [[ "$sys_path" != "/sys" && "$sys_path" != "/" ]]; do
    if [[ -f "${sys_path}/authorized" ]]; then
        echo 0 > "${sys_path}/authorized"
        exit 0
    fi
    sys_path=$(dirname "$sys_path")
done

exit 1
SCRIPT

    chmod +x "$REMOVE_USB_SCRIPT"
    echo -e "${GREEN}Скрипт создан: ${REMOVE_USB_SCRIPT}${NC}"
}

# ─── Генерация правила UDISKS_IGNORE — блокировка всех ───────────────────
generate_block_all_udisks() {
    echo 'ENV{ID_USB_DRIVER}=="usb-storage",ENV{UDISKS_IGNORE}="1"'
    echo 'ENV{ID_USB_DRIVER}=="uas",ENV{UDISKS_IGNORE}="1"'
}

# ─── Генерация правила UDISKS_IGNORE — белый список ──────────────────────
generate_udisks_allow_rules() {
    local serial="$1"
    local product="$2"
    local maxpower="$3"
    local has_rule=0

    if [[ -n "$serial" ]]; then
        build_attr_rule 'ENV{UDISKS_IGNORE}="0"' "$serial" "" ""
        has_rule=1
    fi
    if [[ -n "$product" ]]; then
        build_attr_rule 'ENV{UDISKS_IGNORE}="0"' "" "$product" ""
        has_rule=1
    fi
    if [[ -n "$maxpower" ]]; then
        build_attr_rule 'ENV{UDISKS_IGNORE}="0"' "" "" "$maxpower"
        has_rule=1
    fi

    [[ "$has_rule" -eq 1 ]]
}

generate_whitelist_udisks() {
    local serial="$1"
    local product="$2"
    local maxpower="$3"

    echo 'ENV{ID_USB_DRIVER}=="usb-storage",ENV{UDISKS_IGNORE}="1"'
    echo 'ENV{ID_USB_DRIVER}=="uas",ENV{UDISKS_IGNORE}="1"'

    generate_udisks_allow_rules "$serial" "$product" "$maxpower"
}

# ─── Генерация правила authorized — белый список ─────────────────────────
generate_whitelist_authorized() {
    local serial="$1"
    local product="$2"

    echo 'ACTION!="add", GOTO="dont_remove_usb"'
    echo 'ENV{ID_USB_DRIVER}!="usb-storage", ENV{ID_USB_DRIVER}!="uas", GOTO="dont_remove_usb"'
    build_attr_rule 'GOTO="dont_remove_usb"' "$serial" "$product" || true

    echo 'ENV{ID_USB_DRIVER}=="usb-storage", RUN+="/bin/sh -c '"'"'/usr/bin/remove_usb.sh $devpath'"'"'"'
    echo 'ENV{ID_USB_DRIVER}=="uas", RUN+="/bin/sh -c '"'"'/usr/bin/remove_usb.sh $devpath'"'"'"'
    echo 'LABEL="dont_remove_usb"'
}

# ─── Применить правила udev ──────────────────────────────────────────────
apply_rules() {
    echo -e "${BLUE}Применение правил udev...${NC}"
    udevadm control --reload-rules
    udevadm trigger --subsystem-match=usb --subsystem-match=block 2>/dev/null || true
    echo -e "${GREEN}Правила применены${NC}"
    echo -e "${YELLOW}Рекомендуется переподключить USB-устройства${NC}"
}

# ─── Блокировка всех USB без исключений (UDISKS_IGNORE) ──────────────────
block_all_usb() {
    echo -e "${BLUE}=== Блокировка всех USB-накопителей без исключений (UDISKS_IGNORE) ===${NC}"
    echo ""

    local usb3
    usb3=$(detect_usb3)
    if [[ "$usb3" == "1" ]]; then
        echo -e "  ${GREEN}USB 3.0 обнаружен${NC}"
    else
        echo -e "  ${YELLOW}USB 3.0 не обнаружен${NC}"
    fi
    echo ""

    if [[ -f "$UDEV_RULE_FILE" ]]; then
        local backup="${UDEV_RULE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$UDEV_RULE_FILE" "$backup"
        echo -e "${YELLOW}Текущие правила сохранены: ${backup}${NC}"
    fi

    generate_block_all_udisks > "$UDEV_RULE_FILE"
    echo -e "${GREEN}Правила записаны: ${UDEV_RULE_FILE}${NC}"
    echo ""
    echo -e "${BLUE}Содержимое:${NC}"
    while IFS= read -r line; do
        echo -e "  ${CYAN}${line}${NC}"
    done < "$UDEV_RULE_FILE"
    echo ""

    apply_rules
}

# ─── Блокировка всех USB, кроме белого списка (UDISKS_IGNORE) ────────────
block_except_whitelist_usb() {
    echo -e "${BLUE}=== Блокировка всех USB-накопителей, кроме белого списка (UDISKS_IGNORE) ===${NC}"
    echo ""

    if [[ ! -f "$UDEV_RULE_FILE" ]]; then
        echo -e "${RED}Файл правил не найден: ${UDEV_RULE_FILE}${NC}"
        echo -e "${YELLOW}Сначала добавьте устройство в белый список через пункт 2${NC}"
        return 0
    fi

    if ! grep -q 'ENV{UDISKS_IGNORE}="0"' "$UDEV_RULE_FILE" 2>/dev/null; then
        echo -e "${RED}В текущих правилах нет устройств из белого списка UDISKS_IGNORE${NC}"
        echo -e "${YELLOW}Сначала добавьте разрешённое устройство через пункт 2${NC}"
        return 0
    fi

    local backup="${UDEV_RULE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$UDEV_RULE_FILE" "$backup"
    echo -e "${YELLOW}Текущие правила сохранены: ${backup}${NC}"

    local block_usb_storage='ENV{ID_USB_DRIVER}=="usb-storage",ENV{UDISKS_IGNORE}="1"'
    local block_uas='ENV{ID_USB_DRIVER}=="uas",ENV{UDISKS_IGNORE}="1"'
    local tmp_file
    tmp_file=$(mktemp)

    echo "$block_usb_storage" > "$tmp_file"
    echo "$block_uas" >> "$tmp_file"

    while IFS= read -r line; do
        case "$line" in
            "$block_usb_storage"|"$block_uas") continue ;;
        esac
        echo "$line" >> "$tmp_file"
    done < "$UDEV_RULE_FILE"

    cp "$tmp_file" "$UDEV_RULE_FILE"
    rm -f "$tmp_file"

    echo -e "${GREEN}Режим белого списка включён: все USB-накопители блокируются, кроме разрешённых правил${NC}"
    echo -e "${GREEN}Правила записаны: ${UDEV_RULE_FILE}${NC}"
    echo ""
    echo -e "${BLUE}Содержимое:${NC}"
    while IFS= read -r line; do
        echo -e "  ${CYAN}${line}${NC}"
    done < "$UDEV_RULE_FILE"
    echo ""

    apply_rules
}

# ─── Белый список (UDISKS_IGNORE) ────────────────────────────────────────
whitelist_udisks() {
    echo -e "${BLUE}=== Создание белого списка (UDISKS_IGNORE) ===${NC}"
    echo ""

    if [[ $SCAN_DONE -eq 0 || ${#SCANNED_DEVS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Сначала выполните сканирование устройств (пункт 1 в меню)${NC}"
        echo ""
        read -rp "Просканировать сейчас? (y/n): " scan_now
        if [[ "$scan_now" == "y" || "$scan_now" == "Y" ]]; then
            scan_usb_devices
        else
            return 0
        fi
    fi

    if [[ ${#SCANNED_DEVS[@]} -eq 0 ]]; then
        echo -e "${RED}Нет отсканированных устройств${NC}"
        return 0
    fi

    echo -e "${BLUE}Отсканированные устройства:${NC}"
    echo ""
    for i in "${!SCANNED_DEVS[@]}"; do
        echo -e "  ${GREEN}$((i+1))) ${SCANNED_DEVS[$i]}${NC}"
        [[ -n "${SCANNED_SERIALS[$i]}" ]] && echo -e "      Serial:   ${SCANNED_SERIALS[$i]}"
        [[ -n "${SCANNED_PRODUCTS[$i]}" ]] && echo -e "      Product:  ${SCANNED_PRODUCTS[$i]}"
        [[ -n "${SCANNED_MAXPOWERS[$i]}" ]] && echo -e "      MaxPower: ${SCANNED_MAXPOWERS[$i]}"
        echo ""
    done

    read -rp "Выберите номер устройства для добавления в белый список: " dev_num
    if [[ ! "$dev_num" =~ ^[0-9]+$ || $dev_num -lt 1 || $dev_num -gt ${#SCANNED_DEVS[@]} ]]; then
        echo -e "${RED}Неверный номер${NC}"
        return 0
    fi

    local idx=$((dev_num-1))
    local serial="${SCANNED_SERIALS[$idx]}"
    local product="${SCANNED_PRODUCTS[$idx]}"
    local maxpower="${SCANNED_MAXPOWERS[$idx]}"

    echo ""
    echo -e "${BLUE}Выбранные атрибуты:${NC}"
    [[ -n "$serial" ]] && echo -e "  Serial:    ${serial}"
    [[ -n "$product" ]] && echo -e "  Product:   ${product}"
    [[ -n "$maxpower" ]] && echo -e "  MaxPower:  ${maxpower}"
    echo ""

    echo -e "${BLUE}Какие атрибуты использовать для белого списка?${NC}"
    echo "  1) Serial (наиболее надёжный)"
    echo "  2) Product"
    echo "  3) Serial + Product"
    echo "  4) Все три атрибута"
    echo "  5) Ввести вручную"
    echo ""
    read -rp "Выбор: " attr_choice

    case "$attr_choice" in
        1) product=""; maxpower="" ;;
        2) serial=""; maxpower="" ;;
        3) maxpower="" ;;
        4) ;;
        5)
            read -rp "Serial (Enter для пропуска): " serial
            read -rp "Product (Enter для пропуска): " product
            read -rp "MaxPower (Enter для пропуска): " maxpower
            ;;
    esac

    echo ""
    echo -e "${BLUE}Итоговые параметры белого списка:${NC}"
    [[ -n "$serial" ]] && echo -e "  Serial:   ${serial}"
    [[ -n "$product" ]] && echo -e "  Product:  ${product}"
    [[ -n "$maxpower" ]] && echo -e "  MaxPower: ${maxpower}"
    echo ""

    local allow_rule
    if ! allow_rule=$(generate_udisks_allow_rules "$serial" "$product" "$maxpower"); then
        echo -e "${RED}Не выбран ни один атрибут для белого списка${NC}"
        return 0
    fi

    if [[ -f "$UDEV_RULE_FILE" ]]; then
        echo -e "${BLUE}Текущие правила:${NC}"
        while IFS= read -r line; do
            echo -e "  ${CYAN}${line}${NC}"
        done < "$UDEV_RULE_FILE"
        echo ""

        read -rp "Добавить к существующим правилам? (y/n): " add_existing
        if [[ "$add_existing" == "y" || "$add_existing" == "Y" ]]; then
            if ! grep -Fxq "$allow_rule" "$UDEV_RULE_FILE" 2>/dev/null; then
                echo "$allow_rule" >> "$UDEV_RULE_FILE"
                echo -e "${GREEN}Правило добавлено: ${allow_rule}${NC}"
            else
                echo -e "${YELLOW}Такое правило уже есть${NC}"
            fi
        else
            echo -e "${YELLOW}Создаём новые правила (старые будут сохранены в бэкап)${NC}"
            local backup="${UDEV_RULE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
            cp "$UDEV_RULE_FILE" "$backup"
            generate_whitelist_udisks "$serial" "$product" "$maxpower" > "$UDEV_RULE_FILE"
            echo -e "${GREEN}Правила записаны: ${UDEV_RULE_FILE}${NC}"
        fi
    else
        generate_whitelist_udisks "$serial" "$product" "$maxpower" > "$UDEV_RULE_FILE"
        echo -e "${GREEN}Правила записаны: ${UDEV_RULE_FILE}${NC}"
    fi

    echo ""
    echo -e "${BLUE}Содержимое:${NC}"
    while IFS= read -r line; do
        echo -e "  ${CYAN}${line}${NC}"
    done < "$UDEV_RULE_FILE"
    echo ""

    apply_rules
}

# ─── Белый список (authorized) ───────────────────────────────────────────
whitelist_authorized() {
    echo -e "${BLUE}=== Создание белого списка (authorized) ===${NC}"
    echo ""

    create_remove_script

    if [[ $SCAN_DONE -eq 0 || ${#SCANNED_DEVS[@]} -eq 0 ]]; then
        echo -e "${YELLOW}Сначала выполните сканирование устройств (пункт 1 в меню)${NC}"
        echo ""
        read -rp "Просканировать сейчас? (y/n): " scan_now
        if [[ "$scan_now" == "y" || "$scan_now" == "Y" ]]; then
            scan_usb_devices
        else
            return 0
        fi
    fi

    if [[ ${#SCANNED_DEVS[@]} -eq 0 ]]; then
        echo -e "${RED}Нет отсканированных устройств${NC}"
        return 0
    fi

    echo -e "${BLUE}Отсканированные устройства:${NC}"
    echo ""
    for i in "${!SCANNED_DEVS[@]}"; do
        echo -e "  ${GREEN}$((i+1))) ${SCANNED_DEVS[$i]}${NC}"
        [[ -n "${SCANNED_SERIALS[$i]}" ]] && echo -e "      Serial:   ${SCANNED_SERIALS[$i]}"
        [[ -n "${SCANNED_PRODUCTS[$i]}" ]] && echo -e "      Product:  ${SCANNED_PRODUCTS[$i]}"
        echo ""
    done

    read -rp "Выберите номер устройства для добавления в белый список: " dev_num
    if [[ ! "$dev_num" =~ ^[0-9]+$ || $dev_num -lt 1 || $dev_num -gt ${#SCANNED_DEVS[@]} ]]; then
        echo -e "${RED}Неверный номер${NC}"
        return 0
    fi

    local idx=$((dev_num-1))
    local serial="${SCANNED_SERIALS[$idx]}"
    local product="${SCANNED_PRODUCTS[$idx]}"

    echo ""
    echo -e "${BLUE}Выбранные атрибуты:${NC}"
    [[ -n "$serial" ]] && echo -e "  Serial:  ${serial}"
    [[ -n "$product" ]] && echo -e "  Product: ${product}"
    echo ""

    echo -e "${BLUE}Какие атрибуты использовать?${NC}"
    echo "  1) Serial (наиболее надёжный)"
    echo "  2) Product"
    echo "  3) Оба"
    echo "  4) Ввести вручную"
    echo ""
    read -rp "Выбор: " attr_choice

    case "$attr_choice" in
        1) product="" ;;
        2) serial="" ;;
        3) ;;
        4)
            read -rp "Serial: " serial
            read -rp "Product: " product
            ;;
    esac

    echo ""
    echo -e "${BLUE}Итоговые параметры:${NC}"
    [[ -n "$serial" ]] && echo -e "  Serial:  ${serial}"
    [[ -n "$product" ]] && echo -e "  Product: ${product}"
    echo ""

    local allow_rule
    if ! allow_rule=$(build_attr_rule 'GOTO="dont_remove_usb"' "$serial" "$product"); then
        echo -e "${RED}Не выбран ни один атрибут для белого списка${NC}"
        return 0
    fi

    if [[ -f "$UDEV_RULE_FILE" ]]; then
        read -rp "Перезаписать правила? (y/n): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            local tmp_file
            tmp_file=$(mktemp)
            while IFS= read -r line; do
                if echo "$line" | grep -q "RUN+=.*remove_usb"; then
                    if ! grep -Fxq "$allow_rule" "$UDEV_RULE_FILE" 2>/dev/null; then
                        echo "$allow_rule" >> "$tmp_file"
                    fi
                fi
                echo "$line" >> "$tmp_file"
            done < "$UDEV_RULE_FILE"
            cp "$tmp_file" "$UDEV_RULE_FILE"
            rm -f "$tmp_file"
            echo -e "${GREEN}Правила добавлены к существующим${NC}"
        else
            generate_whitelist_authorized "$serial" "$product" > "$UDEV_RULE_FILE"
            echo -e "${GREEN}Правила записаны: ${UDEV_RULE_FILE}${NC}"
        fi
    else
        generate_whitelist_authorized "$serial" "$product" > "$UDEV_RULE_FILE"
        echo -e "${GREEN}Правила записаны: ${UDEV_RULE_FILE}${NC}"
    fi

    echo ""
    echo -e "${BLUE}Содержимое:${NC}"
    while IFS= read -r line; do
        echo -e "  ${CYAN}${line}${NC}"
    done < "$UDEV_RULE_FILE"
    echo ""

    apply_rules
}

# ─── Разблокировка всех USB ──────────────────────────────────────────────
unblock_all_usb() {
    echo -e "${BLUE}=== Разблокировка всех USB-накопителей ===${NC}"
    echo ""

    if [[ ! -f "$UDEV_RULE_FILE" ]]; then
        echo -e "${YELLOW}Файл правил не найден: ${UDEV_RULE_FILE}${NC}"
        echo -e "${YELLOW}Возможно, USB уже разблокированы${NC}"
        return 0
    fi

    local backup="${UDEV_RULE_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$UDEV_RULE_FILE" "$backup"
    echo -e "${YELLOW}Правила сохранены в бэкап: ${backup}${NC}"

    read -rp "Удалить файл правил и разблокировать все USB? (y/n): " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        rm -f "$UDEV_RULE_FILE"
        echo -e "${GREEN}Файл правил удалён: ${UDEV_RULE_FILE}${NC}"

        if [[ -f "$REMOVE_USB_SCRIPT" ]]; then
            rm -f "$REMOVE_USB_SCRIPT"
            echo -e "${GREEN}Скрипт удалён: ${REMOVE_USB_SCRIPT}${NC}"
        fi

        apply_rules

        echo -e "${BLUE}Восстановление authorized для подключённых устройств...${NC}"
        for dev in /sys/bus/usb/devices/*/authorized; do
            if [[ -f "$dev" ]]; then
                echo 1 > "$dev" 2>/dev/null || true
            fi
        done
        echo -e "${GREEN}Все USB-накопители разблокированы${NC}"
    else
        echo -e "${YELLOW}Отменено${NC}"
    fi
}

# ─── Просмотр текущих правил ─────────────────────────────────────────────
show_rules() {
    echo -e "${BLUE}=== Текущие правила USB ===${NC}"
    echo ""

    if [[ -f "$UDEV_RULE_FILE" ]]; then
        echo -e "  ${GREEN}●${NC} ${UDEV_RULE_FILE}"
        echo ""
        while IFS= read -r line; do
            echo -e "  ${CYAN}${line}${NC}"
        done < "$UDEV_RULE_FILE"
    else
        echo -e "  ${YELLOW}Файл правил не найден — USB-накопители не заблокированы${NC}"
    fi

    echo ""

    if [[ -f "$REMOVE_USB_SCRIPT" ]]; then
        echo -e "  ${GREEN}●${NC} ${REMOVE_USB_SCRIPT}"
    fi

    echo ""
    echo -e "${BLUE}Статус подключённых USB-устройств:${NC}"
    echo ""
    for dev in /sys/bus/usb/devices/*/authorized; do
        if [[ -f "$dev" ]]; then
            local status
            status=$(cat "$dev" 2>/dev/null)
            local devname
            devname=$(basename "$(dirname "$dev")")
            if [[ "$status" == "1" ]]; then
                echo -e "  ${GREEN}●${NC} ${devname}: authorized=${status} (разрешено)"
            elif [[ "$status" == "0" ]]; then
                echo -e "  ${RED}●${NC} ${devname}: authorized=${status} (заблокировано)"
            fi
        fi
    done
    echo ""
}

# ─── Главное меню ─────────────────────────────────────────────────────────
main_menu() {
    while true; do
        echo ""
        echo -e "${BLUE}╔═══════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║       Управление USB-накопителями (РЕД ОС 8)      ║${NC}"
        echo -e "${BLUE}╚═══════════════════════════════════════════════════╝${NC}"
        echo ""
        echo "  1) Сканировать USB-устройства"
        echo "  2) Добавить устройство в белый список (UDISKS_IGNORE)"
        echo "  3) Добавить устройство в белый список (authorized)"
        echo "  4) Блокировать все USB, кроме белого списка (UDISKS_IGNORE)"
        echo "  5) Блокировать все USB без исключений (UDISKS_IGNORE)"
        echo "  6) Разблокировать все USB"
        echo "  7) Просмотреть текущие правила"
        echo "  8) Выход"
        echo ""
        read -rp "Выбор: " choice

        case $choice in
            1) scan_usb_devices ;;
            2) whitelist_udisks ;;
            3) whitelist_authorized ;;
            4) block_except_whitelist_usb ;;
            5) block_all_usb ;;
            6) unblock_all_usb ;;
            7) show_rules ;;
            8) echo "Выход..."; exit 0 ;;
            *) echo -e "${RED}Неверный выбор${NC}" ;;
        esac
    done
}

# ─── Справка ──────────────────────────────────────────────────────────────
show_help() {
    echo "Использование: $0 [опции]"
    echo ""
    echo "Опции:"
    echo "  --scan             Сканировать USB-устройства"
    echo "  --whitelist        Добавить устройство в белый список (UDISKS_IGNORE)"
    echo "  --whitelist-auth   Добавить устройство в белый список (authorized)"
    echo "  --block-whitelist  Блокировать все USB-накопители, кроме белого списка (UDISKS_IGNORE)"
    echo "  --block-all        Блокировать все USB-накопители без исключений (UDISKS_IGNORE)"
    echo "  --unblock          Разблокировать все USB-накопители"
    echo "  --show             Показать текущие правила и статус"
    echo "  --help, -h         Эта справка"
    echo ""
    echo "Без опций запускается интерактивное меню"
    echo ""
    echo "Методы:"
    echo "  UDISKS_IGNORE  — запрещает автомонтирование, устройство видно в системе"
    echo "  authorized     — полностью отключает устройство на уровне шины USB"
    echo ""
    echo "Файлы:"
    echo "  ${UDEV_RULE_FILE}   — правила udev"
    echo "  ${REMOVE_USB_SCRIPT} — скрипт блокировки (authorized метод)"
    echo ""
    echo "Порядок работы:"
    echo "  1. Сканировать устройства (пункт 1 / --scan)"
    echo "  2. Добавить нужное устройство в белый список (пункт 2 или 3)"
    echo "  3. Заблокировать все остальные, сохранив белый список (пункт 4 / --block-whitelist)"
    echo "  4. Пункт 5 / --block-all блокирует все USB-накопители без исключений"
}

# ─── Основная логика ─────────────────────────────────────────────────────
main() {
    check_root
    check_dependencies

    if [[ $# -gt 0 ]]; then
        case "$1" in
            --scan)           scan_usb_devices ;;
            --whitelist)      whitelist_udisks ;;
            --whitelist-auth) whitelist_authorized ;;
            --block-whitelist) block_except_whitelist_usb ;;
            --block-all)      block_all_usb ;;
            --unblock)        unblock_all_usb ;;
            --show)           show_rules ;;
            --help|-h)        show_help ;;
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
