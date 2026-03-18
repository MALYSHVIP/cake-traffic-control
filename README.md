# CAKE Soft Panel

Пакет для мягкой установки панели CAKE на живые VPN-ноды. По умолчанию он ставит только UI, метрики, конфиг и backend панели в `observer`-режиме. Полный CAKE-контур включается только по явному `--mode full`.

Что пакет делает:

- ставит новую панель, helper и systemd-сервис;
- сохраняет существующий `/etc/cake_panel/cake_autoset.conf`, если он уже есть;
- не трогает `ufw`, `iptables`, `fail2ban`, `full-upgrade`, allowlist и self-heal;
- умеет опционально ставить локальный DNS-кэш на `unbound`.

Что внутри:

- `app.py` — backend панели;
- `www/` — фронтенд;
- `cake_soft_panel_ctl.sh` — root helper для whitelist-операций панели;
- `install_soft_cake_panel.sh` — локальный installer пакета;
- `cake_autoset.sh`, `cake_apply_last_good.sh`, `systemd/` — CAKE engine для `--mode full`;
- `unbound_tokervpn_cache.conf`, `netplan_99_tokervpn_local_dns.yaml` — шаблоны для DNS-кэша.

## Поддерживаемые ОС

- Ubuntu `22.04`
- Ubuntu `24.04`
- Debian и Debian-compatible системы с `apt` и `systemd`

`--enable-dns-cache` ориентирован в первую очередь на Ubuntu/netplan-хосты. На системах без `netplan` installer всё равно ставит `unbound` и override для `systemd-resolved`, но netplan-файл не применяет.

## GitHub One-Liner

После публикации в GitHub installer можно ставить так:

```bash
curl -fsSL https://raw.githubusercontent.com/MALYSHVIP/cake-traffic-control/main/install.sh | sudo bash
```

Для форка или тестовой ветки можно явно переопределить repo через env:

```bash
curl -fsSL https://raw.githubusercontent.com/MALYSHVIP/cake-traffic-control/main/install.sh | sudo GITHUB_REPO=<owner>/<repo> bash
```

С аргументами:

```bash
curl -fsSL https://raw.githubusercontent.com/MALYSHVIP/cake-traffic-control/main/install.sh | sudo GITHUB_REPO=<owner>/<repo> bash -s -- --mode full --enable-dns-cache
```

## Локальный запуск из checkout

Из корня пакета:

```bash
sudo bash ./install.sh
```

Или напрямую локальный installer:

```bash
sudo bash ./cake_soft_panel/install_soft_cake_panel.sh
```

## Режимы установки

### `observer` по умолчанию

Ставит:

- панель;
- helper;
- конфиг;
- `cake-soft-panel.service`.

Не ставит и не включает:

- `cake_autoset.sh`;
- `cake_autoset.timer`;
- `cake_apply_last_good.service`.

Это безопасный дефолт для живых нод.

### `full`

Дополнительно ставит:

- `cake_autoset.sh`;
- `cake_apply_last_good.sh`;
- `cake_autoset.service`;
- `cake_autoset.timer`;
- `cake_apply_last_good.service`.

После установки:

- включает `cake_autoset.timer`;
- делает начальный `cake_autoset.sh --force`.

## Опции installer

Поддерживаемые флаги:

- `--mode observer|full`
- `--enable-dns-cache`
- `--port <port>`
- `--bind <addr>`
- `--iface <iface>`
- `--ifb <ifb>`
- `--vpn-ports "<ports>"`
- `--panel-path <path>`
- `--panel-user <user>`

Bootstrap-флаги корневого [install.sh](/Users/vladimircernakov/Documents/New%20project/install.sh):

- `--repo <owner/repo>`
- `--ref <git-ref>`

Поддерживаемые env overrides:

- `GITHUB_REPO`
- `GITHUB_REF`
- `PANEL_PORT`
- `PANEL_BIND`
- `CAKE_IFACE`
- `CAKE_IFB`
- `CAKE_VPN_PORTS`

Дефолты:

- `mode`: `observer`
- `bind`: `0.0.0.0`
- `port`: `8090`
- `iface`: autodetect по default route
- `ifb`: `ifb0`
- `vpn ports`: `443`

## Примеры

Живая нода, только панель:

```bash
sudo bash ./install.sh --mode observer --port 8090 --bind 0.0.0.0
```

Новая нода, панель + CAKE:

```bash
sudo bash ./install.sh --mode full --iface eth0 --vpn-ports "443"
```

Панель + CAKE + локальный DNS-кэш:

```bash
sudo bash ./install.sh --mode full --enable-dns-cache --iface eth0 --vpn-ports "443"
```

С явным скрытым путём панели:

```bash
sudo bash ./install.sh --panel-path /p/mytoken/
```

## Что создаётся на ноде

- app: `/opt/cake_soft_panel`
- config: `/etc/cake_panel/cake_autoset.conf`
- panel env: `/etc/cake_panel/panel.env`
- bootstrap password hint: `/etc/cake_panel/bootstrap_password.txt`
- panel service: `cake-soft-panel.service`

При `--mode full` дополнительно:

- `/usr/local/sbin/cake_autoset.sh`
- `/usr/local/sbin/cake_apply_last_good.sh`
- `cake_autoset.service`
- `cake_autoset.timer`
- `cake_apply_last_good.service`

## DNS-кэш

При `--enable-dns-cache` installer:

- ставит `unbound`;
- раскладывает шаблон `unbound` из пакета;
- настраивает split-DNS:
  - внешние домены -> `1.1.1.1`, `1.0.0.1`
  - `auto.internal`, `ru-central1.internal` -> `10.130.0.2`
  - `metadata.google.internal` -> `169.254.169.254`
- переключает host resolver на `127.0.0.1`.

## Идемпотентность

Повторный запуск installer:

- не должен ломать существующую установку;
- сохраняет существующий `cake_autoset.conf`, если вы не передали явные override-флаги;
- сохраняет уже существующий `PANEL_SECRET`;
- переиспользует уже созданные bootstrap credentials.
