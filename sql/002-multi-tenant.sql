-- ============================================================
-- Organizadísimos · 002 · Multi-tenant con aislamiento estricto
-- ============================================================
-- Cada cliente (empresa) es una "account". Todo dato pertenece a una cuenta y
-- ninguna consulta puede cruzar de una cuenta a otra. La única excepción es el
-- propietario de la plataforma (role='owner'), que administra desde /admin.
-- Idempotente: se puede volver a ejecutar sin romper nada.

-- ---------- 1) Cuentas (tenants) ----------
create table if not exists public.accounts (
  id         uuid primary key default gen_random_uuid(),
  name       text        not null,
  active     boolean     not null default true,
  created_at timestamptz not null default now()
);
alter table public.accounts enable row level security;

-- ---------- 2) Vincular usuarios y tableros a una cuenta ----------
alter table public.profiles add column if not exists account_id uuid references public.accounts(id) on delete restrict;
alter table public.boards   add column if not exists account_id uuid references public.accounts(id) on delete cascade;

-- ---------- 3) Backfill de los datos existentes ----------
-- Una cuenta por cada usuario que aún no tenga: usa su empresa si está
-- registrada, si no su correo. Así ningún dato queda huérfano.
do $$
declare r record; nuevo uuid;
begin
  for r in select id, email, company from public.profiles where account_id is null loop
    insert into public.accounts (name)
    values (coalesce(nullif(trim(r.company), ''), r.email))
    returning id into nuevo;
    update public.profiles set account_id = nuevo where id = r.id;
  end loop;
end $$;

-- Cada tablero hereda la cuenta de su dueño.
update public.boards b
set account_id = p.account_id
from public.profiles p
where b.owner_id = p.id and b.account_id is null;

-- A partir de aquí, pertenecer a una cuenta es obligatorio.
alter table public.profiles alter column account_id set not null;
alter table public.boards   alter column account_id set not null;

create index if not exists profiles_account_idx on public.profiles(account_id);
create index if not exists boards_account_idx   on public.boards(account_id);

-- ---------- 4) Helpers ----------
-- Cuenta del usuario actual. security definer: no cruza RLS ni causa recursión.
create or replace function public.current_account_id()
returns uuid language sql security definer stable set search_path = public as $$
  select account_id from profiles where id = auth.uid();
$$;

-- Acceso permitido solo si el usuario Y su cuenta están activos.
create or replace function public.is_active_user()
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from profiles p
    join accounts a on a.id = p.account_id
    where p.id = auth.uid() and p.active and a.active
  );
$$;

-- ¿Ese usuario pertenece a mi misma cuenta?
create or replace function public.same_account(p_user uuid)
returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from profiles yo, profiles otro
    where yo.id = auth.uid() and otro.id = p_user and yo.account_id = otro.account_id
  );
$$;

-- Búsqueda de correo LIMITADA a la propia cuenta: un cliente no puede
-- siquiera comprobar si un correo de otra empresa existe.
create or replace function public.find_profile_id_by_email(p_email text)
returns uuid language sql security definer stable set search_path = public as $$
  select p.id from profiles p
  where lower(p.email) = lower(trim(p_email))
    and p.active
    and p.account_id = (select account_id from profiles where id = auth.uid())
  limit 1;
$$;

-- ---------- 5) RLS de accounts ----------
drop policy if exists accounts_select on public.accounts;
create policy accounts_select on public.accounts
  for select using (id = public.current_account_id() or public.is_platform_owner());

drop policy if exists accounts_manage_owner on public.accounts;
create policy accounts_manage_owner on public.accounts
  for all using (public.is_platform_owner()) with check (public.is_platform_owner());

-- ---------- 6) profiles: solo dentro de la propia cuenta ----------
drop policy if exists profiles_select_own_or_shared on public.profiles;
create policy profiles_select_own_or_shared on public.profiles
  for select using (
    id = auth.uid()
    or public.is_platform_owner()
    or (account_id = public.current_account_id() and public.shares_board_with(id))
  );

-- ---------- 7) boards: aislamiento estricto por cuenta ----------
drop policy if exists boards_select on public.boards;
create policy boards_select on public.boards for select using (
  public.is_active_user()
  and account_id = public.current_account_id()
  and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
);

drop policy if exists boards_insert on public.boards;
create policy boards_insert on public.boards for insert with check (
  public.is_active_user()
  and auth.uid() = owner_id
  and account_id = public.current_account_id()
);

drop policy if exists boards_update on public.boards;
create policy boards_update on public.boards for update using (
  public.is_active_user()
  and account_id = public.current_account_id()
  and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
) with check (
  public.is_active_user()
  and account_id = public.current_account_id()
  and (auth.uid() = owner_id or public.is_board_member(id, auth.uid()))
);

drop policy if exists boards_delete on public.boards;
create policy boards_delete on public.boards for delete using (
  public.is_active_user()
  and account_id = public.current_account_id()
  and auth.uid() = owner_id
);

-- ---------- 8) board_members: compartir solo dentro de la cuenta ----------
drop policy if exists members_select on public.board_members;
create policy members_select on public.board_members for select using (
  user_id = auth.uid() or public.is_board_owner(board_id, auth.uid())
);

drop policy if exists members_insert on public.board_members;
create policy members_insert on public.board_members for insert with check (
  public.is_board_owner(board_id, auth.uid()) and public.same_account(user_id)
);

drop policy if exists members_delete on public.board_members;
create policy members_delete on public.board_members for delete using (
  public.is_board_owner(board_id, auth.uid())
);
