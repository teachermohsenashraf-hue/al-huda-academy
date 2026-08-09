-- ============================================================================
-- 016_fix_consolidation_and_spread_bugs.sql
--
-- إصلاح باگين حقيقيين — اكتُشفا فقط عند تشغيل اختبارات فعلية شاملة (task #17)
-- ضد بيئة الاختبار، لا بمجرد التحقق النحوي:
--
-- ١) quran_consolidation_week: خطأ "column reference teacher_note is
--    ambiguous" — الجملة UPDATE ... FROM quran_ward_progress p تخلق عمودين
--    بنفس الاسم (كلا الجدولين له teacher_note)، والمرجع في SET كان بلا
--    تأهيل باسم الجدول. لم تكن هذه الدالة قد استُدعيت فعليًا من قبل (لا
--    زر الواجهة ولا اختبار سابق كانا يمرّان بهذا المسار)، فالخطأ كان كامناً
--    منذ migration 010.
--
-- ٢) quran_spread_lateness: توزيع المتأخرات كان "أعمى" تجاه نوع الحصن —
--    لو أكتر من ورد متأخر لنفس النوع (fortress_code) أكتر من عدد أيام
--    التوزيع المطلوبة، اثنان منهم ينتهي بهما المطاف في نفس اليوم لنفس
--    النوع، فيصطدما بقيد "لا تعارض لنفس اليوم" (migration 014) وتفشل
--    العملية كلها بخطأ 23505 بدل التوزيع الناجح. الإصلاح: التوزيع الآن
--    يُبنى لكل نوع حصن على حدة، بعدد فتحات كافٍ لعدد أوراده الفعلي (لو عدد
--    أوراد نوع معيّن أكبر من الأيام المطلوبة، يُمدَّد له تلقائيًا حتى
--    لا يتصادم أي ورد بآخر من نفس نوعه في نفس اليوم أبدًا).
-- ============================================================================

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
    teacher_note = coalesce(w.teacher_note || ' — ', '') || 'أسبوع تثبيت: توقّف الحفظ الجديد مؤقتًا'
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
  v_today date := current_date;
  v_affected integer := 0;
  v_slots_by_fortress jsonb := '{}'::jsonb; -- fortress_code -> date[] (كنص jsonb، نبنيه ونقرأه يدويًا)
  v_probe date;
  v_idx_by_fortress jsonb := '{}'::jsonb;
  v_late_by_fortress jsonb;
  v_fort text;
  v_need integer;
  v_slots date[];
  v_idx integer;
  v_target date;
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

  -- كم ورد متأخر لكل نوع حصن على حدة؟ (عدد فتحات كل نوع لازم يكفي عدده هو،
  -- لا عدد الأيام المطلوبة بالإجمالي — وإلا يتصادم ورد بآخر من نفس النوع)
  select coalesce(jsonb_object_agg(fortress_code, cnt), '{}'::jsonb) into v_late_by_fortress
  from (
    select w.fortress_code, count(*) as cnt
    from quran_plan_wards w
    left join quran_ward_progress p on p.ward_id = w.id
    where w.plan_id = p_plan_id and w.planned_date < v_today and w.is_rest_day = false
      and (p.status is null or p.status not in ('done','partial'))
    group by w.fortress_code
  ) t;

  -- ابنِ قائمة فتحات مستقلة لكل نوع حصن، بعدد كافٍ لعدده الفعلي (لا أقل من p_days)
  for v_fort in select jsonb_object_keys(v_late_by_fortress) loop
    v_need := greatest(p_days, (v_late_by_fortress->>v_fort)::integer);
    v_slots := array[]::date[];
    v_probe := v_today;
    while array_length(v_slots,1) is null or array_length(v_slots,1) < v_need loop
      if extract(isodow from v_probe)::int = any(v_study_days) then
        v_slots := v_slots || v_probe;
      end if;
      v_probe := v_probe + 1;
    end loop;
    v_slots_by_fortress := jsonb_set(v_slots_by_fortress, array[v_fort], to_jsonb(v_slots));
    v_idx_by_fortress := jsonb_set(v_idx_by_fortress, array[v_fort], '0'::jsonb);
  end loop;

  for v_ward in
    select w.id, w.fortress_code from quran_plan_wards w
    left join quran_ward_progress p on p.ward_id = w.id
    where w.plan_id = p_plan_id and w.planned_date < v_today and w.is_rest_day = false
      and (p.status is null or p.status not in ('done','partial'))
    order by w.planned_date
  loop
    v_idx := (v_idx_by_fortress->>v_ward.fortress_code)::integer;
    select array(select jsonb_array_elements_text(v_slots_by_fortress->v_ward.fortress_code))::date[] into v_slots;
    v_target := v_slots[1 + (v_idx % array_length(v_slots,1))];
    update quran_plan_wards set planned_date = v_target where id = v_ward.id;
    v_idx_by_fortress := jsonb_set(v_idx_by_fortress, array[v_ward.fortress_code], to_jsonb(v_idx + 1));
    v_affected := v_affected + 1;
  end loop;

  if v_affected = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_late_wards');
  end if;

  update quran_student_plans set plan_version = plan_version + 1, updated_at = now() where id = p_plan_id;
  insert into quran_plan_edits (plan_id, actor_id, actor_role, action, reason, before_data, after_data, expected_impact)
  values (p_plan_id, auth.uid(), (select role::text from profiles where id = auth.uid()), 'spread_lateness', p_reason,
    null, jsonb_build_object('days', p_days, 'affected_wards', v_affected),
    'توزيع ' || v_affected || ' ورد متأخر على أيام دراسة قادمة، بلا تعارض بين وردين لنفس النوع في نفس اليوم');

  return jsonb_build_object('ok', true, 'affected_wards', v_affected);
end;
$$;
