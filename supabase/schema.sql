-- Supabase schema voor QualityControl app

create extension if not exists "pgcrypto";


-- Types -----------------------------------------------------------------

do $$
begin
  if not exists (
    select 1 from pg_type where typname = 'qc_status'
  ) then
    create type public.qc_status as enum (
      'GOEDGEKEURD',
      'AFGEKEURD',
      'GOED NA AFKEUR'
    );
  end if;
end;
$$;

-- Tabellen --------------------------------------------------------------

create table if not exists public.qc_record (
  id uuid primary key default gen_random_uuid(),
  serial text not null,
  worker_initials text not null,
  status public.qc_status not null,
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
  count(*) filter (where status = 'GOEDGEKEURD'::public.qc_status) as ok,
  count(*) filter (where status = 'AFGEKEURD'::public.qc_status) as nok,
  count(*) filter (where status = 'GOED NA AFKEUR'::public.qc_status) as rework
from public.qc_record
group by worker_initials;

-- Functie ---------------------------------------------------------------

drop function if exists public.qc_insert_record_with_photos(text, text, text, text, date, text[]);
drop function if exists public.qc_insert_record_with_photos(text, text, public.qc_status, text, date, jsonb);

create function public.qc_insert_record_with_photos(
  p_serial text,
  p_worker_initials text,
  p_status public.qc_status,
  p_description text,
  p_qc_date date,
  p_photo_paths jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  new_id uuid;
begin
  insert into public.qc_record (serial, worker_initials, status, description, qc_date)
  values (p_serial, p_worker_initials, p_status, nullif(p_description, ''), coalesce(p_qc_date, current_date))
  returning id into new_id;

  if p_photo_paths is not null and jsonb_typeof(p_photo_paths) = 'array' then
    insert into public.qc_photo (record_id, storage_path)
    select new_id, value
    from jsonb_array_elements_text(p_photo_paths);
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

-- Storage bucket -------------------------------------------------------

insert into storage.buckets (id, name, public)
values ('qc-photos', 'qc-photos', true)
on conflict (id) do update set public = excluded.public;

do $$
begin
  begin
    execute 'alter table if exists storage.objects enable row level security';
  exception
    when insufficient_privilege then
      raise notice 'Skipping enabling RLS on storage.objects due to insufficient privileges.';
  end;

  begin
    if not exists (
      select 1
      from pg_policies
      where schemaname = 'storage'
        and tablename = 'objects'
        and policyname = 'Allow anon read qc-photos'
    ) then
      execute $$create policy "Allow anon read qc-photos" on storage.objects
        for select
        using (bucket_id = 'qc-photos')$$;
    end if;
  exception
    when insufficient_privilege then
      raise notice 'Skipping creation of read policy on storage.objects due to insufficient privileges.';
  end;

  begin
    if not exists (
      select 1
      from pg_policies
      where schemaname = 'storage'
        and tablename = 'objects'
        and policyname = 'Allow anon insert qc-photos'
    ) then
      execute $$create policy "Allow anon insert qc-photos" on storage.objects
        for insert
        with check (bucket_id = 'qc-photos')$$;
    end if;
  exception
    when insufficient_privilege then
      raise notice 'Skipping creation of insert policy on storage.objects due to insufficient privileges.';
  end;
end;
$$;

