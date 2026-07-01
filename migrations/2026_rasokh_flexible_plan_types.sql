-- ============================================================
-- ترحيل: تقسيم نظام الحفظ إلى "رسوخ" (٥ حصون) و"الطالب يختار خطته" (٣ حصون)
-- شغّل هذا السكربت مرة واحدة في Supabase SQL Editor
-- ============================================================

-- 1) عمودان جديدان على quran_systems
alter table quran_systems
  add column if not exists plan_type text not null default 'rasokh'
    check (plan_type in ('rasokh','flexible'));

alter table quran_systems
  add column if not exists path_key text
    check (path_key in ('amma','zahrawan','mufassal','quarter','half','full') or path_key is null);

-- الأنظمة الموجودة فعلاً قبل الترحيل تُعتبر "رسوخ" افتراضياً (لا تغيير في سلوكها)
update quran_systems set plan_type = 'rasokh' where plan_type is null;

-- ============================================================
-- 2) زرع ١٢ نظاماً قالبياً جاهزاً (٦ مسارات × رسوخ/مرن)
--    كل نظام يُنشأ بحالة 'active' مباشرة كي يظهر للمعلم عند بناء خطة طالب جديد.
--    التعديل على المعدلات الفعلية (من أين يبدأ، كم يحفظ يومياً) يتم من المعلم
--    عبر الـ Wizard في أول حصة — هذا فقط "قالب افتراضي" يبدأ منه.
-- ============================================================

do $$
declare
  v_path record;
  v_plan_type text;
  v_system_id uuid;
  v_paths jsonb := '[
    {"key":"amma",     "name":"جزء عمّ وتبارك", "weeks":16},
    {"key":"zahrawan",  "name":"الزهراوان",       "weeks":24},
    {"key":"mufassal",  "name":"المفصّل",          "weeks":20},
    {"key":"quarter",   "name":"ربع القرآن",       "weeks":36},
    {"key":"half",      "name":"نصف القرآن",       "weeks":72},
    {"key":"full",      "name":"القرآن كامل",      "weeks":144}
  ]'::jsonb;
  v_item jsonb;
begin
  for v_item in select * from jsonb_array_elements(v_paths) loop
    foreach v_plan_type in array array['rasokh','flexible'] loop
      -- تجنّب التكرار لو تم تشغيل السكربت أكثر من مرة
      if exists (
        select 1 from quran_systems
        where path_key = (v_item->>'key') and plan_type = v_plan_type
      ) then
        continue;
      end if;

      insert into quran_systems(
        name, description, track, plan_type, path_key,
        target_audience, expected_duration_weeks,
        study_days, rest_days, status
      ) values (
        (v_item->>'name') || ' — ' ||
          (case when v_plan_type='rasokh' then 'رسوخ' else 'الطالب يختار خطته' end),
        'نظام قالب افتراضي لمسار ' || (v_item->>'name') || '، ' ||
          (case when v_plan_type='rasokh'
                then 'بالحصون الخمسة (الحفظ الجديد، المراجعة القريبة، المراجعة البعيدة، التلاوة، السماع).'
                else 'بالحصون الثلاثة (الحفظ الجديد، المراجعة القريبة، المراجعة البعيدة) فقط.' end),
        'fortresses', v_plan_type, (v_item->>'key'),
        null, (v_item->>'weeks')::int,
        '{1,2,3,4,5}', '{6,7}', 'active'
      )
      returning id into v_system_id;

      -- زرع الحصون الخمسة، وتعطيل التلاوة والسماع في نظام "flexible"
      insert into quran_fortresses(system_id, code, name, color, icon, default_unit, order_index, is_enabled)
      values
        (v_system_id, 'new_hifz',    'الحفظ الجديد',         '#0d6b4f', '📖', 'verse', 1, true),
        (v_system_id, 'review_near', 'المراجعة القريبة',      '#1e6091', '🔄', 'verse', 2, true),
        (v_system_id, 'review_far',  'المراجعة البعيدة',      '#6b3fa0', '📚', 'verse', 3, true),
        (v_system_id, 'reading',     'ورد القراءة والتلاوة',  '#bf9a45', '📜', 'page',  4, (v_plan_type='rasokh')),
        (v_system_id, 'listening',   'ورد السماع (الرحمة)',   '#a84d4d', '🎧', 'page',  5, (v_plan_type='rasokh'));

    end loop;
  end loop;
end $$;
