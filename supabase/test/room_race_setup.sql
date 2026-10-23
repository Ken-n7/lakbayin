-- Two independent custom rooms for the two Start/cleanup lock orders.
insert into auth.users(id,email,raw_user_meta_data) values
 ('00000000-0000-0000-0000-00000000e001','host@race.test','{"username":"racehost"}'),
 ('00000000-0000-0000-0000-00000000e002','peer@race.test','{"username":"racepeer"}'),
 ('00000000-0000-0000-0000-00000000e003','gone@race.test','{"username":"racegone"}');
insert into public.sessions(id,admin_id,custom,state) values
 ('11111111-1111-1111-1111-11111111cc01','00000000-0000-0000-0000-00000000e001',true,'lobby'),
 ('11111111-1111-1111-1111-11111111cc02','00000000-0000-0000-0000-00000000e001',true,'lobby');
insert into public.teams(id,session_id,name) values
 ('22222222-2222-2222-2222-22222222cc01','11111111-1111-1111-1111-11111111cc01','Blue'),
 ('22222222-2222-2222-2222-22222222cc02','11111111-1111-1111-1111-11111111cc01','Red'),
 ('22222222-2222-2222-2222-22222222cc03','11111111-1111-1111-1111-11111111cc02','Blue'),
 ('22222222-2222-2222-2222-22222222cc04','11111111-1111-1111-1111-11111111cc02','Red');
insert into public.members(session_id,profile_id,team_id)
 select t.session_id,u.id,t.id from public.teams t cross join auth.users u
 where u.id::text like '%e00%' and t.name=case when u.id::text like '%e002' then 'Red' else 'Blue' end;
update public.members set updated_at=clock_timestamp()-interval '1 minute'
 where profile_id='00000000-0000-0000-0000-00000000e003';
