-- ============================================================
-- Organizadísimos · 016 · FIX: acceso cross-account a boards (la 014 no aplicó)
-- ============================================================
-- CAUSA RAÍZ CONFIRMADA (auditoría en pg_policies): la política boards_select
-- todavía exige `account_id = current_account_id()`. Un miembro invitado de OTRA
-- cuenta (p.ej. deishlerp@, cuenta propia) queda EXCLUIDO → su GET a /boards
-- devuelve vacío → el frontend no encuentra tablero → el auto-create hace POST
-- (403) y `bootstrap` revienta en `boards[0].id`. Resultado: "No hay tareas".
--
-- La 014 debía relajar esto pero NO quedó aplicada. La 015 (visibilidad por
-- responsable) SÍ está aplicada, así que aquí NO se toca task_items_select:
-- sólo se corrige el acceso al TABLERO por pertenencia y el _task_access.
--
-- Aditivo e idempotente.

-- ------------------------------------------------------------
-- 1) boards: ver/editar por PERTENENCIA (dueño o miembro), sin exigir cuenta.
--    (Un invitado sólo ve el tablero al que lo agregaron; /proyectos y /contenido
--     siguen aislados por cuenta: aquí no se tocan.)
-- ------------------------------------------------------------
drop policy if exists boards_select on public.boards;
create policy boards_select on public.boards for select using (
  public.is_active_user()
  and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
);

drop policy if exists boards_update on public.boards;
create policy boards_update on public.boards for update using (
  public.is_active_user()
  and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
) with check (
  public.is_active_user()
  and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
);
-- boards_insert / boards_delete se dejan como están: sólo el dueño, en su cuenta.

-- ------------------------------------------------------------
-- 2) _task_access sin candado de cuenta: para que el invitado (dueño o miembro)
--    pueda iniciar/completar sus tareas por RPC. (La 012 lo bloqueaba por cuenta.)
-- ------------------------------------------------------------
create or replace function public._task_access(p_id uuid)
returns public.task_items language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  select * into t from public.task_items where id = p_id;
  if not found then raise exception 'Tarea no encontrada'; end if;
  if not public.is_active_user() then raise exception 'Cuenta inactiva'; end if;
  if not (public.is_board_owner(t.board_id, auth.uid()) or public.is_board_member(t.board_id, auth.uid())) then
    raise exception 'Sin acceso';
  end if;
  return t;
end $$;

-- ------------------------------------------------------------
-- 3) board_add_member: el dueño de plataforma puede invitar usuarios de cualquier
--    cuenta (para que "Compartir" funcione desde la interfaz). Idempotente.
-- ------------------------------------------------------------
create or replace function public.board_add_member(p_board uuid, p_email text, p_role text default 'member')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_acc uuid; v_owner uuid; v_exists text;
begin
  if not public.can_admin_board(p_board, auth.uid()) then raise exception 'Sin permiso'; end if;
  if p_role not in ('admin','member','viewer') then raise exception 'Rol inválido'; end if;
  select account_id, owner_id into v_acc, v_owner from public.boards where id = p_board;
  select id into v_user from public.profiles
    where lower(email) = lower(trim(p_email))
      and coalesce(status,'active') <> 'deleted'
      and (public.is_platform_owner() or account_id = v_acc)
    limit 1;
  if v_user is null then return jsonb_build_object('found', false); end if;
  if v_user = v_owner then return jsonb_build_object('ownerAlready', true); end if;
  select role into v_exists from public.board_members where board_id = p_board and user_id = v_user;
  if v_exists is not null then return jsonb_build_object('already', true, 'role', v_exists); end if;
  insert into public.board_members(board_id, user_id, role) values (p_board, v_user, p_role)
    on conflict (board_id, user_id) do nothing;
  perform public._audit('member_add', 'board', p_board, jsonb_build_object('user', v_user, 'role', p_role));
  return jsonb_build_object('added', true, 'user', v_user, 'role', p_role);
end $$;

-- ------------------------------------------------------------
-- 4) VERIFICACIÓN incluida: impersona a Desh y comprueba que ya ve BYPEX + tareas.
--    (No modifica nada; se puede borrar. Devuelve 1 fila.)
-- ------------------------------------------------------------
do $$ begin perform 1; end $$;  -- no-op separador
