#!/usr/bin/env bash
# Every suite, one exit code. Run from the repo root:  tools/run_tests.sh
#
# Three things can go wrong and only one of them used to be caught:
#   - a check fails            -> the suite exits nonzero
#   - a SCRIPT ERROR mid-run   -> GDScript aborts the function and CARRIES ON,
#                                 so the suite can still exit 0. Grepped for.
#   - the run hangs            -> a dead coroutine never reaches its own exit,
#                                 and a headless Godot idles forever. Timed out.
set -u
cd "$(dirname "$0")/.." || exit 1          # the `game` directory
LIMIT=${TEST_TIMEOUT:-240}
fail=0

run() {                                     # run <name> <godot args...>
	local name=$1; shift
	local log; log=$(mktemp)
	local hl="--headless"; [[ ${1:-} == "--script" && $2 == *check_guards* ]] && hl=""
	timeout "$LIMIT" godot $hl --path . "$@" >"$log" 2>&1
	local code=$?
	local tail; tail=$(grep -E '^---- ' "$log" | tail -1)
	if [[ $code -eq 124 ]]; then
		echo "FAIL  $name -- timed out after ${LIMIT}s"; fail=1
	elif [[ $code -ne 0 ]]; then
		echo "FAIL  $name -- exit $code  ${tail}"; fail=1
	elif grep -q "SCRIPT ERROR" "$log"; then
		echo "FAIL  $name -- SCRIPT ERROR during the run"
		grep -A2 "SCRIPT ERROR" "$log" | head -6; fail=1
	else
		echo "ok    $name  ${tail}"
	fi
	rm -f "$log"
}

run "rules       " --script res://test_rules.gd
run "dial        " --script res://test_dial.gd
run "relay       " --script res://test_relay.gd
# The home relay's own script runs nowhere in the suites: a parse error there
# took the live relay down once (2026-10-09). This at least loads it.
run "relay tool  " --check-only --script res://tools/relay.gd
run "mathtext    " --script res://test_mathtext.gd
run "auth        " --script res://test_auth.gd
run "collisions  " --script res://test_collisions.gd
# The towers change per game (Terrain.tower_seed): a few games' boards too.
for s in 11 4242 90210 777777; do
	run "  seed $(printf '%-6s' $s)" --script res://test_collisions.gd -- $s
done
run "smoke       " res://scripts/tests/smoke_test.tscn
run "e2e         " res://scripts/tests/e2e_test.tscn
run "touch       " res://scripts/tests/touch_test.tscn
run "devpanel    " res://scripts/tests/dev_panel_test.tscn
run "rescue      " res://scripts/tests/rescue_test.tscn
run "alltime     " res://scripts/tests/alltime_test.tscn
run "keyboard    " res://scripts/tests/keyboard_test.tscn
run "backdrop    " res://scripts/tests/backdrop_test.tscn
run "tower       " res://scripts/tests/tower_test.tscn
run "netretry    " res://scripts/tests/net_retry_test.tscn
run "multiplayer " res://scripts/tests/multiplayer_test.tscn
run "layout      " res://tools/layout.tscn

# The two windowed tools need a GL context, so CI will skip them -- but they
# reach deep into AdventureScreen and nothing else exercises them, so run them
# wherever there is a display. map_shot's `_norm` call sat broken through a
# whole refactor because nothing did.
if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
	shots=$(mktemp -d)
	run "guards (GL) " --script res://tools/check_guards.gd
	timeout "$LIMIT" godot --path . --script res://tools/map_shot.gd -- "$shots" >/dev/null 2>&1 \
		&& echo "ok    shots (GL)   $(ls "$shots" | wc -l) written" \
		|| { echo "FAIL  shots (GL)  -- map_shot.gd"; fail=1; }
	rm -rf "$shots"
else
	echo "skip  GL tools -- no display"
fi

# The server's rules (supabase/schema.sql) on plain Postgres, wherever there is
# one to talk to: PGHOST / PGPORT / PGUSER pointing at a server that lets this
# user create databases. See supabase/test/run.sh.
if command -v psql >/dev/null && [[ -n "${PGHOST:-}" ]] && psql -X -q -c "select 1" >/dev/null 2>&1; then
	if out=$(../supabase/test/run.sh 2>&1); then
		echo "ok    server SQL   $(echo "$out" | grep -E '^---- ' | sed 's/^---- //;s/ ---- /: /;s/, 0 failures//' | paste -sd ';' | sed 's/;/;  /g')"
	else
		echo "FAIL  server SQL"; echo "$out" | grep -E "^FAIL" | head -8; fail=1
	fi
else
	echo "skip  server SQL -- no Postgres (set PGHOST, see supabase/test/run.sh)"
fi

[[ $fail -eq 0 ]] && echo "all suites green" || echo "SUITES FAILED"
exit $fail
