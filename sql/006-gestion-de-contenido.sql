-- ============================================================
-- Organizadísimos · 006 · Módulo "Gestión de Contenido"
-- ============================================================
-- Centro de trabajo del equipo de contenido: cada pieza es una ficha que viaja
-- por un flujo (Idea → … → Publicado → Archivado) y guarda toda su información,
-- archivos, copy, versiones e historial.
--
-- Módulo INDEPENDIENTE del resto (Tareas, Proyectos). No toca ninguna tabla
-- existente: solo añade tablas nuevas.
--
-- Multi-tenant idéntico al resto: TODO cuelga de account_id y las políticas
-- filtran por current_account_id() exigiendo is_active_user(). Idempotente.

-- ---------- Marcas / clientes (incluye la "memoria de marca") ----------
-- memory jsonb guarda tono, palabras permitidas/prohibidas, avatar, promesa,
-- oferta, CTAs favoritos y colores. La UI de memoria y su uso por la IA llegan
-- en fases posteriores; el contenedor ya existe.
create table if not exists public.content_brands (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  name       text not null default 'Nueva marca',
  memory     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists content_brands_account_idx on public.content_brands(account_id);

-- ---------- Contenido: la ficha central ----------
-- copy jsonb reúne todos los textos ({principal, cta, hashtags, first_comment,
-- youtube, tiktok, facebook}). El estado sigue el flujo del módulo; format
-- alimenta los indicadores del dashboard (reels, shorts, carruseles…).
create table if not exists public.content_items (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts(id) on delete cascade,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  brand_id    uuid references public.content_brands(id) on delete set null,
  name        text not null default 'Nuevo contenido',
  client      text,
  platform    text,
  format      text not null default 'reel'
                check (format in ('reel','short','carrusel','historia','video','imagen','otro')),
  status      text not null default 'idea'
                check (status in ('idea','guion','grabacion','edicion','revision',
                                  'correcciones','aprobado','programado','publicado','archivado')),
  responsible text,
  category    text,
  objective   text,
  offer       text,
  avatar      text,
  hook        text,
  cta         text,
  copy        jsonb not null default '{}'::jsonb,
  publish_at  date,
  position    int  not null default 0,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists content_items_account_idx on public.content_items(account_id);
create index if not exists content_items_status_idx  on public.content_items(status);
create index if not exists content_items_pub_idx     on public.content_items(publish_at);
create index if not exists content_items_brand_idx   on public.content_items(brand_id);

-- ---------- Archivos de cada contenido ----------
-- url apunta a Supabase Storage (bucket 'content') o a un enlace externo
-- (Drive, Dropbox…). storage_path se rellena solo cuando el archivo vive en
-- nuestro bucket, para poder borrarlo.
create table if not exists public.content_files (
  id           uuid primary key default gen_random_uuid(),
  content_id   uuid not null references public.content_items(id) on delete cascade,
  account_id   uuid not null references public.accounts(id) on delete cascade,
  kind         text not null default 'otro',
  name         text not null default '',
  url          text,
  storage_path text,
  size         bigint,
  created_by   uuid references auth.users(id) on delete set null,
  created_at   timestamptz not null default now()
);
create index if not exists content_files_content_idx on public.content_files(content_id);

-- ---------- Versiones del copy ----------
-- Cada snapshot importante del copy: n incremental + el copy completo + nota.
create table if not exists public.content_versions (
  id         uuid primary key default gen_random_uuid(),
  content_id uuid not null references public.content_items(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  n          int  not null default 1,
  copy       jsonb not null default '{}'::jsonb,
  note       text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists content_versions_content_idx on public.content_versions(content_id, n desc);

-- ---------- Historial (línea de tiempo automática) ----------
create table if not exists public.content_log (
  id         uuid primary key default gen_random_uuid(),
  content_id uuid not null references public.content_items(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  action     text not null default '',
  detail     text,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists content_log_content_idx on public.content_log(content_id, created_at desc);

-- ---------- Bibliotecas reutilizables (hooks, CTAs, ofertas, ideas) ----------
create table if not exists public.content_library (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  brand_id   uuid references public.content_brands(id) on delete set null,
  kind       text not null default 'idea' check (kind in ('hook','cta','offer','idea')),
  text       text not null default '',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists content_library_account_idx on public.content_library(account_id, kind);

-- ---------- Automatizaciones (estructura preparada, SIN motor) ----------
-- Se define ahora para poder implementar más adelante reglas como
-- "editor termina → En revisión". Por ahora solo almacena la definición.
create table if not exists public.content_automations (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  name       text not null default '',
  trigger    text,
  action     text,
  enabled    boolean not null default false,
  config     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists content_automations_account_idx on public.content_automations(account_id);

-- ---------- RLS: mismo aislamiento estricto que el resto ----------
do $$
declare t text;
begin
  foreach t in array array['content_brands','content_items','content_files',
                           'content_versions','content_log','content_library','content_automations'] loop
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
