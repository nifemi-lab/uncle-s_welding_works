-- =====================================================================
-- DATABASE UPDATE - run this ONCE in Supabase: SQL Editor -> New query ->
-- paste -> Run. Safe to re-run. If you already ran supabase-fix.sql, that
-- is fine - this file contains everything fix did, plus the money tables.
--
-- In plain words it:
--   1. closes the old security holes (setup codes, hidden private
--      columns, locked push functions) - same as supabase-fix.sql;
--   2. adds welder PLANS (free / pro / featured) with a paid-until date
--      and a "family, never charge" flag;
--   3. adds a PAYMENTS book where every payment report is written, so
--      the owner can see and check each one in the Money tab.
-- =====================================================================

-- 1. Setup codes -------------------------------------------------------
alter table public.workers add column if not exists claim_pin text
  default lpad(floor(random() * 1000000)::int::text, 6, '0');

update public.workers
   set claim_pin = lpad(floor(random() * 1000000)::int::text, 6, '0')
 where claim_pin is null;

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

  select * into w from public.workers where auth_uid = uid limit 1;
  if found then
    return jsonb_build_object('ok', true, 'mode', 'ready', 'worker_id', w.id, 'name', w.name);
  end if;

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

  if exists (select 1 from public.workers where phone = p_phone) then
    return jsonb_build_object('error', 'in_use');
  end if;

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

grant execute on function public.finish_welder_setup(text, text, text) to anon, authenticated;

-- push functions: server only
revoke execute on function public.get_push_sub(uuid) from public, anon, authenticated;
grant execute on function public.get_push_sub(uuid) to service_role;
revoke execute on function public.claim_push(text) from public, anon, authenticated;
grant execute on function public.claim_push(text) to service_role;

-- 2. Money: plans on each welder ----------------------------------------
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

-- 3. Who the public may see ---------------------------------------------
-- Customers see the basics plus plan and paid-until (the site needs them
-- to order the list and hide lapsed welders). Everything else - setup
-- codes, logins - stays with the signed-in team only.
revoke select on public.workers from anon;
grant select (id, name, specialty, available, phone, plan, paid_until) on public.workers to anon;

drop policy if exists "anyone can read workers" on public.workers;
drop policy if exists "public reads basic workers" on public.workers;
drop policy if exists "team reads workers" on public.workers;
create policy "public reads basic workers" on public.workers
  for select to anon using (true);
create policy "team reads workers" on public.workers
  for select to authenticated
  using (public.is_team() or auth_uid = auth.uid());

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
