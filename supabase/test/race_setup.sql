-- Two teammates in a running adventure, for run.sh's simultaneous-rescue check.
insert into auth.users (id, email, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', 'teacher@t.dev', '{"username":"teacher","role":"admin"}'),
  ('00000000-0000-0000-0000-00000000aaa1', 'amy@t.dev', '{"username":"amy"}'),
  ('00000000-0000-0000-0000-00000000bbb1', 'bob@t.dev', '{"username":"bob"}');
insert into public.sessions (id, admin_id) values
  ('33333333-3333-3333-3333-333333333333', '00000000-0000-0000-0000-00000000000a');
insert into public.teams (id, session_id, name) values
  ('44444444-4444-4444-4444-444444444444', '33333333-3333-3333-3333-333333333333', 'Reds');
insert into public.members (session_id, team_id, profile_id) values
  ('33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-00000000aaa1'),
  ('33333333-3333-3333-3333-333333333333', '44444444-4444-4444-4444-444444444444', '00000000-0000-0000-0000-00000000bbb1');
update public.sessions set state = 'running', ends_at = now() + interval '10 minutes'
 where id = '33333333-3333-3333-3333-333333333333';
