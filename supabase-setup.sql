-- Run this once in Supabase: SQL Editor -> New query -> paste -> Run.

create extension if not exists "pgcrypto";

-- Welders customers can choose from
create table if not exists public.workers (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  phone text not null check (char_length(phone) between 10 and 20),
  specialty text check (char_length(specialty) <= 120),
  available boolean not null default true,
  created_at timestamptz not null default now()
);

-- Build requests sent by customers
create table if not exists public.requests (
  id uuid primary key default gen_random_uuid(),
  ref text not null check (char_length(ref) between 4 and 20),
  created_at timestamptz not null default now(),
  customer_name text not null check (char_length(customer_name) between 2 and 100),
  customer_phone text not null check (char_length(customer_phone) between 10 and 25),
  location text check (char_length(location) <= 200),
  item text not null check (char_length(item) <= 60),
  details jsonb not null default '{}'::jsonb check (pg_column_size(details) < 4000),
  material text check (char_length(material) <= 80),
  finish text check (char_length(finish) <= 80),
  budget text check (char_length(budget) <= 60),
  needed_by text check (char_length(needed_by) <= 60),
  notes text check (char_length(notes) <= 1000),
  photos jsonb not null default '[]'::jsonb,
  worker_id uuid references public.workers(id) on delete set null,
  status text not null default 'New' check (status in ('New','Quoted','In progress','Done')),
  quote_amount text check (char_length(quote_amount) <= 40),
  admin_notes text check (char_length(admin_notes) <= 2000)
);

-- For projects that already created the requests table before photos existed
alter table public.requests add column if not exists photos jsonb not null default '[]'::jsonb;

alter table public.workers enable row level security;
alter table public.requests enable row level security;

-- Anyone can see the basic welder list (name, specialty, availability).
-- Phone numbers, logins and setup codes stay hidden from the public:
-- only the signed-in team can read them.
drop policy if exists "anyone can read workers" on public.workers;
create policy "anyone can read workers" on public.workers
  for select to anon, authenticated using (true);

revoke select on public.workers from anon;
grant select (id, name, specialty, available, phone) on public.workers to anon;

-- Only the signed-in owner can add, edit or remove welders
drop policy if exists "owner manages workers" on public.workers;
create policy "owner manages workers" on public.workers
  for all to authenticated using (true) with check (true);

-- Customers can send a request, but can never read, change or delete any
drop policy if exists "anyone can send a request" on public.requests;
create policy "anyone can send a request" on public.requests
  for insert to anon, authenticated
  with check (status = 'New' and quote_amount is null and admin_notes is null);

-- Only the signed-in owner can read and manage requests
drop policy if exists "owner reads requests" on public.requests;
create policy "owner reads requests" on public.requests
  for select to authenticated using (true);

drop policy if exists "owner updates requests" on public.requests;
create policy "owner updates requests" on public.requests
  for update to authenticated using (true) with check (true);

drop policy if exists "owner deletes requests" on public.requests;
create policy "owner deletes requests" on public.requests
  for delete to authenticated using (true);

-- Job offers: when a customer picks "Any available welder", one row per
-- available welder. The token is the secret accept/decline link sent to them.
create table if not exists public.offers (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.requests(id) on delete cascade,
  worker_id uuid not null references public.workers(id) on delete cascade,
  token text not null unique check (char_length(token) between 16 and 64),
  status text not null default 'open' check (status in ('open','accepted','declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  unique (request_id, worker_id)
);

alter table public.offers enable row level security;

-- The site creates offers right after a customer sends a request
drop policy if exists "anyone can open offers" on public.offers;
create policy "anyone can open offers" on public.offers
  for insert to anon, authenticated
  with check (status = 'open');

-- Only the signed-in owner can list and manage offers
drop policy if exists "owner reads offers" on public.offers;
create policy "owner reads offers" on public.offers
  for select to authenticated using (true);

drop policy if exists "owner updates offers" on public.offers;
create policy "owner updates offers" on public.offers
  for update to authenticated using (true) with check (true);

drop policy if exists "owner deletes offers" on public.offers;
create policy "owner deletes offers" on public.offers
  for delete to authenticated using (true);

-- Welders never log in: they open a secret link. These two functions are the
-- only way an anonymous visitor can read or answer an offer, and they only
-- ever expose the one offer whose token was given.
create or replace function public.get_offer(p_token text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select jsonb_build_object(
    'offer', jsonb_build_object('id', o.id, 'status', o.status),
    'worker', jsonb_build_object('name', w.name),
    'request', jsonb_build_object(
      'ref', r.ref, 'item', r.item, 'details', r.details,
      'material', r.material, 'finish', r.finish, 'budget', r.budget,
      'needed_by', r.needed_by, 'location', r.location, 'notes', r.notes,
      'photos', r.photos
    )
  )
  from public.offers o
  join public.requests r on r.id = o.request_id
  join public.workers w on w.id = o.worker_id
  where o.token = p_token;
$$;

-- First accept wins: if another offer on the same request is already
-- accepted, this one comes back as 'taken'. On accept the request is
-- assigned to this welder.
create or replace function public.respond_offer(p_token text, p_accept boolean)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  o public.offers%rowtype;
  r public.requests%rowtype;
begin
  select * into o from public.offers where token = p_token for update;
  if not found then
    return jsonb_build_object('error', 'not found');
  end if;
  if o.status <> 'open' then
    return jsonb_build_object('error', o.status);
  end if;

  if p_accept then
    perform 1 from public.offers
      where request_id = o.request_id and status = 'accepted' for update;
    if found then
      update public.offers set status = 'declined', responded_at = now()
        where id = o.id returning * into o;
      return jsonb_build_object('error', 'taken');
    end if;
    update public.offers set status = 'accepted', responded_at = now()
      where id = o.id returning * into o;
    update public.requests set worker_id = o.worker_id
      where id = o.request_id returning * into r;
  else
    update public.offers set status = 'declined', responded_at = now()
      where id = o.id returning * into o;
    select * into r from public.requests where id = o.request_id;
  end if;

  return jsonb_build_object(
    'ok', true, 'status', o.status,
    'request', jsonb_build_object(
      'ref', r.ref, 'item', r.item,
      'customer_name', r.customer_name, 'customer_phone', r.customer_phone
    )
  );
end;
$$;

grant execute on function public.get_offer(text) to anon, authenticated;
grant execute on function public.respond_offer(text, boolean) to anon, authenticated;

-- Photos customers attach to a request. Stored in a public bucket: the file
-- path contains the request reference, so the link is effectively unguessable.
insert into storage.buckets (id, name, public)
  values ('request-photos', 'request-photos', true)
  on conflict (id) do nothing;

drop policy if exists "anyone can upload request photos" on storage.objects;
create policy "anyone can upload request photos" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'request-photos');

drop policy if exists "anyone can view request photos" on storage.objects;
create policy "anyone can view request photos" on storage.objects
  for select to anon, authenticated
  using (bucket_id = 'request-photos');

create index if not exists requests_created_idx on public.requests (created_at desc);
create index if not exists requests_status_idx on public.requests (status);

-- =====================================================================
-- ROLES: owner, staff, welder
-- Run the whole file again in the SQL Editor after saving. Safe to re-run.
-- =====================================================================

-- A welder can sign in, so each welder row can be tied to a login.
alter table public.workers add column if not exists auth_uid uuid;
alter table public.workers add column if not exists login_email text;
alter table public.workers add column if not exists account_status text not null default 'none'
  check (account_status in ('none','pending','active'));

-- Each welder row gets a 6-digit setup code. The owner reads it out to the
-- welder; the welder must type it to claim the row. This stops a stranger
-- from taking over a welder slot just by knowing the phone number.
alter table public.workers add column if not exists claim_pin text
  default lpad(floor(random() * 1000000)::int::text, 6, '0');
update public.workers
   set claim_pin = lpad(floor(random() * 1000000)::int::text, 6, '0')
 where claim_pin is null;

-- The people who run the site. The two original logins are the owners.
create table if not exists public.team_members (
  email text primary key check (char_length(email) between 3 and 200),
  role text not null check (role in ('owner','staff')),
  auth_uid uuid,
  created_at timestamptz not null default now(),
  created_by text
);

-- One-time codes an owner gives to a new staff member.
create table if not exists public.invites (
  code text primary key check (char_length(code) between 6 and 24),
  role text not null default 'staff' check (role in ('owner','staff')),
  created_at timestamptz not null default now(),
  created_by text,
  used_by uuid,
  used_at timestamptz
);

-- Welders who tried to sign up before the workshop added their number.
create table if not exists public.welder_signups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  phone text not null check (char_length(phone) between 10 and 20),
  email text not null,
  auth_uid uuid,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now(),
  reviewed_by text,
  reviewed_at timestamptz
);

alter table public.team_members enable row level security;
alter table public.invites enable row level security;
alter table public.welder_signups enable row level security;

create index if not exists workers_auth_uid_idx on public.workers (auth_uid);
create index if not exists workers_login_email_idx on public.workers (lower(login_email));
create index if not exists welder_signups_status_idx on public.welder_signups (status, created_at desc);

-- ---------------------------------------------------------------------
-- my_role(): what is this signed-in person? Owners and staff are matched
-- by their login email, which is inside the signed-in token. The first
-- time a listed email signs in, their account is tied to the row so it
-- cannot be taken over by someone else signing up with the same name.
-- NOTE: deliberately NOT "stable" - it performs the binding update on
-- first login, and Postgres rejects writes in non-volatile functions.
-- ---------------------------------------------------------------------
create or replace function public.my_role()
returns text
language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  em text := lower(coalesce(auth.jwt() ->> 'email', ''));
  r public.team_members%rowtype;
begin
  if uid is null then return null; end if;
  select * into r from public.team_members where auth_uid = uid limit 1;
  if found then return r.role; end if;
  if em = '' then return null; end if;
  select * into r from public.team_members where lower(email) = em and auth_uid is null limit 1;
  if found then
    update public.team_members set auth_uid = uid where email = r.email;
    return r.role;
  end if;
  return null;
end;
$$;

create or replace function public.is_owner()
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.my_role(), '') = 'owner' $$;

-- coalesce() matters: my_role() returns NULL for outsiders, and
-- "if not is_owner()" would evaluate to NULL (= skipped) in plpgsql,
-- which would let ANY signed-in user pass the owner-only checks.
create or replace function public.is_team()
returns boolean language sql stable security definer set search_path = public
as $$ select coalesce(public.my_role(), '') in ('owner','staff') $$;

-- Which worker row belongs to the signed-in welder (0 if none).
create or replace function public.my_worker_id()
returns uuid language sql stable security definer set search_path = public
as $$
  select id from public.workers
   where auth_uid = auth.uid()
      or (auth_uid is null and login_email is not null
          and lower(login_email) = lower(coalesce(auth.jwt() ->> 'email','')))
   limit 1;
$$;

grant execute on function public.my_role() to anon, authenticated;
grant execute on function public.is_owner() to anon, authenticated;
grant execute on function public.is_team() to anon, authenticated;
grant execute on function public.my_worker_id() to anon, authenticated;

-- ---------------------------------------------------------------------
-- Lock the doors: the old rules let ANY signed-in person change
-- everything. Welders can now sign in, so this has to be tightened.
-- ---------------------------------------------------------------------
drop policy if exists "owner manages workers" on public.workers;
drop policy if exists "anyone can read workers" on public.workers;
drop policy if exists "public reads basic workers" on public.workers;
drop policy if exists "team reads workers" on public.workers;
drop policy if exists "team manages workers" on public.workers;
drop policy if exists "welder updates own record" on public.workers;
drop policy if exists "owner reads requests" on public.requests;
drop policy if exists "team reads requests" on public.requests;
drop policy if exists "owner updates requests" on public.requests;
drop policy if exists "team updates requests" on public.requests;
drop policy if exists "owner deletes requests" on public.requests;
drop policy if exists "owner reads offers" on public.offers;
drop policy if exists "team and own offers read" on public.offers;
drop policy if exists "owner updates offers" on public.offers;
drop policy if exists "team updates offers" on public.offers;
drop policy if exists "owner deletes offers" on public.offers;
drop policy if exists "team members read" on public.team_members;
drop policy if exists "owner manages team" on public.team_members;
drop policy if exists "owner manages invites" on public.invites;
drop policy if exists "welder signs up" on public.welder_signups;
drop policy if exists "welder reads own signup" on public.welder_signups;
drop policy if exists "owner reviews signups" on public.welder_signups;

create policy "team manages workers" on public.workers
  for all to authenticated
  using (public.is_team()) with check (public.is_team());

create policy "public reads basic workers" on public.workers
  for select to anon using (true);

create policy "team reads workers" on public.workers
  for select to authenticated
  using (public.is_team() or auth_uid = auth.uid());

drop policy if exists "welder updates own record" on public.workers;
create policy "welder updates own record" on public.workers
  for update to authenticated
  using (auth_uid = auth.uid()) with check (auth_uid = auth.uid());

drop policy if exists "owner reads requests" on public.requests;
create policy "team reads requests" on public.requests
  for select to authenticated
  using (public.is_team() or id in (
    select request_id from public.offers where worker_id = public.my_worker_id()));

drop policy if exists "owner updates requests" on public.requests;
create policy "team updates requests" on public.requests
  for update to authenticated
  using (public.is_team()) with check (public.is_team());

drop policy if exists "owner deletes requests" on public.requests;
create policy "owner deletes requests" on public.requests
  for delete to authenticated
  using (public.is_owner());

drop policy if exists "owner reads offers" on public.offers;
create policy "team and own offers read" on public.offers
  for select to authenticated
  using (public.is_team() or worker_id = public.my_worker_id());

drop policy if exists "owner updates offers" on public.offers;
create policy "team updates offers" on public.offers
  for update to authenticated
  using (public.is_team()) with check (public.is_team());

drop policy if exists "owner deletes offers" on public.offers;
create policy "owner deletes offers" on public.offers
  for delete to authenticated
  using (public.is_owner());

-- Owners see every team row; everyone else sees only their own.
drop policy if exists "team members read" on public.team_members;
create policy "team members read" on public.team_members
  for select to authenticated
  using (public.is_owner() or auth_uid = auth.uid()
         or lower(email) = lower(coalesce(auth.jwt() ->> 'email','')));

drop policy if exists "owner manages team" on public.team_members;
create policy "owner manages team" on public.team_members
  for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

drop policy if exists "owner manages invites" on public.invites;
create policy "owner manages invites" on public.invites
  for all to authenticated
  using (public.is_owner()) with check (public.is_owner());

drop policy if exists "welder signs up" on public.welder_signups;
create policy "welder signs up" on public.welder_signups
  for insert to authenticated
  with check (status = 'pending' and auth_uid = auth.uid());

drop policy if exists "welder reads own signup" on public.welder_signups;
create policy "welder reads own signup" on public.welder_signups
  for select to authenticated
  using (public.is_owner() or auth_uid = auth.uid()
         or lower(email) = lower(coalesce(auth.jwt() ->> 'email','')));

drop policy if exists "owner reviews signups" on public.welder_signups;
create policy "owner reviews signups" on public.welder_signups
  for update to authenticated
  using (public.is_owner()) with check (public.is_owner());

-- ---------------------------------------------------------------------
-- Welder sign-up. The workshop's WhatsApp number is the key:
--   number already added by staff  -> signed up straight away
--   number not added yet           -> queued for the owner to approve
-- ---------------------------------------------------------------------
create or replace function public.welder_phone_status(p_phone text)
returns jsonb language sql stable security definer set search_path = public
as $$
  select case
    when exists (select 1 from public.workers where phone = p_phone and auth_uid is not null)
      then jsonb_build_object('state', 'in_use')
    when exists (select 1 from public.workers where phone = p_phone)
      then jsonb_build_object('state', 'ready')
    else jsonb_build_object('state', 'unknown')
  end;
$$;

drop function if exists public.finish_welder_setup(text, text);
create or replace function public.finish_welder_setup(p_name text, p_phone text, p_pin text default null)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  em text := lower(coalesce(auth.jwt() ->> 'email', ''));
  w public.workers%rowtype;
  sid uuid;
begin
  if uid is null then
    return jsonb_build_object('error', 'sign_in');
  end if;
  p_name := trim(coalesce(p_name, ''));
  p_phone := trim(coalesce(p_phone, ''));
  p_pin := trim(coalesce(p_pin, ''));
  if char_length(p_name) < 2 then
    return jsonb_build_object('error', 'name');
  end if;
  if p_phone !~ '^[0-9]{10,20}$' then
    return jsonb_build_object('error', 'phone');
  end if;

  -- already tied to a welder record
  select * into w from public.workers where auth_uid = uid limit 1;
  if found then
    return jsonb_build_object('ok', true, 'mode', 'ready', 'worker_id', w.id, 'name', w.name);
  end if;

  -- the workshop already added this number: claim it with the setup code
  select * into w from public.workers where phone = p_phone and auth_uid is null limit 1;
  if found then
    if w.claim_pin is not null and p_pin <> w.claim_pin then
      return jsonb_build_object('error', 'bad_pin');
    end if;
    update public.workers
       set auth_uid = uid, login_email = em, account_status = 'active', claim_pin = null
     where id = w.id returning * into w;
    return jsonb_build_object('ok', true, 'mode', 'claimed', 'worker_id', w.id, 'name', w.name);
  end if;

  -- the number exists but belongs to somebody else
  if exists (select 1 from public.workers where phone = p_phone) then
    return jsonb_build_object('error', 'in_use');
  end if;

  -- not added yet: queue it for the owner
  update public.welder_signups
     set name = p_name, phone = p_phone, email = coalesce(nullif(em, ''), email)
   where auth_uid = uid and status = 'pending'
   returning id into sid;
  if sid is null then
    insert into public.welder_signups (name, phone, email, auth_uid)
    values (p_name, p_phone, coalesce(nullif(em, ''), p_phone || '@welder.local'), uid)
    returning id into sid;
  end if;
  return jsonb_build_object('ok', true, 'mode', 'queued', 'signup_id', sid);
end;
$$;

-- Owner approves a queued welder: that creates their welder record.
create or replace function public.approve_signup(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  s public.welder_signups%rowtype;
  wid uuid;
begin
  if not public.is_owner() then
    return jsonb_build_object('error', 'owner only');
  end if;
  select * into s from public.welder_signups where id = p_id and status = 'pending' for update;
  if not found then
    return jsonb_build_object('error', 'not found');
  end if;
  if exists (select 1 from public.workers where phone = s.phone) then
    update public.welder_signups set status = 'rejected', reviewed_at = now(),
           reviewed_by = coalesce(auth.jwt() ->> 'email', 'owner')
     where id = p_id;
    return jsonb_build_object('error', 'phone exists');
  end if;
  insert into public.workers (name, phone, specialty, available, auth_uid, login_email, account_status)
  values (s.name, s.phone, null, true, s.auth_uid, s.email, 'active')
  returning id into wid;
  update public.welder_signups set status = 'approved', reviewed_at = now(),
         reviewed_by = coalesce(auth.jwt() ->> 'email', 'owner')
   where id = p_id;
  return jsonb_build_object('ok', true, 'worker_id', wid);
end;
$$;

create or replace function public.reject_signup(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_owner() then
    return jsonb_build_object('error', 'owner only');
  end if;
  update public.welder_signups
     set status = 'rejected', reviewed_at = now(),
         reviewed_by = coalesce(auth.jwt() ->> 'email', 'owner')
   where id = p_id and status = 'pending';
  if not found then
    return jsonb_build_object('error', 'not found');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Owner makes a one-time code for a new staff member.
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
    -- Built-in md5/random only: gen_random_bytes needs the pgcrypto
    -- extension, which Supabase may park in a schema we cannot see.
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

-- The new staff member spends the code once, on their own login.
create or replace function public.redeem_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  uid uuid := auth.uid();
  em text := lower(coalesce(auth.jwt() ->> 'email', ''));
  inv public.invites%rowtype;
begin
  if uid is null or em = '' then
    return jsonb_build_object('error', 'sign in first');
  end if;
  if exists (select 1 from public.team_members where lower(email) = em) then
    return jsonb_build_object('error', 'already on the team');
  end if;
  select * into inv from public.invites
   where code = upper(trim(coalesce(p_code, ''))) and used_at is null
   for update;
  if not found then
    return jsonb_build_object('error', 'That code is wrong or already used.');
  end if;
  insert into public.team_members (email, role, auth_uid, created_by)
  values (em, inv.role, uid, coalesce(inv.created_by, 'owner'));
  update public.invites set used_at = now(), used_by = uid where code = inv.code;
  return jsonb_build_object('ok', true, 'role', inv.role);
end;
$$;

grant execute on function public.welder_phone_status(text) to anon, authenticated;
grant execute on function public.finish_welder_setup(text, text, text) to anon, authenticated;
grant execute on function public.approve_signup(uuid) to authenticated;
grant execute on function public.reject_signup(uuid) to authenticated;
grant execute on function public.create_invite() to authenticated;
grant execute on function public.redeem_invite(text) to authenticated;

-- The owner logins. Change these to match yours, then run this file again.
-- To add a second owner later, add another line here and run it once more.
insert into public.team_members (email, role, created_by)
values ('ogiehenifemi@gmail.com', 'owner', 'setup')
on conflict (email) do nothing;

-- =====================================================================
-- NOTIFICATIONS: phone push + live alerts.
-- (Kept in sync with supabase-notify.sql - that file is the one to paste
--  into an already-running project; this block covers fresh installs.)
-- =====================================================================

create table if not exists public.push_subscriptions (
  worker_id uuid not null references public.workers(id) on delete cascade,
  endpoint text primary key,
  subscription jsonb not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;

create table if not exists public.push_log (
  key text primary key,
  created_at timestamptz not null default now()
);
alter table public.push_log enable row level security;

drop policy if exists "welder saves own push sub" on public.push_subscriptions;
create policy "welder saves own push sub"
  on public.push_subscriptions for all to authenticated
  using (worker_id = public.my_worker_id())
  with check (worker_id = public.my_worker_id());

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

create or replace function public.get_push_sub(p_worker uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  select subscription from public.push_subscriptions
   where worker_id = p_worker
   limit 1;
$$;
-- These two are for the push-sending server code only, never for the public.
revoke execute on function public.get_push_sub(uuid) from public, anon, authenticated;
grant execute on function public.get_push_sub(uuid) to service_role;

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
revoke execute on function public.claim_push(text) from public, anon, authenticated;
grant execute on function public.claim_push(text) to service_role;

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
-- MONEY: welder plans and payments
--   free     - listed, receives jobs (family and approved welders)
--   pro      - paid monthly: "Pro" badge and priority in the list
--   featured - paid monthly: gold badge, always first in the list
-- A paid plan stops working when paid_until passes; the welder then
-- disappears from the customer list until they pay again. family_free
-- welders are never charged and never expire.
-- =====================================================================
alter table public.workers add column if not exists plan text not null default 'free'
  check (plan in ('free','pro','featured'));
alter table public.workers add column if not exists paid_until timestamptz;
alter table public.workers add column if not exists family_free boolean not null default false;

create table if not exists public.payments (
  id uuid primary key default gen_random_uuid(),
  worker_id uuid not null references public.workers(id) on delete cascade,
  email text not null default '',
  plan text not null check (plan in ('pro','featured')),
  amount_kobo integer not null check (amount_kobo > 0),
  reference text not null unique,
  status text not null default 'pending' check (status in ('pending','paid','failed')),
  created_at timestamptz not null default now(),
  confirmed_at timestamptz,
  note text
);

alter table public.payments enable row level security;

drop policy if exists "welder records own payment" on public.payments;
create policy "welder records own payment" on public.payments
  for insert to authenticated
  with check (status = 'pending' and worker_id = public.my_worker_id());

drop policy if exists "welder reads own payments" on public.payments;
create policy "welder reads own payments" on public.payments
  for select to authenticated
  using (worker_id = public.my_worker_id() or public.is_team());

drop policy if exists "team manages payments" on public.payments;
create policy "team manages payments" on public.payments
  for update to authenticated
  using (public.is_team()) with check (public.is_team());

-- Prices live here so the website cannot lie about what it charges.
-- pro = 2000 naira, featured = 4000 naira (kobo = naira x 100).
create or replace function public.start_payment(p_plan text)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  wid uuid := public.my_worker_id();
  amt integer;
  ref text;
begin
  if wid is null then
    return jsonb_build_object('error', 'no worker');
  end if;
  amt := case p_plan when 'pro' then 200000 when 'featured' then 400000 else 0 end;
  if amt = 0 then
    return jsonb_build_object('error', 'bad plan');
  end if;
  ref := 'UW-' || substr(md5(random()::text || clock_timestamp()::text), 1, 12);
  insert into public.payments (worker_id, email, plan, amount_kobo, reference)
  values (wid, lower(coalesce(auth.jwt() ->> 'email', '')), p_plan, amt, ref);
  return jsonb_build_object('reference', ref, 'amount_kobo', amt);
end;
$$;
grant execute on function public.start_payment(text) to authenticated;

-- Reporting a transfer only creates the pending row above. Nobody but the
-- owner (approve_payment) or the OPay webhook (service role) may mark money
-- as received, so this old self-serve function is removed if it exists.
drop function if exists public.finish_payment(text);

-- Customers need the plan and expiry to order the list and hide lapsed welders.
revoke select on public.workers from anon;
grant select (id, name, specialty, available, phone, plan, paid_until) on public.workers to anon;

-- =====================================================================
-- OWNER DECIDES: only the workshop ever switches a welder's plan on.
-- =====================================================================

-- The owner ticks a payment off in the Money tab - the plan goes live
-- for 30 days from today. Staff can approve too; customers cannot.
create or replace function public.approve_payment(p_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  p public.payments%rowtype;
begin
  if not public.is_team() then
    return jsonb_build_object('error', 'staff only');
  end if;
  select * into p from public.payments where id = p_id for update;
  if not found then
    return jsonb_build_object('error', 'not found');
  end if;
  if p.status = 'failed' then
    return jsonb_build_object('error', 'failed');
  end if;
  update public.payments
     set status = 'paid',
         confirmed_at = coalesce(confirmed_at, now()),
         note = 'approved by ' || coalesce(auth.jwt() ->> 'email', 'the workshop')
   where id = p_id;
  update public.workers
     set plan = p.plan,
         paid_until = greatest(coalesce(paid_until, now()), now()) + interval '30 days'
   where id = p.worker_id;
  return jsonb_build_object('ok', true, 'plan', p.plan);
end;
$$;
grant execute on function public.approve_payment(uuid) to authenticated;

-- Switch any welder's plan by hand from the Welders tab: cash handed in
-- at the workshop, a plan taken away, or a correction.
create or replace function public.set_worker_plan(p_worker uuid, p_plan text)
returns jsonb language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_team() then
    return jsonb_build_object('error', 'staff only');
  end if;
  if p_plan is null or p_plan not in ('free', 'pro', 'featured') then
    return jsonb_build_object('error', 'bad plan');
  end if;
  update public.workers
     set plan = p_plan,
         paid_until = case when p_plan = 'free' then null
                      else greatest(coalesce(paid_until, now()), now()) + interval '30 days'
                      end
   where id = p_worker;
  if not found then
    return jsonb_build_object('error', 'not found');
  end if;
  return jsonb_build_object('ok', true, 'plan', p_plan);
end;
$$;
grant execute on function public.set_worker_plan(uuid, text) to authenticated;
