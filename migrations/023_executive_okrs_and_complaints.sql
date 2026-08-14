-- ============================================================================
-- 023_executive_okrs_and_complaints.sql
--
-- ما يحتاجه المدير التنفيذي كي يُدير ولا يقرأ فقط:
--   ١) OKRs — أهداف الفصل ونتائجه القابلة للقياس (لتحويل الخطة إلى تنفيذ)
--   ٢) الشكاوى والاعتراضات — قناة موثّقة لشكاوى الأولياء والطلاب والمعلمين
--
-- كلاهما جديد كليًا — لا يوجد في السكيما جدول أو RLS لهما، والاعتماد على
-- التنبيهات/الرسائل لا يوثّق ولا يقيس. جدولان صغيران بحوكمة كاملة.
-- ============================================================================

-- ═══ OKRs ══════════════════════════════════════════════════════════════════
create table if not exists public.executive_okrs (
  id             uuid primary key default gen_random_uuid(),
  quarter        text not null,                 -- '2026-Q3' مثلاً
  objective      text not null,                 -- الهدف الكيفي
  key_result     text not null,                 -- نتيجة قابلة للقياس (نص وصفي)
  target_value   numeric,                       -- الرقم المستهدف (اختياري)
  current_value  numeric default 0,             -- الرقم الحالي (يُحدَّث يدويًا أو حسابيًا)
  unit           text,                          -- 'طالب' | '%' | 'EGP' | 'حصة' ...
  owner_id       uuid references auth.users(id) on delete set null,
  category       text,                          -- growth|quality|financial|team|operations
  status         text not null default 'active',-- active|paused|achieved|dropped
  notes          text,
  created_by     uuid references auth.users(id) on delete set null,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
create index if not exists exec_okrs_quarter_idx  on public.executive_okrs(quarter);
create index if not exists exec_okrs_status_idx   on public.executive_okrs(status);
create index if not exists exec_okrs_owner_idx    on public.executive_okrs(owner_id);

comment on column public.executive_okrs.status   is 'active|paused|achieved|dropped';
comment on column public.executive_okrs.category is 'growth|quality|financial|team|operations';

alter table public.executive_okrs enable row level security;

-- قراءة: كل الطاقم (المشرف والمعلم يريان أهداف الفصل لتتبع التنفيذ)
drop policy if exists okr_read on public.executive_okrs;
create policy okr_read on public.executive_okrs for select
using (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role,'teacher'::user_role])
);

-- كتابة: أدمن + مدير علمي + شريك مؤسس + التنفيذي (بالدور)
drop policy if exists okr_write on public.executive_okrs;
create policy okr_write on public.executive_okrs for all
using (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = 'executive'::user_role
)
with check (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = 'executive'::user_role
);

-- ═══ Complaints ════════════════════════════════════════════════════════════
create table if not exists public.complaints (
  id             uuid primary key default gen_random_uuid(),
  complainant_id uuid references auth.users(id) on delete set null, -- الشاكي
  student_id     bigint references public.students(id) on delete set null, -- إن كانت الشكوى تخصّ طالبًا
  target_type    text,                          -- teacher|group|payment|content|other
  target_id      text,                          -- id مرن (uuid/bigint حسب الحالة)
  subject        text not null,
  body           text,
  severity       text default 'normal',         -- low|normal|high|critical
  status         text not null default 'open',  -- open|investigating|resolved|dismissed
  assigned_to    uuid references auth.users(id) on delete set null,
  resolution     text,
  resolved_by    uuid references auth.users(id) on delete set null,
  resolved_at    timestamptz,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
create index if not exists complaints_status_idx   on public.complaints(status);
create index if not exists complaints_severity_idx on public.complaints(severity);
create index if not exists complaints_stud_idx     on public.complaints(student_id);
create index if not exists complaints_created_idx  on public.complaints(created_at desc);

comment on column public.complaints.status   is 'open|investigating|resolved|dismissed';
comment on column public.complaints.severity is 'low|normal|high|critical';
comment on column public.complaints.target_type is 'teacher|group|payment|content|other';

alter table public.complaints enable row level security;

-- قراءة: الشاكي نفسه + الإدارة + من عُيّن للحل
drop policy if exists cmp_read on public.complaints;
create policy cmp_read on public.complaints for select
using (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role])
  or complainant_id = auth.uid()
  or assigned_to = auth.uid()
);

-- إنشاء: أي مستخدم مسجَّل (يشتكي على نفسه فقط)
drop policy if exists cmp_insert on public.complaints;
create policy cmp_insert on public.complaints for insert
with check ( complainant_id = auth.uid() );

-- تحديث: الإدارة + المسؤول المعيّن
drop policy if exists cmp_update on public.complaints;
create policy cmp_update on public.complaints for update
using (
  is_admin() or is_scientific_director()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role])
  or assigned_to = auth.uid()
)
with check (
  is_admin() or is_scientific_director()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role])
  or assigned_to = auth.uid()
);
