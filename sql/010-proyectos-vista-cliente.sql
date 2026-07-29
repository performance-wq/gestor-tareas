-- ============================================================
-- Organizadísimos · 010 · Proyectos: datos de cliente y vista pública
-- ============================================================
-- SOLO añade columnas y una función (idempotente). No borra ni cambia datos.
-- La vista pública del cliente NO usa las tablas directamente: se sirve por una
-- función security definer que devuelve unicamente los campos permitidos, de
-- modo que la separación interna/pública es a nivel de DATOS, no de CSS.

-- ---------- projects: datos del cliente + configuración del enlace ----------
alter table public.projects add column if not exists client         text;
alter table public.projects add column if not exists niche          text;
alter table public.projects add column if not exists start_date     date;
alter table public.projects add column if not exists end_date       date;
alter table public.projects add column if not exists public_token   text;
alter table public.projects add column if not exists public_enabled boolean not null default false;
alter table public.projects add column if not exists public_show    jsonb not null
  default '{"niche":true,"dates":true,"completed":true,"pending":true,"pct_task":true}'::jsonb;
create unique index if not exists projects_public_token_idx on public.projects(public_token) where public_token is not null;

-- Estados del proyecto pedidos: activo, pausado, finalizado, inactivo, archivado.
-- Se conservan los antiguos por compatibilidad con filas ya guardadas.
alter table public.projects drop constraint if exists projects_status_check;
alter table public.projects add constraint projects_status_check
  check (status in ('active','paused','done','inactive','archived','pending','on_hold','cancelled'));

-- ---------- Visibilidad para el cliente en fases y tareas ----------
alter table public.project_areas add column if not exists client_visible boolean not null default true;
alter table public.project_tasks add column if not exists client_visible boolean not null default true;

-- Estado de tarea: se añade 'paused' (— Pausado).
alter table public.project_tasks drop constraint if exists project_tasks_status_check;
alter table public.project_tasks add constraint project_tasks_status_check
  check (status in ('pending','in_progress','done','paused'));

-- ---------- Función pública de solo lectura ----------
-- Devuelve solo lo permitido para un token válido y activo. Excluye por
-- completo (no solo visualmente) las fases y tareas ocultas y todos sus
-- descendientes, y nunca expone descripciones, responsables ni notas internas.
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
    -- Nivel raíz: tareas sin padre, visibles y cuya fase (si tiene) es visible.
    select t.id, t.area_id, t.parent_id, t.name, t.status, t.position
      from public.project_tasks t
      left join public.project_areas a on a.id = t.area_id
      where t.project_id = proj.id and t.parent_id is null and t.client_visible
        and (t.area_id is null or a.client_visible)
    union all
    -- Descendientes: solo si su padre ya está en el conjunto visible.
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
              from vis)
  ) into res;
  return res;
end $$;

grant execute on function public.public_project(text) to anon, authenticated;
