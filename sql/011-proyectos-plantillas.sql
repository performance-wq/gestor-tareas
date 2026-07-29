-- ============================================================
-- Organizadísimos · 011 · Proyectos: plantillas e hitos
-- ============================================================
-- SOLO añade tablas y columnas + actualiza la función pública (idempotente).
-- No borra ni cambia datos. Multi-tenant igual que el resto.

-- ---------- projects: plantilla de origen (provenance) ----------
alter table public.projects add column if not exists template text;

-- ---------- project_areas: descripción de la fase ----------
alter table public.project_areas add column if not exists description text;

-- ---------- Hitos por fase ----------
-- Los hitos NO son tareas: no entran en el cálculo de avance (que cuenta hojas).
create table if not exists public.project_milestones (
  id             uuid primary key default gen_random_uuid(),
  project_id     uuid not null references public.projects(id) on delete cascade,
  account_id     uuid not null references public.accounts(id) on delete cascade,
  area_id        uuid references public.project_areas(id) on delete cascade,
  name           text not null default 'Hito',
  achieved       boolean not null default false,
  client_visible boolean not null default true,
  position       int not null default 0,
  created_at     timestamptz not null default now()
);
create index if not exists project_milestones_project_idx on public.project_milestones(project_id);

-- ---------- Plantillas de proyecto (arquitectura para administrar varias) ----------
-- account_id NULL = plantilla global (visible para todas las cuentas). structure
-- es un jsonb con la estructura completa: fases → tareas → subtareas + hito.
create table if not exists public.project_templates (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid references public.accounts(id) on delete cascade,
  key         text,
  name        text not null default 'Nueva plantilla',
  description text,
  structure   jsonb not null default '[]'::jsonb,
  active      boolean not null default true,
  position    int not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists project_templates_acc_idx on public.project_templates(account_id);

-- ---------- RLS ----------
alter table public.project_milestones enable row level security;
drop policy if exists project_milestones_tenant on public.project_milestones;
create policy project_milestones_tenant on public.project_milestones
  for all using (public.is_active_user() and account_id = public.current_account_id())
  with check (public.is_active_user() and account_id = public.current_account_id());

-- Plantillas: se pueden LEER las propias y las globales (account_id null); solo
-- se pueden crear/editar/borrar las propias (las globales las gestiona el admin).
alter table public.project_templates enable row level security;
drop policy if exists project_templates_read on public.project_templates;
create policy project_templates_read on public.project_templates
  for select using (public.is_active_user() and (account_id is null or account_id = public.current_account_id()));
drop policy if exists project_templates_write on public.project_templates;
create policy project_templates_write on public.project_templates
  for all using (public.is_active_user() and account_id = public.current_account_id())
  with check (public.is_active_user() and account_id = public.current_account_id());

-- ---------- Función pública: ahora incluye hitos visibles ----------
create or replace function public.public_project(p_token text)
returns jsonb
language plpgsql
security definer
stable
set search_path = public
as $$
declare proj record; res jsonb;
begin
  if p_token is null or length(p_token) < 8 then return null; end if;
  select * into proj from public.projects where public_token = p_token and public_enabled = true;
  if not found then return null; end if;

  with recursive vis as (
    select t.id, t.area_id, t.parent_id, t.name, t.status, t.position
      from public.project_tasks t
      left join public.project_areas a on a.id = t.area_id
      where t.project_id = proj.id and t.parent_id is null and t.client_visible
        and (t.area_id is null or a.client_visible)
    union all
    select c.id, c.area_id, c.parent_id, c.name, c.status, c.position
      from public.project_tasks c
      join vis v on c.parent_id = v.id
      where c.client_visible
  )
  select jsonb_build_object(
    'project', jsonb_build_object(
      'name', proj.name, 'client', proj.client, 'niche', proj.niche,
      'status', proj.status, 'start_date', proj.start_date, 'updated_at', proj.updated_at,
      'show', proj.public_show
    ),
    'areas', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'position', position) order by position), '[]'::jsonb)
              from public.project_areas where project_id = proj.id and client_visible),
    'tasks', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'area_id', area_id, 'parent_id', parent_id, 'name', name, 'status', status, 'position', position) order by position), '[]'::jsonb)
              from vis),
    'milestones', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'area_id', area_id, 'name', name, 'achieved', achieved, 'position', position) order by position), '[]'::jsonb)
              from public.project_milestones m
              where m.project_id = proj.id and m.client_visible
                and (m.area_id is null or exists (select 1 from public.project_areas a where a.id = m.area_id and a.client_visible)))
  ) into res;
  return res;
end $$;

grant execute on function public.public_project(text) to anon, authenticated;
