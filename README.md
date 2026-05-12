# redos_scripts

Административные Bash-скрипты для РЕД ОС 8 и совместимых Linux-систем.

Скрипты помогают управлять CIFS/SMB-шарами, политикой доступа к USB-накопителям и настройками сна. Все операции рассчитаны на запуск администратором и могут изменять системные файлы.

## Исправления

### v1.4 (2026-05-12)

- **mount-manager.sh**: исправлен случай запуска из root-сессии, когда в `/etc/fstab` записывалось `uid=0,gid=0`, и обычный пользователь не видел смонтированную шару. Если реальный пользователь не определяется через `SUDO_USER`, скрипт запрашивает локального пользователя-владельца mount-point.
- **mount-manager.sh**: выбор локального владельца применяется и при обычном добавлении шары, и при загрузке пресета, чтобы старые сценарии не возвращались к `root:root`.

### v1.3 (2026-05-12)

- **mount-manager.sh**: исправлен доступ обычного пользователя к смонтированным CIFS/SMB-шарам. Скрипт добавляет `uid`, `gid`, `forceuid` и `forcegid` для пользователя, из-под которого выполнен `sudo`, поэтому локальные права больше не остаются привязанными к `root:root`.
- **mount-manager.sh**: при повторном добавлении существующей CIFS-записи в `/etc/fstab` запись обновляется с актуальными параметрами монтирования вместо тихого пропуска.

### v1.2 (2026-05-08)

- **mount-manager.sh**: добавлено доменное монтирование SMB-шар через Kerberos-билет текущего пользователя без сохранения пароля в credentials-файл.
- **mount-manager.sh**: добавлена проверка ввода компьютера в домен через `realm list` или `wbinfo -t`, проверка Kerberos-билета через `klist` и запуск `kinit` при отсутствии билета.
- **mount-manager.sh**: исправлен Kerberos-сценарий для серверов, указанных IP-адресом: скрипт пытается найти DNS/FQDN через `getent hosts`, потому что Kerberos требует SPN вида `cifs/server.domain@REALM`.
- **mount-manager.sh**: добавлено предупреждение о `cifs.upcall` и зависимости `keyutils`, которые нужны для CIFS-монтирования с `sec=krb5`.
- **usb-guard.sh**: добавлен отдельный режим `--block-whitelist` и пункт меню для блокировки всех USB-накопителей, кроме уже добавленных в белый список; `--block-all` теперь явно описан как блокировка без исключений.
- **usb-guard.sh**: исправлена генерация белого списка `UDISKS_IGNORE` — разрешающие правила по `serial`, `product` и `bMaxPower` теперь создаются отдельными строками по схеме документации РЕД ОС 8.
- **mount_folders_redos8.sh**: скрипт удалён из репозитория, связанные упоминания удалены из документации.

### v1.1 (2026-05-05)

- **mount-manager.sh**: улучшена функция `sanitize_name` — использует `sed` вместо bash parameter expansion для удаления подчёркиваний, что надёжнее работает с пустыми строками.
- **usb-guard.sh**: исправлена функция `build_attr_rule` — убран `trailing comma` перед action, что делало udev-правила синтаксически корректными.

## Состав

| Скрипт | Назначение |
| --- | --- |
| `mount-manager.sh` | Интерактивное управление CIFS/SMB-шарами, credentials-файлами, Kerberos-монтированием, пресетами и `/etc/fstab`. |
| `usb-guard.sh` | Блокировка USB-накопителей через `udev`, `UDISKS_IGNORE` и `authorized`, с поддержкой белых списков. |
| `sleep-guard-redos8.sh` | Отключение спящего режима на рабочих станциях РЕД ОС 8/MATE, диагностика sleep-событий и откат изменений. |

## Требования

- РЕД ОС 8 или совместимая Linux-система с Bash.
- Root-права для всех основных операций.
- Для CIFS/SMB: `cifs-utils`, опционально `smbclient`; для доменного Kerberos-монтирования нужны `krb5-workstation` и настроенный домен через `realmd`, `sssd` или `winbind`.
- Для USB-управления: `udev`, `udevadm`, `coreutils`, `grep`, `sed`, `mktemp`, `readlink`; опционально `usbutils`/`lsusb`.

## Быстрый Старт

```bash
chmod +x *.sh

sudo ./mount-manager.sh --help
sudo ./usb-guard.sh --help
sudo ./sleep-guard-redos8.sh --help
```

Перед запуском обязательно прочитайте раздел конкретного скрипта ниже.

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
- умеет монтировать доменные SMB-шары через Kerberos-билет текущего пользователя без сохранения пароля;
- может сохранять пресеты в `/etc/mount-manager.conf`;
- перед изменением `/etc/fstab` создаёт backup;
- назначает владельцем CIFS-монтирования пользователя, из-под которого выполнен `sudo`, через `uid`, `gid`, `forceuid`, `forcegid`; при запуске из root-сессии запрашивает владельца явно;
- валидирует имя точки монтирования;
- использует CIFS-права `file_mode=0770,dir_mode=0770`;
- не удаляет непустые директории mount-point принудительно.

Доменное монтирование через Kerberos:

1. Компьютер должен быть введён в домен. Скрипт проверяет это через `realm list` или `wbinfo -t`.
2. Запускайте скрипт через `sudo` из-под доменного пользователя, чтобы он смог определить пользователя по `SUDO_USER`.
3. У пользователя должен быть Kerberos-билет. Если `klist` не найдёт билет, скрипт предложит выполнить `kinit user@DOMAIN`.
4. При выборе Kerberos-режима пароль не записывается в credentials-файл, а CIFS монтируется с `sec=krb5,cruid=<uid>,multiuser`.
5. Для Kerberos используйте DNS-имя или FQDN SMB-сервера, а не IP-адрес. Если введён IP, скрипт попробует найти имя через `getent hosts`; без DNS-имени монтирование будет остановлено до вызова `mount.cifs`.
6. Запись в `/etc/fstab` для Kerberos-режима можно добавить, но она требует Kerberos-билет пользователя после входа в систему. На ранней загрузке системы такая запись может не смонтироваться.

Зависимости:

```bash
sudo dnf install cifs-utils
sudo dnf install samba-client
sudo dnf install krb5-workstation realmd samba-common-tools keyutils
```

`samba-client` нужен только для диагностики через `smbclient`. Пакеты Kerberos и `realmd` нужны только для доменного сценария.

## usb-guard.sh

Скрипт управляет доступом к USB-накопителям через `udev`.

Команды:

```bash
sudo ./usb-guard.sh --scan
sudo ./usb-guard.sh --whitelist
sudo ./usb-guard.sh --whitelist-auth
sudo ./usb-guard.sh --block-whitelist
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
- whitelist по нескольким атрибутам создаётся отдельными разрешающими `udev`-строками, как в документации РЕД ОС 8;
- режим `--block-whitelist` блокирует все USB-накопители через `UDISKS_IGNORE`, но сохраняет уже добавленные разрешающие правила белого списка;
- режим `--block-all` блокирует все USB-накопители без исключений и перезаписывает правила;
- перед перезаписью `/usr/bin/remove_usb.sh` создаёт backup;
- после изменения правил перезагружает `udev` и рекомендует переподключить USB-устройства.

Рекомендуемый порядок для режима белого списка:

1. Просканировать устройства: `sudo ./usb-guard.sh --scan`.
2. Добавить разрешённое устройство: `sudo ./usb-guard.sh --whitelist`.
3. Включить блокировку всех остальных USB-накопителей: `sudo ./usb-guard.sh --block-whitelist`.

Файлы, которые может менять скрипт:

```text
/etc/udev/rules.d/99-usb.rules
/usr/bin/remove_usb.sh
```

## sleep-guard-redos8.sh

Скрипт предназначен для рабочих станций РЕД ОС 8, которые самопроизвольно уходят в режим сна `suspend` и из-за этого теряют сеть. Он не меняет остальные скрипты проекта и работает только с настройками сна.

Команды:

```bash
sudo ./sleep-guard-redos8.sh --apply --user tvmedzhidova
sudo ./sleep-guard-redos8.sh --status
sudo ./sleep-guard-redos8.sh --collect-logs
sudo ./sleep-guard-redos8.sh --undo
```

Что делает `--apply`:

- маскирует `sleep.target`, `suspend.target`, `hibernate.target`, `hybrid-sleep.target`;
- создаёт `/etc/systemd/logind.conf.d/99-redos-no-sleep.conf` с игнорированием событий сна;
- перезапускает `systemd-logind`;
- при указании `--user` отключает таймеры сна и гашения экрана в MATE через `gsettings`;
- не отключает SELinux автоматически.

Диагностика:

```bash
sudo ./sleep-guard-redos8.sh --collect-logs
```

Команда собирает логи `systemd-logind`, sleep/suspend-события, состояние targets, inhibitors, SELinux и список задач Kaspersky KESL, если `kesl-control` установлен.

SELinux и Kaspersky:

В логах может встречаться конфликт `systemd-sleep` с Kaspersky KESL, но это не обязательно причина ухода в сон. Скрипт проверяет этот след диагностически. Временный перевод SELinux в permissive доступен только явным флагом:

```bash
sudo ./sleep-guard-redos8.sh --apply --user tvmedzhidova --selinux-permissive
```

Откат системных изменений:

```bash
sudo ./sleep-guard-redos8.sh --undo
```

## Безопасность

- Запускайте скрипты только после просмотра содержимого и настройки параметров.
- Перед применением на рабочей машине протестируйте сценарий на стенде.
- Держите резервный доступ к системе перед изменением `/etc/fstab` или USB-политик.
- Не коммитьте credentials-файлы, пароли, токены и приватные ключи.
- `mount-manager.sh` может хранить SMB-пресеты с паролем в `/etc/mount-manager.conf`; файл создаётся с правами `600`, но это всё равно чувствительные данные.
- В Kerberos-режиме `mount-manager.sh` не сохраняет пароль пользователя, но требует действующий Kerberos-билет.

## Проверка Синтаксиса

```bash
bash -n mount-manager.sh
bash -n usb-guard.sh
bash tests/mount-manager-tests.sh
```

## Документация Проекта

- `SECURITY.md` — политика безопасного использования и ответственного раскрытия уязвимостей.
- `CONTRIBUTING.md` — рекомендации для контрибьюторов.
