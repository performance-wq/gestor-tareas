-- ============================================================
-- Organizadísimos · 019 · Workspace/permisos: dueño visible, solo admin crea
-- proyectos, protección del dueño. (Consolida e idempotentiza 017 y 018.)
-- ============================================================
-- §5  El dueño (role='owner') debe APARECER en la lista de usuarios de /admin.
-- §2/§13 Solo el administrador (dueño de plataforma) puede CREAR proyectos
--     (boards); un miembro nunca crea su propio workspace/proyecto.
-- §6  El administrador principal no se puede suspender ni eliminar.
-- §7  "No se pudo leer la actividad": la RPC admin_user_activity (017) debe existir.
-- Reincluye 017 (actividad/reasignación + no asignar inactivos) y 018 (borrar
-- agrupador en cascada) por si no se aplicaron. Todo idempotente.
-- NO toca: /proyectos, /contenido, diseño, ni la lógica operativa de Tareas.

-- ------------------------------------------------------------
-- §5) admin_list_users: incluir al DUEÑO además de los clientes.
-- ------------------------------------------------------------
create or replace function public.admin_list_users()
returns jsonb language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  if not public.is_platform_owner() then raise exception 'Solo el administrador'; end if;
  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by (t.email)), '[]'::jsonb) into res from (
    select p.id, p.email, p.full_name, p.company, p.account_id, a.name as account_name,
      coalesce(p.status, case when p.active then 'active' else 'suspended' end) as status,
      p.role, p.created_at, au.last_sign_in_at,
      (select coalesce(jsonb_agg(jsonb_build_object('board_id', pr.board_id, 'name', b.name, 'role', pr.role)), '[]'::jsonb)
       from (
         select b0.id as board_id, 'owner'::text as role from public.boards b0 where b0.owner_id = p.id
         union all
         select bm.board_id, bm.role from public.board_members bm where bm.user_id = p.id
       ) pr join public.boards b on b.id = pr.board_id) as projects
    from public.profiles p
    left join public.accounts a on a.id = p.account_id
    left join auth.users au on au.id = p.id
    where p.role in ('owner','client')
  ) t;
  return res;
end $$;

-- ------------------------------------------------------------
-- §2/§13) Solo el dueño de plataforma puede CREAR proyectos (boards).
--     Un miembro (cliente) ya no puede crear su propio workspace/proyecto.
-- ------------------------------------------------------------
drop policy if exists boards_insert on public.boards;
create policy boards_insert on public.boards for insert with check (
  public.is_active_user()
  and auth.uid() = owner_id
  and account_id = public.current_account_id()
  and public.is_platform_owner()
);

-- ------------------------------------------------------------
-- §6) admin_set_user_status: proteger al administrador principal (owner):
--     no se puede suspender ni eliminar.
-- ------------------------------------------------------------
create or replace function public.admin_set_user_status(p_user uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare v_old text; v_role text;
begin
  if not public.is_platform_owner() then raise exception 'Solo el administrador'; end if;
  if p_status not in ('pending','active','suspended','deleted') then raise exception 'Estado inválido'; end if;
  select status, role into v_old, v_role from public.profiles where id = p_user;
  if not found then raise exception 'Usuario no encontrado'; end if;
  if v_role = 'owner' and p_status in ('suspended','deleted') then
    raise exception 'No se puede suspender ni eliminar al administrador principal';
  end if;
  if p_status = 'deleted' and exists (select 1 from public.boards where owner_id = p_user) then
    raise exception 'Este usuario es dueño de proyectos. Transfiere la propiedad antes de eliminarlo.';
  end if;
  update public.profiles set status = p_status, active = (p_status = 'active') where id = p_user;
  perform public._audit('user_status', 'user', p_user, jsonb_build_object('from', v_old, 'to', p_status));
end $$;

-- ============================================================
-- Reinclusión de 018: borrar agrupador con cascada (trigger sin romper FK).
-- ============================================================
create or replace function public.task_items_audit()
returns trigger language plpgsql security definer set search_path = public as $$
declare actor uuid := auth.uid();
begin
  if TG_OP = 'INSERT' then
    insert into public.task_events(account_id, task_id, actor_id, type, detail)
      values (NEW.account_id, NEW.id, actor, 'created', jsonb_build_object('title', NEW.title));
    if NEW.assignee_id is not null then
      insert into public.task_events(account_id, task_id, actor_id, type, detail)
        values (NEW.account_id, NEW.id, actor, 'assigned', jsonb_build_object('to', NEW.assignee_id));
    end if;
    return NEW;
  elsif TG_OP = 'UPDATE' then
    if NEW.assignee_id is distinct from OLD.assignee_id then
      insert into public.task_events(account_id, task_id, actor_id, type, detail)
        values (NEW.account_id, NEW.id, actor,
                case when OLD.assignee_id is null then 'assigned'
                     when NEW.assignee_id is null then 'unassigned'
                     else 'reassigned' end,
                jsonb_build_object('from', OLD.assignee_id, 'to', NEW.assignee_id));
    end if;
    if NEW.due_date is distinct from OLD.due_date then
      insert into public.task_events(account_id, task_id, actor_id, type, detail)
        values (NEW.account_id, NEW.id, actor, 'due_changed',
                jsonb_build_object('from', OLD.due_date, 'to', NEW.due_date));
    end if;
    if NEW.status is distinct from OLD.status then
      insert into public.task_events(account_id, task_id, actor_id, type, detail)
        values (NEW.account_id, NEW.id, actor,
                case NEW.status
                  when 'in_progress' then case when OLD.status in ('completed','archived') then 'reopened' else 'started' end
                  when 'completed'   then case when OLD.status = 'archived' then 'unarchived' else 'completed' end
                  when 'archived'    then 'archived'
                  when 'pending'     then 'reopened'
                  else 'status_changed' end,
                jsonb_build_object('from', OLD.status, 'to', NEW.status));
    end if;
    return NEW;
  elsif TG_OP = 'DELETE' then
    if OLD.parent_id is not null
       and exists (select 1 from public.task_items where id = OLD.parent_id) then
      insert into public.task_events(account_id, task_id, actor_id, type, detail)
        values (OLD.account_id, OLD.parent_id, actor, 'child_deleted',
                jsonb_build_object('title', OLD.title));
    end if;
    return OLD;
  end if;
  return null;
end $$;

-- ============================================================
-- Reinclusión de 017: actividad, reasignación, y no asignar inactivos.
-- ============================================================
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

grant execute on function public.admin_user_activity(uuid)             to authenticated;
grant execute on function public.admin_reassign_user_tasks(uuid, uuid) to authenticated;
