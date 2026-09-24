# Supabase setup

Cloud backend for NumXventure (SPECS §10 Phase 7). **Phase 4 is still LAN** —
this is here so the schema exists and `Net.gd` has something concrete to sit on
if Q3 comes back "the paper means literal online play".

## 1. Create the project

supabase.com → New project. Note the **region** (pick the nearest one; every
answer in a classroom of 40 phones makes a round trip) and the database
password, which you will not need again.

## 2. Run the schema

SQL Editor → paste `schema.sql` → Run. It is written to run once on an empty
project; re-running it errors on the first `create table`.

With the CLI instead:

    supabase link --project-ref <ref>
    supabase db push

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

## What is in the schema

| Table | Holds |
|---|---|
| `profiles` | username, role, chosen hero — one row per `auth.users` row, created by trigger. The **email lives in `auth.users`**, not here: one copy, and GoTrue owns it |
| `sessions` | one live adventure: duration, state, and the **shared clock** (`ends_at` running, `remaining_s` paused) |
| `teams` | team name per session — the name **is** the join code, unique within the session |
| `members` | a player in a team: gems, correct count, items done, eliminated, finished |
| `questions` | the admin's bank; `QuestionGen` still tops up any station short of active items |
| `team_scores` | view: gems summed per team, which is the leaderboard |

`sessions` and `members` are in the realtime publication, so one pause and the
live leaderboard reach every phone without polling.

## Known gap

Scores are still client-written (`own_member` policy). SPECS §10 Phase 4 says
gem arithmetic is validated server-side; that means a `security definer` RPC —
`apply_answer`, `spend_hint`, `skip_item` — doing the sums in Postgres, after
which that policy narrows to `finished` and `hero`. Marked in `schema.sql`.
Fine for a proctored classroom pilot, not fine for a graded run.
