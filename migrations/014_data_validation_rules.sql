-- ============================================================================
-- 014_data_validation_rules.sql
--
-- قواعد صحة بيانات حقيقية على مستوى القاعدة، لا الواجهة فقط:
-- "لا يوجد ورد يتعارض مع ورد آخر لنفس الطالب في اليوم نفسه بصورة غير مقصودة".
--
-- فحصنا البيانات الحية أولاً (كالعادة قبل أي قيد): وُجدت فعليًا ٨ حالات
-- تعارض حقيقية (١٦ صفاً) — خطتان فقط من إجمالي كل الخطط، وكلها في نفس يوم
-- إنشاء كل خطة تقريبًا (على الأرجح توليد الجدول تكرّر مرتين لنفس الطلب،
-- كضغطة مزدوجة على زر الإنشاء). بعض الأزواج متطابقة تمامًا (نفس السورة/الآيات
-- بالحرف)، لكن بعضها الآخر مختلف فعليًا في المحتوى (مثلاً "النبأ ١→٢٠" مقابل
-- "النبأ ١→٣٥" لنفس اليوم ونفس النوع) — أي حذف تلقائي حتى لو "يبدو واضحاً"
-- كان سيكون تخميناً لأي نسخة هي الصحيحة، وهذا ممنوع صراحةً بالتعليمات.
--
-- القرار: تعليم كل الصفوف الـ١٦ بعلم "يحتاج مراجعة يدوية" بلا حذف أو تعديل
-- لأي منها، وإضافة قيد UNIQUE كـ NOT VALID يمنع أي تعارض جديد من الآن
-- فصاعداً (لا يرفض الصفوف القديمة القليلة، فقط يحمي المستقبل).
-- ============================================================================

-- تعليم الصفوف المتعارضة الموجودة فعلاً — بلا حذف أو تعديل لمحتواها
with conflicts as (
  select plan_id, planned_date, fortress_code
  from quran_plan_wards
  where is_rest_day = false
  group by plan_id, planned_date, fortress_code
  having count(*) > 1
)
update quran_plan_wards w
set data_quality_flag = 'duplicate_or_conflicting_day'
from conflicts c
where w.plan_id = c.plan_id and w.planned_date = c.planned_date and w.fortress_code = c.fortress_code
  and w.is_rest_day = false
  and (w.data_quality_flag is distinct from 'duplicate_or_conflicting_day');

-- القيد نفسه: قيود UNIQUE في Postgres لا تدعم NOT VALID إطلاقًا (خلافاً لـ
-- CHECK/FOREIGN KEY) — البديل الصحيح فهرس فريد جزئي (partial unique index)
-- يستثني الصفوف القديمة المُعلَّمة للتو، فيتحقق فقط مما تبقى (نظيف بالفعل)
-- ويحمي كل إدراج/تعديل جديد من نفس التعارض دون رفض الماضي القليل
create unique index if not exists quran_plan_wards_no_same_day_conflict
  on quran_plan_wards (plan_id, planned_date, fortress_code)
  where is_rest_day = false and data_quality_flag is distinct from 'duplicate_or_conflicting_day';
