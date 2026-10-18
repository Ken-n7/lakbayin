# Supabase setup

Cloud backend for NumXventure. Sessions, scoring and game controls use
Supabase; movement uses the WebSocket relay with private Realtime channels
through the teacher as its fallback.

## 1. Create the project

supabase.com → New project. Note the **region** (pick the nearest one; every
answer in a classroom of 40 phones makes a round trip) and the database
password, which you will not need again.

## 2. Run the schema

SQL Editor → paste `schema.sql` → Run. The file creates a fresh project and
can also be re-run to upgrade an existing one. It preserves accounts,
sessions, scores and authored questions.

Apply the schema before distributing an updated game build. The multiplayer
fixes require `score_event`, the extra member progress fields, session question
snapshots, and the policies on `realtime.messages`. A project with only the old
schema cannot save scores from the updated app. Restart teacher and student
apps together so they all use the private movement channels.

The upgrade repairs old station-completion counters without adding unknown
historical bonuses, and snapshots the current bank for existing running or
paused sessions. New games record hint and station state with each score.

The main lobby topic remains public and carries reload notifications and
nonauthoritative rescue announcements.
Movement inputs and teacher snapshots explicitly join private channels;
`movement_send` and `movement_receive` authorize the owner, teacher and class.
Keep public access enabled for the lobby topic. Public channels with the same
name cannot deliver messages into the private movement channel.

For local verification, `supabase/test/run.sh` runs the schema twice, tests
scoring and permissions, and forces concurrent retries and simultaneous
finishes against a disposable Postgres database.

## 3. Email: codes, not links

Sign-in is by **email**, and there is a **Forgot password** flow, so real
inboxes are in play.

**Send a 6-digit code, not a link.** A confirmation or recovery link needs
somewhere to land — a web page or an Android deep link — and this app has
neither. Authentication → Emails → Templates → edit **Confirm signup** and
**Reset password** to use `{{ .Token }}` instead of `{{ .ConfirmationURL }}`:

    Your NumXventure code is {{ .Token }}. It expires in one hour.

The player types the code; `confirm_sign_up()` / `confirm_reset()` trade it for
a session at `/auth/v1/verify`. No deep link, no website, nothing to host.

**The code's length is a project setting, not six by default.** A real reset
email arrived as **8 digits**. Authentication → Providers → Email → *Email OTP
Length* sets it (6–10). Six is easier to read off a phone and retype; the app
does not care either way and no longer claims a length on screen.

**Set up SMTP before the pilot.** Supabase's built-in mailer is rate-limited to
a couple of messages an hour and is explicitly not for production — a class of
40 registering at once will hit that wall in the first minute. Authentication →
Emails → SMTP Settings, pointed at Resend / SendGrid / Brevo (all have a free
tier well past 40 students). Custom SMTP also lifts the rate limit, which you
then set deliberately under Rate Limits.

If you would rather not deal with mail at all for the classroom pilot, turn
**Confirm email: off** — registration then signs them straight in, and only
Forgot password needs the mailer. Recovery cannot be turned off; it is the
whole point of the feature.

## 4. Copy the two keys

Project Settings → API:

- **Project URL** → `SUPABASE_URL`
- **anon / public key** → `SUPABASE_ANON_KEY`

The anon key is public by design — row level security is the actual guard.
The **service_role** key is not: it bypasses RLS entirely. It does not go in
this repo, in `project.godot`, or in an APK.

For a dev run, export them:

    export SUPABASE_URL=https://<ref>.supabase.co
    export SUPABASE_ANON_KEY=eyJ...

**This project keeps them in `project.godot`** under `[numxventure]`, because
the anon key ships inside every APK regardless — anyone who can install the app
can read it, so keeping it out of git protects nothing while making editor
launches behave differently from builds. RLS is the actual guard.

The environment still wins over the settings, so a dev run can point at a
different project without editing anything.

The one real exposure is that **signup is open**: anyone with the key can
create accounts, admin ones included. Close it once the class roster exists —
Authentication → Providers → Email → **Disable signup**.

The `service_role` key is a different matter and must never go in
`project.godot`, the repo, or an APK.

## 5. Make yourself an admin

Anyone can register as admin per SPECS §2, so this is only for the first
account made before that UI exists. SQL Editor:

    update public.profiles set role = 'admin' where username = '<you>';

## 6. Give the old questions a teacher

Each teacher has their own bank (`questions.owner`, 2026-10-09). Questions
written before that have no owner, so no teacher sees them and no class plays
them until they get one. Once, in the SQL Editor, after the schema:

    update public.questions set owner = (select id from public.profiles where username = '<teacher>')
     where owner is null;

## What is in the schema

| Table | Holds |
|---|---|
| `profiles` | username, role, chosen hero — one row per `auth.users` row, created by trigger. The **email lives in `auth.users`**, not here: one copy, and GoTrue owns it |
| `sessions` | one live adventure: duration, state, the **shared clock** (`ends_at` running, `remaining_s` paused), and the question bank frozen at Start |
| `teams` | team name per session — the name **is** the join code, unique within the session |
| `members` | a player in a team: gems, progress, station completion, hint state, elimination, finish time and a revision for ordering updates |
| `questions` | each teacher's own bank (`owner`); a class plays its teacher's active questions |
| `team_scores` | view: gems summed per team, which is the leaderboard |

Request IDs live in `numxventure_private.score_events`, outside the Data API.
Retries keep the same ID and return the current member row without another
award. The final answer commits its station bonus in the same transaction;
the student's Continue button never owns server progress.

`sessions` and `members` are in the realtime publication, so one pause and the
live leaderboard reach every phone without polling.

## Known gap

The gem sums are done in Postgres (`apply_answer`, `spend_hint`, `skip_item`,
`finish_station`), but whether an answer was right is the phone's word: the
phone checks it, and every student can read the active questions' answers.
Capped at one answer per circle, so a student can lie about being right, not
answer more often. Fine for a proctored class, not for a graded test.
