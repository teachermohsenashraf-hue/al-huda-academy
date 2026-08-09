-- ============================================================================
-- 009_bind_stations_and_wards_to_quran_reference.sql
--
-- يربط حدود المحطات (quran_stations) وأوراد الخطط (quran_plan_wards) فعليًا
-- بمرجع القرآن الحقيقي (008) عبر قيود Foreign Key حقيقية — بدل أرقام سور/آيات
-- حرة غير مُتحقَّق منها. من الآن، أي محاولة لإدراج أو تعديل ورد أو حد محطة
-- برقم آية غير موجود فعليًا في القرآن سترفضها القاعدة نفسها، لا الواجهة فقط.
--
-- فحصنا البيانات الحية قبل كتابة هذا الملف (قراءة فقط):
--   - quran_stations: ٩٠ محطة لها حدود آيات — صفر انتهاكات. القيد يُضاف فورًا
--     كقيد صارم (VALID) بأمان.
--   - quran_plan_wards: ٢٬٣٢٧ ورد له سورة — وُجد صفّان فقط (من ٢٬٣٢٧) بخطأ
--     حدّي حقيقي: ayah_from = آخر آية للسورة + 1 (خطأ off-by-one عند الوصول
--     لنهاية سورة أثناء توليد الجدول القديم، سورة الكهف وسورة الملك). طبقًا
--     للتعليمات الصريحة بعدم تعديل بيانات إنتاجية بصمت أو تخمين نطاق قرآني:
--     لم تُعدَّل هذه الصفوف، بل عُلِّمت بعلم "يحتاج مراجعة" ليراجعها معلم
--     الطالب المعني يدويًا، والقيد على هذا العمود أُضيف كـ NOT VALID (يمنع أي
--     بيانات خاطئة جديدة من الآن فصاعدًا، بلا رفض البيانات القديمة القليلة).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) quran_stations — صفر انتهاكات، قيد صارم فورًا
-- ---------------------------------------------------------------------------
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'quran_stations_boundary_from_fkey') then
    alter table quran_stations add constraint quran_stations_boundary_from_fkey
      foreign key (boundary_surah_from, boundary_ayah_from) references quran_ayahs(surah_no, ayah_no);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'quran_stations_boundary_to_fkey') then
    alter table quran_stations add constraint quran_stations_boundary_to_fkey
      foreign key (boundary_surah_to, boundary_ayah_to) references quran_ayahs(surah_no, ayah_no);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2) quran_plan_wards — علم جودة بيانات + قيد NOT VALID (يحمي المستقبل فقط)
-- ---------------------------------------------------------------------------
alter table quran_plan_wards add column if not exists data_quality_flag text;

-- تعليم الصفّين المعروفين بمشكلة حقيقية — بلا أي تعديل لأرقام السورة/الآية نفسها
update quran_plan_wards
set data_quality_flag = 'invalid_ayah_range'
where surah_no is not null and ayah_from is not null and ayah_to is not null
  and (ayah_from > ayah_to
       or not exists (select 1 from quran_ayahs a where a.surah_no = quran_plan_wards.surah_no and a.ayah_no = quran_plan_wards.ayah_from)
       or not exists (select 1 from quran_ayahs a where a.surah_no = quran_plan_wards.surah_no and a.ayah_no = quran_plan_wards.ayah_to))
  and data_quality_flag is distinct from 'invalid_ayah_range';

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'quran_plan_wards_ayah_from_fkey') then
    alter table quran_plan_wards add constraint quran_plan_wards_ayah_from_fkey
      foreign key (surah_no, ayah_from) references quran_ayahs(surah_no, ayah_no) not valid;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'quran_plan_wards_ayah_to_fkey') then
    alter table quran_plan_wards add constraint quran_plan_wards_ayah_to_fkey
      foreign key (surah_no, ayah_to) references quran_ayahs(surah_no, ayah_no) not valid;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3) دالة مساعدة: هل النطاق (من سورة/آية إلى سورة/آية) نطاق أمامي صحيح فعليًا
--    (لا يرجع للخلف)؟ تُستخدم لاحقًا في قيود/RPCs التحقق من حدود المسار.
-- ---------------------------------------------------------------------------
create or replace function quran_range_is_forward(
  p_surah_from integer, p_ayah_from integer, p_surah_to integer, p_ayah_to integer
) returns boolean
language sql
stable
as $$
  select coalesce(
    (select a1.id <= a2.id
     from quran_ayahs a1, quran_ayahs a2
     where a1.surah_no = p_surah_from and a1.ayah_no = p_ayah_from
       and a2.surah_no = p_surah_to and a2.ayah_no = p_ayah_to),
    false
  )
$$;
