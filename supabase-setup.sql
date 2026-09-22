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

-- Anyone can see the list of welders (name, number, availability)
drop policy if exists "anyone can read workers" on public.workers;
create policy "anyone can read workers" on public.workers
  for select to anon, authenticated using (true);

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
