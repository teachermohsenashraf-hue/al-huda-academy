-- ============================================================================
-- 006_document_core_rls_helper_functions.sql
--
-- Discovered while bootstrapping a staging environment: is_admin(), my_role(),
-- can_see_student(), is_my_group() — the four functions almost EVERY RLS
-- policy in this entire project depends on (SETUP.sql, 001, 002, 005 all
-- reference them) — had ZERO source anywhere in the repository. Not in
-- SETUP.sql, not in any migrations/*.sql file. They only existed live in the
-- dashboard. This is the single most load-bearing piece of undocumented
-- schema found across the whole audit — nothing else in the security model
-- works without these.
--
-- Transcribed verbatim from the live production definitions (read-only
-- introspection, 2026-08-08). CREATE OR REPLACE only — running this against
-- production is a guaranteed no-op (it already matches exactly).
--
-- Worth flagging explicitly (not a bug, but a non-obvious behavior): is_admin()
-- returns true for role IN ('admin','supervisor') — a 'supervisor' account is
-- functionally equivalent to 'admin' everywhere is_admin() gates access,
-- including this file's own RLS policies. 'executive' is NOT included and
-- must be checked separately wherever it should have equal trust (this
-- pattern — `is_admin() OR my_role() IN ('executive','supervisor')` — repeats
-- throughout SETUP.sql precisely because of this).
--
-- This file must run BEFORE any migration whose RLS policies call these
-- functions (001, 002, 005, and most of SETUP.sql) — on a from-scratch
-- environment, the correct order is: 000 → 006 (this file) → 001 → SETUP.sql
-- → the dated 2026_*.sql migrations → 002 → 003 → 004 → 005.
-- ============================================================================

-- نفس القصة بالضبط لنوع mark_state (المستخدم في husoon_marks.state و
-- worship_marks.state) — لا تعريف له في أي مكان بالمستودع، موجود لايف بس
do $$ begin
  if not exists (select 1 from pg_type where typname = 'mark_state') then
    create type mark_state as enum ('todo','part','done','none');
  end if;
end $$;

create or replace function is_admin()
returns boolean
language sql
stable security definer
as $$
  select exists(select 1 from profiles where id = auth.uid() and role in ('admin','supervisor'))
$$;

create or replace function my_role()
returns user_role
language sql
stable security definer
as $$
  select role from profiles where id = auth.uid()
$$;

create or replace function can_see_student(sid bigint)
returns boolean
language sql
stable security definer
as $$
  select
    is_admin()
    or my_role() in ('supervisor','executive')
    or exists(select 1 from students s where s.id=sid and s.parent_id=auth.uid())
    or exists(select 1 from students s where s.id=sid and s.login_id=auth.uid())
    or exists(select 1 from students s where s.id=sid and s.chosen_teacher_id=auth.uid())
    or exists(select 1 from students s join groups g on g.id=s.group_id
              where s.id=sid and g.teacher_id=auth.uid())
$$;

create or replace function is_my_group(gid bigint)
returns boolean
language sql
stable security definer
as $$
  select exists(select 1 from groups g where g.id=gid and g.teacher_id=auth.uid())
$$;

-- المزيد اكتُشف أثناء محاولة تجهيز بيئة اختبار من الصفر (نفس القصة تمامًا:
-- صفر وجود في المستودع، موجودة لايف فقط) — كلها دوال RLS مساعدة صغيرة
create or replace function admin_exists()
returns boolean
language sql
stable security definer
as $$
  select exists(select 1 from profiles where role='admin')
$$;

create or replace function owns_private_group(sid bigint)
returns boolean
language sql
stable security definer
as $$
  select exists(
    select 1 from students s
    where s.id=sid and (s.login_id=auth.uid() or s.parent_id=auth.uid())
  )
$$;

create or replace function my_student_in_group(gid bigint)
returns boolean
language sql
stable security definer
as $$
  select exists(
    select 1 from students s
    where s.group_id=gid and (s.login_id=auth.uid() or s.parent_id=auth.uid())
  )
$$;

create or replace function student_teacher(sid bigint)
returns uuid
language sql
stable security definer
as $$
  select g.teacher_id from students s join groups g on g.id=s.group_id where s.id=sid
$$;

create or replace function teacher_load(tid uuid)
returns integer
language sql
stable security definer
as $$
  select count(*)::int from students where chosen_teacher_id = tid and enrollment_status='active'
$$;

-- handle_new_user + on_auth_user_created: أهم من كل ما سبق — هذا هو المسؤول
-- الفعلي الوحيد عن إنشاء صفّ profiles عند أي تسجيل جديد (وليس أي كود عميل).
-- سبق نقله بالكامل في المحادثة، لكنه لم يُحفَظ كملف migration فعلي حتى الآن.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare r user_role;
begin
  begin r := coalesce((new.raw_user_meta_data->>'role')::user_role, 'parent');
  exception when others then r := 'parent'; end;
  if r in ('admin','supervisor','teacher','executive') and exists(select 1 from profiles where role='admin') then
    r := 'parent';
  end if;
  insert into profiles (id, role, full_name, initials, email)
  values (new.id, r,
    coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
    coalesce(new.raw_user_meta_data->>'initials', left(coalesce(new.raw_user_meta_data->>'full_name','مس'),2)),
    new.email)
  on conflict (id) do nothing;
  begin
    update profiles set
      age        = nullif(new.raw_user_meta_data->>'age','')::int,
      phone      = new.raw_user_meta_data->>'phone',
      country    = new.raw_user_meta_data->>'country',
      governorate= new.raw_user_meta_data->>'governorate',
      residence  = new.raw_user_meta_data->>'residence',
      gender     = new.raw_user_meta_data->>'gender',
      chosen_track = (nullif(new.raw_user_meta_data->>'chosen_track',''))::track_type,
      linked_parent_email = new.raw_user_meta_data->>'parent_email'
    where id = new.id;
  exception when others then null; end;
  return new;
exception when others then return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();
