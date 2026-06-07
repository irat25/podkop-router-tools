#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

echo "== Podkop Router Tools installer =="

if [ "$(id -u)" != "0" ]; then
	echo "Run as root." >&2
	exit 1
fi

mkdir -p \
	/root \
	/usr/libexec \
	/usr/share/luci/menu.d \
	/usr/share/rpcd/acl.d \
	/www/luci-static/resources/view/podkop-watchdog \
	/www/luci-static/resources/view/podkop-auto-update \
	/www/luci-static/resources/view/podkop-updater \
	/www/luci-static/resources/view/tailscale-tools

cat >/root/podkop-watchdog.sh <<'EOF_WATCHDOG'
#!/bin/sh

LOCK="/tmp/podkop-watchdog.lock"
[ -e "$LOCK" ] && exit 0
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

TEST_DOMAIN="ya.ru"
PODKOP_DNS="127.0.0.42"
FAIL_LOG="/root/podkop-watchdog-last-failure.log"

capture_failure() {
	{
		echo "=== date ==="
		date
		echo "=== reason ==="
		echo "$1"
		echo "=== processes ==="
		ps | grep -E '[s]ing-box|[d]nsmasq|[p]odkop' || true
		echo "=== dnsmasq uci ==="
		uci -q show dhcp.@dnsmasq[0] | grep -E 'noresolv|server|resolv|podkop|cachesize' || true
		echo "=== routes ==="
		ip -4 route show default 2>/dev/null || true
		ip -4 rule show 2>/dev/null || true
		echo "=== dns tests ==="
		nslookup "$TEST_DOMAIN" 127.0.0.1 2>&1 | head -20 || true
		nslookup "$TEST_DOMAIN" "$PODKOP_DNS" 2>&1 | head -20 || true
		echo "=== recent logs ==="
		logread 2>/dev/null | grep -iE 'podkop|sing-box|dnsmasq|127\.0\.0\.42|github|release-assets|rule-set|ruleset|\.srs|fatal|panic|failed|watchdog' | tail -180 || true
	} > "$FAIL_LOG"
}

if ! pgrep -f '[s]ing-box' >/dev/null 2>&1 || ! nslookup "$TEST_DOMAIN" "$PODKOP_DNS" >/dev/null 2>&1; then
	logger -t podkop-watchdog "sing-box or podkop DNS failed, restarting podkop"
	capture_failure "sing-box or podkop DNS failed before podkop restart"
	/etc/init.d/podkop restart >/dev/null 2>&1 || true
	sleep 25
fi

if ! nslookup "$TEST_DOMAIN" "$PODKOP_DNS" >/dev/null 2>&1; then
	logger -t podkop-watchdog "podkop DNS still failed, stopping podkop and restarting dnsmasq"
	capture_failure "podkop DNS still failed after podkop restart"
	/etc/init.d/podkop stop >/dev/null 2>&1 || true
	sleep 5
	/etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
fi

exit 0
EOF_WATCHDOG
chmod +x /root/podkop-watchdog.sh

cat >/root/podkop-auto-update.sh <<'EOF_AUTOUPDATE'
#!/bin/sh

LOCK="/tmp/podkop-auto-update.lock"
[ -e "$LOCK" ] && exit 0
touch "$LOCK"
trap 'rm -f "$LOCK"' EXIT

REPO_API="https://api.github.com/repos/itdoginfo/podkop/releases/latest"
INSTALL_URL="https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh"
INSTALLER="/tmp/podkop-install.sh"
LOG="/root/podkop-auto-update.log"
STATE="/root/podkop-auto-update.state"
BACKUP_DIR="/root/podkop-auto-update-backups"

log_msg() {
	mkdir -p "$(dirname "$LOG")"
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
	logger -t podkop-auto-update "$*"
}

normalize_version() {
	printf '%s' "$1" | sed 's/^v//; s/-r[0-9][0-9]*$//'
}

current_version() {
	/usr/bin/podkop show_version 2>/dev/null | head -1 | sed 's/[[:space:]]//g'
}

latest_version() {
	wget -q -T 30 -O - "$REPO_API" 2>/tmp/podkop-auto-update-api.err |
		tr ',' '\n' |
		sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' |
		head -1
}

write_state() {
	{
		echo "last_run=$(date '+%Y-%m-%d %H:%M:%S')"
		echo "current=$1"
		echo "latest=$2"
		echo "action=$3"
		echo "result=$4"
	} > "$STATE"
}

do_install() {
	current="$1"
	latest="$2"
	ts="$(date '+%Y%m%d-%H%M%S')"
	mkdir -p "$BACKUP_DIR"
	uci export podkop > "$BACKUP_DIR/podkop.$ts.uci" 2>/dev/null || true
	cp /etc/sing-box/config.json "$BACKUP_DIR/sing-box-config.$ts.json" 2>/dev/null || true

	log_msg "installing Podkop update: current=$current latest=$latest"
	if ! wget -q -T 60 -O "$INSTALLER" "$INSTALL_URL"; then
		log_msg "failed to download installer from $INSTALL_URL"
		write_state "$current" "$latest" "install" "download_failed"
		return 1
	fi

	sh "$INSTALLER" >> "$LOG" 2>&1
	rc=$?
	rm -f "$INSTALLER"
	after="$(current_version)"

	if [ "$rc" -eq 0 ]; then
		res="ok"
	else
		res="failed_rc_$rc"
	fi

	log_msg "installer result=$res before=$current after=$after latest=$latest"
	write_state "$after" "$latest" "install" "$res"
	return "$rc"
}

mode="${1:-auto}"
current="$(current_version)"
latest="$(latest_version)"

if [ -z "$latest" ]; then
	log_msg "failed to fetch latest Podkop release; api_error=$(cat /tmp/podkop-auto-update-api.err 2>/dev/null | tail -3)"
	write_state "$current" "" "$mode" "latest_fetch_failed"
	exit 1
fi

current_n="$(normalize_version "$current")"
latest_n="$(normalize_version "$latest")"

if [ "$mode" = "force" ]; then
	do_install "$current" "$latest"
	exit $?
fi

if [ "$current_n" = "$latest_n" ]; then
	log_msg "Podkop is up to date: current=$current latest=$latest"
	write_state "$current" "$latest" "$mode" "up_to_date"
	exit 0
fi

if [ "$mode" = "check" ]; then
	log_msg "Podkop update available: current=$current latest=$latest"
	write_state "$current" "$latest" "$mode" "update_available"
	exit 0
fi

do_install "$current" "$latest"
EOF_AUTOUPDATE
chmod +x /root/podkop-auto-update.sh

cat >/usr/libexec/podkop-watchdog-luci <<'EOF_WATCHDOG_LUCI'
#!/bin/sh

SCRIPT="/root/podkop-watchdog.sh"
CRON="/etc/crontabs/root"
CRON_LINE="* * * * * /root/podkop-watchdog.sh"

json_escape() {
	sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g; s/$/\\n/' | tr -d '\n'
}

field() {
	printf '"%s":"%s"' "$1" "$(printf '%s' "$2" | json_escape)"
}

enabled() {
	grep -q '^[^#].*/root/podkop-watchdog.sh' "$CRON" 2>/dev/null && echo true || echo false
}

status_json() {
	en="$(enabled)"
	podkop="$(/etc/init.d/podkop status 2>&1 || true)"
	singbox="$(pgrep -f '[s]ing-box' >/dev/null 2>&1 && echo running || echo stopped)"
	dns="$(nslookup ya.ru 127.0.0.42 >/dev/null 2>&1 && echo ok || echo failed)"
	logs="$(logread 2>/dev/null | grep podkop-watchdog | tail -40 || true)"
	failure="$([ -f /root/podkop-watchdog-last-failure.log ] && tail -120 /root/podkop-watchdog-last-failure.log || true)"
	printf '{'
	field enabled "$en"; printf ','
	field podkop "$podkop"; printf ','
	field singbox "$singbox"; printf ','
	field dns "$dns"; printf ','
	field cron "$(grep podkop-watchdog "$CRON" 2>/dev/null || true)"; printf ','
	field logs "$logs"; printf ','
	field last_failure "$failure"
	printf '}\n'
}

enable_watchdog() {
	touch "$CRON"
	grep -v '/root/podkop-watchdog.sh' "$CRON" >/tmp/podkop-watchdog-cron 2>/dev/null || true
	echo "$CRON_LINE" >> /tmp/podkop-watchdog-cron
	cat /tmp/podkop-watchdog-cron > "$CRON"
	rm -f /tmp/podkop-watchdog-cron
	/etc/init.d/cron restart >/dev/null 2>&1 || true
	echo "enabled"
}

disable_watchdog() {
	touch "$CRON"
	grep -v '/root/podkop-watchdog.sh' "$CRON" >/tmp/podkop-watchdog-cron 2>/dev/null || true
	cat /tmp/podkop-watchdog-cron > "$CRON"
	rm -f /tmp/podkop-watchdog-cron
	/etc/init.d/cron restart >/dev/null 2>&1 || true
	echo "disabled"
}

case "$1" in
	status) status_json ;;
	enable) chmod +x "$SCRIPT"; enable_watchdog ;;
	disable) disable_watchdog ;;
	run) chmod +x "$SCRIPT"; "$SCRIPT" 2>&1 ;;
	chmod) chmod +x "$SCRIPT"; echo "ok" ;;
	*) echo "Usage: $0 status|enable|disable|run|chmod" >&2; exit 1 ;;
esac
EOF_WATCHDOG_LUCI
chmod +x /usr/libexec/podkop-watchdog-luci

cat >/usr/libexec/podkop-auto-update-luci <<'EOF_AUTOUPDATE_LUCI'
#!/bin/sh

SCRIPT="/root/podkop-auto-update.sh"
CRON="/etc/crontabs/root"
CRON_LINE="0 10 * * * /root/podkop-auto-update.sh"

json_escape() {
	sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g; s/$/\\n/' | tr -d '\n'
}

field() {
	printf '"%s":"%s"' "$1" "$(printf '%s' "$2" | json_escape)"
}

enabled() {
	grep -q '^[^#].*/root/podkop-auto-update.sh' "$CRON" 2>/dev/null && echo true || echo false
}

status_json() {
	current="$(/usr/bin/podkop show_version 2>/dev/null | head -1 || true)"
	state="$([ -f /root/podkop-auto-update.state ] && cat /root/podkop-auto-update.state || true)"
	logs="$([ -f /root/podkop-auto-update.log ] && tail -80 /root/podkop-auto-update.log || true)"
	printf '{'
	field enabled "$(enabled)"; printf ','
	field current "$current"; printf ','
	field cron "$(grep podkop-auto-update "$CRON" 2>/dev/null || true)"; printf ','
	field state "$state"; printf ','
	field logs "$logs"
	printf '}\n'
}

enable_update() {
	touch "$CRON"
	grep -v '/root/podkop-auto-update.sh' "$CRON" >/tmp/podkop-auto-update-cron 2>/dev/null || true
	echo "$CRON_LINE" >> /tmp/podkop-auto-update-cron
	cat /tmp/podkop-auto-update-cron > "$CRON"
	rm -f /tmp/podkop-auto-update-cron
	/etc/init.d/cron restart >/dev/null 2>&1 || true
	echo "enabled"
}

disable_update() {
	touch "$CRON"
	grep -v '/root/podkop-auto-update.sh' "$CRON" >/tmp/podkop-auto-update-cron 2>/dev/null || true
	cat /tmp/podkop-auto-update-cron > "$CRON"
	rm -f /tmp/podkop-auto-update-cron
	/etc/init.d/cron restart >/dev/null 2>&1 || true
	echo "disabled"
}

case "$1" in
	status) status_json ;;
	enable) chmod +x "$SCRIPT"; enable_update ;;
	disable) disable_update ;;
	check) chmod +x "$SCRIPT"; "$SCRIPT" check 2>&1 ;;
	force) chmod +x "$SCRIPT"; "$SCRIPT" force 2>&1 ;;
	chmod) chmod +x "$SCRIPT"; echo "ok" ;;
	*) echo "Usage: $0 status|enable|disable|check|force|chmod" >&2; exit 1 ;;
esac
EOF_AUTOUPDATE_LUCI
chmod +x /usr/libexec/podkop-auto-update-luci

cat >/usr/libexec/podkop-updater-luci <<'EOF_UPDATER_LUCI'
#!/bin/sh

BIN="/usr/bin/podkop_updater"
CONF="/etc/config/podkop_updater"

json_escape() {
	sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g; s/$/\\n/' | tr -d '\n'
}

field() {
	printf '"%s":"%s"' "$1" "$(printf '%s' "$2" | json_escape)"
}

install_bin() {
	api="https://api.github.com/repos/VizzleTF/podkop_autoupdater/releases/latest"
	tmp="/tmp/podkop_updater.release.json"
	bin_tmp="/tmp/podkop_updater.bin"
	arch="$(uname -m 2>/dev/null || echo unknown)"
	wget -q -T 30 -O "$tmp" "$api" || { echo "api_download_failed"; return 1; }
	case "$arch" in
		x86_64) want="amd64" ;;
		aarch64|arm64) want="arm64" ;;
		armv7*|armv6*) want="armv7" ;;
		mipsel*|mipsle*) want="mipsle" ;;
		mips*) want="mips" ;;
		*) want="" ;;
	esac
	urls="$(tr ',' '\n' < "$tmp" | sed -n 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | grep -v '\.sha256$')"
	[ -n "$want" ] && url="$(printf '%s\n' "$urls" | grep "/podkop_updater-$want$" | head -1)" || url=""
	[ -n "$url" ] || url="$(printf '%s\n' "$urls" | head -1)"
	[ -n "$url" ] || { echo "asset_not_found"; cat "$tmp"; return 1; }
	echo "download $url"
	wget -T 60 -O "$bin_tmp" "$url" || return 1
	if [ "$(wc -c < "$bin_tmp" 2>/dev/null || echo 0)" -lt 100000 ]; then
		echo "downloaded file is too small, refusing to install"
		rm -f "$bin_tmp"
		return 1
	fi
	mv "$bin_tmp" "$BIN"
	chmod +x "$BIN"
}

ensure_conf() {
	[ -f "$CONF" ] && return 0
	touch "$CONF"
	uci set podkop_updater.settings=settings
	uci set podkop_updater.settings.bot_token=''
	uci set podkop_updater.settings.chat_id=''
	uci set podkop_updater.settings.admin_ids=''
	uci commit podkop_updater
}

status_json() {
	ensure_conf
	version="$($BIN --version 2>&1 || $BIN version 2>&1 || true)"
	service="$(/etc/init.d/podkop_updater status 2>&1 || true)"
	autostart="$([ -e /etc/rc.d/S99podkop_updater ] && echo enabled || echo disabled)"
	config="$(cat "$CONF" 2>/dev/null || true)"
	logs="$(logread 2>/dev/null | grep -i podkop_updater | tail -60 || true)"
	printf '{'
	field binary "$(ls -l "$BIN" 2>/dev/null || echo missing)"; printf ','
	field version "$version"; printf ','
	field service "$service"; printf ','
	field autostart "$autostart"; printf ','
	field config "$config"; printf ','
	field logs "$logs"
	printf '}\n'
}

case "$1" in
	status) status_json ;;
	install) install_bin ;;
	start) /etc/init.d/podkop_updater start 2>&1 ;;
	stop) /etc/init.d/podkop_updater stop 2>&1 ;;
	restart) /etc/init.d/podkop_updater restart 2>&1 ;;
	enable) /etc/init.d/podkop_updater enable 2>&1 ;;
	disable) /etc/init.d/podkop_updater disable 2>&1 ;;
	*) echo "Usage: $0 status|install|start|stop|restart|enable|disable" >&2; exit 1 ;;
esac
EOF_UPDATER_LUCI
chmod +x /usr/libexec/podkop-updater-luci

cat >/usr/libexec/tailscale-tools-luci <<'EOF_TAILSCALE_LUCI'
#!/bin/sh

json_escape() {
	sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g; s/$/\\n/' | tr -d '\n'
}

field() {
	printf '"%s":"%s"' "$1" "$(printf '%s' "$2" | json_escape)"
}

service_status() {
	if [ -x /etc/init.d/tailscale ]; then
		/etc/init.d/tailscale status 2>&1 || true
	else
		echo "missing /etc/init.d/tailscale"
	fi
}

autostart_status() {
	ls /etc/rc.d/S*tailscale >/dev/null 2>&1 && echo enabled || echo disabled
}

tailscale_cmd() {
	if command -v tailscale >/dev/null 2>&1; then
		tailscale "$@" 2>&1 || true
	else
		echo "tailscale command not found"
	fi
}

status_json() {
	printf '{'
	field service "$(service_status)"; printf ','
	field autostart "$(autostart_status)"; printf ','
	field ip "$(tailscale_cmd ip -4 | head -1)"; printf ','
	field status "$(tailscale_cmd status)"; printf ','
	field netcheck "$(tailscale_cmd netcheck)"; printf ','
	field serve "$(tailscale_cmd serve status)"; printf ','
	field logs "$(logread 2>/dev/null | grep -iE 'tailscale|tailscaled' | tail -120 || true)"
	printf '}\n'
}

case "$1" in
	status) status_json ;;
	start) /etc/init.d/tailscale start 2>&1 ;;
	stop) /etc/init.d/tailscale stop 2>&1 ;;
	restart) /etc/init.d/tailscale restart 2>&1 ;;
	enable) /etc/init.d/tailscale enable 2>&1 ;;
	disable) /etc/init.d/tailscale disable 2>&1 ;;
	up) tailscale_cmd up ;;
	down) tailscale_cmd down ;;
	serve-luci-80) tailscale_cmd serve --bg --tcp=80 tcp://127.0.0.1:80 ;;
	serve-luci-8081) tailscale_cmd serve --bg --tcp=8081 tcp://127.0.0.1:80 ;;
	serve-ssh-2222) tailscale_cmd serve --bg --tcp=2222 tcp://127.0.0.1:22 ;;
	clear-serve-80) tailscale_cmd serve --tcp=80 off ;;
	clear-serve-8081) tailscale_cmd serve --tcp=8081 off ;;
	clear-serve-2222) tailscale_cmd serve --tcp=2222 off ;;
	*) echo "Usage: $0 status|start|stop|restart|enable|disable|up|down|serve-luci-80|serve-luci-8081|serve-ssh-2222|clear-serve-80|clear-serve-8081|clear-serve-2222" >&2; exit 1 ;;
esac
EOF_TAILSCALE_LUCI
chmod +x /usr/libexec/tailscale-tools-luci

cat >/etc/init.d/podkop_updater <<'EOF_INIT'
#!/bin/sh /etc/rc.common

START=99
STOP=10
USE_PROCD=1

PROG=/usr/bin/podkop_updater
UCI_PKG=podkop_updater
UCI_SEC=settings

start_service() {
	local token chat

	config_load "$UCI_PKG"
	config_get token "$UCI_SEC" bot_token
	config_get chat "$UCI_SEC" chat_id

	if [ -z "$token" ] || [ -z "$chat" ]; then
		logger -t podkop_updater "not starting: bot_token or chat_id is empty"
		return 0
	fi

	procd_open_instance
	procd_set_param command "$PROG" --daemon
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 0
	procd_set_param stderr 0
	procd_close_instance
}
EOF_INIT
chmod +x /etc/init.d/podkop_updater

uci -q get podkop_updater.settings >/dev/null || {
	touch /etc/config/podkop_updater
	uci set podkop_updater.settings=settings
	uci set podkop_updater.settings.bot_token=''
	uci set podkop_updater.settings.chat_id=''
	uci set podkop_updater.settings.admin_ids=''
	uci commit podkop_updater
}

cat >/www/luci-static/resources/view/podkop-watchdog/status.js <<'EOF_WATCHDOG_JS'
'use strict';
'require view';
'require fs';
'require ui';
'require poll';

var scriptPath = '/root/podkop-watchdog.sh';

function run(args) { return fs.exec('/usr/libexec/podkop-watchdog-luci', args); }
function parse(res) { try { return JSON.parse((res && res.stdout) || '{}'); } catch (e) { return {}; } }
function pre(text) { return E('pre', { 'style': 'white-space:pre-wrap;max-height:320px;overflow:auto' }, text || '--'); }
function row(name, value) { return E('tr', {}, [ E('td', { 'style': 'width:25%' }, name), E('td', {}, value || '--') ]); }
function notify(res) { ui.addNotification(null, pre(((res && res.stdout) || '') + ((res && res.stderr) ? '\n' + res.stderr : '')), 'info'); }

return view.extend({
	load: function() {
		return Promise.all([ L.resolveDefault(run([ 'status' ]), { stdout: '{}' }), L.resolveDefault(fs.read(scriptPath), '') ]);
	},
	refresh: function(nodes) {
		return run([ 'status' ]).then(function(res) {
			var d = parse(res);
			nodes.summary.innerHTML = '';
			nodes.summary.appendChild(E('table', { 'class': 'table' }, [
				row('Cron', d.enabled),
				row('Podkop', d.podkop),
				row('sing-box', d.singbox),
				row('DNS 127.0.0.42', d.dns),
				row('Cron line', d.cron)
			]));
			nodes.logs.textContent = d.logs || 'No logs';
			nodes.failure.textContent = d.last_failure || 'No failure snapshot';
		});
	},
	render: function(data) {
		var code = data[1] || '', summary = E('div'), logs = pre('loading'), failure = pre('loading');
		var editor = E('textarea', { 'style': 'width:100%;min-height:360px;font-family:monospace' }, code);
		var self = this;
		function button(title, action, style) {
			return E('button', { 'class': 'btn cbi-button cbi-button-' + (style || 'action'), 'click': function(ev) {
				ev.preventDefault();
				return run([ action ]).then(notify).then(function() { return self.refresh({ summary: summary, logs: logs, failure: failure }); });
			}}, title);
		}
		poll.add(L.bind(this.refresh, this, { summary: summary, logs: logs, failure: failure }), 8);
		setTimeout(L.bind(this.refresh, this, { summary: summary, logs: logs, failure: failure }), 100);
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Podkop Watchdog'), summary,
			E('p', {}, [ button('Enable cron', 'enable', 'apply'), ' ', button('Disable cron', 'disable', 'reset'), ' ', button('Run now', 'run') ]),
			E('h3', {}, 'Code'), editor,
			E('p', {}, E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': function(ev) {
				ev.preventDefault();
				return fs.write(scriptPath, editor.value).then(function() { return run([ 'chmod' ]); }).then(notify);
			}}, 'Save code')),
			E('h3', {}, 'Log'), logs,
			E('h3', {}, 'Last failure'), failure
		]);
	}
});
EOF_WATCHDOG_JS

cat >/www/luci-static/resources/view/podkop-auto-update/status.js <<'EOF_AUTOUPDATE_JS'
'use strict';
'require view';
'require fs';
'require ui';
'require poll';

var scriptPath = '/root/podkop-auto-update.sh';

function run(args) { return fs.exec('/usr/libexec/podkop-auto-update-luci', args); }
function parse(res) { try { return JSON.parse((res && res.stdout) || '{}'); } catch (e) { return {}; } }
function pre(text) { return E('pre', { 'style': 'white-space:pre-wrap;max-height:340px;overflow:auto' }, text || '--'); }
function row(name, value) { return E('tr', {}, [ E('td', { 'style': 'width:25%' }, name), E('td', {}, value || '--') ]); }
function notify(res) { ui.addNotification(null, pre(((res && res.stdout) || '') + ((res && res.stderr) ? '\n' + res.stderr : '')), 'info'); }

return view.extend({
	load: function() {
		return Promise.all([ L.resolveDefault(run([ 'status' ]), { stdout: '{}' }), L.resolveDefault(fs.read(scriptPath), '') ]);
	},
	refresh: function(nodes) {
		return run([ 'status' ]).then(function(res) {
			var d = parse(res);
			nodes.summary.innerHTML = '';
			nodes.summary.appendChild(E('table', { 'class': 'table' }, [
				row('Cron', d.enabled),
				row('Current Podkop', d.current),
				row('Cron line', d.cron),
				row('State', pre(d.state))
			]));
			nodes.logs.textContent = d.logs || 'No logs';
		});
	},
	render: function(data) {
		var code = data[1] || '', summary = E('div'), logs = pre('loading');
		var editor = E('textarea', { 'style': 'width:100%;min-height:360px;font-family:monospace' }, code);
		var self = this;
		function button(title, action, style) {
			return E('button', { 'class': 'btn cbi-button cbi-button-' + (style || 'action'), 'click': function(ev) {
				ev.preventDefault();
				return run([ action ]).then(notify).then(function() { return self.refresh({ summary: summary, logs: logs }); });
			}}, title);
		}
		poll.add(L.bind(this.refresh, this, { summary: summary, logs: logs }), 10);
		setTimeout(L.bind(this.refresh, this, { summary: summary, logs: logs }), 100);
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Podkop Auto Update'), summary,
			E('p', {}, [ button('Enable daily 10:00', 'enable', 'apply'), ' ', button('Disable', 'disable', 'reset'), ' ', button('Check', 'check'), ' ', button('Force update', 'force', 'apply') ]),
			E('h3', {}, 'Code'), editor,
			E('p', {}, E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': function(ev) {
				ev.preventDefault();
				return fs.write(scriptPath, editor.value).then(function() { return run([ 'chmod' ]); }).then(notify);
			}}, 'Save code')),
			E('h3', {}, 'Log'), logs
		]);
	}
});
EOF_AUTOUPDATE_JS

cat >/www/luci-static/resources/view/podkop-updater/status.js <<'EOF_UPDATER_JS'
'use strict';
'require view';
'require fs';
'require ui';
'require poll';

var conf = '/etc/config/podkop_updater';

function run(args) { return fs.exec('/usr/libexec/podkop-updater-luci', args); }
function parse(res) { try { return JSON.parse((res && res.stdout) || '{}'); } catch (e) { return {}; } }
function pre(text) { return E('pre', { 'style': 'white-space:pre-wrap;max-height:340px;overflow:auto' }, text || '--'); }
function row(name, value) { return E('tr', {}, [ E('td', { 'style': 'width:25%' }, name), E('td', {}, value || '--') ]); }
function notify(res) { ui.addNotification(null, pre(((res && res.stdout) || '') + ((res && res.stderr) ? '\n' + res.stderr : '')), 'info'); }

return view.extend({
	load: function() {
		return Promise.all([ L.resolveDefault(run([ 'status' ]), { stdout: '{}' }), L.resolveDefault(fs.read(conf), '') ]);
	},
	refresh: function(nodes) {
		return run([ 'status' ]).then(function(res) {
			var d = parse(res);
			nodes.summary.innerHTML = '';
			nodes.summary.appendChild(E('table', { 'class': 'table' }, [
				row('Binary', d.binary),
				row('Version', d.version),
				row('Service', d.service),
				row('Autostart', d.autostart)
			]));
			nodes.logs.textContent = d.logs || 'No logs';
		});
	},
	render: function(data) {
		var cfg = data[1] || '', summary = E('div'), logs = pre('loading');
		var editor = E('textarea', { 'style': 'width:100%;min-height:220px;font-family:monospace' }, cfg);
		var self = this;
		function button(title, action, style) {
			return E('button', { 'class': 'btn cbi-button cbi-button-' + (style || 'action'), 'click': function(ev) {
				ev.preventDefault();
				return run([ action ]).then(notify).then(function() { return self.refresh({ summary: summary, logs: logs }); });
			}}, title);
		}
		poll.add(L.bind(this.refresh, this, { summary: summary, logs: logs }), 10);
		setTimeout(L.bind(this.refresh, this, { summary: summary, logs: logs }), 100);
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Podkop Updater TG'), summary,
			E('p', {}, [ button('Install/update binary', 'install', 'apply'), ' ', button('Start', 'start', 'apply'), ' ', button('Stop', 'stop', 'reset'), ' ', button('Restart', 'restart'), ' ', button('Enable autostart', 'enable', 'apply'), ' ', button('Disable autostart', 'disable', 'reset') ]),
			E('h3', {}, 'Config'), editor,
			E('p', {}, E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': function(ev) {
				ev.preventDefault();
				return fs.write(conf, editor.value).then(function() { return run([ 'restart' ]); }).then(notify);
			}}, 'Save config and restart')),
			E('h3', {}, 'Log'), logs
		]);
	}
});
EOF_UPDATER_JS

cat >/www/luci-static/resources/view/tailscale-tools/status.js <<'EOF_TAILSCALE_JS'
'use strict';
'require view';
'require fs';
'require ui';
'require poll';

function run(args) { return fs.exec('/usr/libexec/tailscale-tools-luci', args); }
function parse(res) { try { return JSON.parse((res && res.stdout) || '{}'); } catch (e) { return {}; } }
function pre(text) { return E('pre', { 'style': 'white-space:pre-wrap;max-height:360px;overflow:auto' }, text || '--'); }
function row(name, value) { return E('tr', {}, [ E('td', { 'style': 'width:24%' }, name), E('td', {}, value || '--') ]); }
function notify(res) { ui.addNotification(null, pre(((res && res.stdout) || '') + ((res && res.stderr) ? '\n' + res.stderr : '')), 'info'); }

return view.extend({
	load: function() {
		return L.resolveDefault(run([ 'status' ]), { stdout: '{}' });
	},
	refresh: function(nodes) {
		return run([ 'status' ]).then(function(res) {
			var d = parse(res);
			nodes.summary.innerHTML = '';
			nodes.summary.appendChild(E('table', { 'class': 'table' }, [
				row('Service', d.service),
				row('Autostart', d.autostart),
				row('Tailscale IPv4', d.ip),
				row('Serve', pre(d.serve))
			]));
			nodes.status.textContent = d.status || '--';
			nodes.netcheck.textContent = d.netcheck || '--';
			nodes.logs.textContent = d.logs || 'No tailscale logs';
		});
	},
	render: function() {
		var summary = E('div'), status = pre('loading'), netcheck = pre('loading'), logs = pre('loading');
		var self = this;
		function button(title, action, style) {
			return E('button', { 'class': 'btn cbi-button cbi-button-' + (style || 'action'), 'click': function(ev) {
				ev.preventDefault();
				return run([ action ]).then(notify).then(function() {
					return self.refresh({ summary: summary, status: status, netcheck: netcheck, logs: logs });
				});
			}}, title);
		}
		poll.add(L.bind(this.refresh, this, { summary: summary, status: status, netcheck: netcheck, logs: logs }), 8);
		setTimeout(L.bind(this.refresh, this, { summary: summary, status: status, netcheck: netcheck, logs: logs }), 100);
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Tailscale Tools'), summary,
			E('h3', {}, 'Service'),
			E('p', {}, [
				button('Start', 'start', 'apply'), ' ',
				button('Stop', 'stop', 'reset'), ' ',
				button('Restart', 'restart'), ' ',
				button('Enable autostart', 'enable', 'apply'), ' ',
				button('Disable autostart', 'disable', 'reset')
			]),
			E('h3', {}, 'Tailscale'),
			E('p', {}, [
				button('tailscale up', 'up', 'apply'), ' ',
				button('tailscale down', 'down', 'reset')
			]),
			E('h3', {}, 'Tailscale Serve'),
			E('p', {}, [
				button('LuCI :80', 'serve-luci-80', 'apply'), ' ',
				button('LuCI :8081', 'serve-luci-8081', 'apply'), ' ',
				button('SSH :2222', 'serve-ssh-2222', 'apply')
			]),
			E('p', {}, [
				button('Disable :80', 'clear-serve-80', 'reset'), ' ',
				button('Disable :8081', 'clear-serve-8081', 'reset'), ' ',
				button('Disable :2222', 'clear-serve-2222', 'reset')
			]),
			E('h3', {}, 'Peers'), status,
			E('h3', {}, 'Netcheck'), netcheck,
			E('h3', {}, 'Logs'), logs
		]);
	}
});
EOF_TAILSCALE_JS

cat >/usr/share/luci/menu.d/luci-app-podkop-watchdog.json <<'EOF_MENU_WATCHDOG'
{
	"admin/services/podkop-watchdog": {
		"title": "Podkop Watchdog",
		"order": 70,
		"action": { "type": "view", "path": "podkop-watchdog/status" },
		"depends": { "acl": [ "luci-app-podkop-watchdog" ] }
	}
}
EOF_MENU_WATCHDOG

cat >/usr/share/luci/menu.d/luci-app-podkop-auto-update.json <<'EOF_MENU_AUTOUPDATE'
{
	"admin/services/podkop-auto-update": {
		"title": "Podkop Auto Update",
		"order": 71,
		"action": { "type": "view", "path": "podkop-auto-update/status" },
		"depends": { "acl": [ "luci-app-podkop-auto-update" ] }
	}
}
EOF_MENU_AUTOUPDATE

cat >/usr/share/luci/menu.d/luci-app-podkop-updater.json <<'EOF_MENU_UPDATER'
{
	"admin/services/podkop-updater": {
		"title": "Podkop Updater TG",
		"order": 72,
		"action": { "type": "view", "path": "podkop-updater/status" },
		"depends": { "acl": [ "luci-app-podkop-updater" ] }
	}
}
EOF_MENU_UPDATER

cat >/usr/share/luci/menu.d/luci-app-tailscale-tools.json <<'EOF_MENU_TAILSCALE'
{
	"admin/vpn/tailscale-tools": {
		"title": "Tailscale",
		"order": 30,
		"action": { "type": "view", "path": "tailscale-tools/status" },
		"depends": { "acl": [ "luci-app-tailscale-tools" ] }
	}
}
EOF_MENU_TAILSCALE

cat >/usr/share/rpcd/acl.d/luci-app-podkop-watchdog.json <<'EOF_ACL_WATCHDOG'
{
	"luci-app-podkop-watchdog": {
		"description": "Podkop Watchdog",
		"read": {
			"cgi-io": [ "exec" ],
			"file": {
				"/root/podkop-watchdog.sh": [ "read" ],
				"/usr/libexec/podkop-watchdog-luci": [ "exec" ]
			},
			"ubus": { "file": [ "read", "exec" ] }
		},
		"write": {
			"cgi-io": [ "exec" ],
			"file": {
				"/root/podkop-watchdog.sh": [ "read", "write" ],
				"/usr/libexec/podkop-watchdog-luci": [ "exec" ]
			},
			"ubus": { "file": [ "read", "write", "exec" ] }
		}
	}
}
EOF_ACL_WATCHDOG

cat >/usr/share/rpcd/acl.d/luci-app-podkop-auto-update.json <<'EOF_ACL_AUTOUPDATE'
{
	"luci-app-podkop-auto-update": {
		"description": "Podkop Auto Update",
		"read": {
			"cgi-io": [ "exec" ],
			"file": {
				"/root/podkop-auto-update.sh": [ "read" ],
				"/usr/libexec/podkop-auto-update-luci": [ "exec" ]
			},
			"ubus": { "file": [ "read", "exec" ] }
		},
		"write": {
			"cgi-io": [ "exec" ],
			"file": {
				"/root/podkop-auto-update.sh": [ "read", "write" ],
				"/usr/libexec/podkop-auto-update-luci": [ "exec" ]
			},
			"ubus": { "file": [ "read", "write", "exec" ] }
		}
	}
}
EOF_ACL_AUTOUPDATE

cat >/usr/share/rpcd/acl.d/luci-app-podkop-updater.json <<'EOF_ACL_UPDATER'
{
	"luci-app-podkop-updater": {
		"description": "Podkop Updater TG",
		"read": {
			"cgi-io": [ "exec" ],
			"file": {
				"/etc/config/podkop_updater": [ "read" ],
				"/usr/libexec/podkop-updater-luci": [ "exec" ]
			},
			"ubus": { "file": [ "read", "exec" ] }
		},
		"write": {
			"cgi-io": [ "exec" ],
			"file": {
				"/etc/config/podkop_updater": [ "read", "write" ],
				"/usr/libexec/podkop-updater-luci": [ "exec" ]
			},
			"ubus": { "file": [ "read", "write", "exec" ] }
		}
	}
}
EOF_ACL_UPDATER

cat >/usr/share/rpcd/acl.d/luci-app-tailscale-tools.json <<'EOF_ACL_TAILSCALE'
{
	"luci-app-tailscale-tools": {
		"description": "Tailscale Tools",
		"read": {
			"cgi-io": [ "exec" ],
			"file": {
				"/usr/libexec/tailscale-tools-luci": [ "exec" ]
			},
			"ubus": { "file": [ "exec" ] }
		},
		"write": {
			"cgi-io": [ "exec" ],
			"file": {
				"/usr/libexec/tailscale-tools-luci": [ "exec" ]
			},
			"ubus": { "file": [ "exec" ] }
		}
	}
}
EOF_ACL_TAILSCALE

touch /etc/crontabs/root
grep -v '/root/podkop-watchdog.sh' /etc/crontabs/root >/tmp/podkop-tools-cron 2>/dev/null || true
echo '* * * * * /root/podkop-watchdog.sh' >> /tmp/podkop-tools-cron
cat /tmp/podkop-tools-cron > /etc/crontabs/root
grep -v '/root/podkop-auto-update.sh' /etc/crontabs/root >/tmp/podkop-tools-cron 2>/dev/null || true
echo '0 10 * * * /root/podkop-auto-update.sh' >> /tmp/podkop-tools-cron
cat /tmp/podkop-tools-cron > /etc/crontabs/root
rm -f /tmp/podkop-tools-cron

/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || true

/usr/libexec/podkop-updater-luci install >/tmp/podkop-updater-install.log 2>&1 || true

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
rm -rf /tmp/luci-* /tmp/luci-indexcache 2>/dev/null || true

echo "Installed files:"
ls -l /root/podkop-watchdog.sh /root/podkop-auto-update.sh /usr/libexec/podkop-watchdog-luci /usr/libexec/podkop-auto-update-luci /usr/libexec/podkop-updater-luci /usr/libexec/tailscale-tools-luci /etc/init.d/podkop_updater 2>/dev/null
ls -l /usr/bin/podkop_updater 2>/dev/null || true
echo "Cron:"
grep -E 'podkop-watchdog|podkop-auto-update' /etc/crontabs/root || true
echo "TG updater install log:"
tail -20 /tmp/podkop-updater-install.log 2>/dev/null || true
echo "LuCI:"
echo "  /cgi-bin/luci/admin/services/podkop-watchdog"
echo "  /cgi-bin/luci/admin/services/podkop-auto-update"
echo "  /cgi-bin/luci/admin/services/podkop-updater"
echo "  /cgi-bin/luci/admin/vpn/tailscale-tools"
echo "== Done =="
