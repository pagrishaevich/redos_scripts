# redos_scripts

Административные Bash-скрипты для РЕД ОС 8 и совместимых Linux-систем.

Скрипты помогают управлять bind-монтированиями, CIFS/SMB-шарами и политикой доступа к USB-накопителям. Все операции рассчитаны на запуск администратором и могут изменять системные файлы.

## Состав

| Скрипт | Назначение |
| --- | --- |
| `mount_folders_redos8.sh` | Bind-монтирование локальных директорий с добавлением записей в `/etc/fstab`. |
| `mount-manager.sh` | Интерактивное управление CIFS/SMB-шарами, credentials-файлами, пресетами и `/etc/fstab`. |
| `usb-guard.sh` | Блокировка USB-накопителей через `udev`, `UDISKS_IGNORE` и `authorized`, с поддержкой белых списков. |

## Требования

- РЕД ОС 8 или совместимая Linux-система с Bash.
- Root-права для всех основных операций.
- Для CIFS/SMB: `cifs-utils`, опционально `smbclient`.
- Для USB-управления: `udev`, `udevadm`, `coreutils`, `grep`, `sed`, `mktemp`, `readlink`; опционально `usbutils`/`lsusb`.

## Быстрый Старт

```bash
chmod +x *.sh

sudo ./mount_folders_redos8.sh
sudo ./mount-manager.sh --help
sudo ./usb-guard.sh --help
```

Перед запуском обязательно прочитайте раздел конкретного скрипта ниже.

## mount_folders_redos8.sh

Скрипт предназначен для bind-монтирования локальных директорий.

Перед запуском отредактируйте массив `MOUNTS` внутри файла:

```bash
MOUNTS=(
  "/data/share1 /mnt/share1"
  "/data/share2 /mnt/share2"
)
```

Что делает скрипт:

- проверяет запуск от root;
- создаёт backup `/etc/fstab` в формате `/etc/fstab.bak.<date>`;
- создаёт директории назначения;
- добавляет отсутствующие bind-записи в `/etc/fstab`;
- монтирует только указанные пары директорий;
- не запускает общий `mount -a`, чтобы не ломаться из-за чужих проблемных записей в `/etc/fstab`.

Запуск:

```bash
sudo ./mount_folders_redos8.sh
```

## mount-manager.sh

Скрипт управляет CIFS/SMB-шарами через интерактивное меню или CLI-опции.

Команды:

```bash
sudo ./mount-manager.sh --list
sudo ./mount-manager.sh --add
sudo ./mount-manager.sh --remove
sudo ./mount-manager.sh --load
sudo ./mount-manager.sh --mount-all
```

Особенности:

- создаёт SMB credentials-файлы в `/root/.smbuser_*` с правами `600`;
- может сохранять пресеты в `/etc/mount-manager.conf`;
- перед изменением `/etc/fstab` создаёт backup;
- валидирует имя точки монтирования;
- использует CIFS-права `file_mode=0770,dir_mode=0770`;
- не удаляет непустые директории mount-point принудительно.

Зависимости:

```bash
sudo dnf install cifs-utils
sudo dnf install samba-client
```

`samba-client` нужен только для диагностики через `smbclient`.

## usb-guard.sh

Скрипт управляет доступом к USB-накопителям через `udev`.

Команды:

```bash
sudo ./usb-guard.sh --scan
sudo ./usb-guard.sh --whitelist
sudo ./usb-guard.sh --whitelist-auth
sudo ./usb-guard.sh --block-all
sudo ./usb-guard.sh --unblock
sudo ./usb-guard.sh --show
```

Методы блокировки:

- `UDISKS_IGNORE` запрещает автомонтирование, но устройство остаётся видимым в системе.
- `authorized` отключает устройство на уровне USB-шины через `/sys/bus/usb/devices/.../authorized`.

Особенности текущей версии:

- сканирует именно USB-блочные устройства через `/sys/block`;
- поддерживает драйверы `usb-storage` и `uas`;
- whitelist по нескольким атрибутам создаётся одной `udev`-строкой, то есть атрибуты проверяются совместно;
- перед перезаписью `/usr/bin/remove_usb.sh` создаёт backup;
- после изменения правил перезагружает `udev` и рекомендует переподключить USB-устройства.

Файлы, которые может менять скрипт:

```text
/etc/udev/rules.d/99-usb.rules
/usr/bin/remove_usb.sh
```

## Безопасность

- Запускайте скрипты только после просмотра содержимого и настройки параметров.
- Перед применением на рабочей машине протестируйте сценарий на стенде.
- Держите резервный доступ к системе перед изменением `/etc/fstab` или USB-политик.
- Не коммитьте credentials-файлы, пароли, токены и приватные ключи.
- `mount-manager.sh` может хранить SMB-пресеты с паролем в `/etc/mount-manager.conf`; файл создаётся с правами `600`, но это всё равно чувствительные данные.

## Проверка Синтаксиса

```bash
bash -n mount_folders_redos8.sh
bash -n mount-manager.sh
bash -n usb-guard.sh
```

## Документация Проекта

- `SECURITY.md` — политика безопасного использования и ответственного раскрытия уязвимостей.
- `CONTRIBUTING.md` — рекомендации для контрибьюторов.
