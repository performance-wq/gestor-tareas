-- ============================================================
-- Organizadísimos · 018 · FIX: eliminar agrupador con toda su descendencia
-- ============================================================
-- CAUSA RAÍZ (confirmada con una prueba real, error 23503): el trigger de
-- auditoría task_items_audit(), en BEFORE DELETE, inserta un evento
-- 'child_deleted' apuntando a OLD.parent_id. Al borrar un AGRUPADOR, el
-- ON DELETE CASCADE de parent_id elimina primero el padre y luego las hijas;
-- cada hija intenta registrar el evento sobre el padre YA borrado → viola la
-- FK task_events_task_id_fkey → la transacción entera se revierte. Resultado:
-- las tareas principales/agrupadores no se pueden eliminar.
--
-- SOLUCIÓN: registrar 'child_deleted' SOLO cuando el padre sigue existiendo
-- (es decir, cuando se borra una subtarea suelta). Si el padre también se está
-- borrando (cascada del grupo), se omite el rastro y la cascada completa.
-- No cambia responsables, fechas, historial normal, dashboard ni estados.
--
-- Aditivo e idempotente. Sólo redefine la función del trigger; no toca tablas
-- ni políticas.

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
    -- Sólo dejamos rastro en el padre si el padre SIGUE existiendo (borrado de
    -- una subtarea suelta). Si el padre también se está borrando (cascada de un
    -- agrupador), se omite el evento para no violar la FK y permitir la cascada.
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
