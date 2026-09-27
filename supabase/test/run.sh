#!/usr/bin/env bash
# The server's rules, on plain Postgres -- no Supabase project needed.
#
#   PGHOST=... PGPORT=... PGUSER=postgres supabase/test/run.sh
#
# Makes a throwaway database, loads stubs.sql (the few things a Supabase
# project provides) and schema.sql, and runs the tests. Checks, in order:
#   - schema.sql loads on a fresh project, and loads AGAIN over itself -- it is
#     re-run in the SQL Editor after every change;
#   - it upgrades a project that still has the previous schema (git HEAD);
#   - rescue_test.sql, leaderboard_test.sql;
#   - two teammates rescuing each other at the same moment, from two real
#     connections: both go through, no deadlock.
set -u
cd "$(dirname "$0")/../.." || exit 1          # the repo root
DB=nx_test_$$
fail=0
q() { psql -X -q -v ON_ERROR_STOP=1 -d "$DB" "$@"; }

fresh() {
	psql -X -q -c "drop database if exists $DB;" -c "create database $DB;" >/dev/null || exit 1
	q -f supabase/test/stubs.sql >/dev/null 2>&1 || { echo "FAIL  stubs"; exit 1; }
}

fresh
if q -f supabase/schema.sql >/dev/null 2>&1 && q -f supabase/schema.sql >/dev/null 2>&1; then
	echo "ok    schema.sql loads, and re-runs over itself"
else
	echo "FAIL  schema.sql does not load (or re-run)"; q -f supabase/schema.sql 2>&1 | grep -m3 ERROR; fail=1
fi

if git cat-file -e HEAD:supabase/schema.sql 2>/dev/null; then
	fresh
	if git show HEAD:supabase/schema.sql | q >/dev/null 2>&1 && q -f supabase/schema.sql >/dev/null 2>&1; then
		echo "ok    schema.sql upgrades the committed one (HEAD)"
	else
		echo "FAIL  schema.sql does not upgrade HEAD's"; fail=1
	fi
fi

fresh
q -f supabase/schema.sql >/dev/null 2>&1
out=$(q -t -A -f supabase/test/rescue_test.sql 2>&1)
echo "$out" | grep -E "^(ok|FAIL)" | sed 's/^ok  /ok   /'
echo "$out" | grep -q -- "---- RESCUE SQL PASS" || fail=1
echo "$out" | grep -- "^---- " || { echo "$out" | tail -5; fail=1; }

fresh
q -f supabase/schema.sql >/dev/null 2>&1
out=$(q -t -A -f supabase/test/leaderboard_test.sql 2>&1)
echo "$out" | grep -E "^(ok|FAIL)" | sed 's/^ok  /ok   /'
echo "$out" | grep -q -- "---- LEADERBOARD SQL PASS" || fail=1
echo "$out" | grep -- "^---- " || { echo "$out" | tail -5; fail=1; }

# Two teammates, each rescuing the other, at the same moment: each holds its
# transaction open for a second after the call, so the other's lands mid-way.
fresh
q -f supabase/schema.sql >/dev/null 2>&1
q -f supabase/test/race_setup.sql >/dev/null 2>&1 || { echo "FAIL  race setup"; fail=1; }
race() {   # race <from> <to>
	psql -X -q -t -A -d "$DB" -c "begin;
		select set_config('request.jwt.claim.sub', '$1', true);
		set local role authenticated;
		select gems from public.rescue('33333333-3333-3333-3333-333333333333', '$2', 10);
		select pg_sleep(1);
		commit;" 2>&1
}
A=00000000-0000-0000-0000-00000000aaa1; B=00000000-0000-0000-0000-00000000bbb1
race $A $B > /tmp/nx_race_a.$$ & race $B $A > /tmp/nx_race_b.$$ & wait
if grep -qi "deadlock\|error" /tmp/nx_race_a.$$ /tmp/nx_race_b.$$; then
	echo "FAIL  two teammates rescuing each other at once"; cat /tmp/nx_race_a.$$ /tmp/nx_race_b.$$; fail=1
else
	both=$(q -t -A -c "select string_agg(gems::text, ',' order by profile_id) from public.members
		where session_id = '33333333-3333-3333-3333-333333333333'")
	if [[ $both == "50,50" ]]; then
		echo "ok    two teammates rescuing each other at once: both go through, gems 50/50"
	else
		echo "FAIL  race left gems at $both (want 50,50)"; fail=1
	fi
fi
rm -f /tmp/nx_race_a.$$ /tmp/nx_race_b.$$

psql -X -q -c "drop database if exists $DB;" >/dev/null
[[ $fail -eq 0 ]] && echo "server rules green" || echo "SERVER RULES FAILED"
exit $fail
