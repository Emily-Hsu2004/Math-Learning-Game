-- =========================================================
-- 颱風危機：資料庫設定
-- 注意：原本完整的 setup.sql 不在這個資料夾裡。這份目前只收錄
-- 2026-11-10 起的變更；每一段都可以重複執行。
-- =========================================================


-- =========================================================
-- 2026-11-10：一個帳號只能在一台裝置登入、學生暱稱
--   ・學生帳號已有登入中的 session 時，別台裝置不能再登入（老師帳號不限）
--   ・學生登出時刪除自己的 session；換裝置時由老師在後台「強制登出」
--   ・學生第一次登入要取暱稱，之後只有老師能改；排名顯示暱稱
-- =========================================================

-- 暱稱欄位與不分大小寫的唯一索引（只限有填暱稱的帳號）
alter table students add column if not exists nickname text;
create unique index if not exists students_nickname_lower_key
  on students (lower(nickname)) where nickname is not null;

-- 暱稱格式：去掉控制字元與前後空白，1～10 個字；不合格回傳 null
create or replace function public._game_clean_nickname(p_nick text)
returns text
language sql
immutable
set search_path = public
as $$
  select case when char_length(v) between 1 and 10 then v end
    from (select btrim(regexp_replace(coalesce(p_nick, ''), '[[:cntrl:]]', '', 'g')) as v) t
$$;
revoke execute on function public._game_clean_nickname(text) from public, anon, authenticated;

-- 登入：學生帳號已在其他裝置登入時拒絕
create or replace function public.game_login(p_account text, p_password text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare s students%rowtype; t uuid;
begin
  select * into s from students
   where lower(account) = lower(trim(p_account)) and password = p_password
   for update;                                   -- 同時登入時排隊，避免兩台都進去
  if not found then return json_build_object('ok', false); end if;
  if s.role = 'student' and exists (select 1 from sessions where student_id = s.id) then
    return json_build_object('ok', false, 'reason', 'in_use');
  end if;
  insert into sessions (student_id) values (s.id) returning token into t;
  return json_build_object('ok', true, 'token', t);
end $$;
grant execute on function public.game_login(text, text) to anon, authenticated;

-- 登出：刪除這台裝置的 session，之後才能在別台登入
create or replace function public.game_logout(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from sessions where token = p_token;
  return json_build_object('ok', true);
end $$;
grant execute on function public.game_logout(uuid) to anon, authenticated;

-- 學生取暱稱：只能取一次（已有暱稱就不能自己改）
create or replace function public.game_set_nickname(p_token uuid, p_nickname text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint; v text; cur text;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  select nickname into cur from students where id = sid and role = 'student' for update;
  if not found then return json_build_object('ok', false, 'reason', 'student'); end if;
  if cur is not null then return json_build_object('ok', false, 'reason', 'locked', 'nickname', cur); end if;
  v := _game_clean_nickname(p_nickname);
  if v is null then return json_build_object('ok', false, 'reason', 'invalid'); end if;
  begin
    update students set nickname = v where id = sid;
  exception when unique_violation then
    return json_build_object('ok', false, 'reason', 'taken');
  end;
  return json_build_object('ok', true, 'nickname', v);
end $$;
grant execute on function public.game_set_nickname(uuid, text) to anon, authenticated;

-- 學生資訊：多回傳暱稱
create or replace function public.game_me(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint; s students%rowtype; r level3_runs%rowtype; has_run boolean; lim int;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  select * into s from students where id = sid;
  select * into r from level3_runs where student_id = sid;
  has_run := found;
  select coalesce(time_limit, 180) into lim from levels where level = 3;
  return json_build_object(
    'ok', true, 'account', s.account, 'seat', s.seat, 'name', s.name, 'role', s.role, 'nickname', s.nickname,
    'show_leaderboard', coalesce(_game_setting('show_leaderboard'), 'true') = 'true',
    'reveal_answers',   coalesce(_game_setting('reveal_answers'), 'false') = 'true',
    'unlocked', coalesce((select json_agg(level order by level) from unlocks where student_id = sid), '[]'::json),
    'time_limit', coalesce(lim, 180),
    'server_now', now(),
    'l3', case when has_run then json_build_object(
            'started_at', r.started_at, 'submitted', r.submitted_at is not null,
            'score', r.score, 'used_seconds', r.used_seconds, 'auto', r.auto_submitted)
          else null end);
end $$;
grant execute on function public.game_me(uuid) to anon, authenticated;

-- 排行榜：顯示暱稱，不再傳座號給其他學生；用 is_me 標出自己
create or replace function public.game_leaderboard(p_token uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare sid bigint; v_show boolean; res json;
begin
  sid := _game_sid(p_token);
  if sid is null then return json_build_object('ok', false, 'reason', 'login'); end if;
  v_show := coalesce(_game_setting('show_leaderboard'), 'true') = 'true';
  res := (
    with ranked as (
      select r.student_id, r.seat, coalesce(s.nickname, '（未取暱稱）') as nickname, r.score, r.used_seconds,
             rank() over (order by r.score desc, r.used_seconds asc) as rk
        from level3_runs r join students s on s.id = r.student_id
       where r.submitted_at is not null and s.role = 'student')
    select json_build_object(
      'ok', true, 'show', v_show,
      'total', (select count(*) from ranked),
      'top', case when v_show then coalesce((
               select json_agg(json_build_object('rank', t.rk, 'nickname', t.nickname, 'is_me', t.student_id = sid,
                                                 'score', t.score, 'used_seconds', t.used_seconds)
                               order by t.rk, t.seat)
                 from (select * from ranked order by rk, seat limit 10) t), '[]'::json)
             else '[]'::json end,
      'me', (select json_build_object('rank', case when v_show then rk else null end, 'nickname', nickname,
                                      'score', score, 'used_seconds', used_seconds)
               from ranked where student_id = sid)));
  return res;
end $$;
grant execute on function public.game_leaderboard(uuid) to anon, authenticated;

-- 老師後台資料：多回傳暱稱與是否登入中
create or replace function public.admin_data(p_token uuid, p_from timestamp with time zone, p_to timestamp with time zone)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  return json_build_object(
    'ok', true, 'server_now', now(),
    'attempts', coalesce((
       select json_agg(json_build_object('t', a.created_at, 'seat', a.seat, 'level', a.level, 'item', a.item,
                       'correct', a.correct, 'tag', a.tag, 'attempt', a.attempt, 'answer', a.answer) order by a.created_at)
         from attempts a join students s on s.id = a.student_id
        where s.role = 'student'
          and (p_from is null or a.created_at >= p_from)
          and (p_to   is null or a.created_at <  p_to)), '[]'::json),
    'runs', coalesce((
       select json_agg(json_build_object('seat', s.seat, 'name', s.name, 'nickname', s.nickname, 'started_at', r.started_at,
                       'submitted_at', r.submitted_at, 'score', r.score, 'used_seconds', r.used_seconds,
                       'auto', r.auto_submitted, 'late', r.late, 'answers', r.answers)
                       order by r.score desc nulls last, r.used_seconds asc nulls last)
         from level3_runs r join students s on s.id = r.student_id
        where s.role = 'student'), '[]'::json),
    'students', coalesce((
       select json_agg(json_build_object('seat', s.seat, 'account', s.account, 'password', s.password, 'name', s.name,
                       'nickname', s.nickname,
                       'logged_in', exists (select 1 from sessions se where se.student_id = s.id),
                       'unlocked', coalesce((select json_agg(u.level order by u.level) from unlocks u where u.student_id = s.id), '[]'::json))
                       order by s.seat)
         from students s where s.role = 'student'), '[]'::json),
    'levels', (select json_agg(json_build_object('level', level, 'title', title, 'code', code, 'time_limit', time_limit) order by level) from levels),
    'settings', (select json_object_agg(key, value) from settings));
end $$;
grant execute on function public.admin_data(uuid, timestamp with time zone, timestamp with time zone) to anon, authenticated;

-- 老師強制登出某位學生（學生換裝置、或帳號被別人登入時使用）
create or replace function public.admin_force_logout(p_token uuid, p_seat integer)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare n int;
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  delete from sessions where student_id in (select id from students where seat = p_seat and role = 'student');
  get diagnostics n = row_count;
  return json_build_object('ok', true, 'deleted', n);
end $$;
grant execute on function public.admin_force_logout(uuid, integer) to anon, authenticated;

-- 老師修改學生暱稱；留空表示清除，學生下次進遊戲要重新取
create or replace function public.admin_set_nickname(p_token uuid, p_seat integer, p_nickname text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare v text;
begin
  if not _game_is_teacher(p_token) then return json_build_object('ok', false, 'reason', 'teacher'); end if;
  if btrim(coalesce(p_nickname, '')) = '' then
    v := null;
  else
    v := _game_clean_nickname(p_nickname);
    if v is null then return json_build_object('ok', false, 'reason', 'invalid'); end if;
  end if;
  begin
    update students set nickname = v where seat = p_seat and role = 'student';
  exception when unique_violation then
    return json_build_object('ok', false, 'reason', 'taken');
  end;
  return json_build_object('ok', true, 'nickname', v);
end $$;
grant execute on function public.admin_set_nickname(uuid, integer, text) to anon, authenticated;
