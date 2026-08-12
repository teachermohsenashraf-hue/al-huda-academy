-- ============================================================================
-- 022_test_banks.sql
--
-- بنوك اختبارات حقيقية بدل الوعد بها — بنية بيانات كاملة تُلبّي القسم ٧ من
-- مواصفات المدير العلمي: بنك أسئلة، اختبار، محاولة، درجات، حالة اعتماد،
-- ونتائج قابلة للتحليل حسب المسار والحلقة والمعلم.
--
-- ٣ جداول:
--   test_banks     — تجميعة اختبار كاملة (اسم/فئة/مسار/محطة/حالة/إصدار)
--   test_questions — الأسئلة داخل البنك بترتيبها ونوعها ودرجاتها
--   test_attempts  — محاولة طالب على بنك، بإجاباتها ودرجاتها الكلية
--
-- كل الحقول اختيارية ما عدا الاسم، والحالة تسير في مسار: draft → active →
-- archived. المدير العلمي يعتمد البنك (approved_by/approved_at) قبل تفعيله.
--
-- RLS:
--   test_banks   — قراءة: كل الطاقم + الطلاب لو active. كتابة: مدير علمي/أدمن.
--   test_questions — نفس صلاحيات البنك.
--   test_attempts — الطالب يرى محاولاته، المعلم محاولات طلابه، المدير العلمي الكل.
-- ============================================================================

create table if not exists public.test_banks (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  description    text,
  category       text,        -- memorization|tajweed|review|placement|transition|other
  path_key       text,        -- ربط اختياري بمسار من QURAN_PATHS
  station_id     uuid references public.quran_stations(id) on delete set null,
  status         text not null default 'draft',   -- draft|active|archived
  version        text,
  duration_min   integer,
  pass_score_pct integer default 60,
  created_by     uuid references auth.users(id) on delete set null,
  approved_by    uuid references auth.users(id) on delete set null,
  approved_at    timestamptz,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
create index if not exists test_banks_status_idx   on public.test_banks(status);
create index if not exists test_banks_category_idx on public.test_banks(category);
create index if not exists test_banks_path_idx     on public.test_banks(path_key);

comment on column public.test_banks.category is 'memorization|tajweed|review|placement|transition|other';
comment on column public.test_banks.status   is 'draft|active|archived';

create table if not exists public.test_questions (
  id            uuid primary key default gen_random_uuid(),
  bank_id       uuid not null references public.test_banks(id) on delete cascade,
  order_index   integer not null default 0,
  kind          text not null default 'mcq',   -- mcq|text|recite|rating
  prompt        text not null,
  choices       jsonb,        -- لـmcq: [{key:'A', text:'...', is_correct:true|false}]
  correct_text  text,         -- لـtext: النص المتوقع (مرجعي)
  reference     text,         -- مثال: "سورة البقرة الآيات 1-5"
  points        integer default 1,
  hint          text,
  created_at    timestamptz default now()
);
create index if not exists test_questions_bank_idx on public.test_questions(bank_id, order_index);

comment on column public.test_questions.kind is 'mcq (اختيار من متعدد) | text (إجابة نصية) | recite (تسميع يدوي) | rating (تقييم رقمي)';

create table if not exists public.test_attempts (
  id            uuid primary key default gen_random_uuid(),
  bank_id       uuid not null references public.test_banks(id) on delete restrict,
  student_id    bigint references public.students(id) on delete cascade,
  teacher_id    uuid references auth.users(id) on delete set null,
  started_at    timestamptz default now(),
  submitted_at  timestamptz,
  graded_at     timestamptz,
  score         integer,
  max_score     integer,
  pct           integer,
  status        text not null default 'in_progress', -- in_progress|submitted|graded
  answers       jsonb,        -- {question_id: {value:'...', is_correct:bool, score:N, note:'...'}}
  teacher_note  text,
  created_at    timestamptz default now()
);
create index if not exists test_attempts_bank_idx on public.test_attempts(bank_id);
create index if not exists test_attempts_stud_idx on public.test_attempts(student_id, submitted_at desc);
create index if not exists test_attempts_teacher_idx on public.test_attempts(teacher_id, submitted_at desc);

-- ─── RLS ─────────────────────────────────────────────────────────────────
alter table public.test_banks     enable row level security;
alter table public.test_questions enable row level security;
alter table public.test_attempts  enable row level security;

-- بنوك: قراءة عامة للطاقم + للطلاب النشطين لو البنك active
drop policy if exists tb_read on public.test_banks;
create policy tb_read on public.test_banks for select
using (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role,'teacher'::user_role])
  or (status = 'active' and exists (
    select 1 from students s where s.login_id = auth.uid() and s.enrollment_status = 'active'
  ))
);

-- بنوك: كتابة للمدير العلمي والأدمن فقط
drop policy if exists tb_insert on public.test_banks;
create policy tb_insert on public.test_banks for insert
with check ( created_by = auth.uid() and (is_scientific_director() or is_admin()) );

drop policy if exists tb_update on public.test_banks;
create policy tb_update on public.test_banks for update
using ( is_scientific_director() or is_admin() )
with check ( is_scientific_director() or is_admin() );

-- أسئلة: تتبع صلاحيات البنك
drop policy if exists tq_read on public.test_questions;
create policy tq_read on public.test_questions for select
using (
  exists (
    select 1 from public.test_banks b where b.id = bank_id and (
      is_admin() or is_scientific_director() or is_founding_partner()
      or my_role() = any(array['executive'::user_role,'supervisor'::user_role,'teacher'::user_role])
      or (b.status='active' and exists(select 1 from students s where s.login_id = auth.uid() and s.enrollment_status='active'))
    )
  )
);

drop policy if exists tq_write on public.test_questions;
create policy tq_write on public.test_questions for all
using ( is_scientific_director() or is_admin() )
with check ( is_scientific_director() or is_admin() );

-- محاولات: الطالب يرى محاولاته فقط، المعلم محاولات طلابه، الإدارة والعلمي الكل
drop policy if exists ta_read on public.test_attempts;
create policy ta_read on public.test_attempts for select
using (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role])
  or teacher_id = auth.uid()
  or exists (
    select 1 from students s where s.id = test_attempts.student_id
      and (s.login_id = auth.uid() or s.parent_id = auth.uid())
  )
);

drop policy if exists ta_insert on public.test_attempts;
create policy ta_insert on public.test_attempts for insert
with check (
  is_admin() or is_scientific_director()
  or teacher_id = auth.uid()
  or exists (select 1 from students s where s.id = test_attempts.student_id and s.login_id = auth.uid())
);

drop policy if exists ta_update on public.test_attempts;
create policy ta_update on public.test_attempts for update
using (
  is_admin() or is_scientific_director()
  or teacher_id = auth.uid()
  or exists (
    select 1 from students s where s.id = test_attempts.student_id
      and s.login_id = auth.uid() and test_attempts.status = 'in_progress'
  )
)
with check (
  is_admin() or is_scientific_director()
  or teacher_id = auth.uid()
  or exists (select 1 from students s where s.id = test_attempts.student_id and s.login_id = auth.uid())
);
