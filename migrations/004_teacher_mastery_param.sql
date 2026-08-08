-- ============================================================================
-- 004_teacher_mastery_param.sql
--
-- إضافة صغيرة ودقيقة: عمود teacher_mastery موجود بالفعل في quran_ward_progress
-- منذ البداية، لكن quran_mark_ward() (حتى بعد تحديث 002) لم يكن يكتبه أبداً —
-- لا يوجد أي معامل له في الدالة. اكتُشف هذا أثناء ربط شاشة "تقييم الحصة"
-- الحالية بمحرك الحصون الحقيقي (بدل درجة students.mastery القديمة المنفصلة).
--
-- هذا الملف يُعيد تعريف quran_mark_ward بنفس منطقها بالضبط (من 002) + معامل
-- واحد إضافي p_teacher_mastery. آمن للتشغيل: CREATE OR REPLACE فقط.
-- ============================================================================

create or replace function quran_mark_ward(
  p_ward_id uuid, p_status text default null::text, p_planned_for_date date default null::date,
  p_actual_date date default null::date, p_is_early boolean default null::boolean, p_is_late boolean default null::boolean,
  p_days_offset integer default null::integer, p_student_mastery integer default null::integer,
  p_student_note text default null::text, p_teacher_note text default null::text,
  p_clear_teacher_note boolean default false, p_touch_teacher boolean default false, p_teacher_approve boolean default false,
  p_teacher_mastery integer default null::integer
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
    teacher_mastery
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
    p_teacher_mastery
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
    updated_at = now(),
    marked_by_role = coalesce(v_marked_role, quran_ward_progress.marked_by_role),
    marked_by_id = coalesce(auth.uid(), quran_ward_progress.marked_by_id);

  return jsonb_build_object('ok', true);
end;
$$;
