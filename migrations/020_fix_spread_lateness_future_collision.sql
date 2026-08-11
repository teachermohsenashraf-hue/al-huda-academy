-- ============================================================================
-- 020_fix_spread_lateness_future_collision.sql
--
-- إصلاح باگ ثالث في quran_spread_lateness — اكتُشِف من الاستخدام الحقيقي:
--
-- migration 016 حلّ تصادم متأخرَين من نفس النوع في نفس اليوم عبر بناء قائمة
-- فتحات مستقلة لكل fortress_code. لكن الخوارزمية ما زالت تتجاهل حقيقة أن
-- الأيام المستهدفة قد يكون فيها بالفعل ورد مجدوَل قادم (غير متأخر) من نفس
-- النوع — عندها إدراج المتأخر يصطدم مع قيد "منع تعارض نفس اليوم" ويظهر
-- للمعلم خطأ 23505 غامض من صفحة "مركز إنقاذ الخطة".
--
-- الإصلاح: عند بناء فتحات كل fortress_code، نستبعد الأيام التي فيها بالفعل
-- ورد من هذا النوع (سواء متأخر أو قادم، بغضّ النظر عن حالة تقدّم الطالب)،
-- ونمدّد نافذة البحث حتى نجد أعداد الفتحات المطلوبة.
-- ============================================================================

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
  v_slots_by_fortress jsonb := '{}'::jsonb;
  v_probe date;
  v_idx_by_fortress jsonb := '{}'::jsonb;
  v_late_by_fortress jsonb;
  v_fort text;
  v_need integer;
  v_slots date[];
  v_idx integer;
  v_target date;
  v_max_probe_days integer := 365; -- سقف احتياطي حتى لا نلفّ للأبد لو الخطة كلها ممتلئة
  v_days_seen integer;
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

  select coalesce(jsonb_object_agg(fortress_code, cnt), '{}'::jsonb) into v_late_by_fortress
  from (
    select w.fortress_code, count(*) as cnt
    from quran_plan_wards w
    left join quran_ward_progress p on p.ward_id = w.id
    where w.plan_id = p_plan_id and w.planned_date < v_today and w.is_rest_day = false
      and (p.status is null or p.status not in ('done','partial'))
    group by w.fortress_code
  ) t;

  -- لكل نوع حصن: ابنِ قائمة فتحات كافية عبر أيام دراسية قادمة، مستبعِداً الأيام
  -- التي فيها بالفعل أي ورد من هذا النوع (متأخر أو مجدول قادماً) — كلا الحالتين
  -- تُنشئ تصادم قيد unique عند نقل ورد آخر إليها.
  for v_fort in select jsonb_object_keys(v_late_by_fortress) loop
    v_need := greatest(p_days, (v_late_by_fortress->>v_fort)::integer);
    v_slots := array[]::date[];
    v_probe := v_today;
    v_days_seen := 0;
    while (array_length(v_slots,1) is null or array_length(v_slots,1) < v_need) and v_days_seen < v_max_probe_days loop
      if extract(isodow from v_probe)::int = any(v_study_days) then
        -- هل يوجد ورد من هذا النوع في هذا اليوم بالفعل (نفس الخطة، ليس يوم راحة)؟
        -- ملاحظة: نستثني الأوراد المتأخرة نفسها التي سنُعيد جدولتها (planned_date<today)
        -- لأنها ستخرج من هذا اليوم فور تحديث planned_date. لكن الأوراد بتاريخ >= today
        -- (بما فيها ورد اليوم نفسه) تبقى وتُنشئ تصادماً.
        if not exists (
          select 1 from quran_plan_wards w2
          where w2.plan_id = p_plan_id
            and w2.planned_date = v_probe
            and w2.fortress_code = v_fort
            and w2.is_rest_day = false
        ) then
          v_slots := v_slots || v_probe;
        end if;
      end if;
      v_probe := v_probe + 1;
      v_days_seen := v_days_seen + 1;
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
    select array(select jsonb_array_elements_text(v_slots_by_fortress->v_ward.fortress_code))::date[] into v_slots;
    if v_slots is null or array_length(v_slots,1) is null or array_length(v_slots,1) = 0 then
      -- لا فتحات متاحة لهذا النوع (كل الأيام القادمة إلى v_max_probe_days ممتلئة) — نتخطى بأمان
      continue;
    end if;
    v_idx := (v_idx_by_fortress->>v_ward.fortress_code)::integer;
    v_target := v_slots[1 + (v_idx % array_length(v_slots,1))];
    update quran_plan_wards set planned_date = v_target where id = v_ward.id;
    v_idx_by_fortress := jsonb_set(v_idx_by_fortress, array[v_ward.fortress_code], to_jsonb(v_idx + 1));
    v_affected := v_affected + 1;
  end loop;

  if v_affected = 0 then
    return jsonb_build_object('ok', false, 'error', 'no_slots_available');
  end if;

  update quran_student_plans set plan_version = plan_version + 1, updated_at = now() where id = p_plan_id;
  insert into quran_plan_edits (plan_id, actor_id, actor_role, action, reason, before_data, after_data, expected_impact)
  values (p_plan_id, auth.uid(), (select role::text from profiles where id = auth.uid()), 'spread_lateness', p_reason,
    null, jsonb_build_object('days', p_days, 'affected_wards', v_affected),
    'توزيع ' || v_affected || ' ورد متأخر على أيام دراسة قادمة، مع تجنّب أيام فيها ورد من نفس النوع مسبقاً');

  return jsonb_build_object('ok', true, 'affected_wards', v_affected);
end;
$$;
