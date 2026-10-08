#!/usr/bin/env bash
# The movement relay at home: the relay (tools/relay.gd) behind a free
# tunnel, kept running. A tunnel's address changes on every start; the relay
# publishes each new one to Supabase, where phones look it up -- a phone that
# loses the old address reads the new one on its next retry.
#
#   game/tools/relay/run.sh            # Ctrl-C (or the systemd unit) stops it
#
# Kept running, piece by piece:
#   - the relay stops: only the relay restarts, same address, nobody moves;
#   - the tunnel stops: a new tunnel, a new address, the relay republishes;
#   - the tunnel runs but its address stops answering: after PROBE_FAILS
#     failed checks PROBE_S apart, it is replaced as if it had stopped.
#
# Two tunnel services, Cloudflare first. Its free tunnels carry no uptime
# promise, so when CF_BAD_MAX Cloudflare tunnels in a row will not start or
# will not reach the relay, Pinggy stands in (free: an hour a tunnel, renewed
# like any stopped tunnel; its address carries this connection's public IP).
# While on Pinggy, a fresh Cloudflare tunnel is tried every CF_RETRY_S and
# taken back once it reaches the relay. Phones need nothing: they follow the
# published address. With no tunnel at all they move through the teacher's
# hub, as before the relay.
#
# Needs: cloudflared on the PATH (or CLOUDFLARED=/path), ssh (for Pinggy),
# and an admin account in ~/.config/numxventure/relay.env (RELAY_ENV to move it):
#   NUMX_RELAY_EMAIL=...
#   NUMX_RELAY_PASSWORD=...
# RELAY_HZ sets the snapshots a second (default 20).
set -u
cd "$(dirname "$0")/../.." || exit 1          # the `game` directory
CF=${CLOUDFLARED:-cloudflared}
HZ=${RELAY_HZ:-20}
ENV_FILE=${RELAY_ENV:-$HOME/.config/numxventure/relay.env}
LOG=${RELAY_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/numxventure-relay}
PROBE_S=${PROBE_S:-30}
PROBE_FAILS=${PROBE_FAILS:-3}
CF_BAD_MAX=${CF_BAD_MAX:-2}
CF_RETRY_S=${CF_RETRY_S:-600}
PORT=47317
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE -- see the top of $0"; exit 1; }
command -v "$CF" >/dev/null || { echo "no cloudflared -- install it or set CLOUDFLARED"; exit 1; }
set -a; . "$ENV_FILE"; set +a
mkdir -p "$LOG"

tun=""        # the tunnel's process
url=""        # its public address (https://...)
via=""        # cloudflare | pinggy
relay=""
cf_bad=0      # Cloudflare tunnels in a row that would not start or not reach the relay
cf_tried=0    # when Cloudflare was last tried, while on Pinggy

say() { echo "$(date '+%F %T') $*"; }
now() { date +%s; }

stop() {
	kill $tun $relay 2>/dev/null
	wait 2>/dev/null
	godot --headless --path . --script res://tools/relay.gd -- --unpublish >> "$LOG/relay.log" 2>&1
	exit 0
}
trap stop INT TERM

# Waits up to 30s for a tunnel's address in its log; prints it, or nothing.
address_in() {
	local log=$1 pattern=$2 got
	for _ in $(seq 1 30); do
		got=$(grep -o -E "$pattern" "$log" 2>/dev/null | head -1)
		[ -n "$got" ] && { echo "$got"; return; }
		sleep 1
	done
}

# A Cloudflare tunnel: sets $1_pid and $1_url (empty if none came).
cloudflare() {
	"$CF" tunnel --no-autoupdate --url "http://127.0.0.1:$PORT" > "$LOG/tunnel-$1.log" 2>&1 &
	local pid=$!
	local got
	got=$(address_in "$LOG/tunnel-$1.log" 'https://[a-z0-9-]+\.trycloudflare\.com')
	[ -z "$got" ] && { kill $pid 2>/dev/null; pid=""; }
	printf -v "$1_pid" '%s' "$pid"
	printf -v "$1_url" '%s' "$got"
}

pinggy() {
	ssh -T -p 443 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$LOG/pinggy_known_hosts" \
		-o ServerAliveInterval=30 -o ExitOnForwardFailure=yes -R0:127.0.0.1:$PORT a.pinggy.io \
		> "$LOG/tunnel-pinggy.log" 2>&1 &
	local pid=$!
	local got
	got=$(address_in "$LOG/tunnel-pinggy.log" 'https://[a-z0-9-]+\.run\.pinggy-free\.link')
	[ -z "$got" ] && { kill $pid 2>/dev/null; pid=""; }
	pg_pid=$pid
	pg_url=$got
}

# Does an address reach the relay? A WebSocket handshake over HTTP/1.1
# (HTTP/2 to Cloudflare does not carry one, and gets 502) answers 101 when
# it does; a gone tunnel does not resolve at all.
answers() {
	[ "$(curl --http1.1 -s -o /dev/null -w '%{http_code}' --max-time 8 \
		-H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' \
		-H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$1/")" = "101" ]
}

# A tunnel to put the relay behind: Cloudflare unless it has failed
# CF_BAD_MAX times running, then Pinggy.
start_tunnel() {
	tun=""; url=""; via=""
	if [ "$cf_bad" -lt "$CF_BAD_MAX" ]; then
		cloudflare main
		if [ -n "$main_pid" ]; then
			tun=$main_pid; url=$main_url; via=cloudflare
			return
		fi
		cf_bad=$((cf_bad + 1))
		say "cloudflare tunnel did not start ($cf_bad of $CF_BAD_MAX)"
		[ "$cf_bad" -lt "$CF_BAD_MAX" ] && return
	fi
	pinggy
	if [ -n "$pg_pid" ]; then
		tun=$pg_pid; url=$pg_url; via=pinggy
		cf_tried=$(now)
	fi
}

start_relay() {
	godot --headless --path . --script res://tools/relay.gd -- --hz "$HZ" --url "${url/https:/wss:}" >> "$LOG/relay.log" 2>&1 &
	relay=$!
}

# The relay behind a different tunnel: a new address, so a new relay (it
# publishes the address it was started with).
switch_to() {
	local old=$tun
	tun=$1; url=$2; via=$3
	kill $old 2>/dev/null; sleep 1; kill -9 $old 2>/dev/null; wait $old 2>/dev/null
	kill $relay 2>/dev/null; wait $relay 2>/dev/null
	say "relay at ${url/https:/wss:} (via $via)"
	start_relay
}

fails=0
since_probe=0
while true; do
	if [ -z "$tun" ] || ! kill -0 "$tun" 2>/dev/null; then
		[ -n "$tun" ] && say "tunnel stopped ($via)"
		kill $relay 2>/dev/null; wait $relay 2>/dev/null; relay=""
		start_tunnel
		if [ -z "$tun" ]; then
			say "no tunnel; phones use the teacher's hub. Again in 10s"
			sleep 10
			continue
		fi
		say "relay at ${url/https:/wss:} (via $via)"
		start_relay
		fails=0
		since_probe=0
	elif ! kill -0 "$relay" 2>/dev/null; then
		say "relay stopped; restarting it on the same address"
		start_relay
	fi
	sleep 5
	since_probe=$((since_probe + 5))
	if [ "$since_probe" -ge "$PROBE_S" ]; then
		since_probe=0
		if answers "$url"; then
			fails=0
			[ "$via" = cloudflare ] && cf_bad=0
		else
			fails=$((fails + 1))
			say "address did not answer ($fails of $PROBE_FAILS, $via)"
			if [ "$fails" -ge "$PROBE_FAILS" ]; then
				if [ "$via" = cloudflare ]; then
					cf_bad=$((cf_bad + 1))
					say "cloudflare tunnel dead ($cf_bad of $CF_BAD_MAX)"
				fi
				say "replacing the tunnel"
				# A hung tunnel may not take a polite kill: then a hard one.
				kill $tun 2>/dev/null; sleep 2; kill -9 $tun 2>/dev/null; wait $tun 2>/dev/null
			fi
		fi
	fi
	# On Pinggy: is Cloudflare back? A fresh tunnel has to reach the relay
	# before anything moves to it.
	if [ "$via" = pinggy ] && [ $(( $(now) - cf_tried )) -ge "$CF_RETRY_S" ]; then
		cf_tried=$(now)
		cloudflare retry
		if [ -n "$retry_pid" ] && sleep 3 && answers "$retry_url"; then
			say "cloudflare is back"
			cf_bad=0
			switch_to "$retry_pid" "$retry_url" cloudflare
			fails=0
			since_probe=0
		else
			[ -n "$retry_pid" ] && kill $retry_pid 2>/dev/null
			say "cloudflare still out; staying on pinggy"
		fi
	fi
done
