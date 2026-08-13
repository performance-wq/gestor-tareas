-- ============================================================
-- Organizadísimos · 015 · Responsables múltiples + visibilidad por usuario
-- ============================================================
-- (1) Arregla el bug de persistencia del responsable: la asignación pasa a una
--     RPC SECURITY DEFINER (antes se escribía la columna `assignee_legacy`, que
--     NO tiene GRANT UPDATE → el write se rechazaba y el valor volvía a
--     "— Sin asignar —").
-- (2) Una tarea puede tener VARIOS responsables (tabla task_assignees).
-- (3) Visibilidad: el admin del proyecto ve TODAS las tareas; el operativo/viewer
--     ve SÓLO donde está asignado (validado en backend por RLS + RPC de carga).
-- (4) Historial de asignaciones; no se pierden las asignaciones actuales.
--
-- Aditivo e idempotente. El editor SQL corre todo en una transacción implícita.

-- ============================================================
-- 1) TABLA task_assignees (relación tarea ↔ usuarios)
-- ============================================================
create table if not exists public.task_assignees (
  task_id    uuid not null references public.task_items(id) on delete cascade,
  user_id    uuid not null references public.profiles(id)   on delete cascade,
  account_id uuid,
  added_by   uuid,
  added_at   timestamptz not null default now(),
  primary key (task_id, user_id)
);
create index if not exists task_assignees_user_idx on public.task_assignees(user_id);
create index if not exists task_assignees_task_idx on public.task_assignees(task_id);
alter table public.task_assignees enable row level security;
revoke all on public.task_assignees from anon;
revoke all on public.task_assignees from authenticated;
grant select on public.task_assignees to authenticated;

-- Helper: ¿ese usuario es responsable de la tarea?
create or replace function public.is_task_assignee(p_task uuid, p_user uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from public.task_assignees where task_id = p_task and user_id = p_user);
$$;

-- RLS: puedes ver una fila de responsables si puedes ver la tarea
-- (admin del proyecto, o eres uno de los responsables → ves a tus co-responsables).
drop policy if exists task_assignees_select on public.task_assignees;
create policy task_assignees_select on public.task_assignees for select using (
  public.is_active_user() and exists (
    select 1 from public.task_items t
    where t.id = task_assignees.task_id
      and (public.can_admin_board(t.board_id, auth.uid()) or public.is_task_assignee(t.id, auth.uid()))
  )
);

-- ============================================================
-- 2) MIGRACIÓN (§19): copiar el responsable único actual a task_assignees
-- ============================================================
insert into public.task_assignees (task_id, user_id, account_id, added_by)
select id, assignee_id, account_id, assignee_id
from public.task_items
where assignee_id is not null
on conflict (task_id, user_id) do nothing;
-- La columna assignee_id se CONSERVA (compat/rollback) pero deja de usarse: el
-- front ya no la escribe, así el trigger de auditoría de assignee_id no dispara.

-- ============================================================
-- 3) VISIBILIDAD: admin ve todo; operativo/viewer sólo lo asignado
-- ============================================================
drop policy if exists task_items_select on public.task_items;
create policy task_items_select on public.task_items for select using (
  public.is_active_user() and (
    public.can_admin_board(board_id, auth.uid())
    or public.is_task_assignee(id, auth.uid())
  )
);

-- Historial: visible para quien pueda ver la tarea.
drop policy if exists task_events_select on public.task_events;
create policy task_events_select on public.task_events for select using (
  public.is_active_user() and exists (
    select 1 from public.task_items t
    where t.id = task_events.task_id
      and (public.can_admin_board(t.board_id, auth.uid()) or public.is_task_assignee(t.id, auth.uid()))
  )
);

-- Carga por rol: el admin recibe todas las tareas del tablero; el operativo
-- recibe sólo las suyas MÁS sus ancestros (para que el árbol/encabezados se
-- rendericen sin exponer tareas ajenas). SECURITY DEFINER: la lógica de
-- ancestros se resuelve aquí y no en la política RLS.
create or replace function public.list_task_items(p_board uuid)
returns setof public.task_items language plpgsql security definer stable set search_path = public as $$
begin
  if not public.is_active_user() then return; end if;
  if public.can_admin_board(p_board, auth.uid()) then
    return query select * from public.task_items where board_id = p_board order by position;
    return;
  end if;
  return query
  with recursive mine as (
    select t.id, t.parent_id from public.task_items t
    where t.board_id = p_board and public.is_task_assignee(t.id, auth.uid())
    union
    select p.id, p.parent_id from public.task_items p
    join mine m on p.id = m.parent_id
  )
  select ti.* from public.task_items ti
  where ti.id in (select id from mine)
  order by ti.position;
end $$;
grant execute on function public.list_task_items(uuid) to authenticated;

-- ============================================================
-- 4) RPC: fijar los responsables de una tarea (dueño o admin de proyecto)
-- ============================================================
-- Reemplaza la escritura directa que causaba el bug. Idempotente: calcula
-- altas/bajas contra lo existente y registra un evento por cada cambio.
create or replace function public.task_set_assignees(p_task uuid, p_users uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_board uuid; v_acc uuid; u uuid; v_added uuid[] := '{}'; v_removed uuid[] := '{}';
begin
  select board_id, account_id into v_board, v_acc from public.task_items where id = p_task;
  if v_board is null then raise exception 'Tarea no encontrada'; end if;
  if not public.can_admin_board(v_board, auth.uid()) then
    raise exception 'Sin permiso para cambiar responsables'; end if;
  p_users := coalesce(p_users, '{}');
  -- Validar: cada usuario debe pertenecer al proyecto (dueño o miembro).
  foreach u in array p_users loop
    if not (public.is_board_owner(v_board, u) or public.is_board_member(v_board, u)) then
      raise exception 'Un usuario seleccionado no pertenece al proyecto';
    end if;
  end loop;
  -- Bajas: los que estaban y ya no vienen en la lista.
  for u in select user_id from public.task_assignees
           where task_id = p_task and not (user_id = any (p_users)) loop
    delete from public.task_assignees where task_id = p_task and user_id = u;
    v_removed := v_removed || u;
    insert into public.task_events (account_id, task_id, actor_id, type, detail)
      values (v_acc, p_task, auth.uid(), 'assignee_removed', jsonb_build_object('user', u));
  end loop;
  -- Altas: los nuevos.
  foreach u in array p_users loop
    if not exists (select 1 from public.task_assignees where task_id = p_task and user_id = u) then
      insert into public.task_assignees (task_id, user_id, account_id, added_by)
        values (p_task, u, v_acc, auth.uid());
      v_added := v_added || u;
      insert into public.task_events (account_id, task_id, actor_id, type, detail)
        values (v_acc, p_task, auth.uid(), 'assignee_added', jsonb_build_object('user', u));
    end if;
  end loop;
  return jsonb_build_object(
    'assignees', (select coalesce(jsonb_agg(user_id), '[]'::jsonb)
                  from public.task_assignees where task_id = p_task),
    'added', to_jsonb(v_added), 'removed', to_jsonb(v_removed));
end $$;
grant execute on function public.task_set_assignees(uuid, uuid[]) to authenticated;

-- ============================================================
-- 5) CICLO DE VIDA: cualquier responsable (o admin) inicia/completa
-- ============================================================
create or replace function public.task_start(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not (public.can_admin_board(t.board_id, auth.uid()) or public.is_task_assignee(t.id, auth.uid())) then
    raise exception 'No eres responsable de esta tarea'; end if;
  update public.task_items set status = 'in_progress',
    started_at = coalesce(started_at, now()), started_by = coalesce(started_by, auth.uid())
  where id = p_id;
end $$;

create or replace function public.task_complete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not (public.can_admin_board(t.board_id, auth.uid()) or public.is_task_assignee(t.id, auth.uid())) then
    raise exception 'No eres responsable de esta tarea'; end if;
  update public.task_items set status = 'completed', completed_at = now(), completed_by = auth.uid()
  where id = p_id;
end $$;

grant execute on function public.is_task_assignee(uuid, uuid) to authenticated;
