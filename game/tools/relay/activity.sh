#!/usr/bin/env bash
# Who used the home relay, when, and how much -- from the JSON lines the relay
# appends (RelayServer._activity, tools/relay/run.sh --activity). Local only:
# reading this file costs Supabase nothing.
#
#   tools/relay/activity.sh sessions            each run of the relay: when, who, how long
#   tools/relay/activity.sh days                a line a day: connections, people, minutes, bytes
#   tools/relay/activity.sh users               a line a person: sessions, first/last, minutes, bytes
#   tools/relay/activity.sh raw                 the records themselves, names added
#
#   --since YYYY-MM-DD  --until YYYY-MM-DD      keep a window (until is exclusive)
#   --no-names                                  skip the one cached Supabase lookup
#
# Names: the relay records a profile id (a uuid), never a name, so the live
# path never asks Supabase. This script turns ids into usernames on demand:
# the ids it has not seen before go in one `profiles` query, the answers are
# kept in users.json beside the log, and later runs ask for nothing. Needs
# SUPABASE_URL / SUPABASE_ANON_KEY (as the sim tools take them) and the admin
# in ~/.config/numxventure/relay.env (RELAY_ENV to move it); without them it
# prints ids.
set -u

STATE=${XDG_STATE_HOME:-$HOME/.local/state}/numxventure-relay
ACTIVITY=${ACTIVITY:-$STATE/activity.jsonl}
CACHE=${ACTIVITY%.jsonl}.users.json
ENV_FILE=${RELAY_ENV:-$HOME/.config/numxventure/relay.env}
PROJECT=${PROJECT_FILE:-$(dirname "$0")/../../project.godot}

cmd=""
since=""
until=""
names=1
while [ $# -gt 0 ]; do
	case "$1" in
		--since) since=${2:-}; shift 2 ;;
		--until) until=${2:-}; shift 2 ;;
		--no-names) names=0; shift ;;
		-h|--help) cmd="help"; shift ;;
		*) cmd=$1; shift ;;
	esac
done
[ -z "$cmd" ] && cmd="help"

if [ ! -f "$ACTIVITY" ]; then
	echo "no activity log yet: $ACTIVITY" >&2
	echo "(the relay writes it once run.sh passes --activity; nothing recorded before that)" >&2
	exit 0
fi

# A window, as a jq filter. ts is "YYYY-MM-DDTHH:MM:SSZ", so plain string
# comparison sorts and bounds it -- a bare date is a prefix of every time in it.
window='select(.ts != null)'
[ -n "$since" ] && window="$window | select(.ts >= \"$since\")"
[ -n "$until" ] && window="$window | select(.ts < \"$until\")"

# ids on stdin -> JSON object {id: username}. Cached; one query for the rest.
names_json() {
	local ids; ids=$(sort -u)
	[ -z "$ids" ] && { echo '{}'; return; }
	local known='{}'
	[ -f "$CACHE" ] && known=$(cat "$CACHE")
	local missing
	missing=$(jq -Rr --argjson known "$known" 'select(. as $id | ($known|has($id))|not)' <<<"$ids")
	if [ -n "$missing" ] && [ "$names" = 1 ]; then
		local url key email pass token got
		# The env first (dev machines); else the app's own settings, where the
		# public url and anon key already live (project.godot, numxventure/
		# supabase/*). Either way this is read-only -- no writes, no storage.
		url=${SUPABASE_URL:-$(sed -n 's/^supabase\/url="\(.*\)"/\1/p' "$PROJECT" 2>/dev/null | head -1)}
		key=${SUPABASE_ANON_KEY:-$(sed -n 's/^supabase\/anon_key="\(.*\)"/\1/p' "$PROJECT" 2>/dev/null | head -1)}
		if [ -n "$url" ] && [ -n "$key" ] && [ -f "$ENV_FILE" ]; then
			# shellcheck disable=SC1090
			email=$(sed -n 's/^NUMX_RELAY_EMAIL=//p' "$ENV_FILE")
			pass=$(sed -n 's/^NUMX_RELAY_PASSWORD=//p' "$ENV_FILE")
			token=$(curl -s --max-time 15 "$url/auth/v1/token?grant_type=password" \
				-H "apikey: $key" -H "Content-Type: application/json" \
				-d "{\"email\":\"$email\",\"password\":\"$pass\"}" | jq -r '.access_token // ""')
			if [ -n "$token" ]; then
				local list in
				list=$(paste -sd, <<<"$missing")     # uuids: safe unquoted in in.(...)
				got=$(curl -s --max-time 15 \
					"$url/rest/v1/profiles?select=id,username&id=in.($list)" \
					-H "apikey: $key" -H "Authorization: Bearer $token" \
					| jq -c 'if type == "array" then map({(.id): .username}) | add // {} else {} end')
				known=$(jq -n --argjson a "$known" --argjson b "$got" '$a * $b')
				printf '%s\n' "$known" >"$CACHE"
			fi
		fi
	fi
	printf '%s\n' "$known"
}

column() { command column -t -s $'\t' 2>/dev/null || cat; }

case "$cmd" in
sessions)
	echo -e "session\tfirst\tlast\tpeople\tminutes\tMB"
	jq -rs "[ .[] | $window ] | group_by(.session) | .[]
		| [ .[0].session,
		    (map(.ts)|min),
		    (map(.ts)|max),
		    (map(select(.event==\"join\")|.profile)|unique|length),
		    (((map(select(.event==\"leave\")|.dur_s)|add)//0)/60*10|round/10),
		    (((map(select(.event==\"leave\")|.bytes_out)|add)//0)/1048576*100|round/100) ]
		| @tsv" "$ACTIVITY" | column
	;;
days)
	echo -e "day\tconnections\tpeople\tminutes\tmsgs in\tmsgs out\tMB"
	jq -rs "[ .[] | $window | select(.event==\"leave\") ] | group_by(.ts[0:10]) | .[]
		| [ .[0].ts[0:10],
		    length,
		    (map(.profile)|unique|length),
		    (((map(.dur_s)|add)//0)/60*10|round/10),
		    ((map(.msgs_in)|add)//0),
		    ((map(.msgs_out)|add)//0),
		    (((map(.bytes_out)|add)//0)/1048576*100|round/100) ]
		| @tsv" "$ACTIVITY" | column
	;;
users)
	leaves=$(jq -rs "[ .[] | $window | select(.event==\"leave\") ]" "$ACTIVITY")
	known='{}'
	if [ "$names" = 1 ]; then
		known=$(jq -r '.[].profile' <<<"$leaves" | names_json)
	fi
	echo -e "who\tsessions\tconnections\tfirst\tlast\tminutes\tmsgs in\tmsgs out\tMB"
	jq -r --argjson names "$known" '
		group_by(.profile) | .[]
		| (.[0].profile) as $id
		| [ ($names[$id] // $id),
		    (map(.session)|unique|length),
		    length,
		    (map(.ts)|min),
		    (map(.ts)|max),
		    (((map(.dur_s)|add)//0)/60*10|round/10),
		    ((map(.msgs_in)|add)//0),
		    ((map(.msgs_out)|add)//0),
		    (((map(.bytes_out)|add)//0)/1048576*100|round/100) ]
		| @tsv' <<<"$leaves" | column
	;;
raw)
	leaves=$(cat "$ACTIVITY")
	known='{}'
	if [ "$names" = 1 ]; then
		known=$(jq -r 'select(.profile != "")|.profile' <<<"$leaves" | names_json)
	fi
	jq -r --argjson names "$known" --arg since "$since" --arg until "$until" '
		select(.ts != null)
		| (if $since  == "" then . else select(.ts >= $since) end)
		| (if $until  == "" then . else select(.ts <  $until) end)
		| [ .ts, .event, (.session // ""), ($names[.profile] // .profile // ""),
		    (.role // ""), ((.dur_s // "")|tostring), ((.bytes_out // "")|tostring), (.why // "") ]
		| @tsv' <<<"$leaves" | column
	;;
*)
	cat >&2 <<EOF
usage: activity.sh [sessions|days|users|raw] [--since YYYY-MM-DD] [--until YYYY-MM-DD] [--no-names]
  reads $ACTIVITY
EOF
	exit 2
	;;
esac
