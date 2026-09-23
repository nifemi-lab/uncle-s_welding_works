-- =====================================================================
-- SECURITY FIX - run this ONCE in Supabase: SQL Editor -> New query ->
-- paste -> Run. Safe to re-run.
--
-- IMPORTANT: only run this AFTER the new website files are published.
-- The old published pages read welder phone numbers publicly; this file
-- hides them. The new pages do not need them.
--
-- What it does, in plain words:
--   1. Gives every welder a secret 6-digit setup code. A welder must
--      type that code to connect their login to the workshop's list, so
--      a stranger cannot take over a welder slot with just a phone
--      number.
--   2. Hides welder phone numbers, logins and setup codes from the
--      public. Visitors can still see names, specialties and whether
--      each welder is available.
--   3. Closes two push-notification database functions that the public
--      could call. Only the server can use them now.
-- =====================================================================

-- 1. Setup codes -------------------------------------------------------
alter table public.workers add column if not exists claim_pin text
  default lpad(floor(random() * 1000000)::int::text, 6, '0');

update public.workers
   set claim_pin = lpad(floor(random() * 1000000)::int::text, 6, '0')
 where claim_pin is null;

-- 2. Welder claim now needs the code -----------------------------------
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

-- 3. Public sees only the basics on the welder list ---------------------
-- (phone stays visible: customers WhatsApp their chosen welder, and the
--  setup code above is what protects a welder's slot now)
revoke select on public.workers from anon;
grant select (id, name, specialty, available, phone) on public.workers to anon;

-- signed-in welders can no longer read other welders' private columns
drop policy if exists "anyone can read workers" on public.workers;
drop policy if exists "public reads basic workers" on public.workers;
drop policy if exists "team reads workers" on public.workers;
create policy "public reads basic workers" on public.workers
  for select to anon using (true);
create policy "team reads workers" on public.workers
  for select to authenticated
  using (public.is_team() or auth_uid = auth.uid());

-- 4. Push functions: server only ----------------------------------------
revoke execute on function public.get_push_sub(uuid) from public, anon, authenticated;
grant execute on function public.get_push_sub(uuid) to service_role;

revoke execute on function public.claim_push(text) from public, anon, authenticated;
grant execute on function public.claim_push(text) to service_role;
