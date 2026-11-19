-- جسر: إعداد قاعدة البيانات والتخزين
-- انسخ هذا الملف كاملًا والصقه في SQL Editor ثم اضغط Run مرة واحدة.

-- 1) جدول العناصر (مقفل تمامًا، لا يُوصل إليه إلا عبر الدوال بالأسفل)
create table if not exists public.items (
  id uuid primary key default gen_random_uuid(),
  room text not null,
  kind text not null check (kind in ('text','file')),
  data text not null,
  path text,
  size bigint default 0,
  created_at timestamptz not null default now()
);
create index if not exists items_room_time on public.items (room, created_at desc);
alter table public.items enable row level security;
revoke all on public.items from anon, authenticated;

-- 2) الدوال: لا تعمل إلا لمن يملك معرّف الدرج المشتق من العبارة السرية
create or replace function public.list_items(p_room text)
returns table (id uuid, kind text, data text, path text, size bigint, created_at timestamptz)
language sql security definer set search_path = public as $$
  select i.id, i.kind, i.data, i.path, i.size, i.created_at
  from public.items i
  where i.room = p_room and length(p_room) = 64
  order by i.created_at desc
  limit 300;
$$;

create or replace function public.add_item(p_room text, p_kind text, p_data text, p_path text default null, p_size bigint default 0)
returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if length(p_room) <> 64 then raise exception 'bad room'; end if;
  if length(p_data) > 500000 then raise exception 'too big'; end if;
  if p_path is not null and split_part(p_path, '/', 1) <> p_room then raise exception 'bad path'; end if;
  insert into public.items (room, kind, data, path, size)
  values (p_room, p_kind, p_data, p_path, p_size)
  returning id into new_id;
  return new_id;
end $$;

create or replace function public.delete_item(p_room text, p_id uuid)
returns text language sql security definer set search_path = public as $$
  delete from public.items where id = p_id and room = p_room returning path;
$$;

revoke all on function public.list_items(text) from public;
revoke all on function public.add_item(text, text, text, text, bigint) from public;
revoke all on function public.delete_item(text, uuid) from public;
grant execute on function public.list_items(text) to anon, authenticated;
grant execute on function public.add_item(text, text, text, text, bigint) to anon, authenticated;
grant execute on function public.delete_item(text, uuid) to anon, authenticated;

-- 3) مخزن الملفات (خاص، والملفات تُرفع مشفّرة من المتصفح)
insert into storage.buckets (id, name, public, file_size_limit)
values ('drop', 'drop', false, 52428800)
on conflict (id) do nothing;

drop policy if exists "jisr insert" on storage.objects;
drop policy if exists "jisr read" on storage.objects;
drop policy if exists "jisr delete" on storage.objects;
create policy "jisr insert" on storage.objects for insert to anon with check (bucket_id = 'drop');
create policy "jisr read"   on storage.objects for select to anon using (bucket_id = 'drop');
create policy "jisr delete" on storage.objects for delete to anon using (bucket_id = 'drop');
