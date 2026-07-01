-- ============================================================
-- ترحيل: معدل مخصص لكل طالب + اختيار محطة البداية الصحيحة
-- شغّل هذا السكربت مرة واحدة في Supabase SQL Editor
-- ============================================================

-- جدول جديد: معدلات مخصّصة لكل خطة طالب (تتجاوز إعداد المحطة الافتراضي
-- لهذا الطالب فقط، بدون التأثير على باقي الطلاب على نفس المحطة)
create table if not exists quran_plan_fortress_rates(
  id uuid primary key default gen_random_uuid(),
  plan_id uuid references quran_student_plans(id) on delete cascade,
  fortress_id uuid references quran_fortresses(id) on delete cascade,
  daily_amount numeric not null,
  unit text,
  created_at timestamptz default now(),
  unique(plan_id, fortress_id)
);

-- تذكير: فعّل RLS وسياسات الوصول المناسبة (المعلم/المشرف/المدير) لهذا الجدول
-- كما هو مطبّق على باقي جداول qsystems.
