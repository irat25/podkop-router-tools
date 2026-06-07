#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

echo "== Podkop Watchdog standalone installer =="

mkdir -p \
	/usr/libexec \
	/usr/share/luci/menu.d \
	/usr/share/rpcd/acl.d \
	/www/luci-static/resources/view/podkop-watchdog

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
		logread 2>/dev/null | grep -E 'podkop|sing-box|dnsmasq' | tail -80 || true
	} >"$FAIL_LOG"
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

service_status() {
	if [ -x "/etc/init.d/$1" ]; then
		"/etc/init.d/$1" status 2>&1 || true
	else
		echo "not installed"
	fi
}

dns_status() {
	if nslookup ya.ru 127.0.0.42 >/dev/null 2>&1; then
		echo "ok / 127.0.0.42 / ya.ru"
	else
		echo "failed / 127.0.0.42 / ya.ru"
	fi
}

status_json() {
	en="$(enabled)"
	podkop="$(service_status podkop)"
	singbox="$(pgrep -f '[s]ing-box' >/dev/null 2>&1 && echo running || echo stopped)"
	dns="$(dns_status)"
	script_info="$(ls -l "$SCRIPT" 2>/dev/null || echo missing)"
	cron_line="$(grep podkop-watchdog "$CRON" 2>/dev/null || true)"
	logs="$(logread 2>/dev/null | grep podkop-watchdog | tail -80 || true)"
	failure="$([ -f /root/podkop-watchdog-last-failure.log ] && tail -120 /root/podkop-watchdog-last-failure.log || true)"
	printf '{'
	field enabled "$en"; printf ','
	field podkop "$podkop"; printf ','
	field singbox "$singbox"; printf ','
	field dns "$dns"; printf ','
	field script "$script_info"; printf ','
	field cron "$cron_line"; printf ','
	field logs "$logs"; printf ','
	field last_failure "$failure"
	printf '}\n'
}

enable_watchdog() {
	touch "$CRON"
	grep -v '/root/podkop-watchdog.sh' "$CRON" >/tmp/podkop-watchdog-cron 2>/dev/null || true
	echo "$CRON_LINE" >>/tmp/podkop-watchdog-cron
	cat /tmp/podkop-watchdog-cron >"$CRON"
	rm -f /tmp/podkop-watchdog-cron
	/etc/init.d/cron enable >/dev/null 2>&1 || true
	/etc/init.d/cron restart >/dev/null 2>&1 || true
	logger -t podkop-watchdog "cron enabled"
	echo "enabled"
}

disable_watchdog() {
	touch "$CRON"
	grep -v '/root/podkop-watchdog.sh' "$CRON" >/tmp/podkop-watchdog-cron 2>/dev/null || true
	cat /tmp/podkop-watchdog-cron >"$CRON"
	rm -f /tmp/podkop-watchdog-cron
	/etc/init.d/cron restart >/dev/null 2>&1 || true
	logger -t podkop-watchdog "cron disabled"
	echo "disabled"
}

case "${1:-status}" in
	status) status_json ;;
	enable) chmod +x "$SCRIPT"; enable_watchdog ;;
	disable) disable_watchdog ;;
	run) chmod +x "$SCRIPT"; "$SCRIPT" 2>&1 ;;
	chmod) chmod +x "$SCRIPT"; echo "ok" ;;
	*) echo "Usage: $0 status|enable|disable|run|chmod" >&2; exit 1 ;;
esac
EOF_WATCHDOG_LUCI
chmod +x /usr/libexec/podkop-watchdog-luci

cat >/www/luci-static/resources/view/podkop-watchdog/status.js <<'EOF_WATCHDOG_JS'
'use strict';
'require view';
'require fs';
'require ui';
'require poll';

var scriptPath = '/root/podkop-watchdog.sh';

function run(args) {
	return fs.exec('/usr/libexec/podkop-watchdog-luci', args);
}

function parse(res) {
	try {
		return JSON.parse((res && res.stdout) || '{}');
	} catch (e) {
		return {};
	}
}

function pre(text, maxHeight) {
	return E('pre', {
		'style': 'white-space:pre-wrap;max-height:' + (maxHeight || 260) + 'px;overflow:auto'
	}, text || '--');
}

function row(name, value) {
	return E('tr', {}, [
		E('td', { 'style': 'width:28%;font-weight:600' }, name),
		E('td', {}, value || '--')
	]);
}

function badge(d) {
	var enabled = d.enabled === true || d.enabled === 'true';
	var dnsOk = (d.dns || '').indexOf('ok') === 0;
	var singboxOk = d.singbox === 'running';
	var color = '#b58900';
	var text = 'Watchdog выключен или требует внимания';

	if (enabled && dnsOk && singboxOk) {
		color = '#238636';
		text = 'Watchdog включен и проверки проходят';
	} else if (!dnsOk || !singboxOk) {
		color = '#d14';
		text = 'Watchdog видит проблему';
	}

	return E('span', {
		'style': 'display:inline-block;padding:7px 10px;border-radius:4px;background:' + color + ';color:#fff;font-weight:700'
	}, text);
}

function notify(res) {
	ui.addNotification(null, pre(((res && res.stdout) || '') + ((res && res.stderr) ? '\n' + res.stderr : ''), 220), 'info');
}

return view.extend({
	load: function() {
		return Promise.all([
			L.resolveDefault(run([ 'status' ]), { stdout: '{}' }),
			L.resolveDefault(fs.read(scriptPath), '')
		]);
	},

	refresh: function(nodes) {
		return run([ 'status' ]).then(function(res) {
			var d = parse(res);
			nodes.badge.innerHTML = '';
			nodes.badge.appendChild(badge(d));
			nodes.summary.innerHTML = '';
			nodes.summary.appendChild(E('table', { 'class': 'table' }, [
				row('Cron', d.enabled === 'true' ? 'enabled' : 'disabled'),
				row('Podkop', d.podkop),
				row('sing-box', d.singbox),
				row('DNS Podkop', d.dns),
				row('Script', d.script),
				row('Cron line', d.cron)
			]));
			nodes.logs.innerHTML = '';
			nodes.logs.appendChild(pre(d.logs, 220));
			nodes.failure.innerHTML = '';
			nodes.failure.appendChild(pre(d.last_failure, 260));
		});
	},

	render: function(data) {
		var d = parse(data[0]);
		var code = E('textarea', {
			'style': 'width:100%;min-height:400px;font-family:monospace;white-space:pre'
		}, data[1] || '');
		var nodes = {
			badge: E('div', { 'style': 'margin:10px 0 12px 0' }),
			summary: E('div'),
			logs: E('div'),
			failure: E('div')
		};
		nodes.badge.appendChild(badge(d));
		nodes.summary.appendChild(E('table', { 'class': 'table' }, [
			row('Cron', d.enabled === 'true' ? 'enabled' : 'disabled'),
			row('Podkop', d.podkop),
			row('sing-box', d.singbox),
			row('DNS Podkop', d.dns),
			row('Script', d.script),
			row('Cron line', d.cron)
		]));

		poll.add(L.bind(this.refresh, this, nodes), 10);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Podkop Watchdog'),
			E('div', { 'class': 'cbi-map-descr' }, 'Контроль sing-box и DNS Podkop с аварийным отключением Podkop, если DNS не оживает.'),
			E('h3', {}, 'Статус'),
			nodes.badge,
			nodes.summary,
			E('div', { 'style': 'margin:18px 0;display:flex;gap:8px;flex-wrap:wrap' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() { return run([ 'enable' ]).then(notify).then(L.bind(this.refresh, this, nodes)); }) }, 'Включить cron'),
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, function() { return run([ 'disable' ]).then(notify).then(L.bind(this.refresh, this, nodes)); }) }, 'Выключить cron'),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() { return run([ 'run' ]).then(notify).then(L.bind(this.refresh, this, nodes)); }) }, 'Запустить сейчас')
			]),
			E('h3', {}, 'Код watchdog'),
			code,
			E('div', { 'style': 'margin:10px 0 18px 0' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, function() {
					return fs.write(scriptPath, code.value).then(function() {
						return run([ 'chmod' ]);
					}).then(function(res) {
						notify(res);
						ui.addNotification(null, E('p', {}, 'Код сохранен'), 'info');
					});
				}) }, 'Сохранить код')
			]),
			E('h3', {}, 'Лог'),
			nodes.logs,
			E('h3', {}, 'Последний аварийный снимок'),
			nodes.failure
		]);
	}
});
EOF_WATCHDOG_JS

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

touch /etc/crontabs/root
grep -v '/root/podkop-watchdog.sh' /etc/crontabs/root >/tmp/podkop-watchdog-cron 2>/dev/null || true
echo '* * * * * /root/podkop-watchdog.sh' >>/tmp/podkop-watchdog-cron
cat /tmp/podkop-watchdog-cron >/etc/crontabs/root
rm -f /tmp/podkop-watchdog-cron

/etc/init.d/cron enable >/dev/null 2>&1 || true
/etc/init.d/cron restart >/dev/null 2>&1 || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
rm -rf /tmp/luci-* /tmp/luci-indexcache 2>/dev/null || true

echo "Installed files:"
ls -l /root/podkop-watchdog.sh /usr/libexec/podkop-watchdog-luci 2>/dev/null || true
echo "Cron:"
grep podkop-watchdog /etc/crontabs/root 2>/dev/null || true
echo "LuCI:"
echo "  /cgi-bin/luci/admin/services/podkop-watchdog"
echo "== Done =="
