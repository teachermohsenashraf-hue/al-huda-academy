-- ============================================================================
-- 008_document_core_table_rls_policies.sql
--
-- The single largest gap found while bootstrapping staging: every RLS policy
-- on all ten "core" tables from 000_core_schema.sql (profiles, groups,
-- students, chats, messages, join_requests, payments, sessions,
-- session_ratings, notifications) exists live in production with ZERO
-- source anywhere in the repository. 000_core_schema.sql only enables RLS
-- on them (`alter table ... enable row level security`) with an explicit
-- comment saying policies live in SETUP.sql — but they were never actually
-- added there. This was caught concretely: bootstrapping a fresh staging
-- database from every file in this repo produced a `payments` table with
-- RLS enabled and ZERO policies (deny-all), which made confirm_payment()
-- silently unusable — a real smoke-test failure, not a theoretical one.
--
-- Transcribed verbatim from live production (read-only introspection).
-- CREATE POLICY guarded with DROP POLICY IF EXISTS first (idempotent,
-- matches this repo's existing convention). Running this against production
-- is a no-op — every policy already matches exactly.
-- ============================================================================

-- ---------- profiles ----------
drop policy if exists "profiles admin all" on profiles;
create policy "profiles admin all" on profiles for all
  using (is_admin() or my_role() = 'executive')
  with check (is_admin() or my_role() = 'executive');
drop policy if exists "profiles read" on profiles;
create policy "profiles read" on profiles for select to authenticated
  using (is_admin() or my_role() in ('supervisor','executive') or role in ('teacher','supervisor') or id = auth.uid()
    or exists (select 1 from students s where (s.parent_id = profiles.id or s.login_id = profiles.id)
      and (s.parent_id = auth.uid() or s.login_id = auth.uid() or s.chosen_teacher_id = auth.uid()
        or exists (select 1 from groups g where g.id = s.group_id and g.teacher_id = auth.uid()))));
drop policy if exists "profiles self update" on profiles;
create policy "profiles self update" on profiles for update using (id = auth.uid());

-- ---------- groups ----------
drop policy if exists "groups see" on groups;
create policy "groups see" on groups for select
  using (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid()
    or (is_private and owns_private_group(student_id)) or my_student_in_group(id));
drop policy if exists "groups insert" on groups;
create policy "groups insert" on groups for insert
  with check (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid());
drop policy if exists "groups update" on groups;
create policy "groups update" on groups for update
  using (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid())
  with check (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid());
drop policy if exists "groups teacher" on groups;
create policy "groups teacher" on groups for update
  using (teacher_id = auth.uid() or is_admin() or my_role() = 'supervisor');
drop policy if exists "groups delete" on groups;
create policy "groups delete" on groups for delete
  using (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid());

-- ---------- students ----------
drop policy if exists "students write" on students;
create policy "students write" on students for all
  using (is_admin() or my_role() in ('supervisor','executive') or parent_id = auth.uid() or login_id = auth.uid() or chosen_teacher_id = auth.uid() or is_my_group(group_id))
  with check (is_admin() or my_role() in ('supervisor','executive') or parent_id = auth.uid() or login_id = auth.uid() or chosen_teacher_id = auth.uid() or is_my_group(group_id));
drop policy if exists "parent add child" on students;
create policy "parent add child" on students for insert
  with check (parent_id = auth.uid() or is_admin() or exists (select 1 from groups g where g.id = students.group_id and g.teacher_id = auth.uid()));
drop policy if exists "students see" on students;
create policy "students see" on students for select
  using (is_admin() or my_role() in ('supervisor','executive') or parent_id = auth.uid() or login_id = auth.uid() or chosen_teacher_id = auth.uid() or is_my_group(group_id));

-- ---------- chats ----------
drop policy if exists "chats party read" on chats;
create policy "chats party read" on chats for select to authenticated using (auth.uid() = any(party_ids));
drop policy if exists "chats party insert" on chats;
create policy "chats party insert" on chats for insert to authenticated with check (auth.uid() = any(party_ids));
drop policy if exists "chats party update" on chats;
create policy "chats party update" on chats for update to authenticated using (auth.uid() = any(party_ids)) with check (auth.uid() = any(party_ids));

-- ---------- messages ----------
drop policy if exists "messages party read" on messages;
create policy "messages party read" on messages for select to authenticated
  using (sender_id = auth.uid() or exists (select 1 from chats c where c.id = messages.chat_id and auth.uid() = any(c.party_ids)));
drop policy if exists "messages party insert" on messages;
create policy "messages party insert" on messages for insert to authenticated
  with check (sender_id = auth.uid() and exists (select 1 from chats c where c.id = messages.chat_id and auth.uid() = any(c.party_ids)));
drop policy if exists "messages sender update" on messages;
create policy "messages sender update" on messages for update to authenticated using (sender_id = auth.uid()) with check (sender_id = auth.uid());

-- ---------- join_requests ----------
drop policy if exists "jr_write" on join_requests;
create policy "jr_write" on join_requests for all
  using (is_admin() or my_role() = 'supervisor' or applicant_id = auth.uid() or parent_id = auth.uid())
  with check (is_admin() or my_role() = 'supervisor' or applicant_id = auth.uid() or parent_id = auth.uid());
drop policy if exists "jr_see" on join_requests;
create policy "jr_see" on join_requests for select
  using (is_admin() or my_role() in ('supervisor','executive') or applicant_id = auth.uid() or parent_id = auth.uid()
    or exists (select 1 from students s where s.id = join_requests.student_id and s.chosen_teacher_id = auth.uid()));

-- ---------- payments ----------
-- ⚠️ الأهم في هذا الملف: بدون هذه السياسة الأربعة كانت payments بلا سياسات
-- إطلاقًا على قاعدة فارغة تمامًا (RLS مفعّل + صفر سياسات = رفض كل شيء)
-- — وهو ما كان سيمنع confirm_payment()/reject_payment() تمامًا (اكتُشف فعليًا
-- أثناء اختبار الدخان: INSERT فشلت بـ 42501 رغم أن المتصل admin حقيقي).
drop policy if exists "pay see" on payments;
create policy "pay see" on payments for select
  using (is_admin() or my_role() in ('supervisor','executive') or can_see_student(student_id));
drop policy if exists "pay insert" on payments;
create policy "pay insert" on payments for insert
  with check (is_admin() or my_role() in ('supervisor','executive')
    or exists (select 1 from students s where s.id = payments.student_id and s.parent_id = auth.uid())
    or exists (select 1 from students s where s.id = payments.student_id and s.login_id = auth.uid()));
drop policy if exists "pay update" on payments;
create policy "pay update" on payments for update
  using (is_admin() or my_role() in ('supervisor','executive'))
  with check (is_admin() or my_role() in ('supervisor','executive'));
drop policy if exists "pay delete" on payments;
create policy "pay delete" on payments for delete using (is_admin());

-- ---------- sessions ----------
drop policy if exists "sessions see" on sessions;
create policy "sessions see" on sessions for select
  using (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid()
    or (student_id is not null and can_see_student(student_id))
    or exists (select 1 from students s where s.group_id = sessions.group_id and can_see_student(s.id)));
drop policy if exists "sessions write" on sessions;
create policy "sessions write" on sessions for all
  using (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid())
  with check (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid());

-- ---------- session_ratings ----------
drop policy if exists "sr see" on session_ratings;
create policy "sr see" on session_ratings for select
  using (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid() or can_see_student(student_id));
drop policy if exists "sr write" on session_ratings;
create policy "sr write" on session_ratings for all
  using (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid())
  with check (is_admin() or my_role() in ('supervisor','executive') or teacher_id = auth.uid());

-- ---------- notifications ----------
drop policy if exists "user reads own notifications" on notifications;
create policy "user reads own notifications" on notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists "user updates own notifications" on notifications;
create policy "user updates own notifications" on notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "notif own" on notifications;
create policy "notif own" on notifications for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid() or is_admin() or my_role() = 'supervisor');
drop policy if exists "notif admin create" on notifications;
create policy "notif admin create" on notifications for insert
  with check (is_admin() or my_role() in ('supervisor','executive') or user_id = auth.uid());
-- "notif insert scoped" هي الإصلاح الموثَّق فعلاً في SETUP.sql (ثغرة انتحال الصفة،
-- راجع القسم ٥ هناك) — مُعاد ذكرها هنا فقط لضمان الترتيب الصحيح على بيئة فارغة
drop policy if exists "any authenticated can insert notifications" on notifications;
drop policy if exists "notif insert scoped" on notifications;
create policy "notif insert scoped" on notifications for insert to authenticated with check (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or user_id = auth.uid()
  or exists (select 1 from chats c where auth.uid() = any(c.party_ids) and notifications.user_id = any(c.party_ids))
  or exists (select 1 from students s where (s.login_id = notifications.user_id or s.parent_id = notifications.user_id)
    and (s.chosen_teacher_id = auth.uid() or exists (select 1 from groups g where g.id = s.group_id and g.teacher_id = auth.uid())))
  or exists (select 1 from students s where (s.login_id = auth.uid() or s.parent_id = auth.uid())
    and (s.chosen_teacher_id = notifications.user_id or exists (select 1 from groups g where g.id = s.group_id and g.teacher_id = notifications.user_id)))
);
