# Podkop Router Tools

Набор LuCI-страниц и служебных скриптов для OpenWrt:

- Podkop Watchdog
- Podkop Auto Update
- Podkop Updater TG

В репозитории нет паролей, Telegram-токенов, Tailscale authkey или приватных конфигов.

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

## Расписание

Установщик включает cron:

- Watchdog: каждую минуту
- Auto Update: ежедневно в 10:00

## Telegram Updater

`Podkop Updater TG` устанавливает LuCI-страницу, init-скрипт и Go-бинарник `podkop_updater` с публичных релизов `VizzleTF/podkop_autoupdater`, если GitHub доступен с роутера.

Страница LuCI повторяет основные настройки оригинального updater:

- `bot_token` - токен Telegram-бота из `@BotFather`
- `chat_id` - Telegram chat id из `@get_id_bot`
- `check_interval` - часы между проверками, по умолчанию `6`
- `router_label` - имя роутера в Telegram-дашборде
- `admin_ids` - разрешённые Telegram user ID через пробел
- `auto_update` - автообновление Podkop
- `auto_update_self` - автообновление updater
- `backup_keep` - сколько бэкапов хранить

Текущий `bot_token` в LuCI не показывается: отображается только публичная часть `Bot ID`. Если поле token оставить пустым при сохранении, старый токен сохраняется.

Чтобы сервис стартовал, заполните `/etc/config/podkop_updater`:

```uci
config settings 'settings'
        option bot_token 'TELEGRAM_BOT_TOKEN'
        option chat_id 'TELEGRAM_CHAT_ID'
        option check_interval '6'
        option router_label 'Home'
        option admin_ids 'TELEGRAM_USER_ID'
        option auto_update '0'
        option auto_update_self '0'
        option backup_keep '10'
```

После запуска откройте Telegram-чат с ботом и отправьте `/menu`.
