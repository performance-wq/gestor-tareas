-- ============================================================
-- Organizadísimos · 012 · Tareas: control operativo, roles, historial
-- ============================================================
-- Mueve el árbol de tareas del blob boards.data a tablas relacionales para
-- poder: (a) generar fechas reales EN EL SERVIDOR, (b) reforzar permisos en
-- backend (RLS + privilegios por columna + RPCs), (c) conservar un historial
-- de eventos no sobrescribible. Solo afecta al módulo Tareas.
--
-- Modelo de roles SIN columna nueva:
--   Administrador de un board = su dueño (boards.owner_id) → is_board_owner().
--   Usuario operativo         = miembro (board_members)    → is_board_member().
-- Reutiliza los helpers existentes: current_account_id(), is_active_user(),
-- is_board_owner(board,uid), is_board_member(board,uid).
--
-- Idempotente: se puede volver a ejecutar. La migración se salta los boards
-- ya migrados (boards.data.migratedToTaskItems = true).

-- ============================================================
-- 1) TABLAS
-- ============================================================

create table if not exists public.task_items (
  id             uuid primary key default gen_random_uuid(),
  account_id     uuid not null references public.accounts(id) on delete cascade,
  board_id       uuid not null references public.boards(id)   on delete cascade,
  parent_id      uuid references public.task_items(id)        on delete cascade,
  title          text not null default '',
  position       int  not null default 0,
  assignee_id    uuid references public.profiles(id),          -- responsable (usuario real)
  assignee_legacy text,                                        -- nombre viejo si no casó al migrar
  tags           jsonb not null default '[]'::jsonb,
  due_date       date,                                         -- fecha de entrega (la fija el admin)
  status         text not null default 'pending'
                   check (status in ('pending','in_progress','completed','archived')),
  created_by     uuid default auth.uid(),
  created_at     timestamptz not null default now(),
  started_at     timestamptz,  started_by  uuid,
  completed_at   timestamptz,  completed_by uuid,
  archived_at    timestamptz,  archived_by  uuid
);
create index if not exists task_items_board_idx    on public.task_items(board_id);
create index if not exists task_items_parent_idx   on public.task_items(parent_id);
create index if not exists task_items_assignee_idx on public.task_items(assignee_id);

-- Historial de eventos por tarea (auditoría, no sobrescribible por clientes).
create table if not exists public.task_events (
  id         uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.accounts(id) on delete cascade,
  task_id    uuid references public.task_items(id) on delete cascade,
  actor_id   uuid,
  type       text not null,
  detail     jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists task_events_task_idx on public.task_events(task_id);

-- ============================================================
-- 2) PRIVILEGIOS POR COLUMNA (clave para §12)
-- ============================================================
-- El cliente autenticado NUNCA puede escribir status ni las fechas reales
-- (*_at / *_by): esas solo las fijan las RPCs security definer. El admin sí
-- puede editar por UPDATE directo el subconjunto operativo de columnas.
revoke all on public.task_items  from anon;
revoke all on public.task_items  from authenticated;
grant  select, delete on public.task_items to authenticated;
-- INSERT y UPDATE restringidos por columna: el cliente nunca escribe status ni
-- las fechas reales (*_at / *_by). Una tarea nace 'pending' sin sellos; el
-- estado y las fechas solo los mueven las RPCs security definer.
grant  insert (account_id, board_id, parent_id, title, position, assignee_id, due_date, tags)
       on public.task_items to authenticated;
grant  update (title, position, parent_id, assignee_id, due_date, tags)
       on public.task_items to authenticated;

revoke all on public.task_events from anon;
revoke all on public.task_events from authenticated;
grant  select on public.task_events to authenticated;   -- solo lectura; escribe el trigger

-- ============================================================
-- 3) RLS
-- ============================================================
alter table public.task_items  enable row level security;
alter table public.task_events enable row level security;

-- task_items: ven dueño y miembros del board (misma cuenta). Escritura directa
-- solo el dueño (admin); los operativos actúan por RPC.
drop policy if exists task_items_select on public.task_items;
create policy task_items_select on public.task_items for select using (
  public.is_active_user() and account_id = public.current_account_id()
  and (public.is_board_owner(board_id, auth.uid()) or public.is_board_member(board_id, auth.uid()))
);
drop policy if exists task_items_insert on public.task_items;
create policy task_items_insert on public.task_items for insert with check (
  public.is_active_user() and account_id = public.current_account_id()
  and public.is_board_owner(board_id, auth.uid())
);
drop policy if exists task_items_update on public.task_items;
create policy task_items_update on public.task_items for update using (
  public.is_active_user() and account_id = public.current_account_id()
  and public.is_board_owner(board_id, auth.uid())
) with check (
  public.is_active_user() and account_id = public.current_account_id()
  and public.is_board_owner(board_id, auth.uid())
);
drop policy if exists task_items_delete on public.task_items;
create policy task_items_delete on public.task_items for delete using (
  public.is_active_user() and account_id = public.current_account_id()
  and public.is_board_owner(board_id, auth.uid())
);

-- task_events: lectura para quien ve la tarea. Sin insert/update/delete de
-- clientes (solo triggers/RPCs security definer escriben) → inmutable.
drop policy if exists task_events_select on public.task_events;
create policy task_events_select on public.task_events for select using (
  public.is_active_user() and account_id = public.current_account_id()
  and exists (
    select 1 from public.task_items t
    where t.id = task_events.task_id
      and (public.is_board_owner(t.board_id, auth.uid()) or public.is_board_member(t.board_id, auth.uid()))
  )
);

-- ============================================================
-- 4) AUDITORÍA (trigger security definer = fuente única del historial)
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
    -- La fila y sus eventos se borran en cascada; si tiene padre, dejamos rastro
    -- en el padre para que la eliminación quede en el historial (§29).
    if OLD.parent_id is not null then
      insert into public.task_events(account_id, task_id, actor_id, type, detail)
        values (OLD.account_id, OLD.parent_id, actor, 'child_deleted',
                jsonb_build_object('title', OLD.title));
    end if;
    return OLD;
  end if;
  return null;
end $$;

drop trigger if exists trg_task_items_ins on public.task_items;
drop trigger if exists trg_task_items_upd on public.task_items;
drop trigger if exists trg_task_items_del on public.task_items;
create trigger trg_task_items_ins after insert  on public.task_items for each row execute function public.task_items_audit();
create trigger trg_task_items_upd after update  on public.task_items for each row execute function public.task_items_audit();
create trigger trg_task_items_del before delete on public.task_items for each row execute function public.task_items_audit();

-- ============================================================
-- 5) RPCs de ciclo de vida (fechas del servidor + permisos)
-- ============================================================
-- Helper interno: carga la tarea y valida acceso de la cuenta/board.
create or replace function public._task_access(p_id uuid)
returns public.task_items language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  select * into t from public.task_items where id = p_id;
  if not found then raise exception 'Tarea no encontrada'; end if;
  if not public.is_active_user() then raise exception 'Cuenta inactiva'; end if;
  if t.account_id <> public.current_account_id() then raise exception 'Sin acceso'; end if;
  if not (public.is_board_owner(t.board_id, auth.uid()) or public.is_board_member(t.board_id, auth.uid())) then
    raise exception 'Sin acceso';
  end if;
  return t;
end $$;

-- Iniciar: el responsable o el admin. Sella started_at solo la primera vez.
create or replace function public.task_start(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not (public.is_board_owner(t.board_id, auth.uid()) or t.assignee_id = auth.uid()) then
    raise exception 'No eres el responsable';
  end if;
  update public.task_items set
    status     = 'in_progress',
    started_at = coalesce(started_at, now()),
    started_by = coalesce(started_by, auth.uid())
  where id = p_id;
end $$;

-- Completar: el responsable o el admin. Sella la fecha real de finalización.
create or replace function public.task_complete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not (public.is_board_owner(t.board_id, auth.uid()) or t.assignee_id = auth.uid()) then
    raise exception 'No eres el responsable';
  end if;
  update public.task_items set
    status       = 'completed',
    completed_at = now(),
    completed_by = auth.uid()
  where id = p_id;
end $$;

-- Reabrir: solo admin. Limpia finalización/archivo, conserva el inicio.
create or replace function public.task_reopen(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not public.is_board_owner(t.board_id, auth.uid()) then raise exception 'Solo el administrador puede reabrir'; end if;
  update public.task_items set
    status       = case when started_at is not null then 'in_progress' else 'pending' end,
    completed_at = null, completed_by = null,
    archived_at  = null, archived_by  = null
  where id = p_id;
end $$;

-- Archivar: solo admin, solo tareas completadas. Sella archived_at.
create or replace function public.task_archive(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not public.is_board_owner(t.board_id, auth.uid()) then raise exception 'Solo el administrador puede archivar'; end if;
  if t.status <> 'completed' then raise exception 'Solo se archivan tareas completadas'; end if;
  update public.task_items set
    status = 'archived', archived_at = now(), archived_by = auth.uid()
  where id = p_id;
end $$;

-- Desarchivar: solo admin. Vuelve a completada.
create or replace function public.task_unarchive(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not public.is_board_owner(t.board_id, auth.uid()) then raise exception 'Solo el administrador puede desarchivar'; end if;
  update public.task_items set
    status = 'completed', archived_at = null, archived_by = null
  where id = p_id;
end $$;

-- Eliminar: solo admin. Nunca borra completadas/archivadas (§restricción).
create or replace function public.task_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.task_items;
begin
  t := public._task_access(p_id);
  if not public.is_board_owner(t.board_id, auth.uid()) then raise exception 'Solo el administrador puede eliminar'; end if;
  if t.status in ('completed','archived') then
    raise exception 'No se puede eliminar una tarea completada o archivada';
  end if;
  delete from public.task_items where id = p_id;  -- cascada: hijos + eventos
end $$;

grant execute on function public.task_start(uuid)     to authenticated;
grant execute on function public.task_complete(uuid)  to authenticated;
grant execute on function public.task_reopen(uuid)    to authenticated;
grant execute on function public.task_archive(uuid)   to authenticated;
grant execute on function public.task_unarchive(uuid) to authenticated;
grant execute on function public.task_delete(uuid)    to authenticated;

-- ============================================================
-- 6) MIGRACIÓN desde boards.data (idempotente)
-- ============================================================
-- Inserta un nodo del árbol jsonb y recurre en sus subtareas.
create or replace function public._migrate_task_node(
  p_node jsonb, p_parent uuid, p_board uuid, p_account uuid, p_pos int)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_id uuid; v_assignee uuid; v_legacy text; v_done boolean;
  v_name text; child jsonb; i int := 0;
begin
  v_name := coalesce(nullif(trim(p_node->>'assignee'), ''), null);
  if v_name is not null then
    select id into v_assignee from public.profiles
      where account_id = p_account and active
        and (lower(coalesce(full_name,'')) = lower(v_name) or lower(email) = lower(v_name))
      limit 1;
    if v_assignee is null then v_legacy := v_name; end if;
  end if;
  v_done := coalesce((p_node->>'done')::boolean, false);

  insert into public.task_items(
    account_id, board_id, parent_id, title, position, assignee_id, assignee_legacy,
    tags, status, created_at, completed_at)
  values (
    p_account, p_board, p_parent, coalesce(p_node->>'text',''), p_pos,
    v_assignee, v_legacy,
    coalesce(p_node->'tags', '[]'::jsonb),
    case when v_done then 'completed' else 'pending' end,
    coalesce((p_node->>'createdAt')::timestamptz, now()),
    case when v_done then coalesce((p_node->>'completedAt')::timestamptz, now()) else null end
  ) returning id into v_id;

  for child in select * from jsonb_array_elements(coalesce(p_node->'subtasks', '[]'::jsonb)) loop
    perform public._migrate_task_node(child, v_id, p_board, p_account, i);
    i := i + 1;
  end loop;
end $$;

create or replace function public.migrate_boards_to_task_items()
returns int language plpgsql security definer set search_path = public as $$
declare b record; node jsonb; i int; n int := 0;
begin
  for b in select id, account_id, data from public.boards loop
    if coalesce((b.data->>'migratedToTaskItems')::boolean, false) then continue; end if;
    i := 0;
    for node in select * from jsonb_array_elements(coalesce(b.data->'tasks', '[]'::jsonb)) loop
      perform public._migrate_task_node(node, null, b.id, b.account_id, i);
      i := i + 1;  n := n + 1;
    end loop;
    update public.boards
      set data = jsonb_set(coalesce(data,'{}'::jsonb), '{migratedToTaskItems}', 'true'::jsonb)
      where id = b.id;
  end loop;
  return n;  -- nº de tareas raíz migradas
end $$;

-- Ejecuta la migración SIN disparar el trigger de auditoría (evita un evento
-- 'created' falso, con fecha de migración, por cada nodo).
alter table public.task_items disable trigger trg_task_items_ins;
select public.migrate_boards_to_task_items();
alter table public.task_items enable  trigger trg_task_items_ins;
