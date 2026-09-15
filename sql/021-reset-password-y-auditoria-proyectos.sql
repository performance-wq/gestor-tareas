-- ============================================================
-- Organizadísimos · 021 · Resetear contraseña + auditoría de proyectos de miembros
-- ============================================================
-- (A) El administrador puede CAMBIAR/RESETEAR la contraseña de un usuario que la
--     olvidó. Se hace en la base (pgcrypto/bcrypt) sin depender de correos ni de
--     Edge Functions. Solo el dueño de plataforma.
-- (B) Auditoría: lista los usuarios NO-admin que poseen tableros propios (en el
--     modelo de empresa un miembro NO debe tener proyectos propios). Se muestra
--     al final para decidir la limpieza.
-- Idempotente.

-- ------------------------------------------------------------
-- (A) Cambiar/resetear contraseña (solo administrador)
-- ------------------------------------------------------------
create or replace function public.admin_set_password(p_user uuid, p_password text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not public.is_platform_owner() then raise exception 'Solo el administrador'; end if;
  if length(coalesce(p_password, '')) < 8 then raise exception 'La contraseña debe tener al menos 8 caracteres'; end if;
  update auth.users
     set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')),
         updated_at = now()
   where id = p_user;
  if not found then raise exception 'Usuario no encontrado'; end if;
  perform public._audit('password_reset', 'user', p_user, '{}'::jsonb);
end $$;

grant execute on function public.admin_set_password(uuid, text) to authenticated;

-- ------------------------------------------------------------
-- (B) AUDITORÍA: miembros (no-admin) que poseen tableros propios (no deberían).
--     Este SELECT es el último → su resultado se muestra en el editor.
-- ------------------------------------------------------------
select p.email, p.role, coalesce(p.status, '?') as status,
       b.id as board_id, b.name as proyecto,
       (select count(*) from public.task_items t where t.board_id = b.id) as tareas
from public.boards b
join public.profiles p on p.id = b.owner_id
where p.role <> 'owner'
order by p.email, b.name;
