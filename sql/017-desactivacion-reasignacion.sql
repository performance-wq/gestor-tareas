-- ============================================================
-- Organizadísimos · 017 · Desactivar/eliminar usuario con reasignación
-- ============================================================
-- §14-16/§24: al desactivar (o eliminar lógicamente) a un usuario:
--   · se puede REASIGNAR sus tareas ACTIVAS a otro usuario ANTES,
--   · NO se borra nada (tareas, historial, fechas, autoría se conservan),
--   · un usuario inactivo no puede recibir NUEVAS asignaciones.
-- Aditivo e idempotente. Solo el dueño de plataforma usa las RPCs admin_*.

-- ------------------------------------------------------------
-- 1) Actividad de un usuario (para decidir y para el aviso del panel)
-- ------------------------------------------------------------
create or replace function public.admin_user_activity(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_active int; v_completed int; v_total int; v_owned int;
begin
  if not public.is_platform_owner() then raise exception 'Solo el administrador'; end if;
  select count(*) into v_total from public.task_assignees where user_id = p_user;
  select count(*) into v_active from public.task_assignees ta
    join public.task_items t on t.id = ta.task_id
    where ta.user_id = p_user and t.status in ('pending','in_progress');
  select count(*) into v_completed from public.task_assignees ta
    join public.task_items t on t.id = ta.task_id
    where ta.user_id = p_user and t.status in ('completed','archived');
  select count(*) into v_owned from public.boards where owner_id = p_user;
  return jsonb_build_object('active', v_active, 'completed', v_completed,
                            'total', v_total, 'owned_boards', v_owned);
end $$;

-- ------------------------------------------------------------
-- 2) Reasignar las tareas ACTIVAS de un usuario a otro (antes de desactivar).
--    Conserva el historial: agrega al nuevo y quita al anterior SOLO de las
--    tareas activas; las completadas/archivadas NO se tocan. Registra eventos.
-- ------------------------------------------------------------
create or replace function public.admin_reassign_user_tasks(p_from uuid, p_to uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r record; v_n int := 0; v_to_status text;
begin
  if not public.is_platform_owner() then raise exception 'Solo el administrador'; end if;
  if p_from = p_to then raise exception 'Elige un usuario distinto'; end if;
  select coalesce(status,'active') into v_to_status from public.profiles where id = p_to;
  if not found then raise exception 'Usuario destino no encontrado'; end if;
  if v_to_status <> 'active' then raise exception 'El usuario destino debe estar activo'; end if;
  for r in
    select ta.task_id, t.board_id, t.account_id
    from public.task_assignees ta
    join public.task_items t on t.id = ta.task_id
    where ta.user_id = p_from and t.status in ('pending','in_progress')
  loop
    -- El destino debe poder ver la tarea: asegurar membresía en el tablero.
    if not (public.is_board_owner(r.board_id, p_to) or public.is_board_member(r.board_id, p_to)) then
      insert into public.board_members(board_id, user_id, role) values (r.board_id, p_to, 'member')
        on conflict (board_id, user_id) do nothing;
    end if;
    if not exists (select 1 from public.task_assignees where task_id = r.task_id and user_id = p_to) then
      insert into public.task_assignees(task_id, user_id, account_id, added_by)
        values (r.task_id, p_to, r.account_id, auth.uid());
      insert into public.task_events(account_id, task_id, actor_id, type, detail)
        values (r.account_id, r.task_id, auth.uid(), 'assignee_added', jsonb_build_object('user', p_to));
    end if;
    delete from public.task_assignees where task_id = r.task_id and user_id = p_from;
    insert into public.task_events(account_id, task_id, actor_id, type, detail)
      values (r.account_id, r.task_id, auth.uid(), 'assignee_removed', jsonb_build_object('user', p_from));
    v_n := v_n + 1;
  end loop;
  perform public._audit('reassign_tasks', 'user', p_from, jsonb_build_object('to', p_to, 'count', v_n));
  return jsonb_build_object('reassigned', v_n);
end $$;

-- ------------------------------------------------------------
-- 3) task_set_assignees: un usuario INACTIVO no puede recibir NUEVAS tareas
--    (§14). Los que ya eran responsables pueden permanecer o quitarse.
-- ------------------------------------------------------------
create or replace function public.task_set_assignees(p_task uuid, p_users uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_board uuid; v_acc uuid; u uuid; v_added uuid[] := '{}'; v_removed uuid[] := '{}';
begin
  select board_id, account_id into v_board, v_acc from public.task_items where id = p_task;
  if v_board is null then raise exception 'Tarea no encontrada'; end if;
  if not public.can_admin_board(v_board, auth.uid()) then
    raise exception 'Sin permiso para cambiar responsables'; end if;
  p_users := coalesce(p_users, '{}');
  foreach u in array p_users loop
    if not (public.is_board_owner(v_board, u) or public.is_board_member(v_board, u)) then
      raise exception 'Un usuario seleccionado no pertenece al proyecto';
    end if;
    -- Sólo se valida "activo" para responsables NUEVOS (no para conservar los ya puestos).
    if not exists (select 1 from public.task_assignees where task_id = p_task and user_id = u) then
      if (select coalesce(status,'active') from public.profiles where id = u) <> 'active' then
        raise exception 'No puedes asignar a un usuario inactivo';
      end if;
    end if;
  end loop;
  for u in select user_id from public.task_assignees
           where task_id = p_task and not (user_id = any (p_users)) loop
    delete from public.task_assignees where task_id = p_task and user_id = u;
    v_removed := v_removed || u;
    insert into public.task_events (account_id, task_id, actor_id, type, detail)
      values (v_acc, p_task, auth.uid(), 'assignee_removed', jsonb_build_object('user', u));
  end loop;
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

grant execute on function public.admin_user_activity(uuid)            to authenticated;
grant execute on function public.admin_reassign_user_tasks(uuid, uuid) to authenticated;
