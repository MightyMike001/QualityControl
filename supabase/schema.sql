-- Supabase schema voor QualityControl app

create extension if not exists "pgcrypto";

-- Tabellen --------------------------------------------------------------

create table if not exists public.qc_record (
  id uuid primary key default gen_random_uuid(),
  serial text not null,
  worker_initials text not null,
  status text not null,
  description text,
  qc_date date not null default current_date,
  created_at timestamptz not null default now()
);

create table if not exists public.qc_photo (
  id uuid primary key default gen_random_uuid(),
  record_id uuid not null references public.qc_record(id) on delete cascade,
  storage_path text not null,
  created_at timestamptz not null default now()
);

-- View ------------------------------------------------------------------

create or replace view public.v_qc_worker_stats as
select
  worker_initials,
  count(*) as total,
  count(*) filter (where status = 'GOEDGEKEURD') as ok,
  count(*) filter (where status = 'AFGEKEURD') as nok,
  count(*) filter (where status = 'GOED NA AFKEUR') as rework
from public.qc_record
group by worker_initials;

-- Functie ---------------------------------------------------------------

create or replace function public.qc_insert_record_with_photos(
  p_serial text,
  p_worker_initials text,
  p_status text,
  p_description text,
  p_qc_date date,
  p_photo_paths text[]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
  path text;
begin
  insert into public.qc_record (serial, worker_initials, status, description, qc_date)
  values (p_serial, p_worker_initials, p_status, nullif(p_description, ''), coalesce(p_qc_date, current_date))
  returning id into new_id;

  if array_length(p_photo_paths, 1) is not null then
    foreach path in array p_photo_paths loop
      insert into public.qc_photo (record_id, storage_path)
      values (new_id, path);
    end loop;
  end if;

  return new_id;
end;
$$;

-- RLS -------------------------------------------------------------------

alter table public.qc_record enable row level security;
alter table public.qc_photo enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'qc_record'
      and policyname = 'Allow anon read qc_record'
  ) then
    create policy "Allow anon read qc_record" on public.qc_record
      for select using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'qc_record'
      and policyname = 'Allow anon insert qc_record'
  ) then
    create policy "Allow anon insert qc_record" on public.qc_record
      for insert with check (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'qc_photo'
      and policyname = 'Allow anon read qc_photo'
  ) then
    create policy "Allow anon read qc_photo" on public.qc_photo
      for select using (true);
  end if;

  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'qc_photo'
      and policyname = 'Allow anon insert qc_photo'
  ) then
    create policy "Allow anon insert qc_photo" on public.qc_photo
      for insert with check (true);
  end if;
end;
$$;

-- Opmerking: maak een storage bucket 'qc-photos' en sta public read toe via policies.
