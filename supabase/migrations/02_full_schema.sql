-- =====================================================================
-- NOTES APP: FULL DATABASE SCRIPT  (Supabase SQL Editor mein EK BAAR chalana)
-- Pehle "templates" table ban chuka hai, usse yahan dobara nahi banate.
-- =====================================================================

-- ---------- 1. TABLES ----------

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default 'Student',
  college text, branch text, year text, avatar_url text,
  created_at timestamptz not null default now()
);

create table communities (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  type text not null check (type in ('branch','division','subject','friends')),
  privacy text not null default 'private' check (privacy in ('public','private','invite_only')),
  course text, branch text,
  join_code text unique not null,
  is_code_active boolean not null default true,
  code_expires_at timestamptz,
  max_members int,
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now()
);

create table members (
  community_id uuid not null references communities(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('admin','cr','member')),
  status text not null default 'active' check (status in ('active','pending','removed')),
  joined_at timestamptz not null default now(),
  primary key (community_id, user_id)
);

create table terms (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id) on delete cascade,
  name text not null,
  term_no int,
  academic_year text,
  is_current boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now()
);

create table subjects (
  id uuid primary key default gen_random_uuid(),
  term_id uuid not null references terms(id) on delete cascade,
  community_id uuid not null references communities(id) on delete cascade,
  name text not null,
  code text, teacher text,
  choice_group text,
  from_template boolean not null default false,
  is_archived boolean not null default false,
  sort_order int not null default 0,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);

create table subject_requests (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id) on delete cascade,
  requested_by uuid not null references profiles(id),
  name text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);

create table notes (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references communities(id) on delete cascade,
  subject_id uuid not null references subjects(id),
  uploaded_by uuid not null references profiles(id),
  title text,
  category text not null default 'class_note'
    check (category in ('class_note','unit_note','assignment','pyq','other')),
  unit_no int,
  topic text,
  class_date date not null default current_date,
  due_date date,
  exam_year int,
  upload_batch_id uuid,
  notified boolean not null default false,
  is_pinned boolean not null default false,
  helpful_count int not null default 0,
  is_deleted boolean not null default false,
  last_edited_by uuid references profiles(id),
  last_edited_at timestamptz,
  created_at timestamptz not null default now()
);

create table note_files (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references notes(id) on delete cascade,
  file_path text not null,
  file_type text not null check (file_type in ('image','pdf')),
  page_no int not null default 1,
  size_bytes bigint,
  created_at timestamptz not null default now()
);

create table note_edits (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references notes(id) on delete cascade,
  edited_by uuid references profiles(id),
  field text not null,
  old_value text, new_value text,
  edited_at timestamptz not null default now()
);

create table note_suggestions (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references notes(id) on delete cascade,
  suggested_by uuid not null references profiles(id),
  field text not null check (field in ('subject','unit','topic','date','other')),
  new_value text,
  comment text,
  status text not null default 'pending' check (status in ('pending','accepted','rejected')),
  reject_reason text,
  resolved_by uuid references profiles(id),
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index one_pending_suggestion
  on note_suggestions (note_id, suggested_by) where status = 'pending';

create table likes (
  note_id uuid not null references notes(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

create table saves (
  note_id uuid not null references notes(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (note_id, user_id)
);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles(id) on delete cascade,
  community_id uuid references communities(id) on delete cascade,
  note_id uuid references notes(id) on delete cascade,
  type text not null,
  message text not null,
  is_read boolean not null default false,
  created_at timestamptz not null default now()
);

create index idx_members_user on members (user_id);
create index idx_terms_comm on terms (community_id);
create index idx_subjects_term on subjects (term_id);
create index idx_notes_comm_date on notes (community_id, class_date desc);
create index idx_notes_subject_date on notes (subject_id, class_date desc);
create index idx_notes_batch on notes (upload_batch_id);
create index idx_files_note on note_files (note_id);
create index idx_notif_user on notifications (user_id, created_at desc);

-- ---------- 2. HELPER FUNCTIONS (permission checks) ----------

create or replace function is_member(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members
    where community_id = cid and user_id = auth.uid() and status = 'active');
$$;

create or replace function is_staff(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members
    where community_id = cid and user_id = auth.uid()
      and status = 'active' and role in ('admin','cr'));
$$;

create or replace function is_admin(cid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from members
    where community_id = cid and user_id = auth.uid()
      and status = 'active' and role = 'admin');
$$;

-- ---------- 3. NEW USER -> PROFILE ----------

create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name',
                           new.raw_user_meta_data->>'name',
                           split_part(new.email, '@', 1), 'Student'))
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- 4. COMMUNITY FUNCTIONS (app inhe call karega) ----------

-- internal: template se term + subjects load karna (app seedha call nahi kar sakta)
create or replace function _load_term(p_community uuid, p_term_no int) returns uuid
language plpgsql security definer set search_path = public as $$
declare c communities; t templates; v_term uuid;
begin
  select * into c from communities where id = p_community;
  select * into t from templates
    where course = c.course and branch = c.branch and term_no = p_term_no limit 1;
  insert into terms (community_id, name, term_no)
    values (p_community, coalesce(t.term_name, 'Sem ' || p_term_no), p_term_no)
    returning id into v_term;
  if t.id is not null then
    insert into subjects (term_id, community_id, name, choice_group, from_template, sort_order, created_by)
    select v_term, p_community, x->>'name', x->>'choice_group', true,
           coalesce((x->>'sort_order')::int, 0), auth.uid()
    from jsonb_array_elements(t.subjects) x;
  end if;
  return v_term;
end $$;

create or replace function create_community(
  p_name text, p_type text, p_privacy text,
  p_course text, p_branch text, p_term_no int default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_code text;
begin
  if auth.uid() is null then raise exception 'Login zaruri hai'; end if;
  loop
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from communities where join_code = v_code);
  end loop;
  insert into communities (name, type, privacy, course, branch, join_code, created_by)
    values (trim(p_name), p_type, p_privacy, p_course, p_branch, v_code, auth.uid())
    returning id into v_id;
  insert into members (community_id, user_id, role, status)
    values (v_id, auth.uid(), 'admin', 'active');
  if p_term_no is not null then perform _load_term(v_id, p_term_no); end if;
  return v_id;
end $$;

create or replace function start_new_term(p_community uuid, p_term_no int) returns uuid
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff(p_community) then raise exception 'Sirf Admin ya CR ye kar sakta hai'; end if;
  update terms set is_current = false, is_archived = true
    where community_id = p_community and is_current;
  return _load_term(p_community, p_term_no);
end $$;

create or replace function join_community(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c communities; m members; v_status text; v_count int; who text;
begin
  if auth.uid() is null then raise exception 'Login zaruri hai'; end if;
  select * into c from communities where upper(join_code) = upper(trim(p_code));
  if not found or not c.is_code_active
     or (c.code_expires_at is not null and c.code_expires_at < now()) then
    raise exception 'Code galat hai ya band ho gaya hai';
  end if;
  select * into m from members where community_id = c.id and user_id = auth.uid();
  if found then
    if m.status = 'removed' then raise exception 'Aapko is community se hata diya gaya hai'; end if;
    return jsonb_build_object('community_id', c.id, 'name', c.name, 'status', m.status);
  end if;
  if c.max_members is not null then
    select count(*) into v_count from members where community_id = c.id and status = 'active';
    if v_count >= c.max_members then raise exception 'Community full ho chuki hai'; end if;
  end if;
  -- private = approval chahiye; public aur invite_only = code se seedha join
  v_status := case when c.privacy = 'private' then 'pending' else 'active' end;
  insert into members (community_id, user_id, role, status)
    values (c.id, auth.uid(), 'member', v_status);
  if v_status = 'pending' then
    select name into who from profiles where id = auth.uid();
    insert into notifications (user_id, community_id, type, message)
    select user_id, c.id, 'join_request', who || ' ne ' || c.name || ' join karne ki request bheji hai'
    from members where community_id = c.id and status = 'active' and role in ('admin','cr');
  end if;
  return jsonb_build_object('community_id', c.id, 'name', c.name, 'status', v_status);
end $$;

create or replace function reset_join_code(p_community uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if not is_staff(p_community) then raise exception 'Sirf Admin ya CR ye kar sakta hai'; end if;
  loop
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    exit when not exists (select 1 from communities where join_code = v_code);
  end loop;
  update communities set join_code = v_code, is_code_active = true where id = p_community;
  return v_code;
end $$;

create or replace function set_member_role(p_community uuid, p_user uuid, p_role text) returns void
language plpgsql security definer set search_path = public as $$
declare target members;
begin
  if not is_admin(p_community) then raise exception 'Sirf Admin role badal sakta hai'; end if;
  if p_role not in ('cr','member') then raise exception 'Role galat hai'; end if;
  select * into target from members where community_id = p_community and user_id = p_user;
  if not found then raise exception 'Member nahi mila'; end if;
  if target.role = 'admin' then raise exception 'Admin ka role badla nahi ja sakta'; end if;
  update members set role = p_role where community_id = p_community and user_id = p_user;
end $$;

-- p_status: 'active' (approve / wapas lao) ya 'removed' (hata do)
create or replace function set_member_status(p_community uuid, p_user uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare target members; cname text;
begin
  if not is_staff(p_community) then raise exception 'Sirf Admin ya CR ye kar sakta hai'; end if;
  if p_status not in ('active','removed') then raise exception 'Status galat hai'; end if;
  select * into target from members where community_id = p_community and user_id = p_user;
  if not found then raise exception 'Member nahi mila'; end if;
  if target.role = 'admin' then raise exception 'Admin ko hataya nahi ja sakta'; end if;
  if target.role = 'cr' and not is_admin(p_community) then
    raise exception 'CR ko sirf Admin hata sakta hai';
  end if;
  update members set status = p_status where community_id = p_community and user_id = p_user;
  if p_status = 'active' and target.status = 'pending' then
    select name into cname from communities where id = p_community;
    insert into notifications (user_id, community_id, type, message)
      values (p_user, p_community, 'join_approved', cname || ' mein aapki request accept ho gayi');
  end if;
end $$;

-- ---------- 5. NOTES: triggers ----------

create or replace function notes_before_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.community_id := old.community_id;
  new.uploaded_by := old.uploaded_by;
  new.upload_batch_id := old.upload_batch_id;
  new.created_at := old.created_at;
  if coalesce(current_setting('app.internal', true), '') <> '1' then
    new.helpful_count := old.helpful_count;
  end if;
  if new.is_pinned is distinct from old.is_pinned and not is_staff(new.community_id) then
    new.is_pinned := old.is_pinned;
  end if;
  if new.subject_id is distinct from old.subject_id and not exists
     (select 1 from subjects where id = new.subject_id and community_id = new.community_id) then
    raise exception 'Ye subject is community ka nahi hai';
  end if;
  if new.subject_id is distinct from old.subject_id
     or new.unit_no is distinct from old.unit_no
     or new.topic is distinct from old.topic
     or new.class_date is distinct from old.class_date
     or new.category is distinct from old.category then
    new.last_edited_by := auth.uid();
    new.last_edited_at := now();
  end if;
  return new;
end $$;

create trigger trg_notes_before_update before update on notes
  for each row execute function notes_before_update();

create or replace function notes_after_update() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.subject_id is distinct from old.subject_id then
    insert into note_edits (note_id, edited_by, field, old_value, new_value) values
      (new.id, auth.uid(), 'subject',
       (select name from subjects where id = old.subject_id),
       (select name from subjects where id = new.subject_id));
  end if;
  if new.unit_no is distinct from old.unit_no then
    insert into note_edits (note_id, edited_by, field, old_value, new_value)
      values (new.id, auth.uid(), 'unit', old.unit_no::text, new.unit_no::text);
  end if;
  if new.topic is distinct from old.topic then
    insert into note_edits (note_id, edited_by, field, old_value, new_value)
      values (new.id, auth.uid(), 'topic', old.topic, new.topic);
  end if;
  if new.class_date is distinct from old.class_date then
    insert into note_edits (note_id, edited_by, field, old_value, new_value)
      values (new.id, auth.uid(), 'date', old.class_date::text, new.class_date::text);
  end if;
  return new;
end $$;

create trigger trg_notes_after_update after update on notes
  for each row execute function notes_after_update();

-- helpful count (likes ke hisaab se)
create or replace function sync_helpful() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_note uuid;
begin
  if tg_op = 'DELETE' then v_note := old.note_id; else v_note := new.note_id; end if;
  perform set_config('app.internal', '1', true);
  update notes set helpful_count = (select count(*) from likes where note_id = v_note)
    where id = v_note;
  perform set_config('app.internal', '0', true);
  return null;
end $$;

create trigger trg_likes_sync after insert or delete on likes
  for each row execute function sync_helpful();

-- ek upload ka ek notification (app upload ke baad ye call karega)
create or replace function publish_upload(p_batch uuid) returns int
language plpgsql security definer set search_path = public as $$
declare v_comm uuid; v_subjects text; v_who text; v_count int;
begin
  select community_id into v_comm from notes
    where upload_batch_id = p_batch and uploaded_by = auth.uid()
      and is_deleted = false and notified = false limit 1;
  if v_comm is null then return 0; end if;
  select string_agg(distinct s.name, ', ') into v_subjects
    from notes n join subjects s on s.id = n.subject_id
    where n.upload_batch_id = p_batch and n.uploaded_by = auth.uid();
  select name into v_who from profiles where id = auth.uid();
  insert into notifications (user_id, community_id, type, message)
    select user_id, v_comm, 'new_notes', v_who || ' ne notes upload kiye: ' || v_subjects
    from members where community_id = v_comm and status = 'active' and user_id <> auth.uid();
  get diagnostics v_count = row_count;
  update notes set notified = true
    where upload_batch_id = p_batch and uploaded_by = auth.uid();
  return v_count;
end $$;

-- note delete (asal mein hide hota hai, wapas aa sakta hai)
create or replace function delete_note(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n notes;
begin
  select * into n from notes where id = p_id;
  if not found then raise exception 'Note nahi mila'; end if;
  if n.uploaded_by <> auth.uid() and not is_staff(n.community_id) then
    raise exception 'Aap ye note delete nahi kar sakte';
  end if;
  update notes set is_deleted = true where id = p_id;
end $$;

-- ---------- 6. CORRECTION SUGGEST ----------

create or replace function notify_suggestion() returns trigger
language plpgsql security definer set search_path = public as $$
declare n notes; who text;
begin
  select * into n from notes where id = new.note_id;
  select name into who from profiles where id = new.suggested_by;
  if n.uploaded_by <> new.suggested_by then
    insert into notifications (user_id, community_id, note_id, type, message)
      values (n.uploaded_by, n.community_id, n.id, 'suggestion',
              who || ' ne aapke note par correction suggest kiya hai');
  end if;
  return new;
end $$;

create trigger trg_suggestion_notify after insert on note_suggestions
  for each row execute function notify_suggestion();

create or replace function accept_suggestion(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare sg note_suggestions; n notes;
begin
  select * into sg from note_suggestions where id = p_id and status = 'pending';
  if not found then raise exception 'Suggestion nahi mila ya pehle hi handle ho chuka hai'; end if;
  select * into n from notes where id = sg.note_id;
  if auth.uid() is distinct from n.uploaded_by and not is_staff(n.community_id) then
    raise exception 'Aapko ye karne ki permission nahi hai';
  end if;
  if sg.field = 'subject' then
    update notes set subject_id = sg.new_value::uuid where id = n.id;
  elsif sg.field = 'unit' then
    update notes set unit_no = nullif(sg.new_value, '')::int where id = n.id;
  elsif sg.field = 'topic' then
    update notes set topic = sg.new_value where id = n.id;
  elsif sg.field = 'date' then
    update notes set class_date = sg.new_value::date where id = n.id;
  end if;
  update note_suggestions set status = 'accepted', resolved_by = auth.uid(), resolved_at = now()
    where id = p_id;
  insert into notifications (user_id, community_id, note_id, type, message)
    values (sg.suggested_by, n.community_id, n.id, 'suggestion_accepted',
            'Aapka correction suggestion accept ho gaya');
end $$;

create or replace function reject_suggestion(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare sg note_suggestions; n notes;
begin
  select * into sg from note_suggestions where id = p_id and status = 'pending';
  if not found then raise exception 'Suggestion nahi mila ya pehle hi handle ho chuka hai'; end if;
  select * into n from notes where id = sg.note_id;
  if auth.uid() is distinct from n.uploaded_by and not is_staff(n.community_id) then
    raise exception 'Aapko ye karne ki permission nahi hai';
  end if;
  update note_suggestions
    set status = 'rejected', reject_reason = p_reason, resolved_by = auth.uid(), resolved_at = now()
    where id = p_id;
  insert into notifications (user_id, community_id, note_id, type, message)
    values (sg.suggested_by, n.community_id, n.id, 'suggestion_rejected',
            'Aapka correction suggestion reject hua' || coalesce(': ' || p_reason, ''));
end $$;

-- ---------- 7. PRIVACY RULES (Row Level Security) ----------

alter table profiles          enable row level security;
alter table communities       enable row level security;
alter table members           enable row level security;
alter table terms             enable row level security;
alter table subjects          enable row level security;
alter table subject_requests  enable row level security;
alter table notes             enable row level security;
alter table note_files        enable row level security;
alter table note_edits        enable row level security;
alter table note_suggestions  enable row level security;
alter table likes             enable row level security;
alter table saves             enable row level security;
alter table notifications     enable row level security;
alter table templates         enable row level security;

-- templates: login kiya hua koi bhi padh sakta hai, badal nahi sakta
create policy templates_read on templates for select to authenticated using (true);

-- profiles
create policy profiles_read on profiles for select to authenticated using (true);
create policy profiles_update_own on profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_insert_own on profiles for insert to authenticated
  with check (id = auth.uid());

-- communities (banana / join: functions se hota hai)
create policy communities_read on communities for select to authenticated
  using (privacy = 'public' or is_member(id));
create policy communities_update on communities for update to authenticated
  using (is_admin(id)) with check (is_admin(id));
create policy communities_delete on communities for delete to authenticated
  using (is_admin(id));

-- members
create policy members_read on members for select to authenticated
  using (user_id = auth.uid() or is_member(community_id));
create policy members_leave on members for delete to authenticated
  using (user_id = auth.uid());

-- terms
create policy terms_read on terms for select to authenticated using (is_member(community_id));
create policy terms_update on terms for update to authenticated
  using (is_staff(community_id)) with check (is_staff(community_id));

-- subjects (add / edit / archive: sirf Admin aur CR)
create policy subjects_read on subjects for select to authenticated using (is_member(community_id));
create policy subjects_insert on subjects for insert to authenticated
  with check (is_staff(community_id) and exists
    (select 1 from terms t where t.id = subjects.term_id and t.community_id = subjects.community_id));
create policy subjects_update on subjects for update to authenticated
  using (is_staff(community_id)) with check (is_staff(community_id));

-- subject requests (member request bheje, CR approve kare)
create policy sreq_insert on subject_requests for insert to authenticated
  with check (requested_by = auth.uid() and is_member(community_id));
create policy sreq_read on subject_requests for select to authenticated
  using (requested_by = auth.uid() or is_staff(community_id));
create policy sreq_update on subject_requests for update to authenticated
  using (is_staff(community_id)) with check (is_staff(community_id));

-- notes (har member upload kare; edit: uploader ya CR/Admin; delete = is_deleted true)
create policy notes_read on notes for select to authenticated
  using (is_member(community_id) and is_deleted = false);
create policy notes_insert on notes for insert to authenticated
  with check (uploaded_by = auth.uid() and is_member(community_id) and exists
    (select 1 from subjects s where s.id = notes.subject_id
       and s.community_id = notes.community_id and s.is_archived = false));
create policy notes_update on notes for update to authenticated
  using (uploaded_by = auth.uid() or is_staff(community_id))
  with check (uploaded_by = auth.uid() or is_staff(community_id));

-- note files
create policy files_read on note_files for select to authenticated
  using (exists (select 1 from notes n where n.id = note_files.note_id));
create policy files_insert on note_files for insert to authenticated
  with check (exists (select 1 from notes n
    where n.id = note_files.note_id and n.uploaded_by = auth.uid()));
create policy files_delete on note_files for delete to authenticated
  using (exists (select 1 from notes n where n.id = note_files.note_id
    and (n.uploaded_by = auth.uid() or is_staff(n.community_id))));

-- edit history
create policy edits_read on note_edits for select to authenticated
  using (exists (select 1 from notes n where n.id = note_edits.note_id));

-- correction suggestions
create policy sugg_read on note_suggestions for select to authenticated
  using (suggested_by = auth.uid() or exists (select 1 from notes n
    where n.id = note_suggestions.note_id
      and (n.uploaded_by = auth.uid() or is_staff(n.community_id))));
create policy sugg_insert on note_suggestions for insert to authenticated
  with check (suggested_by = auth.uid() and status = 'pending'
    and exists (select 1 from notes n where n.id = note_suggestions.note_id));

-- likes / saves
create policy likes_read on likes for select to authenticated
  using (exists (select 1 from notes n where n.id = likes.note_id));
create policy likes_insert on likes for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from notes n where n.id = likes.note_id));
create policy likes_delete on likes for delete to authenticated using (user_id = auth.uid());

create policy saves_read on saves for select to authenticated using (user_id = auth.uid());
create policy saves_insert on saves for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from notes n where n.id = saves.note_id));
create policy saves_delete on saves for delete to authenticated using (user_id = auth.uid());

-- notifications (sirf apne)
create policy notif_read on notifications for select to authenticated using (user_id = auth.uid());
create policy notif_update on notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notif_delete on notifications for delete to authenticated using (user_id = auth.uid());

-- ---------- 8. FUNCTION PERMISSIONS ----------

do $$
declare r record;
begin
  for r in select p.proname as nm, p.oid::regprocedure as sig
           from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' loop
    if r.nm like '\_%' then
      execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    else
      execute format('revoke all on function %s from public, anon', r.sig);
      execute format('grant execute on function %s to authenticated', r.sig);
    end if;
  end loop;
end $$;

-- ---------- 9. FILE STORAGE (private bucket "notes") ----------
-- File path ka format: <community_id>/<user_id>/<filename>

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('notes', 'notes', false, 20971520,
        array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do nothing;

create policy notes_storage_read on storage.objects for select to authenticated
  using (bucket_id = 'notes' and is_member(((storage.foldername(name))[1])::uuid));

create policy notes_storage_upload on storage.objects for insert to authenticated
  with check (bucket_id = 'notes'
    and is_member(((storage.foldername(name))[1])::uuid)
    and (storage.foldername(name))[2] = auth.uid()::text);

create policy notes_storage_delete on storage.objects for delete to authenticated
  using (bucket_id = 'notes'
    and ((storage.foldername(name))[2] = auth.uid()::text
         or is_staff(((storage.foldername(name))[1])::uuid)));

-- ---------- 10. LIVE UPDATES (notification bell ke liye) ----------

do $$
begin
  alter publication supabase_realtime add table notifications;
exception when others then null;
end $$;

-- DONE. Check: Table Editor mein 14 tables (templates ko milakar) dikhne chahiye.
