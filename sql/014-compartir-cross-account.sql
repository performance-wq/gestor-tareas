-- ============================================================
-- Organizadísimos · 014 · Compartir proyectos entre cuentas (acceso de invitado)
-- ============================================================
-- PROBLEMA (causa raíz del error "Ese correo no tiene una cuenta en esta empresa
-- todavía"): cada usuario creado desde /admin nace como su PROPIA cuenta (tenant)
-- —lo hace el trigger handle_new_user—. Por tanto deishlerp@gmail.com NO está en
-- la cuenta del dueño de la plataforma (performance@), y todo el modelo de datos
-- exigía "misma cuenta" para:
--   · board_add_member  (rechazaba con {found:false} → el mensaje de la pantalla)
--   · boards_select / task_items_select / task_events_select  (no vería el tablero)
--   · _task_access      (no podría iniciar/completar sus tareas por RPC)
--
-- SOLUCIÓN: acceso de INVITADO. Para COMPARTIR un proyecto, basta ser dueño o
-- miembro del tablero (pertenencia), sin exigir misma cuenta. Cada cliente sigue
-- siendo su propio tenant y /proyectos y /contenido siguen AISLADOS por cuenta
-- (este archivo NO los toca). Un invitado sólo ve el tablero al que lo agregaron
-- y sus tareas; nada más.
--
-- Aditivo e idempotente. El editor SQL corre todo en una transacción implícita.

-- ============================================================
-- 1) LECTURA POR PERTENENCIA (no por cuenta)
-- ============================================================
-- Ver un tablero: ser su dueño o su miembro, viva donde viva tu cuenta.
drop policy if exists boards_select on public.boards;
create policy boards_select on public.boards for select using (
  public.is_active_user()
  and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
);

-- Actualizar el tablero (p.ej. reordenar tareas guardadas en boards.data):
-- dueño o miembro, sin exigir misma cuenta (igual que antes, pero cross-account).
drop policy if exists boards_update on public.boards;
create policy boards_update on public.boards for update using (
  public.is_active_user()
  and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
) with check (
  public.is_active_user()
  and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
);
-- boards_insert / boards_delete se dejan como están: sólo el dueño, en su cuenta.

-- Ver las tareas: dueño o miembro del tablero.
drop policy if exists task_items_select on public.task_items;
create policy task_items_select on public.task_items for select using (
  public.is_active_user()
  and (public.is_board_owner(board_id, auth.uid()) or public.is_board_member(board_id, auth.uid()))
);

-- Ver el historial: quien pueda ver la tarea asociada.
drop policy if exists task_events_select on public.task_events;
create policy task_events_select on public.task_events for select using (
  public.is_active_user()
  and exists (
    select 1 from public.task_items t
    where t.id = task_events.task_id
      and (public.is_board_owner(t.board_id, auth.uid()) or public.is_board_member(t.board_id, auth.uid()))
  )
);

-- ============================================================
-- 2) ESCRITURA DIRECTA POR ADMIN DE PROYECTO (dueño o admin), cross-account
-- ============================================================
-- El account_id de la fila debe ser el del TABLERO (no se puede falsificar hacia
-- otra cuenta); el permiso lo da can_admin_board. Los miembros/lectores no
-- escriben directo: actúan por RPC (task_start/complete), que ya valida acceso.
drop policy if exists task_items_insert on public.task_items;
create policy task_items_insert on public.task_items for insert with check (
  public.is_active_user()
  and public.can_admin_board(board_id, auth.uid())
  and account_id = (select b.account_id from public.boards b where b.id = board_id)
);
drop policy if exists task_items_update on public.task_items;
create policy task_items_update on public.task_items for update using (
  public.is_active_user()
  and public.can_admin_board(board_id, auth.uid())
) with check (
  public.is_active_user()
  and public.can_admin_board(board_id, auth.uid())
  and account_id = (select b.account_id from public.boards b where b.id = board_id)
);
drop policy if exists task_items_delete on public.task_items;
create policy task_items_delete on public.task_items for delete using (
  public.is_active_user()
  and public.can_admin_board(board_id, auth.uid())
);

-- ============================================================
-- 3) RPCs DE CICLO DE VIDA: acceso por pertenencia (sin exigir misma cuenta)
-- ============================================================
-- _task_access es la puerta de todas las RPCs (start/complete/reopen/...): quitamos
-- el candado de cuenta para que un invitado (dueño o miembro) pueda operar.
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

-- ============================================================
-- 4) board_add_member: el DUEÑO DE PLATAFORMA agrega invitados de cualquier cuenta
-- ============================================================
-- Un admin de proyecto normal (cliente) sigue limitado a su propia cuenta (no
-- puede ni comprobar correos de otras empresas). El dueño de la plataforma
-- (performance@) puede invitar a cualquier usuario existente y activo.
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

-- board_members insert directo (fuera de la RPC) permanece restringido a la propia
-- cuenta por members_insert; la RPC security-definer es la vía para invitados.
