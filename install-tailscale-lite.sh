#!/bin/sh
set -eu

PATH=/usr/sbin:/usr/bin:/sbin:/bin

echo "== Tailscale Lite LuCI installer =="

mkdir -p \
	/usr/libexec \
	/usr/share/luci/menu.d \
	/usr/share/rpcd/acl.d \
	/www/luci-static/resources/view/tailscale-lite \
	/etc/tailscale

if ! command -v tailscaled >/dev/null 2>&1 || ! command -v tailscale >/dev/null 2>&1; then
	echo "tailscale is not installed, trying opkg install tailscale..."
	opkg update || true
	opkg install tailscale || true
fi

touch /etc/config/tailscale_lite
if ! uci -q get tailscale_lite.settings >/dev/null 2>&1; then
	uci -q batch <<'EOF_UCI'
set tailscale_lite.settings=settings
set tailscale_lite.settings.enabled='0'
set tailscale_lite.settings.login_server='https://controlplane.tailscale.com'
set tailscale_lite.settings.authkey=''
set tailscale_lite.settings.hostname=''
set tailscale_lite.settings.port='41641'
set tailscale_lite.settings.state_dir='/etc/tailscale'
set tailscale_lite.settings.accept_dns='0'
set tailscale_lite.settings.advertise_routes=''
commit tailscale_lite
EOF_UCI
fi

cat >/etc/init.d/tailscale-lite <<'EOF_INIT'
#!/bin/sh /etc/rc.common

START=90
STOP=10
USE_PROCD=1

start_service() {
	config_load tailscale_lite
	config_get port settings port '41641'
	config_get state_dir settings state_dir '/etc/tailscale'

	mkdir -p "$state_dir"
	procd_open_instance
	procd_set_param command /usr/sbin/tailscaled --no-logs-no-support --port "$port" --state "$state_dir/tailscaled.state"
	procd_set_param env TS_DEBUG_FIREWALL_MODE=nftables
	procd_set_param env TS_NO_LOGS_NO_SUPPORT=true
	procd_set_param respawn 3600 5 5
	procd_close_instance
}
EOF_INIT
chmod +x /etc/init.d/tailscale-lite

cat >/usr/libexec/tailscale-lite-luci <<'EOF_HELPER'
#!/bin/sh

CONFIG="tailscale_lite"
OFFICIAL_INIT="/etc/init.d/tailscale"
FALLBACK_INIT="/etc/init.d/tailscale-lite"

json_escape() {
	tr -d '\033' | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g; s/$/\\n/' | tr -d '\n'
}

field() {
	printf '"%s":"%s"' "$1" "$(printf '%s' "$2" | json_escape)"
}

get() {
	uci -q get "$CONFIG.settings.$1" 2>/dev/null || true
}

set_opt() {
	uci -q set "$CONFIG.settings.$1=$2"
}

init_script() {
	if [ -x "$OFFICIAL_INIT" ]; then
		echo "$OFFICIAL_INIT"
	else
		echo "$FALLBACK_INIT"
	fi
}

authkey_state() {
	[ -n "$(get authkey)" ] && echo "set" || echo "not set"
}

daemon_status() {
	init="$(init_script)"
	"$init" status 2>&1 || true
}

autostart_status() {
	init="$(init_script)"
	"$init" enabled >/dev/null 2>&1 && echo enabled || echo disabled
}

tailscale_ips() {
	tailscale ip 2>&1 || true
}

tailscale_status() {
	tailscale status --peers=false 2>&1 | head -80 || true
}

status_json() {
	enabled="$(get enabled)"
	server="$(get login_server)"
	hostname="$(get hostname)"
	port="$(get port)"
	state_dir="$(get state_dir)"
	accept_dns="$(get accept_dns)"
	advertise_routes="$(get advertise_routes)"
	version="$(tailscale version 2>&1 | head -3 || true)"
	pid="$(pidof tailscaled 2>/dev/null | tr '\n' ' ' || true)"
	ips="$(tailscale_ips)"
	ts_status="$(tailscale_status)"
	logs="$(logread 2>/dev/null | grep -Ei 'tailscale|tailscaled|tailscale-lite' | tail -80 || true)"
	printf '{'
	field enabled "$enabled"; printf ','
	field service "$(daemon_status)"; printf ','
	field autostart "$(autostart_status)"; printf ','
	field pid "$pid"; printf ','
	field ips "$ips"; printf ','
	field status "$ts_status"; printf ','
	field version "$version"; printf ','
	field login_server "$server"; printf ','
	field hostname "$hostname"; printf ','
	field port "$port"; printf ','
	field state_dir "$state_dir"; printf ','
	field accept_dns "$accept_dns"; printf ','
	field advertise_routes "$advertise_routes"; printf ','
	field authkey "$(authkey_state)"; printf ','
	field init "$(init_script)"; printf ','
	field logs "$logs"
	printf '}\n'
}

save_config() {
	set_opt enabled "${1:-0}"
	set_opt login_server "${2:-}"
	[ -n "${3:-}" ] && set_opt authkey "$3"
	set_opt hostname "${4:-}"
	set_opt port "${5:-41641}"
	set_opt state_dir "${6:-/etc/tailscale}"
	set_opt accept_dns "${7:-0}"
	set_opt advertise_routes "${8:-}"
	uci commit "$CONFIG"
	echo "saved"
}

daemon_start() {
	init="$(init_script)"
	mkdir -p "$(get state_dir)"
	"$init" start 2>&1 || true
	sleep 2
}

daemon_stop() {
	tailscale down 2>&1 || true
	init="$(init_script)"
	"$init" stop 2>&1 || true
}

tailscale_up() {
	server="$(get login_server)"
	key="$(get authkey)"
	hostname="$(get hostname)"
	accept_dns="$(get accept_dns)"
	advertise_routes="$(get advertise_routes)"

	daemon_start

	args="--accept-dns=false"
	[ "$accept_dns" = "1" ] && args="--accept-dns=true"
	[ -n "$server" ] && args="$args --login-server=$server"
	[ -n "$hostname" ] && args="$args --hostname=$hostname"
	[ -n "$advertise_routes" ] && args="$args --advertise-routes=$advertise_routes"
	[ -n "$key" ] && args="$args --authkey=$key"

	# shellcheck disable=SC2086
	tailscale up $args 2>&1 || true
}

case "${1:-status}" in
	status) status_json ;;
	save) shift; save_config "$@" ;;
	start) uci set "$CONFIG.settings.enabled=1"; uci commit "$CONFIG"; tailscale_up ;;
	stop) uci set "$CONFIG.settings.enabled=0"; uci commit "$CONFIG"; daemon_stop ;;
	restart) daemon_stop; sleep 2; tailscale_up ;;
	enable) init="$(init_script)"; "$init" enable 2>&1 || true; uci set "$CONFIG.settings.enabled=1"; uci commit "$CONFIG"; echo enabled ;;
	disable) init="$(init_script)"; "$init" disable 2>&1 || true; uci set "$CONFIG.settings.enabled=0"; uci commit "$CONFIG"; echo disabled ;;
	logout) tailscale logout 2>&1 || true ;;
	cleanup) tailscaled --cleanup 2>&1 || true ;;
	*) echo "Usage: $0 status|save|start|stop|restart|enable|disable|logout|cleanup" >&2; exit 1 ;;
esac
EOF_HELPER
chmod +x /usr/libexec/tailscale-lite-luci

cat >/www/luci-static/resources/view/tailscale-lite/settings.js <<'EOF_JS'
'use strict';
'require view';
'require fs';
'require ui';
'require poll';

var helperPath = '/usr/libexec/tailscale-lite-luci';

function run(args) {
	return fs.exec(helperPath, args);
}

function clean(value) {
	return String(value || '').replace(/\s+$/g, '');
}

function parse(res) {
	try {
		return JSON.parse((res && res.stdout) || '{}');
	} catch (e) {
		return { service: 'parse error', logs: ((res && res.stdout) || '') + ((res && res.stderr) ? '\n' + res.stderr : '') };
	}
}

function row(name, value) {
	return E('tr', {}, [
		E('td', { 'style': 'width:24%;padding:2px 0' }, name),
		E('td', { 'style': 'padding:2px 0' }, clean(value) || '--')
	]);
}

function pre(text) {
	return E('pre', { 'style': 'white-space:pre-wrap;max-height:300px;overflow:auto' }, clean(text) || '--');
}

function notify(res) {
	ui.addNotification(null, pre(((res && res.stdout) || '') + ((res && res.stderr) ? '\n' + res.stderr : '')), 'info');
}

function field(label, input) {
	return E('div', { 'style': 'margin:8px 0;display:flex;gap:12px;align-items:center;max-width:760px' }, [
		E('label', { 'style': 'width:180px' }, label),
		input
	]);
}

function input(value, placeholder, password) {
	return E('input', {
		'class': 'cbi-input-text',
		'type': password ? 'password' : 'text',
		'value': clean(value),
		'placeholder': placeholder || '',
		'style': 'flex:1'
	});
}

return view.extend({
	load: function() {
		return L.resolveDefault(run([ 'status' ]), { stdout: '{}' });
	},

	refresh: function(nodes) {
		return L.resolveDefault(run([ 'status' ]), { stdout: '{}' }).then(function(res) {
			var d = parse(res);
			nodes.summary.innerHTML = '';
			nodes.summary.appendChild(E('table', { 'class': 'table' }, [
				row('Service', d.service),
				row('Autostart', d.autostart),
				row('PID', d.pid),
				row('Tailscale IP', d.ips),
				row('Auth key', d.authkey),
				row('Login server', d.login_server),
				row('Init script', d.init),
				row('Version', d.version)
			]));
			nodes.status.innerHTML = '';
			nodes.status.appendChild(pre(d.status));
			nodes.logs.innerHTML = '';
			nodes.logs.appendChild(pre(d.logs));
		});
	},

	render: function(res) {
		var d = parse(res);
		var nodes = {
			summary: E('div'),
			status: E('div'),
			logs: E('div')
		};

		var enabled = E('input', { 'type': 'checkbox' });
		enabled.checked = clean(d.enabled) === '1';
		var server = input(d.login_server || 'https://controlplane.tailscale.com', 'https://controlplane.tailscale.com');
		var key = input('', 'paste new auth key here', true);
		var hostname = input(d.hostname, 'optional device name');
		var port = input(d.port || '41641', '41641');
		var stateDir = input(d.state_dir || '/etc/tailscale', '/etc/tailscale');
		var acceptDns = E('input', { 'type': 'checkbox' });
		acceptDns.checked = clean(d.accept_dns) === '1';
		var routes = input(d.advertise_routes, '192.168.1.0/24, optional');

		nodes.summary.appendChild(E('table', { 'class': 'table' }, [
			row('Service', d.service),
			row('Autostart', d.autostart),
			row('PID', d.pid),
			row('Tailscale IP', d.ips),
			row('Auth key', d.authkey),
			row('Login server', d.login_server),
			row('Init script', d.init),
			row('Version', d.version)
		]));
		nodes.status.appendChild(pre(d.status));
		nodes.logs.appendChild(pre(d.logs));

		poll.add(L.bind(this.refresh, this, nodes), 10);

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, 'Tailscale Lite'),
			E('div', { 'class': 'cbi-map-descr' }, 'Minimal LuCI control for Tailscale/headscale. The stored auth key is never displayed; enter a new key only when you want to change it.'),
			nodes.summary,
			E('h3', {}, 'Settings'),
			field('Enable wanted', enabled),
			field('Login server', server),
			field('New auth key', key),
			field('Device name', hostname),
			field('Port', port),
			field('State directory', stateDir),
			field('Accept DNS', acceptDns),
			field('Advertise routes', routes),
			E('div', { 'style': 'margin:18px 0;display:flex;gap:8px;flex-wrap:wrap' }, [
				E('button', { 'class': 'btn cbi-button cbi-button-save', 'click': ui.createHandlerFn(this, function() {
					return run([ 'save', enabled.checked ? '1' : '0', server.value, key.value, hostname.value, port.value, stateDir.value, acceptDns.checked ? '1' : '0', routes.value ])
						.then(function(res) { key.value = ''; notify(res); })
						.then(L.bind(this.refresh, this, nodes));
				}) }, 'Save settings'),
				E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
					return run([ 'save', enabled.checked ? '1' : '0', server.value, key.value, hostname.value, port.value, stateDir.value, acceptDns.checked ? '1' : '0', routes.value ])
						.then(function() { key.value = ''; return run([ 'start' ]); })
						.then(notify)
						.then(L.bind(this.refresh, this, nodes));
				}) }, 'Save and start'),
				E('button', { 'class': 'btn cbi-button cbi-button-negative', 'click': ui.createHandlerFn(this, function() {
					return run([ 'stop' ]).then(notify).then(L.bind(this.refresh, this, nodes));
				}) }, 'Stop'),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() {
					return run([ 'restart' ]).then(notify).then(L.bind(this.refresh, this, nodes));
				}) }, 'Restart'),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() {
					return run([ 'enable' ]).then(notify).then(L.bind(this.refresh, this, nodes));
				}) }, 'Enable autostart'),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() {
					return run([ 'disable' ]).then(notify).then(L.bind(this.refresh, this, nodes));
				}) }, 'Disable autostart'),
				E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() {
					return run([ 'logout' ]).then(notify).then(L.bind(this.refresh, this, nodes));
				}) }, 'Logout')
			]),
			E('h3', {}, 'Tailscale status'),
			nodes.status,
			E('h3', {}, 'Log'),
			nodes.logs
		]);
	}
});
EOF_JS

cat >/usr/share/luci/menu.d/luci-app-tailscale-lite.json <<'EOF_MENU'
{
	"admin/vpn/tailscale-lite": {
		"title": "Tailscale Lite",
		"order": 62,
		"action": { "type": "view", "path": "tailscale-lite/settings" },
		"depends": { "acl": [ "luci-app-tailscale-lite" ] }
	}
}
EOF_MENU

cat >/usr/share/rpcd/acl.d/luci-app-tailscale-lite.json <<'EOF_ACL'
{
	"luci-app-tailscale-lite": {
		"description": "Tailscale Lite",
		"read": {
			"cgi-io": [ "exec" ],
			"file": { "/usr/libexec/tailscale-lite-luci": [ "exec" ] },
			"ubus": { "file": [ "exec" ], "uci": [ "get" ] },
			"uci": [ "tailscale_lite" ]
		},
		"write": {
			"cgi-io": [ "exec" ],
			"file": { "/usr/libexec/tailscale-lite-luci": [ "exec" ] },
			"ubus": { "file": [ "exec" ], "uci": [ "get", "set", "commit" ] },
			"uci": [ "tailscale_lite" ]
		}
	}
}
EOF_ACL

/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
rm -rf /tmp/luci-* /tmp/luci-indexcache 2>/dev/null || true

echo "Installed files:"
ls -l /usr/libexec/tailscale-lite-luci /etc/init.d/tailscale-lite /www/luci-static/resources/view/tailscale-lite/settings.js 2>/dev/null || true
echo "LuCI:"
echo "  /cgi-bin/luci/admin/vpn/tailscale-lite"
echo "== Done =="
