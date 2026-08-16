-- ============================================================================
-- 027_supervisor_ops.sql
--
-- تحويل دور المشرف من مشاهد إلى مركز قرار وتشغيل:
--   supervisor_actions — سجل تدقيق كامل لكل قرار مشرف مهم (نقل/توزيع/إغلاق حالة)
--   supervisor_cases   — الحالات المكتشفة تلقائيًا (مع دي-دوب + دورة حياة)
--
-- تصميم مبسّط: لا triggers ثقيلة. الاكتشاف يتم من داخل التطبيق عبر قواعد،
-- والجدولان يحفظان الحالة والقرار لا يعيدان حسابها.
-- ============================================================================

-- ═══ supervisor_actions — audit trail ═══
create table if not exists public.supervisor_actions (
  id           uuid primary key default gen_random_uuid(),
  supervisor_id uuid references auth.users(id) on delete set null,
  kind         text not null,
    -- assign_student|transfer_student|create_halqa|edit_halqa|edit_plan|
    -- approve_request|reject_request|close_case|reopen_case|note|contact|
    -- capacity_change|other
  target_type  text,     -- student|teacher|halqa|plan|case|request
  target_id    text,     -- id مرن (uuid/bigint)
  summary      text,
  before_data  jsonb,
  after_data   jsonb,
  note         text,
  created_at   timestamptz default now()
);
create index if not exists sup_act_who_idx  on public.supervisor_actions(supervisor_id, created_at desc);
create index if not exists sup_act_tgt_idx  on public.supervisor_actions(target_type, target_id);
create index if not exists sup_act_kind_idx on public.supervisor_actions(kind);

alter table public.supervisor_actions enable row level security;

drop policy if exists supact_read on public.supervisor_actions;
create policy supact_read on public.supervisor_actions for select
using (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role])
);
drop policy if exists supact_insert on public.supervisor_actions;
create policy supact_insert on public.supervisor_actions for insert
with check (
  supervisor_id = auth.uid() and (
    is_admin() or my_role() = 'supervisor'::user_role or my_role() = 'executive'::user_role
  )
);

-- ═══ supervisor_cases — حالة طالب/معلم تحتاج انتباه ═══
create table if not exists public.supervisor_cases (
  id            uuid primary key default gen_random_uuid(),
  subject_type  text not null,   -- student|teacher|halqa
  subject_id    text not null,   -- id مرن حسب النوع
  kind          text not null,   -- late_wards|attendance_drop|mastery_drop|no_teacher|no_plan|paid_no_group|teacher_no_report|teacher_no_session|other
  priority      text not null default 'follow_up',  -- urgent|follow_up|review
  reasons       jsonb not null default '[]'::jsonb, -- [{code, detail, since, value}]
  status        text not null default 'open',        -- open|processed|reopened|closed
  first_seen    timestamptz default now(),
  last_seen     timestamptz default now(),
  processed_by  uuid references auth.users(id) on delete set null,
  processed_at  timestamptz,
  processed_note text,
  reopened_at   timestamptz,
  reopen_reason text,
  closed_by     uuid references auth.users(id) on delete set null,
  closed_at     timestamptz,
  updated_at    timestamptz default now(),
  unique(subject_type, subject_id, kind)  -- لا نُكرر حالة مفتوحة لنفس الشخص من نفس النوع
);
create index if not exists supcase_status_idx  on public.supervisor_cases(status, priority);
create index if not exists supcase_subj_idx    on public.supervisor_cases(subject_type, subject_id);
create index if not exists supcase_kind_idx    on public.supervisor_cases(kind);

comment on column public.supervisor_cases.status   is 'open|processed|reopened|closed';
comment on column public.supervisor_cases.priority is 'urgent|follow_up|review';
comment on column public.supervisor_cases.kind     is 'late_wards|attendance_drop|mastery_drop|no_teacher|no_plan|paid_no_group|teacher_no_report|teacher_no_session|other';

alter table public.supervisor_cases enable row level security;

drop policy if exists supcase_read on public.supervisor_cases;
create policy supcase_read on public.supervisor_cases for select
using (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role,'teacher'::user_role])
);
drop policy if exists supcase_write on public.supervisor_cases;
create policy supcase_write on public.supervisor_cases for all
using (
  is_admin() or is_scientific_director()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role])
)
with check (
  is_admin() or is_scientific_director()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role])
);

-- ═══ supervisor_visits — لتتبع «منذ آخر دخول» بدل الاعتماد على localStorage ═══
create table if not exists public.supervisor_visits (
  supervisor_id      uuid primary key references auth.users(id) on delete cascade,
  last_visited_at    timestamptz not null default now(),
  prev_visited_at    timestamptz,
  updated_at         timestamptz default now()
);
alter table public.supervisor_visits enable row level security;

drop policy if exists supvis_all on public.supervisor_visits;
create policy supvis_all on public.supervisor_visits for all
using ( supervisor_id = auth.uid() or is_admin() )
with check ( supervisor_id = auth.uid() or is_admin() );
