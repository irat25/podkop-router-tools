# Podkop Router Tools

Набор LuCI-страниц и служебных скриптов для OpenWrt:

- Podkop Watchdog
- Podkop Auto Update
- Podkop Updater TG

В репозитории нет паролей, Telegram-токенов, authkey Tailscale или приватных конфигов.

## Установка

После публикации репозитория в GitHub установку можно запускать на роутере так:

```sh
sh <(wget -O - https://raw.githubusercontent.com/OWNER/REPO/main/install.sh)
```

Для BusyBox `ash`, где `<(...)` может не работать:

```sh
wget -O /tmp/podkop-router-tools-install.sh https://raw.githubusercontent.com/OWNER/REPO/main/install.sh
sh /tmp/podkop-router-tools-install.sh
```

После установки в LuCI появятся:

- `Services -> Podkop Watchdog`
- `Services -> Podkop Auto Update`
- `Services -> Podkop Updater TG`

## Расписание

Установщик включает cron:

- Watchdog: каждую минуту
- Auto Update: ежедневно в 10:00

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

