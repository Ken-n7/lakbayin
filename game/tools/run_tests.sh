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
# The suites are offline by design but expect a server to be configured (the
# sign-in screens): a dead address, never the real one. The server has its
# own tests (server/tests).
export LAKBAYIN_SERVER_URL=https://offline.invalid
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
		grep -E '^\s*FAIL ' "$log" | head -5   # which checks, not just how many
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
run "world       " res://scripts/tests/world_test.tscn
run "match       " res://scripts/tests/match_test.tscn
run "e2e         " res://scripts/tests/e2e_test.tscn
run "touch       " res://scripts/tests/touch_test.tscn
run "devpanel    " res://scripts/tests/dev_panel_test.tscn
run "keyboard    " res://scripts/tests/keyboard_test.tscn
run "backdrop    " res://scripts/tests/backdrop_test.tscn
run "baybayin    " res://scripts/tests/baybayin_test.tscn
run "multiplayer " res://scripts/tests/multiplayer_test.tscn
run "layout      " res://tools/layout.tscn

[[ $fail -eq 0 ]] && echo "all suites green" || echo "SUITES FAILED"
exit $fail
