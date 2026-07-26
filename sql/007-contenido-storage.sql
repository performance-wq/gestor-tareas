-- ============================================================
-- Organizadísimos · 007 · Storage del módulo de Contenido
-- ============================================================
-- Bucket 'content' para los archivos de cada pieza (video, miniatura, PSD…).
-- Las rutas son <account_id>/<content_id>/<archivo>, y las políticas aíslan por
-- la primera carpeta = account_id, igual que el resto del multi-tenant.
-- Idempotente.

insert into storage.buckets (id, name, public)
values ('content', 'content', true)
on conflict (id) do nothing;

-- Un usuario activo solo puede tocar objetos cuya primera carpeta sea su cuenta.
drop policy if exists content_storage_select on storage.objects;
create policy content_storage_select on storage.objects
  for select using (
    bucket_id = 'content'
    and (storage.foldername(name))[1] = public.current_account_id()::text
  );

drop policy if exists content_storage_insert on storage.objects;
create policy content_storage_insert on storage.objects
  for insert with check (
    bucket_id = 'content'
    and public.is_active_user()
    and (storage.foldername(name))[1] = public.current_account_id()::text
  );

drop policy if exists content_storage_delete on storage.objects;
create policy content_storage_delete on storage.objects
  for delete using (
    bucket_id = 'content'
    and (storage.foldername(name))[1] = public.current_account_id()::text
  );
