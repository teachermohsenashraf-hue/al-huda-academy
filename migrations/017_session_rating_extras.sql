-- ============================================================================
-- 017_session_rating_extras.sql
--
-- توسيع session_ratings لدعم نافذة تقييم الحصة الشاملة (المواصفات، القسم ٤):
-- ١) teacher_private_note — ملاحظة خاصة يراها المعلم فقط (وليس الطالب/ولي
--    الأمر). كان جدول التقييمات لا يميّز بين ما يظهر للطالب وما هو للمعلم،
--    فأي ملاحظة نقدية دقيقة كان المعلم مضطراً يكتبها في مكان خارجي أو يتجنّبها.
-- ٢) next_action — الإجراء التالي بعد التقييم (اعتماد/إعادة/تخفيف/علاجية/تعديل)
--    نص حر بقيود قصيرة، لتجنّب إنشاء ENUM جديد يفرض migration لاحقاً عند
--    إضافة قيمة. القيم المتوقعة: approve, repeat_ward, lighten_next,
--    add_remedial, open_plan_edit, none.
-- ٣) next_action_data — تفاصيل هيكلية للإجراء (مثلاً قيمة التخفيض بالنسبة
--    المئوية، أو تاريخ الورد العلاجي). jsonb حتى تنمو بدون migration جديد.
--
-- كل الأعمدة NULLABLE بلا قيمة افتراضية — الصفوف القديمة تبقى صحيحة كما هي،
-- والواجهة الجديدة تقرأ NULL على أنها "لم تُعبَّأ" وتعرض الحقول فارغة.
-- ============================================================================

alter table public.session_ratings
  add column if not exists teacher_private_note text,
  add column if not exists next_action text,
  add column if not exists next_action_data jsonb;

-- تعليقات توثيقية على مستوى القاعدة (تظهر في أدوات مثل psql \d+)
comment on column public.session_ratings.teacher_private_note is 'ملاحظة خاصة يراها المعلم فقط — لا تُعرض للطالب أو ولي الأمر مطلقاً';
comment on column public.session_ratings.next_action        is 'قرار المعلم بعد الحصة: approve|repeat_ward|lighten_next|add_remedial|open_plan_edit|none';
comment on column public.session_ratings.next_action_data   is 'تفاصيل الإجراء التالي (مثلاً {"ward_id":"…"} أو {"pct":25})';

-- ملاحظة: لا نفرض CHECK على next_action حتى تظل إضافة قيم جديدة مستقبلاً
-- ممكنة من كود التطبيق دون migration، وتبقى التغطية عبر اختبار Smoke لاحقاً.
