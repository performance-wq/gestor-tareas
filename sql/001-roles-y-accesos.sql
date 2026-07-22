-- ============================================================
-- Organizadísimos · 001 · Roles, estado de cuenta y aislamiento
-- ============================================================
-- Separa dos perfiles: 'owner' (propietario del SaaS) y 'client'
-- (cliente final). Cierra la enumeración de correos que permitía
-- que cualquier usuario autenticado leyera TODA la tabla profiles.
-- Idempotente: se puede volver a ejecutar sin romper nada.

-- ---------- 1) Campos de rol y estado ----------
alter table public.profiles
  add column if not exists role       text        not null default 'client',
  add column if not exists active     boolean     not null default true,
  add column if not exists full_name  text,
  add column if not exists company    text,
  add column if not exists created_at timestamptz not null default now();

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add  constraint profiles_role_check check (role in ('owner','client'));

-- El propietario de la plataforma.
update public.profiles set role = 'owner', active = true
where lower(email) = 'performance@agenciapex.com';

-- ---------- 2) Helpers security definer ----------
-- Nunca se cruzan dos tablas con RLS activo dentro de sus propias
-- políticas: estas funciones bypasean RLS y evitan recursión infinita.

create or replace function public.is_platform_owner()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'owner');
$$;

create or replace function public.is_active_user()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and active);
$$;

-- Resuelve UN correo concreto sin exponer el listado completo.
-- Sustituye al select abierto sobre profiles que usaba "compartir proyecto".
create or replace function public.find_profile_id_by_email(p_email text)
returns uuid language sql security definer stable set search_path = public as $$
  select id from profiles
  where lower(email) = lower(trim(p_email)) and active
  limit 1;
$$;

-- ¿El usuario actual comparte algún tablero con p_user?
-- Permite que los miembros de un proyecto sigan viendo los correos
-- de sus compañeros, sin abrir el resto de la tabla.
create or replace function public.shares_board_with(p_user uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1
    from boards b
    where (b.owner_id = auth.uid()
           or exists (select 1 from board_members m where m.board_id = b.id and m.user_id = auth.uid()))
      and (b.owner_id = p_user
           or exists (select 1 from board_members m2 where m2.board_id = b.id and m2.user_id = p_user))
  );
$$;

-- ---------- 3) profiles: cerrar la fuga de correos ----------
drop policy if exists profiles_select_authenticated on public.profiles;
drop policy if exists profiles_select_own_or_shared on public.profiles;
create policy profiles_select_own_or_shared on public.profiles
  for select using (
    id = auth.uid()
    or public.is_platform_owner()
    or public.shares_board_with(id)
  );

-- Solo el propietario de la plataforma administra cuentas.
drop policy if exists profiles_update_owner on public.profiles;
create policy profiles_update_owner on public.profiles
  for update using (public.is_platform_owner()) with check (public.is_platform_owner());

drop policy if exists profiles_delete_owner on public.profiles;
create policy profiles_delete_owner on public.profiles
  for delete using (public.is_platform_owner());

-- ---------- 4) Cuentas desactivadas pierden el acceso a los datos ----------
-- Se conservan las reglas anteriores y se les añade la condición de cuenta activa.

drop policy if exists boards_select on public.boards;
create policy boards_select on public.boards
  for select using (
    public.is_active_user()
    and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
  );

drop policy if exists boards_insert on public.boards;
create policy boards_insert on public.boards
  for insert with check (public.is_active_user() and auth.uid() = owner_id);

drop policy if exists boards_update on public.boards;
create policy boards_update on public.boards
  for update using (
    public.is_active_user()
    and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
  ) with check (
    public.is_active_user()
    and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
  );

drop policy if exists boards_delete on public.boards;
create policy boards_delete on public.boards
  for delete using (public.is_active_user() and auth.uid() = owner_id);
