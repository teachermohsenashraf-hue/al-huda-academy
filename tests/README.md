# اختبارات الدخان (Smoke Tests)

`smoke.staging.mjs` — اختبارات حقيقية (لا تخمينية) تعمل ضد بيئة staging منفصلة تمامًا عن الإنتاج:

- **مشروع الاختبار**: `teachermohsenashraf@gmail.com's Project` (ref: `nwfgsaumkubferjjsuny`)
- **مشروع الإنتاج**: `اكاديمية تعليم العرب` (ref: `yvloiecymqbhpoizfucl`) — لا يُلمَس إطلاقًا من هذا الملف

## التشغيل

```bash
node tests/smoke.staging.mjs
```

لا يحتاج أي إعداد إضافي — كل المفاتيح مضمَّنة (anon + service_role الخاصان ببيئة الاختبار فقط، وهما مفتاحان علنيان بالتصميم مثل المفتاح المضمَّن في `index.html`).

## إعداد بيئة الاختبار (مرة واحدة، مُنفَّذ بالفعل)

بيئة `nwfgsaumkubferjjsuny` جُهِّزت بتشغيل كل ملفات الـ migrations بالترتيب التالي (**ترتيب حساس**، بعض الملفات يعتمد على دوال/أنواع معرَّفة في ملفات أخرى):

```
000_core_schema.sql
006_document_core_rls_helper_functions.sql   ← لازم قبل أي شيء يستخدم is_admin()/my_role()
001_document_undocumented_live_tables.sql
SETUP.sql
2026_rasokh_flexible_plan_types.sql
2026_plan_custom_rates_and_starting_station.sql
002_security_and_progress_tracking.sql
003_secure_send_push_trigger.sql
004_teacher_mastery_param.sql
005_plan_edit_history_and_remedial_wards.sql
007_fix_quran_mark_ward_overload.sql
008_quran_reference_data.sql
009_bind_stations_and_wards_to_quran_reference.sql
010_plan_model_and_flexibility_rpcs.sql
011_progress_states_and_not_done_reason.sql
012_rescue_center.sql
013_legacy_ward_migration_assessment.sql   ← توثيقي بحت، بلا تأثير فعلي
014_data_validation_rules.sql
015_help_requests.sql
016_fix_consolidation_and_spread_bugs.sql
```

عبر: `supabase db query --linked -f <file>` (يحتاج `SUPABASE_ACCESS_TOKEN` مضبوطًا ومشروعًا مربوطًا `supabase link --project-ref nwfgsaumkubferjjsuny`).

كذلك: `mailer_autoconfirm=true` مفعَّل على بيئة الاختبار فقط (لا حاجة لتأكيد بريد إلكتروني عند التسجيل التجريبي).

## حساب Admin ثابت للاختبار

`permanent.admin@smoketest.local` — أُنشئ مباشرة عبر SQL (وليس عبر تسجيل ذاتي، لتفادي الاعتماد الهش على "أول حساب في القاعدة" الذي لا يصلح لإعادة التشغيل المتكرر). كلمة المرور والتفاصيل في `tests/smoke.staging.mjs` نفسه، ولا صلة له بأي حساب حقيقي.

## ماذا يغطّي

٢٠ مجموعة، ٦٤ تأكيداً:

- تكامل التسجيل وحارس تصعيد الصلاحيات، إنشاء حساب معلم موثوق
- بناء خطة حفظ حقيقية، تعليم/اعتماد ورد (والتحقّق من `marked_by_role` المحسوب سيرفريًا)
- عزل RLS بين طالبين، تأكيد/رفض الدفع الذرّي، رفض طلب الدعم المالي، الحذف الناعم وسجل التدقيق
- **المرجع القرآني**: عدد السور/الآيات الفعلي، ورفض ورد بآية غير موجودة على مستوى القاعدة
- **تخفيف حجم الورد**: تحقّق رياضي دقيق من نتيجة التخفيض (لا تقريب)
- **أسبوع تثبيت**: يوقف الحفظ الجديد فقط، يحوّله ليوم راحة فعليًا
- **مركز الإنقاذ**: تجميع المتأخرات + توزيعها فعليًا على أيام منفصلة بلا أي تصادم مع قيد منع التعارض
- **سجل تعديلات الخطة**: كل أداة تعديل تُسجَّل تلقائيًا
- **حالة "جزئي" المستقلة** + **سبب عدم الإتمام**
- **طلبات المساعدة**: الطالب يطلب، لا يقدر يقفل طلبه بنفسه، المعلم يقدر
- **منع تعارض الأوراد لنفس اليوم**: فهرس فريد جزئي يرفض الإدراج المتعارض فعليًا

## باگان حقيقيان اكتُشفا بهذه الاختبارات بالذات (لا بالفحص النحوي)

١. `quran_consolidation_week` كانت بها خطأ "column reference ambiguous" حقيقي — لم يكن أي مسار سابق (زر واجهة أو اختبار) قد استدعاها فعليًا قبل هذه الاختبارات.
٢. `quran_spread_lateness` كانت تفشل بالكامل (خطأ 23505) لو عدد الأوراد المتأخرة من نفس نوع الحصن أكبر من عدد أيام التوزيع المطلوبة — تصادم مباشر مع قيد منع التعارض (014). أُصلح الاثنان في `016_fix_consolidation_and_spread_bugs.sql`، وأُعيد تشغيل الاختبارات كاملةً بعد الإصلاح (٦٤/٦٤ ناجحة).

## بوابة النشر (CI)

`.github/workflows/staging-tests.yml` يشغّل هذا الملف تلقائيًا عند أي `push`/`pull_request` على `main`. **تنبيه مهم**: هذا يُظهر ✅/❌ واضحة في تبويب Actions على GitHub، لكنه **لا يمنع** فيرسل من النشر فعليًا إلا لو فُعِّلت "Required status checks" في إعدادات الفرع `main` من لوحة GitHub نفسها (Settings → Branches) — قرار إداري على مستوى المستودع لم يُفعَّل هنا عمدًا (يحتاج موافقتك الصريحة، لأنه يغيّر سياسة من يقدر يدمج على `main`).

## ماذا لا يغطّي بعد

شاشات الواجهة نفسها (لا Playwright/Cypress) — هذه اختبارات مستوى API/RLS/RPC مباشرة، تثبت أن الخادم يتصرف صح، وليس أن كل زر في `index.html` يستدعي الشيء الصحيح. مسار الحلقات الجماعية (متعددة الطلاب) غير مغطّى — فقط المسار الخاص (١ لـ ١) وهو المسار الحقيقي الفعلي للتسجيل.
