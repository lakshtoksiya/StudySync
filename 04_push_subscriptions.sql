-- Push notifications: stores each device that turned on Push alerts.
-- Run ONCE in Supabase SQL Editor (after 01, 02, 03).

create table if not exists push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index if not exists idx_push_user on push_subscriptions (user_id);

alter table push_subscriptions enable row level security;

-- A user can only see and remove their own devices.
create policy push_select_own on push_subscriptions for select to authenticated
  using (user_id = auth.uid());
create policy push_delete_own on push_subscriptions for delete to authenticated
  using (user_id = auth.uid());

-- The app saves a device through this function (it also moves a device
-- to the new user if someone else logs in on the same phone).
create or replace function save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  insert into push_subscriptions (user_id, endpoint, p256dh, auth)
    values (auth.uid(), p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth;
end $$;

revoke all on function save_push_subscription(text, text, text) from public, anon;
grant execute on function save_push_subscription(text, text, text) to authenticated;
