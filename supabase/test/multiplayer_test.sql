-- Regressions for lost replies, restarts, deadlines, team locks and private movement.
create temp table results (n serial, ok boolean, name text, detail text);
create function pg_temp.check(ok boolean, name text, detail text default '')
returns void language sql as $$ insert into results(ok,name,detail) values(coalesce(ok,false),name,detail) $$;
create function pg_temp.as_player(who uuid, stmt text) returns text language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', who::text, true);
  perform set_config('role', 'authenticated', true);
  execute stmt;
  perform set_config('role', 'postgres', true);
  return '';
exception when others then
  perform set_config('role', 'postgres', true);
  return sqlerrm;
end $$;
insert into auth.users(id,email,raw_user_meta_data) values
('00000000-0000-0000-0000-00000000000a','teacher@t.dev','{"username":"teacher","role":"admin"}'),
('00000000-0000-0000-0000-00000000000b','alice@t.dev','{"username":"alice"}'),
('00000000-0000-0000-0000-00000000000c','bob@t.dev','{"username":"bob"}'),
('00000000-0000-0000-0000-00000000000d','other@t.dev','{"username":"other","role":"admin"}');
insert into public.questions(owner,station,prompt,answer)
select '00000000-0000-0000-0000-00000000000a', case when n<=8 then 1 when n<=11 then 2 else 3 end,
       'Authored '||n,'2' from generate_series(1,14) n;
insert into public.sessions(id,admin_id)
select (repeat(n::text,8)||'-'||repeat(n::text,4)||'-'||repeat(n::text,4)||'-'||repeat(n::text,4)||'-'||repeat(n::text,12))::uuid,
       '00000000-0000-0000-0000-00000000000a' from generate_series(1,6) n;
insert into public.members(session_id,profile_id)
select s.id,p.id from public.sessions s cross join public.profiles p where p.role='player';
insert into public.teams(id,session_id,name) values
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1','33333333-3333-3333-3333-333333333333','Red'),
('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2','33333333-3333-3333-3333-333333333333','Blue');
update public.members set team_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1' where session_id='33333333-3333-3333-3333-333333333333';

-- Removing a player is the teacher's lobby tool, never a player's way to
-- erase their own score and never something another teacher can do.
do $$
declare a uuid := '00000000-0000-0000-0000-00000000000b';
  b uuid := '00000000-0000-0000-0000-00000000000c';
  t uuid := '00000000-0000-0000-0000-00000000000a';
  other uuid := '00000000-0000-0000-0000-00000000000d';
  s uuid := '66666666-6666-6666-6666-666666666666'; err text;
begin
  err := pg_temp.as_player(a,format('delete from public.members where session_id=%L and profile_id=%L',s,a));
  perform pg_temp.check(err='' and exists(select 1 from public.members where session_id=s and profile_id=a),
    'a player cannot remove themself from the lobby',err);
  err := pg_temp.as_player(other,format('delete from public.members where session_id=%L and profile_id=%L',s,b));
  perform pg_temp.check(err='' and exists(select 1 from public.members where session_id=s and profile_id=b),
    'another teacher cannot remove this class''s player',err);
  err := pg_temp.as_player(t,format('delete from public.members where session_id=%L and profile_id=%L',s,b));
  perform pg_temp.check(err='' and not exists(select 1 from public.members where session_id=s and profile_id=b),
    'the session teacher can remove a player before Start',err);
  update public.sessions set state='running',ends_at=now()+interval '10 minutes' where id=s;
  err := pg_temp.as_player(t,format('delete from public.members where session_id=%L and profile_id=%L',s,a));
  perform pg_temp.check(err='' and exists(select 1 from public.members where session_id=s and profile_id=a),
    'the session teacher cannot remove a player after Start',err);
end $$;

update public.sessions set state='running',ends_at=now()+interval '10 minutes';

do $$
declare a uuid := '00000000-0000-0000-0000-00000000000b';
  t uuid := '00000000-0000-0000-0000-00000000000a';
  s uuid := '11111111-1111-1111-1111-111111111111';
  ev uuid := gen_random_uuid(); err text; m public.members;
begin
  err := pg_temp.as_player(a,format('select public.score_event(%L,%L,''answer'',true,0,0)',s,ev));
  err := err || pg_temp.as_player(a,format('select public.score_event(%L,%L,''answer'',true,0,0)',s,ev));
  select * into m from public.members where session_id=s and profile_id=a;
  perform pg_temp.check(err='' and m.items_done=1 and m.gems=60,'one request ID scores exactly once',err);
  err := pg_temp.as_player(a,format('select public.score_event(%L,%L,''answer'',false,0,0)',s,ev));
  perform pg_temp.check(err like '%already used%','a reused request ID cannot change its payload',err);
  err := pg_temp.as_player(a,format('select public.score_event(%L,%L,''answer'',true,0,0)',s,gen_random_uuid()));
  perform pg_temp.check(err like '%no longer current%','a queued answer cannot resolve the wrong circle',err);
  update public.sessions set state='ended' where id=s;
  err := pg_temp.as_player(a,format('select public.score_event(%L,%L,''answer'',true,0,0)',s,ev));
  perform pg_temp.check(err='' and (select gems=60 from public.members where session_id=s and profile_id=a),
    'a lost reply is recoverable after End without another award',err);
  err := pg_temp.as_player(a,'select * from numxventure_private.score_events');
  perform pg_temp.check(err like '%permission denied%','clients cannot read or forge the score ledger',err);

  s := '22222222-2222-2222-2222-222222222222';
  update public.sessions set ends_at=now()-interval '1 second' where id=s;
  foreach err in array array['apply_answer','skip_item','spend_hint','finish_run'] loop
    perform pg_temp.check(pg_temp.as_player(a,format('select public.%I(%L%s)',err,s,
      case when err='apply_answer' then ',true' else '' end))='the adventure is not running',
      err||' refuses an expired deadline');
  end loop;
  err := pg_temp.as_player(a,format('select public.rescue(%L,%L,1)',s,'00000000-0000-0000-0000-00000000000c'));
  perform pg_temp.check(err='the adventure is not running','rescue refuses an expired deadline',err);
  perform pg_temp.check((select bool_and(gems=50 and items_done=0) from public.members where session_id=s),
    'expired requests mutate no player');

  s := '33333333-3333-3333-3333-333333333333';
  err := pg_temp.as_player(a,format('update public.members set team_id=null where session_id=%L and profile_id=%L',s,a));
  perform pg_temp.check(err like '%teams are locked%','a player cannot clear a locked team',err);
  err := pg_temp.as_player(a,format('update public.members set team_id=%L where session_id=%L and profile_id=%L',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2',s,a));
  perform pg_temp.check(err like '%teams are locked%','a direct switch remains locked',err);
  err := pg_temp.as_player(t,'delete from public.teams where id=''aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa1''');
  perform pg_temp.check(err='' and (select bool_and(team_id is null) from public.members where session_id=s),
    'the teacher can still remove a team during play',err);
  err := pg_temp.as_player(a,format('update public.members set team_id=%L where session_id=%L and profile_id=%L',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2',s,a));
  perform pg_temp.check(err='','a genuinely removed team can be replaced while playing',err);
  update public.sessions set state='ended' where id=s;
  err := pg_temp.as_player(a,format('update public.members set team_id=null where session_id=%L and profile_id=%L',s,a));
  perform pg_temp.check(err like '%teams are locked%','completed results cannot be moved by clearing the team',err);
  err := pg_temp.as_player('00000000-0000-0000-0000-00000000000c',format(
    'update public.members set team_id=%L where session_id=%L and profile_id=%L',
    'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa2',s,'00000000-0000-0000-0000-00000000000c'));
  perform pg_temp.check(err like '%teams are locked%','even a teamless player cannot rewrite completed results',err);
end $$;

do $$
declare a uuid := '00000000-0000-0000-0000-00000000000b';
  s uuid := '44444444-4444-4444-4444-444444444444'; err text; m public.members; i int;
begin
  for i in 0..7 loop
    err := pg_temp.as_player(a,format('select public.score_event(%L,%L,''answer'',true,%s,0)',s,gen_random_uuid(),i));
  end loop;
  select * into m from public.members where session_id=s and profile_id=a;
  perform pg_temp.check(err='' and m.items_done=8 and m.stations_done=1 and m.gems=140 and m.perfect_stations[1],
    'the final answer atomically commits its station and bonus',err);
  err := pg_temp.as_player(a,format('select public.finish_station(%L,true)',s));
  perform pg_temp.check(err='' and (select gems=140 from public.members where session_id=s and profile_id=a),
    'an older client completion call cannot award a second bonus',err);
  err := pg_temp.as_player(a,format('select public.score_event(%L,%L,''hint'',false,8,1)',s,gen_random_uuid()));
  err := pg_temp.as_player(a,format('select public.score_event(%L,%L,''hint'',false,8,1)',s,gen_random_uuid()));
  select * into m from public.members where session_id=s and profile_id=a;
  perform pg_temp.check(err like '%hint is not available%' and m.item_used_hint and m.station_used_hint and m.hints_used=1,
    'a rejoined question retains its one hint and station penalty',err);
  for i in 8..13 loop
    err := pg_temp.as_player(a,format('select public.score_event(%L,%L,''answer'',true,%s,1)',s,gen_random_uuid(),i));
  end loop;
  select * into m from public.members where session_id=s and profile_id=a;
  perform pg_temp.check(m.stations_done=3 and m.gems=205 and not m.perfect_stations[2] and m.perfect_stations[3],
    'restored station state produces the correct later bonuses');
  err := pg_temp.as_player(a,format('select public.finish_run(%L)',s));
  perform pg_temp.check(err='' and (select finished from public.members where session_id=s and profile_id=a),
    'a boundary restart can finish without any UI completion call',err);
  perform pg_temp.check((select jsonb_array_length(question_bank)=14 from public.sessions where id=s),
    'Start freezes the complete authored bank');
  update public.questions set prompt='Changed after Start',active=false;
  perform pg_temp.check((select question_bank->0->>'prompt' like 'Authored %' from public.sessions where id=s),
    'later bank edits cannot change a running or restored adventure');
end $$;

do $$
declare a uuid := '00000000-0000-0000-0000-00000000000b';
  b uuid := '00000000-0000-0000-0000-00000000000c';
  t uuid := '00000000-0000-0000-0000-00000000000a';
  other uuid := '00000000-0000-0000-0000-00000000000d';
  s uuid := '55555555-5555-5555-5555-555555555555'; topic text; err text;
begin
  topic := 'numxventure:snap:'||s;
  perform set_config('realtime.topic',topic,true);
  err := pg_temp.as_player(a,format('insert into realtime.messages(topic,extension) values(%L,''broadcast'')',topic));
  perform pg_temp.check(err like '%row-level security%','a player cannot publish a teacher snapshot',err);
  err := pg_temp.as_player(t,format('insert into realtime.messages(topic,extension) values(%L,''broadcast'')',topic));
  perform pg_temp.check(err='','the session teacher can publish its snapshots',err);
  err := pg_temp.as_player(other,format('insert into realtime.messages(topic,extension) values(%L,''broadcast'')',topic));
  perform pg_temp.check(err like '%row-level security%','another teacher cannot impersonate the session teacher',err);
  perform set_config('request.jwt.claim.sub',a::text,true);
  perform pg_temp.check(public.can_use_movement(topic,false),'a member may receive its snapshots');
  perform set_config('request.jwt.claim.sub',other::text,true);
  perform pg_temp.check(not public.can_use_movement(topic,false),'a nonmember cannot read the movement channel');
  topic := 'numxventure:in:'||s||':'||a;
  perform set_config('realtime.topic',topic,true);
  err := pg_temp.as_player(a,format('insert into realtime.messages(topic,extension) values(%L,''broadcast'')',topic));
  perform pg_temp.check(err='','a member may publish its own movement',err);
  err := pg_temp.as_player(b,format('insert into realtime.messages(topic,extension) values(%L,''broadcast'')',topic));
  perform pg_temp.check(err like '%row-level security%','a member cannot impersonate another input topic',err);
  perform set_config('request.jwt.claim.sub',t::text,true);
  perform pg_temp.check(public.can_use_movement(topic,false) and not public.can_use_movement(topic,true),
    'the teacher reads inputs without publishing as a player');
  perform pg_temp.check(not public.can_use_movement('numxventure:snap:bad',false),'malformed topics are denied without exceptions');
end $$;

select case when ok then 'ok  ' else 'FAIL' end || '  ' || name
       || case when not ok and detail<>'' then '   <'||detail||'>' else '' end from results order by n;
select format('---- MULTIPLAYER SQL %s ---- %s checks, %s failures',
  case when bool_and(ok) then 'PASS' else 'FAIL' end,count(*),count(*) filter(where not ok)) from results;
