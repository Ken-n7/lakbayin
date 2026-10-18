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
#   - rescue_test.sql, leaderboard_test.sql, scoring_test.sql,
#     isolation_test.sql, relay_test.sql;
#   - two relays taking the free relay row at the same moment: exactly one does;
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

fresh
q -f supabase/schema.sql >/dev/null 2>&1
out=$(q -t -A -f supabase/test/scoring_test.sql 2>&1)
echo "$out" | grep -E "^(ok|FAIL)" | sed 's/^ok  /ok   /'
echo "$out" | grep -q -- "---- SCORING SQL PASS" || fail=1
echo "$out" | grep -- "^---- " || { echo "$out" | tail -5; fail=1; }

fresh
q -f supabase/schema.sql >/dev/null 2>&1
out=$(q -t -A -f supabase/test/isolation_test.sql 2>&1)
echo "$out" | grep -E "^(ok|FAIL)" | sed 's/^ok  /ok   /'
echo "$out" | grep -q -- "---- ISOLATION SQL PASS" || fail=1
echo "$out" | grep -- "^---- " || { echo "$out" | tail -5; fail=1; }

fresh
q -f supabase/schema.sql >/dev/null 2>&1
out=$(q -t -A -f supabase/test/relay_test.sql 2>&1)
echo "$out" | grep -E "^(ok|FAIL)" | sed 's/^ok  /ok   /'
echo "$out" | grep -q -- "---- RELAY SQL PASS" || fail=1
echo "$out" | grep -- "^---- " || { echo "$out" | tail -5; fail=1; }

fresh
q -f supabase/schema.sql >/dev/null 2>&1
out=$(q -t -A -f supabase/test/multiplayer_test.sql 2>&1)
echo "$out" | grep -E "^(ok|FAIL)" | sed 's/^ok  /ok   /'
echo "$out" | grep -q -- "---- MULTIPLAYER SQL PASS" || fail=1
echo "$out" | grep -- "^---- " || { echo "$out" | tail -5; fail=1; }

# Leave a clean schema for the relay race's fixed fixture IDs.
fresh
q -f supabase/schema.sql >/dev/null 2>&1
# Two relays taking the free row at the same moment, from two connections:
# exactly one gets it -- a class is never split between two relays.
q -c "insert into auth.users (id, email, raw_user_meta_data) values
	('00000000-0000-0000-0000-0000000000a0', 'h@t.dev', '{\"username\":\"home\",\"role\":\"admin\"}'),
	('00000000-0000-0000-0000-0000000000b0', 't@t.dev', '{\"username\":\"teacher\",\"role\":\"admin\"}')
	on conflict do nothing; update public.relay set url = null;" >/dev/null 2>&1
claim() {   # claim <user> <owner>
	psql -X -q -t -A -d "$DB" -c "begin;
		select set_config('request.jwt.claim.sub', '$1', true);
		set local role authenticated;
		select public.claim_relay('$2', 'wss://$2', 20);
		select pg_sleep(1);
		commit;" 2>&1 | grep -E '^(t|f)$|ERROR'
}
claim 00000000-0000-0000-0000-0000000000a0 home > /tmp/nx_relay_a.$$ &
claim 00000000-0000-0000-0000-0000000000b0 backup > /tmp/nx_relay_b.$$ & wait
won=$(cat /tmp/nx_relay_a.$$ /tmp/nx_relay_b.$$ | sort | tr '\n' ' ')
if [[ $won == "f t " ]]; then
	echo "ok    two relays taking the free row at once: exactly one gets it"
else
	echo "FAIL  two relays at once gave: $won"; fail=1
fi
rm -f /tmp/nx_relay_a.$$ /tmp/nx_relay_b.$$

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

# Finishing players and score retries serialize on the session before touching
# members. Hold transactions open to force the second connection to overlap.
fresh
q -f supabase/schema.sql >/dev/null 2>&1
q -f supabase/test/race_setup.sql >/dev/null 2>&1
q -c "update public.members set items_done=14,stations_done=3,gems=220;" >/dev/null
finish_race() {
	psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" -c "begin;
		select set_config('request.jwt.claim.sub', '$1', true);
		set local role authenticated;
		select finished from public.finish_run('33333333-3333-3333-3333-333333333333');
		select pg_sleep(1); commit;" > "$2" 2>&1
}
finish_race "$A" /tmp/nx_finish_a.$$ & finish_race "$B" /tmp/nx_finish_b.$$ & wait
state=$(q -t -A -c "select state from public.sessions where id='33333333-3333-3333-3333-333333333333'")
if [[ $state == ended ]] && ! grep -qi 'error' /tmp/nx_finish_a.$$ /tmp/nx_finish_b.$$; then
	echo "ok    simultaneous final players end the session"
else
	echo "FAIL  simultaneous final players left state=$state"; cat /tmp/nx_finish_a.$$ /tmp/nx_finish_b.$$; fail=1
fi
rm -f /tmp/nx_finish_a.$$ /tmp/nx_finish_b.$$

fresh
q -f supabase/schema.sql >/dev/null 2>&1
q -f supabase/test/race_setup.sql >/dev/null 2>&1
retry_race() {
	psql -X -q -t -A -v ON_ERROR_STOP=1 -d "$DB" -c "begin;
		select set_config('request.jwt.claim.sub', '$A', true);
		set local role authenticated;
		select gems from public.score_event('33333333-3333-3333-3333-333333333333',
		 '99999999-9999-9999-9999-999999999999','answer',true,0,0);
		select pg_sleep(1); commit;" > "$1" 2>&1
}
retry_race /tmp/nx_retry_a.$$ & retry_race /tmp/nx_retry_b.$$ & wait
row=$(q -t -A -c "select items_done||','||gems from public.members where profile_id='$A'")
if [[ $row == 1,60 ]] && ! grep -qi 'error' /tmp/nx_retry_a.$$ /tmp/nx_retry_b.$$; then
	echo "ok    concurrent retries award one answer once"
else
	echo "FAIL  concurrent retries left row=$row"; cat /tmp/nx_retry_a.$$ /tmp/nx_retry_b.$$; fail=1
fi
rm -f /tmp/nx_retry_a.$$ /tmp/nx_retry_b.$$

psql -X -q -c "drop database if exists $DB;" >/dev/null
[[ $fail -eq 0 ]] && echo "server rules green" || echo "SERVER RULES FAILED"
exit $fail
