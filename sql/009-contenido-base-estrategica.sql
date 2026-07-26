-- ============================================================
-- Organizadísimos · 009 · Contenido: base estratégica y relaciones
-- ============================================================
-- SOLO añade tablas y columnas (idempotente). No borra ni cambia datos.
-- Multi-tenant idéntico: todo cuelga de account_id + brand_id, RLS por
-- current_account_id() con is_active_user().

-- ---------- Datos del proyecto (marca): contacto, nicho, descripción ----------
alter table public.content_brands add column if not exists contact     text;
alter table public.content_brands add column if not exists niche       text;
alter table public.content_brands add column if not exists description text;

-- ---------- Base estratégica: avatares ----------
create table if not exists public.content_avatars (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts(id) on delete cascade,
  brand_id    uuid not null references public.content_brands(id) on delete cascade,
  name        text not null default 'Nuevo avatar',
  description text, pains text, desires text, objections text,
  awareness   text, features text, notes text,
  is_default  boolean not null default false,
  archived    boolean not null default false,
  position    int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists content_avatars_brand_idx on public.content_avatars(brand_id);

-- ---------- Base estratégica: productos / servicios ----------
create table if not exists public.content_products (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts(id) on delete cascade,
  brand_id    uuid not null references public.content_brands(id) on delete cascade,
  name        text not null default 'Nuevo producto',
  description text, benefit text, features text, price text, notes text,
  archived    boolean not null default false,
  position    int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists content_products_brand_idx on public.content_products(brand_id);

-- ---------- Base estratégica: ofertas y variantes ----------
create table if not exists public.content_offers (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts(id) on delete cascade,
  brand_id    uuid not null references public.content_brands(id) on delete cascade,
  product_id  uuid references public.content_products(id) on delete set null,
  name        text not null default 'Nueva oferta',
  promise text, benefits text, bonuses text, price text, guarantee text,
  objections text, cta text, notes text,
  archived    boolean not null default false,
  position    int not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists content_offers_brand_idx on public.content_offers(brand_id);

-- ---------- Historial de cambios de la base estratégica ----------
create table if not exists public.content_strategy_log (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts(id) on delete cascade,
  brand_id    uuid not null references public.content_brands(id) on delete cascade,
  entity_type text not null default '',   -- avatar | product | offer
  entity_id   uuid,
  entity_name text,
  action      text not null default '',   -- creó | editó | duplicó | archivó | eliminó
  before      jsonb,
  after       jsonb,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);
create index if not exists content_strategy_log_brand_idx on public.content_strategy_log(brand_id, created_at desc);

-- ---------- content_items: relaciones y campos múltiples ----------
alter table public.content_items add column if not exists avatar_id  uuid references public.content_avatars(id)  on delete set null;
alter table public.content_items add column if not exists product_id uuid references public.content_products(id) on delete set null;
alter table public.content_items add column if not exists offer_id   uuid references public.content_offers(id)   on delete set null;
alter table public.content_items add column if not exists angles     jsonb not null default '[]'::jsonb;  -- varios ángulos
alter table public.content_items add column if not exists platforms  jsonb not null default '[]'::jsonb;  -- plataformas adicionales
alter table public.content_items add column if not exists is_ad      boolean not null default false;      -- orgánico vs anuncio
alter table public.content_items add column if not exists verdict    text;                                -- funciono | medias | no

-- ---------- RLS de las tablas nuevas ----------
do $$
declare t text;
begin
  foreach t in array array['content_avatars','content_products','content_offers','content_strategy_log'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I_tenant on public.%I', t, t);
    execute format($f$
      create policy %I_tenant on public.%I
        for all
        using (public.is_active_user() and account_id = public.current_account_id())
        with check (public.is_active_user() and account_id = public.current_account_id())
    $f$, t, t);
  end loop;
end $$;
