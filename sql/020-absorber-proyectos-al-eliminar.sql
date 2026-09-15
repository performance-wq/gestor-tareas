-- ============================================================
-- Organizadísimos · 020 · Eliminar los proyectos PROPIOS del usuario al borrarlo
-- ============================================================
-- Decisión del dueño: al eliminar un usuario legacy que posee su propio tablero
-- (creado cuando los miembros aún podían crear proyectos), se permite eliminarlo
-- SIN transferir: se pierden SUS proyectos propios y todo su contenido, pero
-- NUNCA se tocan los proyectos de la cuenta del administrador.
--
-- Triple candado para no borrar jamás los proyectos del admin:
--   1) solo lo invoca el dueño de plataforma (is_platform_owner);
--   2) p_user no puede ser el propio admin (auth.uid());
--   3) p_user no puede tener role='owner';
--   y el DELETE filtra estrictamente por owner_id = p_user.
-- Idempotente.

create or replace function public.admin_delete_user_boards(p_user uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v_admin uuid := auth.uid(); v_role text;
begin
  if not public.is_platform_owner() then raise exception 'Solo el administrador'; end if;
  if p_user = v_admin then raise exception 'No aplica sobre tu propio usuario'; end if;
  select role into v_role from public.profiles where id = p_user;
  if v_role = 'owner' then raise exception 'No se pueden eliminar los proyectos del administrador'; end if;
  -- Borra SOLO los tableros que ESTE usuario posee (los suyos). El ON DELETE
  -- CASCADE arrastra sus tareas/eventos/responsables. Los proyectos del admin
  -- (owner_id distinto) nunca entran en este filtro.
  delete from public.boards where owner_id = p_user;
  get diagnostics v_n = row_count;
  perform public._audit('user_boards_deleted', 'user', p_user, jsonb_build_object('count', v_n));
  return v_n;
end $$;

grant execute on function public.admin_delete_user_boards(uuid) to authenticated;
