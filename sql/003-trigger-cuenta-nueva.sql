-- ============================================================
-- Organizadísimos · 003 · El alta de usuario crea su cuenta
-- ============================================================
-- Tras la migración 002, profiles.account_id es obligatorio. El trigger que
-- crea el perfil al dar de alta un usuario no lo sabía, así que cualquier alta
-- fallaba. Ahora crea una cuenta propia y engancha el perfil a ella.
-- La Edge Function admin-create-user puede después mover al usuario a la
-- cuenta real de la empresa.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare nueva uuid;
begin
  insert into public.accounts (name) values (new.email) returning id into nueva;
  insert into public.profiles (id, email, account_id) values (new.id, new.email, nueva);
  return new;
end;
$$;
