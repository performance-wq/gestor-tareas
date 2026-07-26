-- ============================================================
-- Organizadísimos · 008 · Contenido como biblioteca por proyecto/marca
-- ============================================================
-- Evolución del módulo de Contenido. SOLO añade columnas nuevas (idempotente);
-- no borra ni cambia datos existentes, y las políticas RLS ya cubren las
-- columnas nuevas por estar a nivel de tabla.
--
-- Un "proyecto de contenido" = una marca / cliente / empresa / persona. Se
-- reutiliza content_brands como ese nivel superior, ahora con logo y archivado.

-- ---------- content_brands = proyecto de contenido ----------
alter table public.content_brands add column if not exists image_url text;
alter table public.content_brands add column if not exists archived boolean not null default false;

-- ---------- content_items: guion, ángulo, resultados, evaluación, análisis ----------
-- guion    {hook, body, cta}         -- lo que se DICE en el video
-- results  {views, reach, likes...}  -- métricas manuales por ahora
-- eval     {verdict, funciono, reutilizar, ...}
-- analysis {worked, not_worked, change, why, reuse, adapt, learning}
-- tags     ["etiqueta", ...]
-- El caption/copy sigue en la columna copy jsonb (se le añaden claves nuevas
-- desde el cliente: headline, title, description, instagram — sin migración).
alter table public.content_items add column if not exists guion    jsonb not null default '{}'::jsonb;
alter table public.content_items add column if not exists angle    text;
alter table public.content_items add column if not exists results  jsonb not null default '{}'::jsonb;
alter table public.content_items add column if not exists rating   int;
alter table public.content_items add column if not exists eval     jsonb not null default '{}'::jsonb;
alter table public.content_items add column if not exists analysis jsonb not null default '{}'::jsonb;
alter table public.content_items add column if not exists tags     jsonb not null default '[]'::jsonb;

-- ---------- content_files: orden (para carruseles) ----------
alter table public.content_files add column if not exists position int not null default 0;

-- ---------- content_library: permitir la biblioteca de "ángulos" ----------
alter table public.content_library drop constraint if exists content_library_kind_check;
alter table public.content_library
  add constraint content_library_kind_check
  check (kind in ('hook','cta','offer','idea','angle'));
