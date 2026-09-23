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
	timeout "$LIMIT" godot --headless --path . "$@" >"$log" 2>&1
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
run "collisions  " --script res://test_collisions.gd
run "smoke       " res://scripts/tests/smoke_test.tscn
run "e2e         " res://scripts/tests/e2e_test.tscn
run "touch       " res://scripts/tests/touch_test.tscn

[[ $fail -eq 0 ]] && echo "all suites green" || echo "SUITES FAILED"
exit $fail
