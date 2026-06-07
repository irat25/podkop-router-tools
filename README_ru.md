# Podkop Router Tools

Набор LuCI-страниц и служебных скриптов для OpenWrt:

- Podkop Watchdog
- Podkop Auto Update
- Podkop Updater TG
- Tailscale Tools

В репозитории нет паролей, Telegram-токенов, authkey Tailscale или приватных конфигов.

## Установка

Для BusyBox `ash` на OpenWrt используйте такой вариант:

```sh
wget -O /tmp/podkop-router-tools-install.sh https://raw.githubusercontent.com/irat25/podkop-router-tools/main/install.sh
sh /tmp/podkop-router-tools-install.sh
```

Если оболочка поддерживает process substitution, можно одной строкой:

```sh
sh <(wget -O - https://raw.githubusercontent.com/irat25/podkop-router-tools/main/install.sh)
```

После установки в LuCI появятся:

- `Services -> Podkop Watchdog`
- `Services -> Podkop Auto Update`
- `Services -> Podkop Updater TG`
- `VPN -> Tailscale`

## Расписание

Установщик включает cron:

- Watchdog: каждую минуту
- Auto Update: ежедневно в 10:00

## Tailscale Tools

Страница показывает статус сервиса, Tailscale IP, список peers, netcheck, логи и текущий `tailscale serve status`.

Доступные действия:

- start/stop/restart сервиса
- enable/disable автозапуска
- `tailscale up` / `tailscale down`
- ввод нового auth key без отображения текущего ключа
- проброс LuCI через Tailscale Serve на порты `80` и `8081`
- проброс SSH через Tailscale Serve на порт `2222`

## Telegram Updater

`Podkop Updater TG` устанавливает LuCI-страницу и init-скрипт. Бинарник `podkop_updater` скачивается с публичных релизов `VizzleTF/podkop_autoupdater`, если GitHub доступен с роутера.

Чтобы сервис стартовал, заполните `/etc/config/podkop_updater`:

```uci
config settings 'settings'
        option bot_token 'TELEGRAM_BOT_TOKEN'
        option chat_id 'TELEGRAM_CHAT_ID'
        option admin_ids 'TELEGRAM_USER_ID'
```

Без `bot_token` и `chat_id` сервис не стартует, это сделано специально.
