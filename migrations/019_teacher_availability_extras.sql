-- ============================================================================
-- 019_teacher_availability_extras.sql
--
-- توسيع profiles ليدعم الإتاحة الكاملة للمعلم (المواصفات القسم ١١):
-- ١) weekly_slots — جدول أسبوعي للمواعيد المتاحة للحصص الجديدة.
--    نستخدم jsonb حتى لا يتقيّد الشكل بمخطط جدول فرعي، ونتيح للمعلم إضافة
--    عدة فترات في اليوم الواحد ("صباحية + مسائية").
--    البنية المتوقعة (بلا CHECK صارم حتى تنمو):
--      [{"day":1..7,"from":"HH:MM","to":"HH:MM","note":"…"}]
-- ٢) timezone — منطقة زمنية IANA (مثل Africa/Cairo / Asia/Riyadh).
-- ٣) max_students — السعة القصوى للمعلم. 0 = بلا حد.
-- ٤) age_range — الفئة العمرية أو المستوى المناسب — نص حر مرن.
--
-- كل الأعمدة NULLABLE لتحافظ على توافق الطلاب الحاليين.
-- ============================================================================

alter table public.profiles
  add column if not exists weekly_slots jsonb,
  add column if not exists timezone text,
  add column if not exists max_students integer,
  add column if not exists age_range text;

comment on column public.profiles.weekly_slots is 'جدول الإتاحة الأسبوعي: [{day:1..7, from:HH:MM, to:HH:MM, note:...}]';
comment on column public.profiles.timezone     is 'منطقة زمنية IANA (Asia/Riyadh, Africa/Cairo، إلخ)';
comment on column public.profiles.max_students is 'السعة القصوى للطلاب (0 = بلا حد)';
comment on column public.profiles.age_range    is 'الفئة العمرية / المستوى المناسب (نص حر: ٦-١٢، بالغين، مبتدئ، …)';
