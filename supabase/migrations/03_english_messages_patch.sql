-- Patch: database messages ko English mein badalta hai (functions replace hote hain, data ya permissions nahi badalte)
-- Pehle se chali hui 02_full_schema.sql ke baad EK BAAR chalao.

create or replace function create_community(
  p_name text, p_type text, p_privacy text,
  p_course text, p_branch text, p_term_no int default null
) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_code text;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
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
  if not is_staff(p_community) then raise exception 'Only an Admin or CR can do this'; end if;
  update terms set is_current = false, is_archived = true
    where community_id = p_community and is_current;
  return _load_term(p_community, p_term_no);
end $$;

create or replace function join_community(p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare c communities; m members; v_status text; v_count int; who text;
begin
  if auth.uid() is null then raise exception 'Login required'; end if;
  select * into c from communities where upper(join_code) = upper(trim(p_code));
  if not found or not c.is_code_active
     or (c.code_expires_at is not null and c.code_expires_at < now()) then
    raise exception 'Invalid code, or the code is turned off';
  end if;
  select * into m from members where community_id = c.id and user_id = auth.uid();
  if found then
    if m.status = 'removed' then raise exception 'You have been removed from this community'; end if;
    return jsonb_build_object('community_id', c.id, 'name', c.name, 'status', m.status);
  end if;
  if c.max_members is not null then
    select count(*) into v_count from members where community_id = c.id and status = 'active';
    if v_count >= c.max_members then raise exception 'This community is full'; end if;
  end if;
  -- private = approval chahiye; public aur invite_only = code se seedha join
  v_status := case when c.privacy = 'private' then 'pending' else 'active' end;
  insert into members (community_id, user_id, role, status)
    values (c.id, auth.uid(), 'member', v_status);
  if v_status = 'pending' then
    select name into who from profiles where id = auth.uid();
    insert into notifications (user_id, community_id, type, message)
    select user_id, c.id, 'join_request', who || ' requested to join ' || c.name
    from members where community_id = c.id and status = 'active' and role in ('admin','cr');
  end if;
  return jsonb_build_object('community_id', c.id, 'name', c.name, 'status', v_status);
end $$;

create or replace function reset_join_code(p_community uuid) returns text
language plpgsql security definer set search_path = public as $$
declare v_code text;
begin
  if not is_staff(p_community) then raise exception 'Only an Admin or CR can do this'; end if;
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
  if not is_admin(p_community) then raise exception 'Only an Admin can change roles'; end if;
  if p_role not in ('cr','member') then raise exception 'Invalid role'; end if;
  select * into target from members where community_id = p_community and user_id = p_user;
  if not found then raise exception 'Member not found'; end if;
  if target.role = 'admin' then raise exception 'An Admin role cannot be changed'; end if;
  update members set role = p_role where community_id = p_community and user_id = p_user;
end $$;

create or replace function set_member_status(p_community uuid, p_user uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
declare target members; cname text;
begin
  if not is_staff(p_community) then raise exception 'Only an Admin or CR can do this'; end if;
  if p_status not in ('active','removed') then raise exception 'Invalid status'; end if;
  select * into target from members where community_id = p_community and user_id = p_user;
  if not found then raise exception 'Member not found'; end if;
  if target.role = 'admin' then raise exception 'An Admin cannot be removed'; end if;
  if target.role = 'cr' and not is_admin(p_community) then
    raise exception 'Only an Admin can remove a CR';
  end if;
  update members set status = p_status where community_id = p_community and user_id = p_user;
  if p_status = 'active' and target.status = 'pending' then
    select name into cname from communities where id = p_community;
    insert into notifications (user_id, community_id, type, message)
      values (p_user, p_community, 'join_approved', 'Your request to join ' || cname || ' was approved');
  end if;
end $$;

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
    raise exception 'This subject does not belong to this community';
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
    select user_id, v_comm, 'new_notes', v_who || ' uploaded notes: ' || v_subjects
    from members where community_id = v_comm and status = 'active' and user_id <> auth.uid();
  get diagnostics v_count = row_count;
  update notes set notified = true
    where upload_batch_id = p_batch and uploaded_by = auth.uid();
  return v_count;
end $$;

create or replace function delete_note(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n notes;
begin
  select * into n from notes where id = p_id;
  if not found then raise exception 'Note not found'; end if;
  if n.uploaded_by <> auth.uid() and not is_staff(n.community_id) then
    raise exception 'You cannot delete this note';
  end if;
  update notes set is_deleted = true where id = p_id;
end $$;

create or replace function notify_suggestion() returns trigger
language plpgsql security definer set search_path = public as $$
declare n notes; who text;
begin
  select * into n from notes where id = new.note_id;
  select name into who from profiles where id = new.suggested_by;
  if n.uploaded_by <> new.suggested_by then
    insert into notifications (user_id, community_id, note_id, type, message)
      values (n.uploaded_by, n.community_id, n.id, 'suggestion',
              who || ' suggested a correction on your note');
  end if;
  return new;
end $$;

create or replace function accept_suggestion(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare sg note_suggestions; n notes;
begin
  select * into sg from note_suggestions where id = p_id and status = 'pending';
  if not found then raise exception 'Suggestion not found or already handled'; end if;
  select * into n from notes where id = sg.note_id;
  if auth.uid() is distinct from n.uploaded_by and not is_staff(n.community_id) then
    raise exception 'You do not have permission to do this';
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
            'Your correction suggestion was accepted');
end $$;

create or replace function reject_suggestion(p_id uuid, p_reason text default null) returns void
language plpgsql security definer set search_path = public as $$
declare sg note_suggestions; n notes;
begin
  select * into sg from note_suggestions where id = p_id and status = 'pending';
  if not found then raise exception 'Suggestion not found or already handled'; end if;
  select * into n from notes where id = sg.note_id;
  if auth.uid() is distinct from n.uploaded_by and not is_staff(n.community_id) then
    raise exception 'You do not have permission to do this';
  end if;
  update note_suggestions
    set status = 'rejected', reject_reason = p_reason, resolved_by = auth.uid(), resolved_at = now()
    where id = p_id;
  insert into notifications (user_id, community_id, note_id, type, message)
    values (sg.suggested_by, n.community_id, n.id, 'suggestion_rejected',
            'Your correction suggestion was rejected' || coalesce(': ' || p_reason, ''));
end $$;
