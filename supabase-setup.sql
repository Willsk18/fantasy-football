-- Cross-device sync for the 2026 draft board.
-- Run once: Supabase dashboard -> SQL Editor -> New query -> paste -> Run.

create table if not exists public.boards (
  code       text primary key,
  data       jsonb not null,
  updated_at timestamptz not null default now(),
  constraint boards_code_shape
    check (code ~ '^[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$')
);

-- RLS on with no policies attached, plus the revoke below, means the anon key
-- cannot touch this table directly at all. That matters: the anon key ships in
-- the page source, so without this anyone could read every row in the table.
-- All access goes through the two functions below, which run as the table
-- owner and only ever return the single row whose code you already know.
alter table public.boards enable row level security;
revoke all on public.boards from anon, authenticated;

create or replace function public.board_get(p_code text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select data from public.boards where code = p_code;
$$;

create or replace function public.board_put(p_code text, p_data jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_code !~ '^[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}$' then
    raise exception 'malformed code';
  end if;
  if pg_column_size(p_data) > 400000 then
    raise exception 'payload too large';
  end if;
  insert into public.boards as b (code, data, updated_at)
  values (p_code, p_data, now())
  on conflict (code) do update
    set data = excluded.data, updated_at = now();
end;
$$;

revoke all on function public.board_get(text)        from public;
revoke all on function public.board_put(text, jsonb) from public;
grant execute on function public.board_get(text)        to anon;
grant execute on function public.board_put(text, jsonb) to anon;
