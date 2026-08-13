-- ============================================================
-- Organizadísimos · 013 · Usuarios, roles de proyecto y permisos
-- ============================================================
-- Añade: estados de usuario (pending/active/suspended/deleted), roles por
-- proyecto en board_members (admin/member/viewer) + unicidad y limpieza de
-- duplicados, email único normalizado, auditoría, y RPCs security-definer para
-- gestión de usuarios (dueño de plataforma) y membresías (admin de proyecto).
-- Refuerza los permisos de task_items para el "admin de proyecto".
-- Aditivo e idempotente. El editor SQL corre todo en una transacción implícita
-- (un error revierte TODO).

-- ============================================================
-- 1) ESTADOS DE USUARIO (profiles.status)
-- ============================================================
alter table public.profiles add column if not exists status text;
-- Migrar desde el booleano `active` existente.
update public.profiles set status = case when active then 'active' else 'suspended' end
  where status is null;
-- El dueño de la plataforma siempre activo.
update public.profiles set status = 'active', active = true where role = 'owner';
alter table public.profiles drop constraint if exists profiles_status_check;
alter table public.profiles add constraint profiles_status_check
  check (status in ('pending','active','suspended','deleted'));
alter table public.profiles alter column status set default 'pending';

-- Email único normalizado (evita cuentas duplicadas por mayúsculas/espacios).
create unique index if not exists profiles_email_lower_uniq on public.profiles (lower(email));

-- Alta de usuario: nace PENDIENTE (§8). El alta la hace el dueño vía Edge
-- Function, que luego puede activarlo o dejarlo pendiente de aprobación.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare nueva uuid;
begin
  insert into public.accounts (name) values (new.email) returning id into nueva;
  insert into public.profiles (id, email, account_id, status, active)
    values (new.id, new.email, nueva, 'pending', false);
  return new;
end $$;

-- Acceso solo si el usuario está ACTIVO (status) y su cuenta activa.
create or replace function public.is_active_user()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.profiles p
    join public.accounts a on a.id = p.account_id
    where p.id = auth.uid() and p.status = 'active' and a.active
  );
$$;

-- ============================================================
-- 2) ROLES POR PROYECTO (board_members.role) + LIMPIEZA (§15) + UNICIDAD (§16)
-- ============================================================
alter table public.board_members add column if not exists role text;
update public.board_members set role = 'member' where role is null;
alter table public.board_members drop constraint if exists board_members_role_check;
alter table public.board_members add constraint board_members_role_check
  check (role in ('admin','member','viewer'));
alter table public.board_members alter column role set default 'member';

-- Limpieza: el DUEÑO nunca debe figurar como miembro (causa del correo repetido).
delete from public.board_members bm using public.boards b
  where bm.board_id = b.id and bm.user_id = b.owner_id;
-- Deduplicar membresías (board_id,user_id): conservar una sola fila.
delete from public.board_members a using public.board_members b
  where a.board_id = b.board_id and a.user_id = b.user_id and a.ctid > b.ctid;
-- Una sola membresía por usuario y proyecto.
create unique index if not exists board_members_board_user_uniq
  on public.board_members(board_id, user_id);

-- Helpers de permiso de proyecto.
create or replace function public.can_admin_board(p_board uuid, p_user uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select public.is_board_owner(p_board, p_user)
    or exists (select 1 from public.board_members
               where board_id = p_board and user_id = p_user and role = 'admin');
$$;
create or replace function public.board_role(p_board uuid, p_user uuid)
returns text language sql security definer stable set search_path = public as $$
  select case when public.is_board_owner(p_board, p_user) then 'owner'
    else (select role from public.board_members where board_id = p_board and user_id = p_user) end;
$$;

-- ============================================================
-- 3) task_items: descripción + refuerzo de permisos (admin de proyecto)
-- ============================================================
alter table public.task_items add column if not exists description text;
grant update (title, position, parent_id, assignee_id, due_date, tags, description)
  on public.task_items to authenticated;
grant insert (account_id, board_id, parent_id, title, position, assignee_id, due_date, tags, description)
  on public.task_items to authenticated;

-- Escritura directa: dueño O admin de proyecto (antes solo dueño).
drop policy if exists task_items_insert on public.task_items;
create policy task_items_insert on public.task_items for insert with check (
  public.is_active_user() and account_id = public.current_account_id()
  and public.can_admin_board(board_id, auth.uid())
);
drop policy if exists task_items_update on public.task_items;
create policy task_items_update on public.task_items for update using (
  public.is_active_user() and account_id = public.current_account_id()
  and public.can_admin_board(board_id, auth.uid())
) with check (
  public.is_active_user() and account_id = public.current_account_id()
  and public.can_admin_board(board_id, auth.uid())
);
drop policy if exists task_items_delete on public.task_items;
create policy task_items_delete on public.task_items for delete using (
  public.is_active_user() and account_id = public.current_account_id()
  and public.can_admin_board(board_id, auth.uid())
);

-- RPCs de ciclo de vida: el "admin de proyecto" también puede (antes solo dueño).
create or replace function public.task_reopen(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not public.can_admin_board(t.board_id, auth.uid()) then raise exception 'Sin permiso para reabrir'; end if;
  update public.task_items set
    status = case when started_at is not null then 'in_progress' else 'pending' end,
    completed_at = null, completed_by = null, archived_at = null, archived_by = null
  where id = p_id;
end $$;

create or replace function public.task_archive(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not public.can_admin_board(t.board_id, auth.uid()) then raise exception 'Sin permiso para archivar'; end if;
  if t.status <> 'completed' then raise exception 'Solo se archivan tareas completadas'; end if;
  update public.task_items set status = 'archived', archived_at = now(), archived_by = auth.uid() where id = p_id;
end $$;

create or replace function public.task_unarchive(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not public.can_admin_board(t.board_id, auth.uid()) then raise exception 'Sin permiso para desarchivar'; end if;
  update public.task_items set status = 'completed', archived_at = null, archived_by = null where id = p_id;
end $$;

create or replace function public.task_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not public.can_admin_board(t.board_id, auth.uid()) then raise exception 'Sin permiso para eliminar'; end if;
  if t.status in ('completed','archived') then raise exception 'No se puede eliminar una tarea completada o archivada'; end if;
  delete from public.task_items where id = p_id;
end $$;

-- start/complete: el responsable, el admin de proyecto o el dueño.
create or replace function public.task_start(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not (public.can_admin_board(t.board_id, auth.uid()) or t.assignee_id = auth.uid()) then
    raise exception 'No eres el responsable'; end if;
  update public.task_items set status = 'in_progress',
    started_at = coalesce(started_at, now()), started_by = coalesce(started_by, auth.uid())
  where id = p_id;
end $$;

create or replace function public.task_complete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not (public.can_admin_board(t.board_id, auth.uid()) or t.assignee_id = auth.uid()) then
    raise exception 'No eres el responsable'; end if;
  update public.task_items set status = 'completed', completed_at = now(), completed_by = auth.uid()
  where id = p_id;
end $$;

-- ============================================================
-- 4) AUDITORÍA (§20)
-- ============================================================
create table if not exists public.audit_log (
  id          uuid primary key default gen_random_uuid(),
  account_id  uuid,
  actor_id    uuid,
  action      text not null,
  target_type text,
  target_id   uuid,
  detail      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists audit_log_created_idx on public.audit_log(created_at desc);
alter table public.audit_log enable row level security;
revoke all on public.audit_log from anon;
revoke all on public.audit_log from authenticated;
grant select on public.audit_log to authenticated;
drop policy if exists audit_log_select on public.audit_log;
create policy audit_log_select on public.audit_log for select using (public.is_platform_owner());

create or replace function public._audit(p_action text, p_ttype text, p_tid uuid, p_detail jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_log(account_id, actor_id, action, target_type, target_id, detail)
  values (public.current_account_id(), auth.uid(), p_action, p_ttype, p_tid, coalesce(p_detail, '{}'::jsonb));
$$;

-- ============================================================
-- 5) RPCs de gestión de USUARIOS (solo dueño de plataforma)
-- ============================================================
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
    where p.role = 'client'
  ) t;
  return res;
end $$;

-- Cambiar estado: activar / suspender / reactivar / eliminar (lógico).
create or replace function public.admin_set_user_status(p_user uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare v_old text; v_role text;
begin
  if not public.is_platform_owner() then raise exception 'Solo el administrador'; end if;
  if p_status not in ('pending','active','suspended','deleted') then raise exception 'Estado inválido'; end if;
  select status, role into v_old, v_role from public.profiles where id = p_user;
  if not found then raise exception 'Usuario no encontrado'; end if;
  if p_status = 'deleted' then
    if v_role = 'owner' then raise exception 'No se puede eliminar al administrador de la plataforma'; end if;
    if exists (select 1 from public.boards where owner_id = p_user) then
      raise exception 'Este usuario es dueño de proyectos. Transfiere la propiedad antes de eliminarlo.';
    end if;
  end if;
  update public.profiles set status = p_status, active = (p_status = 'active') where id = p_user;
  perform public._audit('user_status', 'user', p_user, jsonb_build_object('from', v_old, 'to', p_status));
end $$;

create or replace function public.admin_find_user_by_email(p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare res jsonb;
begin
  if not public.is_platform_owner() then raise exception 'Solo el administrador'; end if;
  select jsonb_build_object('id', p.id, 'email', p.email, 'full_name', p.full_name,
    'status', coalesce(p.status, case when p.active then 'active' else 'suspended' end),
    'role', p.role, 'account_id', p.account_id)
    into res from public.profiles p where lower(p.email) = lower(trim(p_email)) limit 1;
  return res;  -- null si no existe
end $$;

-- ============================================================
-- 6) RPCs de MEMBRESÍAS (dueño o admin de proyecto), idempotentes (§12,13,16)
-- ============================================================
create or replace function public.board_add_member(p_board uuid, p_email text, p_role text default 'member')
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_user uuid; v_acc uuid; v_owner uuid; v_exists text;
begin
  if not public.can_admin_board(p_board, auth.uid()) then raise exception 'Sin permiso'; end if;
  if p_role not in ('admin','member','viewer') then raise exception 'Rol inválido'; end if;
  select account_id, owner_id into v_acc, v_owner from public.boards where id = p_board;
  select id into v_user from public.profiles
    where lower(email) = lower(trim(p_email)) and account_id = v_acc and coalesce(status,'active') <> 'deleted'
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

create or replace function public.board_set_member_role(p_board uuid, p_user uuid, p_role text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_admin_board(p_board, auth.uid()) then raise exception 'Sin permiso'; end if;
  if p_role not in ('admin','member','viewer') then raise exception 'Rol inválido'; end if;
  update public.board_members set role = p_role where board_id = p_board and user_id = p_user;
  perform public._audit('member_role', 'board', p_board, jsonb_build_object('user', p_user, 'role', p_role));
end $$;

create or replace function public.board_remove_member(p_board uuid, p_user uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.can_admin_board(p_board, auth.uid()) then raise exception 'Sin permiso'; end if;
  if exists (select 1 from public.boards where id = p_board and owner_id = p_user) then
    raise exception 'No se puede quitar al dueño del proyecto. Transfiere la propiedad primero.';
  end if;
  delete from public.board_members where board_id = p_board and user_id = p_user;
  perform public._audit('member_remove', 'board', p_board, jsonb_build_object('user', p_user));
end $$;

create or replace function public.board_transfer_owner(p_board uuid, p_new_owner uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_acc uuid;
begin
  if not public.is_board_owner(p_board, auth.uid()) and not public.is_platform_owner() then
    raise exception 'Solo el dueño puede transferir la propiedad'; end if;
  select account_id into v_acc from public.boards where id = p_board;
  if not exists (select 1 from public.profiles where id = p_new_owner and account_id = v_acc) then
    raise exception 'El nuevo dueño debe pertenecer a la misma cuenta'; end if;
  update public.boards set owner_id = p_new_owner where id = p_board;
  -- El nuevo dueño no debe seguir como miembro; el anterior pasa a admin.
  delete from public.board_members where board_id = p_board and user_id = p_new_owner;
  perform public._audit('owner_transfer', 'board', p_board, jsonb_build_object('to', p_new_owner));
end $$;

grant execute on function public.can_admin_board(uuid, uuid)        to authenticated;
grant execute on function public.board_role(uuid, uuid)             to authenticated;
grant execute on function public.admin_list_users()                 to authenticated;
grant execute on function public.admin_set_user_status(uuid, text)  to authenticated;
grant execute on function public.admin_find_user_by_email(text)     to authenticated;
grant execute on function public.board_add_member(uuid, text, text) to authenticated;
grant execute on function public.board_set_member_role(uuid, uuid, text) to authenticated;
grant execute on function public.board_remove_member(uuid, uuid)    to authenticated;
grant execute on function public.board_transfer_owner(uuid, uuid)   to authenticated;
