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
  if ! grep -qsE "^[[:space:]]*${src//\//\\/}[[:space:]]+${dst//\//\\/}[[:space:]]+none[[:space:]]+bind([[:space:],].*)?$" "$FSTAB"; then
    echo "$line" >> "$FSTAB"
    echo "Добавлено в fstab: $line"
  else
    echo "Уже есть в fstab: $src -> $dst"
  fi

  # Монтируем сразу, если еще не смонтировано
  if ! findmnt -rn -S "$src" -T "$dst" >/dev/null 2>&1; then
    mount --bind "$src" "$dst"
    echo "Смонтировано: $src -> $dst"
  else
    echo "Уже смонтировано: $src -> $dst"
  fi
done

echo
echo "Проверка fstab:"
mount -a
echo "Готово."
