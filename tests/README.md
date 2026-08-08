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
008_document_core_table_rls_policies.sql
```

عبر: `supabase db query --linked -f <file>` (يحتاج `SUPABASE_ACCESS_TOKEN` مضبوطًا ومشروعًا مربوطًا `supabase link --project-ref nwfgsaumkubferjjsuny`).

كذلك: `mailer_autoconfirm=true` مفعَّل على بيئة الاختبار فقط (لا حاجة لتأكيد بريد إلكتروني عند التسجيل التجريبي).

## حساب Admin ثابت للاختبار

`permanent.admin@smoketest.local` — أُنشئ مباشرة عبر SQL (وليس عبر تسجيل ذاتي، لتفادي الاعتماد الهش على "أول حساب في القاعدة" الذي لا يصلح لإعادة التشغيل المتكرر). كلمة المرور والتفاصيل في `tests/smoke.staging.mjs` نفسه، ولا صلة له بأي حساب حقيقي.

## ماذا يغطّي

١٢ مجموعة، ٣٧ تأكيداً: تكامل التسجيل وحارس تصعيد الصلاحيات، إنشاء حساب معلم موثوق، بناء خطة حفظ حقيقية، تعليم/اعتماد ورد (والتحقّق من `marked_by_role` المحسوب سيرفريًا)، عزل RLS بين طالبين، تأكيد/رفض الدفع الذرّي، رفض طلب الدعم المالي، الحذف الناعم وسجل التدقيق.

## ماذا لا يغطّي بعد

شاشات الواجهة نفسها (لا Playwright/Cypress) — هذه اختبارات مستوى API/RLS/RPC مباشرة، تثبت أن الخادم يتصرف صح، وليس أن كل زر في `index.html` يستدعي الشيء الصحيح. مسار الحلقات الجماعية (متعددة الطلاب) غير مغطّى — فقط المسار الخاص (١ لـ ١) وهو المسار الحقيقي الفعلي للتسجيل.
