-- ============================================================
-- Organizadísimos · 004 · Módulo "Organizador de Proyectos"
-- ============================================================
-- Módulo INDEPENDIENTE del gestor de Tareas (boards/board_members), que no se
-- toca. Tareas = pendientes individuales y rápidos. Organizador = ejecución
-- completa de un proyecto.
--
-- Tres pilares, y nada más: (1) organizar el trabajo, (2) registrar
-- indicadores, (3) documentar cambios. Lo que no sirva a uno de los tres, no
-- se implementa.
--
-- Multi-tenant: TODO cuelga de account_id y las políticas filtran por
-- current_account_id(), igual que boards. Un cliente jamás ve otra empresa.
-- Idempotente: se puede volver a ejecutar sin romper nada.

-- ---------- Proyectos ----------
create table if not exists public.projects (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid not null references public.accounts(id) on delete cascade,
  owner_id    uuid not null references auth.users(id) on delete cascade,
  name        text not null default 'Nuevo proyecto',
  description text,
  status      text not null default 'active' check (status in ('active','done','archived')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists projects_account_idx on public.projects(account_id);

-- ---------- Áreas o fases (Estrategia, Creativos, Landing, Publicidad...) ----------
create table if not exists public.project_areas (
  id         uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  account_id uuid not null references public.accounts(id) on delete cascade,
  name       text not null default 'Nueva área',
  position   int  not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists project_areas_project_idx on public.project_areas(project_id);

-- ---------- Tareas y subtareas ----------
-- parent_id auto-referencial: una subtarea es una tarea con padre. El avance
-- se DERIVA en el cliente (% de subtareas completadas); nunca se persiste,
-- para que no quede inconsistente al agregar o borrar subtareas.
create table if not exists public.project_tasks (
  id               uuid primary key default gen_random_uuid(),
  project_id       uuid not null references public.projects(id) on delete cascade,
  account_id       uuid not null references public.accounts(id) on delete cascade,
  area_id          uuid references public.project_areas(id) on delete set null,
  parent_id        uuid references public.project_tasks(id) on delete cascade,
  name             text not null default '',
  description      text,
  responsible      text,
  priority         text not null default 'medium' check (priority in ('low','medium','high')),
  due_date         date,
  status           text not null default 'pending' check (status in ('pending','in_progress','done')),
  -- Seguimiento OPCIONAL y con indicadores libres: cada tarea define los suyos
  -- ([{id,label,value}]). Por eso jsonb y no columnas fijas.
  tracking_enabled boolean not null default false,
  tracking         jsonb   not null default '[]'::jsonb,
  position         int     not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists project_tasks_project_idx on public.project_tasks(project_id);
create index if not exists project_tasks_area_idx    on public.project_tasks(area_id);
create index if not exists project_tasks_parent_idx  on public.project_tasks(parent_id);

-- ---------- Bitácora de cambios ----------
-- Historial técnico del proyecto, NO un chat ni comentarios.
create table if not exists public.project_log (
  id          uuid primary key default gen_random_uuid(),
  project_id  uuid not null references public.projects(id) on delete cascade,
  account_id  uuid not null references public.accounts(id) on delete cascade,
  entry_date  date not null default current_date,
  area        text not null default '',
  change_text text not null default '',
  reason      text,
  result      text,
  notes       text,
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists project_log_project_idx on public.project_log(project_id, entry_date desc);

-- ---------- RLS: mismo aislamiento estricto que el resto ----------
alter table public.projects      enable row level security;
alter table public.project_areas enable row level security;
alter table public.project_tasks enable row level security;
alter table public.project_log   enable row level security;

do $$
declare t text;
begin
  foreach t in array array['projects','project_areas','project_tasks','project_log'] loop
    execute format('drop policy if exists %I_tenant on public.%I', t, t);
    execute format($f$
      create policy %I_tenant on public.%I
        for all
        using (public.is_active_user() and account_id = public.current_account_id())
        with check (public.is_active_user() and account_id = public.current_account_id())
    $f$, t, t);
  end loop;
end $$;
