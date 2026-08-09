-- ============================================================================
-- 010_plan_model_and_flexibility_rpcs.sql
--
-- تحسين نموذج خطة الطالب + أول دفعة من أدوات مرونة المعلم الذرّية (RPCs).
-- تحقّقنا من بيانات quran_student_plans.status الحية أولاً (11 نشطة، 2 مكتملة
-- فقط، لا قيم أخرى) — إضافة قيد CHECK بالحالات الخمس آمنة تمامًا هنا.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) نموذج الخطة: خمس حالات صريحة، وتيرة، ونسخة (بدل نص حر بلا قيد)
-- ---------------------------------------------------------------------------
alter table quran_student_plans add column if not exists pace text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'quran_student_plans_pace_check') then
    alter table quran_student_plans add constraint quran_student_plans_pace_check
      check (pace is null or pace in ('light','medium','intense'));
  end if;
end $$;

alter table quran_student_plans add column if not exists plan_version integer not null default 1;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'quran_student_plans_status_check') then
    alter table quran_student_plans add constraint quran_student_plans_status_check
      check (status in ('active','paused','needs_reset','completed','cancelled'));
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2) تخفيف الورد بنسبة — على الأوراد المستقبلية غير المنجَزة فقط، بدقة فعلية
--    (مسافة معرّفات quran_ayahs الحقيقية، لا تقدير "٣٠ آية ≈ يوم" القديم).
--    عملية واحدة ذرّية، وتُسجَّل في quran_plan_edits تلقائيًا.
-- ---------------------------------------------------------------------------
create or replace function quran_reduce_ward_load(
  p_plan_id uuid, p_percent numeric, p_reason text, p_fortress_code text default 'new_hifz'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_staff boolean;
  v_today date := current_date;
  v_ward record;
  v_from_id integer; v_to_id integer; v_new_to_id integer; v_new_ayah_no integer; v_new_surah_no integer;
  v_affected integer := 0;
  v_before jsonb := '[]'::jsonb; v_after jsonb := '[]'::jsonb;
begin
  if p_percent <= 0 or p_percent >= 100 then
    return jsonb_build_object('ok', false, 'error', 'invalid_percent');
  end if;
  select exists(
    select 1 from quran_student_plans qp where qp.id = p_plan_id
    and (qp.teacher_id = auth.uid() or is_admin() or my_role() = any(array['executive','supervisor']::user_role[]))
  ) into v_is_staff;
  if not v_is_staff then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  for v_ward in
    select w.* from quran_plan_wards w
    left join quran_ward_progress p on p.ward_id = w.id
    where w.plan_id = p_plan_id and w.fortress_code = p_fortress_code
      and w.planned_date >= v_today and w.is_rest_day = false
      and w.surah_no is not null and w.ayah_from is not null and w.ayah_to is not null
      and (p.status is null or p.status <> 'done')
  loop
    select id into v_from_id from quran_ayahs where surah_no = v_ward.surah_no and ayah_no = v_ward.ayah_from;
    select id into v_to_id from quran_ayahs where surah_no = v_ward.surah_no and ayah_no = v_ward.ayah_to;
    if v_from_id is null or v_to_id is null or v_to_id < v_from_id then
      continue; -- ورد بعلم جودة بيانات أصلاً — لا نلمسه هنا، يحتاج مراجعة يدوية منفصلة
    end if;
    v_new_to_id := v_from_id + greatest(0, round((v_to_id - v_from_id) * (1 - p_percent/100.0)));
    select surah_no, ayah_no into v_new_surah_no, v_new_ayah_no from quran_ayahs where id = v_new_to_id;
    v_before := v_before || jsonb_build_object('ward_id', v_ward.id, 'ayah_to', v_ward.ayah_to, 'surah_no', v_ward.surah_no);
    update quran_plan_wards set
      ayah_to = case when v_new_surah_no = v_ward.surah_no then v_new_ayah_no else v_ward.ayah_to end,
      amount_label = v_ward.surah_name || ' • ' || v_ward.ayah_from || '-' ||
        (case when v_new_surah_no = v_ward.surah_no then v_new_ayah_no else v_ward.ayah_to end)
    where id = v_ward.id;
    v_after := v_after || jsonb_build_object('ward_id', v_ward.id, 'ayah_to', case when v_new_surah_no = v_ward.surah_no then v_new_ayah_no else v_ward.ayah_to end);
    v_affected := v_affected + 1;
  end loop;

  if v_affected = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_eligible_wards');
  end if;

  update quran_student_plans set plan_version = plan_version + 1, updated_at = now() where id = p_plan_id;
  insert into quran_plan_edits (plan_id, actor_id, actor_role, action, reason, before_data, after_data, expected_impact)
  values (p_plan_id, auth.uid(), (select role::text from profiles where id = auth.uid()), 'reduced_ward_load', p_reason,
    jsonb_build_object('wards', v_before), jsonb_build_object('wards', v_after, 'percent', p_percent),
    'تخفيف ' || p_percent || '٪ من حجم ' || v_affected || ' ورد مستقبلي لم يُنجَز بعد — لا يغيّر مواعيد الأيام نفسها');

  return jsonb_build_object('ok', true, 'affected_wards', v_affected);
end;
$$;

-- ---------------------------------------------------------------------------
-- 3) أسبوع تثبيت — إيقاف الحفظ الجديد لعدد أيام محدد، وتحويلها لمراجعة قريبة
--    فقط (لا حذف لأي ورد، فقط تعطيل مؤقت لحصن الحفظ الجديد داخل المدى المحدد)
-- ---------------------------------------------------------------------------
create or replace function quran_consolidation_week(
  p_plan_id uuid, p_start_date date, p_days integer, p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_is_staff boolean;
  v_end_date date := p_start_date + (greatest(1, p_days) - 1);
  v_affected integer;
begin
  select exists(
    select 1 from quran_student_plans qp where qp.id = p_plan_id
    and (qp.teacher_id = auth.uid() or is_admin() or my_role() = any(array['executive','supervisor']::user_role[]))
  ) into v_is_staff;
  if not v_is_staff then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  update quran_plan_wards w set
    teacher_note = coalesce(teacher_note || ' — ', '') || 'أسبوع تثبيت: توقّف الحفظ الجديد مؤقتًا'
  from quran_ward_progress p
  where w.plan_id = p_plan_id and w.fortress_code = 'new_hifz'
    and w.planned_date between p_start_date and v_end_date
    and (p.ward_id is null or p.ward_id != w.id);
  get diagnostics v_affected = row_count;

  update quran_plan_wards set is_rest_day = true
  where plan_id = p_plan_id and fortress_code = 'new_hifz' and planned_date between p_start_date and v_end_date
    and id not in (select ward_id from quran_ward_progress where status = 'done');

  update quran_student_plans set plan_version = plan_version + 1, updated_at = now() where id = p_plan_id;
  insert into quran_plan_edits (plan_id, actor_id, actor_role, action, reason, before_data, after_data, expected_impact)
  values (p_plan_id, auth.uid(), (select role::text from profiles where id = auth.uid()), 'consolidation_week', p_reason,
    null, jsonb_build_object('start_date', p_start_date, 'end_date', v_end_date, 'days', p_days),
    'إيقاف الحفظ الجديد من ' || p_start_date || ' إلى ' || v_end_date || ' — المراجعة القريبة/البعيدة تستمر كالمعتاد، موعد الإتمام يتأجّل بنفس عدد الأيام');

  return jsonb_build_object('ok', true, 'start_date', p_start_date, 'end_date', v_end_date);
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) ضبط الوتيرة المعلنة للخطة — تسمية وصفية تُعرض في الواجهات، تُسجَّل بسبب
-- ---------------------------------------------------------------------------
create or replace function quran_set_pace(p_plan_id uuid, p_pace text, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_before text; v_is_staff boolean;
begin
  if p_pace not in ('light','medium','intense') then
    return jsonb_build_object('ok', false, 'error', 'invalid_pace');
  end if;
  select exists(
    select 1 from quran_student_plans qp where qp.id = p_plan_id
    and (qp.teacher_id = auth.uid() or is_admin() or my_role() = any(array['executive','supervisor']::user_role[]))
  ) into v_is_staff;
  if not v_is_staff then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;
  select pace into v_before from quran_student_plans where id = p_plan_id;
  update quran_student_plans set pace = p_pace, updated_at = now() where id = p_plan_id;
  insert into quran_plan_edits (plan_id, actor_id, actor_role, action, reason, before_data, after_data)
  values (p_plan_id, auth.uid(), (select role::text from profiles where id = auth.uid()), 'pace_changed', p_reason,
    jsonb_build_object('pace', v_before), jsonb_build_object('pace', p_pace));
  return jsonb_build_object('ok', true);
end;
$$;
