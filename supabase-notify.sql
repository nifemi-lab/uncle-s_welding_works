-- =====================================================================
-- NOTIFICATIONS: phone push + live alerts for Uncle's Welding Works.
-- Run in Supabase -> SQL Editor -> New query -> paste -> Run.
-- Safe to re-run (everything drops-and-recreates or checks first).
-- =====================================================================

-- Which phones/browsers each welder switched alerts on for.
create table if not exists public.push_subscriptions (
  worker_id uuid not null references public.workers(id) on delete cascade,
  endpoint text primary key,
  subscription jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;

-- One row per (request, welder): the notifier only ever sends once.
create table if not exists public.push_log (
  key text primary key,
  created_at timestamptz not null default now()
);
alter table public.push_log enable row level security;

-- The signed-in welder may read/replace only their own subscription.
-- push_log has no policies at all: only the functions below touch it.
drop policy if exists "welder saves own push sub" on public.push_subscriptions;
create policy "welder saves own push sub"
  on public.push_subscriptions for all to authenticated
  using (worker_id = public.my_worker_id())
  with check (worker_id = public.my_worker_id());

-- Save this welder's browser subscription. Replaces the same device's
-- old entry, and any duplicate endpoint left on another welder.
create or replace function public.save_push_subscription(p_sub jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  wid uuid := public.my_worker_id();
  ep text := coalesce(p_sub ->> 'endpoint', '');
begin
  if wid is null then
    return jsonb_build_object('error', 'no worker');
  end if;
  if char_length(ep) < 20 then
    return jsonb_build_object('error', 'bad subscription');
  end if;
  delete from public.push_subscriptions where endpoint = ep;
  insert into public.push_subscriptions (worker_id, endpoint, subscription)
    values (wid, ep, p_sub);
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.save_push_subscription(jsonb) to authenticated;

-- Server-side read for the notifier: where should this welder's phone
-- be reached? Granted only to anon because the edge function calls it
-- with the publishable key; leaking an endpoint is useless without the
-- VAPID private key, which never leaves Supabase's secrets.
create or replace function public.get_push_sub(p_worker uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select subscription from public.push_subscriptions
   where worker_id = p_worker
   limit 1;
$$;
grant execute on function public.get_push_sub(uuid) to anon;

-- Claim = "I am the one sending this job's alert to this welder".
-- First caller wins; everyone else gets false and stays quiet.
create or replace function public.claim_push(p_key text)
returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  insert into public.push_log (key) values (p_key)
    on conflict do nothing;
  return found;
end;
$$;
grant execute on function public.claim_push(text) to anon;

-- Live alerts: let open pages hear about new requests / offers /
-- sign-ups the moment they happen instead of waiting for a refresh.
do $$
declare t text;
begin
  foreach t in array array['requests', 'offers', 'welder_signups'] loop
    if not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

-- =====================================================================
-- STAFF SIGN-UPS: applicants wait in a queue until the owner approves.
-- =====================================================================

create table if not exists public.staff_signups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  email text not null check (char_length(email) between 3 and 200),
  auth_uid uuid,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_by text,
  reviewed_at timestamptz
);
alter table public.staff_signups enable row level security;
create index if not exists staff_signups_status_idx on public.staff_signups (status, created_at desc);

-- The applicant can see their own row; the owner sees all. No insert or
-- update policies on purpose: only the functions below may touch rows.
drop policy if exists "applicant reads own staff signup" on public.staff_signups;
create policy "applicant reads own staff signup"
  on public.staff_signups for select to authenticated
  using (public.is_owner() or auth_uid = auth.uid()
         or lower(email) = lower(coalesce(auth.jwt() ->> 'email','')));

-- The confirmed applicant files their own application. Runs again on any
-- device, so losing a browser never loses the application.
create or replace function public.finish_staff_signup(p_name text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  em text := lower(coalesce(auth.jwt() ->> 'email', ''));
  nm text := left(trim(coalesce(p_name, '')), 60);
  st text;
begin
  if uid is null or em = '' then
    return jsonb_build_object('error', 'sign in first');
  end if;
  if nm = '' then nm := split_part(em, '@', 1); end if;
  if exists (select 1 from public.team_members where lower(email) = em) then
    return jsonb_build_object('mode', 'already');
  end if;
  select status into st from public.staff_signups
   where lower(email) = em order by created_at desc limit 1;
  if found then
    if st = 'pending' then
      update public.staff_signups set auth_uid = uid where lower(email) = em and status = 'pending';
      return jsonb_build_object('mode', 'queued');
    end if;
    return jsonb_build_object('mode', st);
  end if;
  insert into public.staff_signups (name, email, auth_uid)
  values (nm, em, uid);
  return jsonb_build_object('mode', 'queued');
end;
$$;
grant execute on function public.finish_staff_signup(text) to authenticated;

-- What is the state of this login's staff application?
create or replace function public.my_staff_signup()
returns text
language sql stable security definer set search_path = public
as $$
  select status from public.staff_signups
   where auth_uid = auth.uid()
      or lower(email) = lower(coalesce(auth.jwt() ->> 'email',''))
   order by created_at desc
   limit 1;
$$;
grant execute on function public.my_staff_signup() to authenticated;

-- Owner approves: the person is added to the staff team on the spot.
create or replace function public.approve_staff_signup(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  s public.staff_signups%rowtype;
begin
  if not public.is_owner() then
    return jsonb_build_object('error', 'owner only');
  end if;
  select * into s from public.staff_signups
   where id = p_id and status = 'pending' for update;
  if not found then
    return jsonb_build_object('error', 'not found');
  end if;
  if not exists (select 1 from public.team_members where lower(email) = lower(s.email)) then
    insert into public.team_members (email, role, auth_uid, created_by)
    values (lower(s.email), 'staff', s.auth_uid, 'staff approval');
  end if;
  update public.staff_signups
     set status = 'approved', reviewed_at = now(),
         reviewed_by = coalesce(auth.jwt() ->> 'email', 'owner')
   where id = p_id;
  return jsonb_build_object('ok', true, 'email', s.email);
end;
$$;

create or replace function public.reject_staff_signup(p_id uuid)
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_owner() then
    return jsonb_build_object('error', 'owner only');
  end if;
  update public.staff_signups
     set status = 'rejected', reviewed_at = now(),
         reviewed_by = coalesce(auth.jwt() ->> 'email', 'owner')
   where id = p_id and status = 'pending';
  if not found then
    return jsonb_build_object('error', 'not found');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.approve_staff_signup(uuid) to authenticated;
grant execute on function public.reject_staff_signup(uuid) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public'
       and tablename = 'staff_signups'
  ) then
    alter publication supabase_realtime add table public.staff_signups;
  end if;
end $$;

-- =====================================================================
-- WORK PORTFOLIO: the "show your work" requirement.
-- A welder must add at least 3 photos of past work before customers can
-- pick them by name; applicants attach photos so the owner can judge the
-- work before approving the sign-up.
-- =====================================================================

alter table public.welder_signups
  add column if not exists photos jsonb not null default '[]'::jsonb;

create table if not exists public.worker_photos (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid not null references public.workers(id) on delete cascade,
  url text not null check (char_length(url) between 10 and 4000),
  created_at timestamptz not null default now()
);
alter table public.worker_photos enable row level security;
create index if not exists worker_photos_worker_idx on public.worker_photos (worker_id, created_at);

-- The portfolio is advertising: everyone (customers included) may read it.
drop policy if exists "public reads portfolio" on public.worker_photos;
create policy "public reads portfolio"
  on public.worker_photos for select
  using (true);

-- The welder manages their own portfolio; owner and staff may tidy it up.
drop policy if exists "team or welder adds portfolio photos" on public.worker_photos;
create policy "team or welder adds portfolio photos"
  on public.worker_photos for insert to authenticated
  with check (
    public.is_team()
    or exists (select 1 from public.workers w
                where w.id = worker_id and w.auth_uid = auth.uid())
  );

drop policy if exists "team or welder removes portfolio photos" on public.worker_photos;
create policy "team or welder removes portfolio photos"
  on public.worker_photos for delete to authenticated
  using (
    public.is_team()
    or exists (select 1 from public.workers w
                where w.id = worker_id and w.auth_uid = auth.uid())
  );

-- While waiting for approval, the applicant attaches work photos to the
-- application. Replaces the list each save; only a pending row is editable.
create or replace function public.save_signup_photos(p_urls jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  em text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if uid is null or em = '' then
    return jsonb_build_object('error', 'sign in first');
  end if;
  if p_urls is null or jsonb_typeof(p_urls) <> 'array'
     or jsonb_array_length(p_urls) > 12 then
    return jsonb_build_object('error', 'bad list');
  end if;
  if exists (
    select 1 from jsonb_array_elements_text(p_urls) t(url)
     where char_length(t.url) < 10 or char_length(t.url) > 4000
  ) then
    return jsonb_build_object('error', 'bad photo');
  end if;
  update public.welder_signups
     set photos = p_urls
   where status = 'pending'
     and (auth_uid = uid or lower(email) = em);
  if not found then
    return jsonb_build_object('error', 'not pending');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.save_signup_photos(jsonb) to authenticated;

-- =====================================================================
-- INVITE FIX: create_invite used gen_random_bytes (pgcrypto), which is
-- not visible on every Supabase project, so "Create invite code" crashed
-- with a hidden error. Re-creates the function using built-ins only.
-- =====================================================================
create or replace function public.create_invite()
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  c text;
  n int := 0;
begin
  if not public.is_owner() then
    return jsonb_build_object('error', 'owner only');
  end if;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text || auth.uid()::text), 1, 8));
    exit when not exists (select 1 from public.invites where code = c);
    n := n + 1;
    if n > 50 then return jsonb_build_object('error', 'try again'); end if;
  end loop;
  insert into public.invites (code, role, created_by)
  values (c, 'staff', coalesce(auth.jwt() ->> 'email', 'owner'));
  return jsonb_build_object('ok', true, 'code', c);
end;
$$;
grant execute on function public.create_invite() to authenticated;
