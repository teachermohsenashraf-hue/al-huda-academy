-- ============================================================================
-- 012_rescue_center.sql
--
-- مركز إنقاذ الخطة: تجميع المتأخرات حسب النوع والسبب (بدل بطاقات حمراء متكررة
-- بلا تجميع)، معاينة الأثر قبل الاعتماد، وتوزيع المتأخرات على أيام يحدّدها
-- المعلم كعملية ذرّية واحدة.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) ملخص المتأخرات: العدد الإجمالي، مُجمَّعاً حسب نوع الحصن، ومُجمَّعاً حسب
--    سبب التعثر المُسجَّل (لو الطالب اختار سببًا عند "لم أتم"؛ وإلا فهو "لم يُسجَّل
--    محاولة إطلاقًا" — تمييز مهم: تعثّر معلوم السبب مقابل غياب تام عن التسجيل)
-- ---------------------------------------------------------------------------
create or replace function quran_rescue_summary(p_plan_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_access boolean;
  v_by_fortress jsonb;
  v_by_reason jsonb;
  v_total integer;
begin
  select exists(
    select 1 from quran_student_plans qp where qp.id = p_plan_id and (
      is_admin() or my_role() = any(array['executive','supervisor']::user_role[])
      or qp.teacher_id = auth.uid()
    )
  ) into v_has_access;
  if not v_has_access then
    return jsonb_build_object('error', 'forbidden');
  end if;

  select coalesce(jsonb_object_agg(fortress_code, cnt), '{}'::jsonb) into v_by_fortress
  from (
    select w.fortress_code, count(*) as cnt
    from quran_plan_wards w
    left join quran_ward_progress p on p.ward_id = w.id
    where w.plan_id = p_plan_id and w.planned_date < current_date and w.is_rest_day = false
      and (p.status is null or p.status not in ('done','partial'))
    group by w.fortress_code
  ) t;

  select coalesce(jsonb_object_agg(coalesce(reason_key,'not_recorded'), cnt), '{}'::jsonb) into v_by_reason
  from (
    select p.not_done_reason as reason_key, count(*) as cnt
    from quran_plan_wards w
    left join quran_ward_progress p on p.ward_id = w.id
    where w.plan_id = p_plan_id and w.planned_date < current_date and w.is_rest_day = false
      and (p.status is null or p.status not in ('done','partial'))
    group by p.not_done_reason
  ) t;

  select count(*) into v_total
  from quran_plan_wards w
  left join quran_ward_progress p on p.ward_id = w.id
  where w.plan_id = p_plan_id and w.planned_date < current_date and w.is_rest_day = false
    and (p.status is null or p.status not in ('done','partial'));

  return jsonb_build_object('ok', true, 'total', v_total, 'by_fortress', v_by_fortress, 'by_reason', v_by_reason);
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) معاينة أثر "توزيع المتأخرات على N يوم" قبل أي اعتماد فعلي — بلا أي كتابة،
--    قراءة فقط، ترجع: عدد الأوراد المتأثرة، موعد الإتمام الحالي، والمتوقع الجديد
-- ---------------------------------------------------------------------------
create or replace function quran_preview_spread_lateness(p_plan_id uuid, p_days integer)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_access boolean;
  v_late_count integer;
  v_current_target date;
  v_new_target date;
begin
  select exists(
    select 1 from quran_student_plans qp where qp.id = p_plan_id and (
      is_admin() or my_role() = any(array['executive','supervisor']::user_role[]) or qp.teacher_id = auth.uid()
    )
  ) into v_has_access;
  if not v_has_access then
    return jsonb_build_object('error', 'forbidden');
  end if;

  select count(*) into v_late_count
  from quran_plan_wards w
  left join quran_ward_progress p on p.ward_id = w.id
  where w.plan_id = p_plan_id and w.planned_date < current_date and w.is_rest_day = false
    and (p.status is null or p.status not in ('done','partial'));

  select end_date_target into v_current_target from quran_student_plans where id = p_plan_id;
  -- بلا كتابة: توزيع المتأخرات على أيام دراسة يعني تمديد آخر الجدول بنفس عدد
  -- الأيام المطلوبة للتوزيع (تقدير مباشر بلا تعقيد إضافي هنا؛ الحساب الدقيق
  -- الفعلي يحدث وقت التنفيذ الحقيقي في quran_spread_lateness)
  v_new_target := coalesce(v_current_target, current_date) + greatest(0, p_days);

  return jsonb_build_object('ok', true, 'affected_wards', v_late_count,
    'current_target_date', v_current_target, 'projected_target_date', v_new_target,
    'days_added', p_days);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) تنفيذ فعلي: توزيع المتأخرات على N يوم دراسة قادم — عملية ذرّية واحدة،
--    تُسجَّل في quran_plan_edits تلقائيًا. لا تُعالَج المتأخرات بترحيل تلقائي
--    فوق الأيام القادمة بلا موافقة المعلم؛ هذه الدالة تُستدعى فقط بعد أن يختار
--    المعلم صراحةً "توزيع على N يوم" من مركز الإنقاذ.
-- ---------------------------------------------------------------------------
create or replace function quran_spread_lateness(p_plan_id uuid, p_days integer, p_reason text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_has_access boolean;
  v_study_days integer[];
  v_ward record;
  v_idx integer := 0;
  v_today date := current_date;
  v_affected integer := 0;
  v_slots date[] := array[]::date[];
  v_probe date;
begin
  if p_days is null or p_days <= 0 then
    return jsonb_build_object('ok', false, 'error', 'invalid_days');
  end if;
  select exists(
    select 1 from quran_student_plans qp where qp.id = p_plan_id and (
      is_admin() or my_role() = any(array['executive','supervisor']::user_role[]) or qp.teacher_id = auth.uid()
    )
  ) into v_has_access;
  if not v_has_access then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select coalesce(study_days, array[1,2,3,4,5]) into v_study_days from quran_student_plans where id = p_plan_id;

  -- 🔴 نبني أولاً قائمة بأول N تاريخ دراسة فعلي صالح (نتخطّى أيام الراحة أثناء
  -- البناء نفسه، لا بعده) — الصياغة الأولى (اليوم + idx%N ثم تصحيح الأيام
  -- المرفوضة لاحقًا) كانت تُسبّب تصادمًا حقيقيًا: لو "اليوم" نفسه يوم راحة،
  -- أكثر من فتحة توزيع كانت تُدفَع لنفس أول يوم دراسة صالح، فتتكدّس كل
  -- المتأخرات على يوم واحد بدل توزيعها فعليًا. اتحقق بالاختبار المباشر على
  -- بيئة الاختبار: قبل الإصلاح ٤ من ٥ أوراد انتهت في نفس اليوم بدل التوزيع
  -- على ٣ أيام كما طُلب.
  v_probe := v_today;
  while array_length(v_slots,1) is null or array_length(v_slots,1) < p_days loop
    if extract(isodow from v_probe)::int = any(v_study_days) then
      v_slots := v_slots || v_probe;
    end if;
    v_probe := v_probe + 1;
  end loop;

  for v_ward in
    select w.id, w.planned_date from quran_plan_wards w
    left join quran_ward_progress p on p.ward_id = w.id
    where w.plan_id = p_plan_id and w.planned_date < v_today and w.is_rest_day = false
      and (p.status is null or p.status not in ('done','partial'))
    order by w.planned_date
  loop
    update quran_plan_wards set planned_date = v_slots[1 + (v_idx % p_days)] where id = v_ward.id;
    v_idx := v_idx + 1;
    v_affected := v_affected + 1;
  end loop;

  if v_affected = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_late_wards');
  end if;

  update quran_student_plans set plan_version = plan_version + 1, updated_at = now() where id = p_plan_id;
  insert into quran_plan_edits (plan_id, actor_id, actor_role, action, reason, before_data, after_data, expected_impact)
  values (p_plan_id, auth.uid(), (select role::text from profiles where id = auth.uid()), 'spread_lateness', p_reason,
    null, jsonb_build_object('days', p_days, 'affected_wards', v_affected),
    'توزيع ' || v_affected || ' ورد متأخر على أول ' || p_days || ' يوم دراسة قادم');

  return jsonb_build_object('ok', true, 'affected_wards', v_affected);
end;
$$;
