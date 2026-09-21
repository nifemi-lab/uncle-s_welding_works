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
  worker_id uuid references public.workers(id) on delete set null,
  status text not null default 'New' check (status in ('New','Quoted','In progress','Done')),
  quote_amount text check (char_length(quote_amount) <= 40),
  admin_notes text check (char_length(admin_notes) <= 2000)
);

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

create index if not exists requests_created_idx on public.requests (created_at desc);
create index if not exists requests_status_idx on public.requests (status);
