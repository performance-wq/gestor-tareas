-- ============================================================
-- Organizadísimos · 005 · Estados del proyecto
-- ============================================================
-- Amplía projects.status para la gestión visual del módulo de Proyectos:
-- active (Activo), pending (Pendiente), on_hold (En espera),
-- done (Finalizado), cancelled (Cancelado). Se conserva 'archived' por si
-- alguna fila antigua lo usara. Idempotente.

alter table public.projects drop constraint if exists projects_status_check;
alter table public.projects
  add constraint projects_status_check
  check (status in ('active','pending','on_hold','done','cancelled','archived'));
