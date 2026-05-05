#!/usr/bin/env bash
# mount_folders_redos8.sh
# Монтирует локальные папки (bind) и добавляет их в /etc/fstab
# Запуск: sudo bash mount_folders_redos8.sh

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Ошибка: скрипт нужно запускать от root (sudo)." >&2
  exit 1
fi

# Список монтирований: "ИСТОЧНИК НАЗНАЧЕНИЕ"
# Добавьте/измените пары под себя:
MOUNTS=(
  "/data/share1 /mnt/share1"
  "/data/share2 /mnt/share2"
  "/var/log/app /opt/app/log"
)

FSTAB="/etc/fstab"
BACKUP="/etc/fstab.bak.$(date +%F_%H-%M-%S)"

fstab_has_entry() {
  local src="$1"
  local dst="$2"

  while read -r line; do
    # Убираем комментарии и пустые строки
    [[ -n "${line// }" ]] || continue
    line="${line%%[[:space:]]#*}"
    [[ -n "${line// }" ]] || continue
    
    # Парсим только первые 6 полей
    read -r fs_src fs_dst fs_type fs_opts _ < <(echo "$line")
    
    [[ -n "$fs_src" ]] || continue
    [[ "$fs_src" == "#"* ]] && continue
    if [[ "$fs_src" == "$src" && "$fs_dst" == "$dst" && "$fs_type" == "none" && ",$fs_opts," == *",bind,"* ]]; then
      return 0
    fi
  done < "$FSTAB"

  return 1
}

is_bind_mounted() {
  local src="$1"
  local dst="$2"
  local current_src

  current_src=$(findmnt -rn --target "$dst" --output SOURCE 2>/dev/null || true)
  [[ "$current_src" == "$src" ]]
}

cp -a "$FSTAB" "$BACKUP"
echo "Резервная копия fstab: $BACKUP"

for pair in "${MOUNTS[@]}"; do
  src="${pair%% *}"
  dst="${pair##* }"

  if [[ ! -d "$src" ]]; then
    echo "Пропуск: источник не существует: $src" >&2
    continue
  fi

  mkdir -p "$dst"

  # Строка для fstab
  # Формат: source target fstype options dump pass
  line="$src $dst none bind 0 0"

  # Если записи для source+target еще нет — добавляем
  if ! fstab_has_entry "$src" "$dst"; then
    echo "$line" >> "$FSTAB"
    echo "Добавлено в fstab: $line"
  else
    echo "Уже есть в fstab: $src -> $dst"
  fi

  # Монтируем сразу, если еще не смонтировано
  if ! is_bind_mounted "$src" "$dst"; then
    mount --bind "$src" "$dst"
    echo "Смонтировано: $src -> $dst"
  else
    echo "Уже смонтировано: $src -> $dst"
  fi
done

echo
echo "Проверка добавленных bind-монтирований:"
for pair in "${MOUNTS[@]}"; do
  src="${pair%% *}"
  dst="${pair##* }"

  [[ -d "$src" ]] || continue
  if ! is_bind_mounted "$src" "$dst"; then
    mount --bind "$src" "$dst"
  fi
done
echo "Готово."
