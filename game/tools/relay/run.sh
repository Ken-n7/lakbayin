#!/usr/bin/env bash
# The movement relay at home: the relay (tools/relay.gd) behind a Cloudflare
# quick tunnel, kept running. The tunnel's address changes on every start;
# the relay publishes each new one to Supabase, where phones look it up.
#
#   game/tools/relay/run.sh            # Ctrl-C (or the systemd unit) stops it
#
# Needs: cloudflared on the PATH (or CLOUDFLARED=/path), and an admin account
# in ~/.config/numxventure/relay.env (RELAY_ENV to move it):
#   NUMX_RELAY_EMAIL=...
#   NUMX_RELAY_PASSWORD=...
# RELAY_HZ sets the snapshots a second (default 20).
set -u
cd "$(dirname "$0")/../.." || exit 1          # the `game` directory
CF=${CLOUDFLARED:-cloudflared}
HZ=${RELAY_HZ:-20}
ENV_FILE=${RELAY_ENV:-$HOME/.config/numxventure/relay.env}
LOG=${RELAY_LOG:-${XDG_STATE_HOME:-$HOME/.local/state}/numxventure-relay}
[ -f "$ENV_FILE" ] || { echo "no $ENV_FILE -- see the top of $0"; exit 1; }
command -v "$CF" >/dev/null || { echo "no cloudflared -- install it or set CLOUDFLARED"; exit 1; }
set -a; . "$ENV_FILE"; set +a
mkdir -p "$LOG"

stop() {
	kill $(jobs -p) 2>/dev/null
	wait 2>/dev/null
	godot --headless --path . --script res://tools/relay.gd -- --unpublish >> "$LOG/relay.log" 2>&1
	exit 0
}
trap stop INT TERM

while true; do
	"$CF" tunnel --no-autoupdate --url http://127.0.0.1:47317 > "$LOG/tunnel.log" 2>&1 &
	cf=$!
	url=""
	for _ in $(seq 1 30); do
		url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG/tunnel.log" | head -1)
		[ -n "$url" ] && break
		sleep 1
	done
	if [ -z "$url" ]; then
		echo "$(date '+%F %T') tunnel did not start; again in 10s"
		kill $cf 2>/dev/null; sleep 10; continue
	fi
	echo "$(date '+%F %T') relay at ${url/https:/wss:}"
	godot --headless --path . --script res://tools/relay.gd -- --hz "$HZ" --url "${url/https:/wss:}" >> "$LOG/relay.log" 2>&1 &
	relay=$!
	wait -n $cf $relay                  # whichever stops first takes the other with it
	kill $cf $relay 2>/dev/null
	wait 2>/dev/null
	echo "$(date '+%F %T') stopped; restarting in 3s"
	sleep 3
done
