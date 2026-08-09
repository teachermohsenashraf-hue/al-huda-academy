-- ============================================================================
-- 011_progress_states_and_not_done_reason.sql
--
-- تفريق حالات التقدّم + سبب عدم الإنجاز. فحصنا القيم الحية أولاً فعليًا:
-- quran_ward_progress.status المستخدَم فعلًا: done (25), missed (65 —
-- تضبطها applyAbsenceShift تلقائيًا)، not_started (1). القيمة 'skipped' مُستخدَمة
-- في الكود (زر "لم أتم") لكن صفر صف بها حاليًا. لا قيم أخرى موجودة — إضافة
-- قيد CHECK بالخمس حالات آمنة تمامًا.
--
-- ⚠️ درس migration 004 مُطبَّق هنا بدقة: تعديل quran_mark_ward بمعامل جديد
-- يحتاج حذف صريح للنسخة القديمة (نفس المعاملات بالضبط) قبل إنشاء الجديدة،
-- وإلا نكرّر نفس باگ الازدواج الحرج الذي أُصلح في migration 007.
-- ============================================================================

alter table quran_ward_progress add column if not exists not_done_reason text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'quran_ward_progress_not_done_reason_check') then
    alter table quran_ward_progress add constraint quran_ward_progress_not_done_reason_check
      check (not_done_reason is null or not_done_reason in ('time_pressure','difficulty','absence','needs_listening','other'));
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'quran_ward_progress_status_check') then
    alter table quran_ward_progress add constraint quran_ward_progress_status_check
      check (status in ('not_started','done','partial','missed','skipped'));
  end if;
end $$;

-- حذف صريح للنسخة القديمة (١٤ معامل بالضبط) قبل إنشاء نسخة ١٥ معاملاً —
-- يمنع تكرار باگ الازدواج المُصلَح في 007
drop function if exists quran_mark_ward(
  uuid, text, date, date, boolean, boolean, integer, integer, text, text, boolean, boolean, boolean, integer
);

create or replace function quran_mark_ward(
  p_ward_id uuid, p_status text default null::text, p_planned_for_date date default null::date,
  p_actual_date date default null::date, p_is_early boolean default null::boolean, p_is_late boolean default null::boolean,
  p_days_offset integer default null::integer, p_student_mastery integer default null::integer,
  p_student_note text default null::text, p_teacher_note text default null::text,
  p_clear_teacher_note boolean default false, p_touch_teacher boolean default false, p_teacher_approve boolean default false,
  p_teacher_mastery integer default null::integer, p_not_done_reason text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  v_is_owner boolean;
  v_is_staff boolean;
  v_is_student_self boolean;
  v_marked_role text;
begin
  select exists(
    select 1 from quran_plan_wards w
    join quran_student_plans qp on qp.id = w.plan_id
    where w.id = p_ward_id
      and (qp.login_id = auth.uid()
           or exists (select 1 from students s where s.id = qp.student_id
                      and (s.login_id = auth.uid() or s.parent_id = auth.uid())))
  ) into v_is_owner;

  select exists(
    select 1 from quran_plan_wards w
    join quran_student_plans qp on qp.id = w.plan_id
    where w.id = p_ward_id
      and (qp.teacher_id = auth.uid() or is_admin()
           or my_role() = any(array['executive','supervisor']::user_role[]))
  ) into v_is_staff;

  if not (v_is_owner or v_is_staff) then
    return jsonb_build_object('error','forbidden');
  end if;

  if p_touch_teacher or p_teacher_approve or (v_is_staff and not v_is_owner) then
    v_marked_role := 'teacher';
  elsif v_is_owner then
    select exists(
      select 1 from quran_plan_wards w join quran_student_plans qp on qp.id = w.plan_id
      where w.id = p_ward_id and qp.login_id = auth.uid()
    ) into v_is_student_self;
    v_marked_role := case when v_is_student_self then 'student' else 'parent' end;
  end if;

  insert into quran_ward_progress(
    ward_id, student_login_id, status, planned_for_date, actual_date,
    is_early, is_late, days_offset, student_mastery, student_note,
    teacher_note, teacher_id, teacher_approved_at, updated_at, marked_by_role, marked_by_id,
    teacher_mastery, not_done_reason
  ) values (
    p_ward_id,
    case when v_is_owner then auth.uid() else null end,
    coalesce(p_status,'not_started'), p_planned_for_date, p_actual_date,
    coalesce(p_is_early,false), coalesce(p_is_late,false), p_days_offset,
    p_student_mastery, p_student_note,
    p_teacher_note,
    case when p_touch_teacher or p_teacher_approve then auth.uid() else null end,
    case when p_teacher_approve then now() else null end,
    now(), v_marked_role, auth.uid(),
    p_teacher_mastery, p_not_done_reason
  )
  on conflict (ward_id) do update set
    status = coalesce(p_status, quran_ward_progress.status),
    planned_for_date = coalesce(p_planned_for_date, quran_ward_progress.planned_for_date),
    actual_date = coalesce(p_actual_date, quran_ward_progress.actual_date),
    is_early = coalesce(p_is_early, quran_ward_progress.is_early),
    is_late = coalesce(p_is_late, quran_ward_progress.is_late),
    days_offset = coalesce(p_days_offset, quran_ward_progress.days_offset),
    student_mastery = coalesce(p_student_mastery, quran_ward_progress.student_mastery),
    student_note = coalesce(p_student_note, quran_ward_progress.student_note),
    teacher_note = case when p_clear_teacher_note then null else coalesce(p_teacher_note, quran_ward_progress.teacher_note) end,
    teacher_id = case when p_touch_teacher or p_teacher_approve then auth.uid() else quran_ward_progress.teacher_id end,
    teacher_approved_at = case when p_teacher_approve then now() else quran_ward_progress.teacher_approved_at end,
    teacher_mastery = coalesce(p_teacher_mastery, quran_ward_progress.teacher_mastery),
    not_done_reason = coalesce(p_not_done_reason, quran_ward_progress.not_done_reason),
    updated_at = now(),
    marked_by_role = coalesce(v_marked_role, quran_ward_progress.marked_by_role),
    marked_by_id = coalesce(auth.uid(), quran_ward_progress.marked_by_id);

  return jsonb_build_object('ok', true);
end;
$$;
