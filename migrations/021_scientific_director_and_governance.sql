-- ============================================================================
-- 021_scientific_director_and_governance.sql
--
-- بناء دور "المدير العلمي / الشريك المؤسس" كطبقة أعلى من role='admin' القائم،
-- بدون كسر ما هو مبني عليه. المدير التنفيذي يبقى admin/executive عادياً.
--
-- الطبقة تتكوّن من:
--
-- ١) علَمَان (bool) على profiles:
--    - is_founding_partner  → شريك مؤسس (اطلاع كامل على "نظرة الشريك" +
--      المشاركة في قرارات الشراكة)
--    - is_scientific_director → المدير العلمي (اعتماد المحتوى العلمي والمناهج
--      والمعايير والخطط العلاجية، ومراجعة جودة التعليم)
--
--    وضعناهما علَمَين لا role جديد، حتى لا نضطر لتوسيع الـuser_role enum
--    ولا نُغيّر أي سياسة RLS قائمة معتمدة على is_admin()/my_role().
--
-- ٢) جدول content_approvals — بوابة الاعتماد لكل المحتوى العلمي: منهج، مسار،
--    محطة، حصن، اختبار، معيار، خطة علاجية، رسالة تعليمية موجهة، منتج علمي.
--    الحالة تسير في مسار موثّق (draft → in_review → scientifically_approved
--    → awaiting_executive → ready_to_publish → published، وفروع needs_edit
--    و rejected و archived).
--
-- ٣) جدول partnership_decisions — القرارات الكبرى التي لا يجوز أن ينفرد بها
--    طرف: إطلاق منتج علمي كبير، تعاقد كبير، تغيير النشاط، شراكة، استخدام
--    العلامة خارج المشروع، بيع/إغلاق. لكل قرار موقف مسجّل لكل شريك مع
--    ملاحظة، ومسار زمني مغلق النهاية.
--
-- كل السياسات RLS مبنية على is_admin() القائمة + الأعلام الجديدة. الوصول
-- الافتراضي: قراءة لكل المشرفين والمديرين، وكتابة على المسارات العلمية
-- محصورة بمن يحمل الأعلام المقابلة.
-- ============================================================================

-- ─── ١) أعلام profiles ─────────────────────────────────────────────────────
alter table public.profiles
  add column if not exists is_founding_partner   boolean not null default false,
  add column if not exists is_scientific_director boolean not null default false;

comment on column public.profiles.is_founding_partner   is 'شريك مؤسس — يرى "نظرة الشريك" ويشارك في قرارات الشراكة';
comment on column public.profiles.is_scientific_director is 'المدير العلمي — يعتمد المحتوى والمناهج والمعايير';

-- دالتان مساعدتان تُستخدمان في السياسات وواجهة التطبيق بلا تكرار منطق
create or replace function public.is_scientific_director()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_scientific_director from profiles where id = auth.uid()), false)
$$;

create or replace function public.is_founding_partner()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select is_founding_partner from profiles where id = auth.uid()), false)
$$;

-- ─── ٢) جدول content_approvals ─────────────────────────────────────────────
create table if not exists public.content_approvals (
  id                      uuid primary key default gen_random_uuid(),
  kind                    text not null,
  target_type             text,
  target_id               text,
  title                   text not null,
  summary                 text,
  reason                  text,
  version                 text,
  previous_version        text,
  impact                  jsonb,
  attachments             jsonb,
  requested_by            uuid references auth.users(id) on delete set null,
  status                  text not null default 'draft',
  scientific_reviewer     uuid references auth.users(id) on delete set null,
  scientific_reviewed_at  timestamptz,
  scientific_review_note  text,
  executive_reviewer      uuid references auth.users(id) on delete set null,
  executive_reviewed_at   timestamptz,
  executive_review_note   text,
  published_at            timestamptz,
  created_at              timestamptz default now(),
  updated_at              timestamptz default now()
);

create index if not exists content_approvals_status_idx  on public.content_approvals(status);
create index if not exists content_approvals_kind_idx    on public.content_approvals(kind);
create index if not exists content_approvals_created_idx on public.content_approvals(created_at desc);

comment on column public.content_approvals.kind    is 'curriculum|path|station|fortress|test|standard|remedial|material|message|product|other';
comment on column public.content_approvals.status  is 'draft|in_review|needs_edit|scientifically_approved|awaiting_executive|ready_to_publish|published|rejected|archived';
comment on column public.content_approvals.impact  is 'أثر التعديل: {"students":N,"teachers":N,"paths":[...],"stations":[...]}';

alter table public.content_approvals enable row level security;

-- قراءة: أي مدير/مشرف/تنفيذي/مدير علمي/شريك
drop policy if exists ca_read on public.content_approvals;
create policy ca_read on public.content_approvals for select
using ( is_admin() or my_role() = any(array['executive'::user_role,'supervisor'::user_role]) or is_scientific_director() or is_founding_partner() );

-- إدراج المسودات: مقدّم الطلب (أي مشرف/مدير/تنفيذي/مدير علمي)
drop policy if exists ca_insert on public.content_approvals;
create policy ca_insert on public.content_approvals for insert
with check (
  requested_by = auth.uid()
  and ( is_admin() or my_role() = any(array['executive'::user_role,'supervisor'::user_role]) or is_scientific_director() )
);

-- تحديث المسودات من صاحبها + قرار المدير العلمي + قرار التنفيذي
-- ملاحظة: نضع سياسة واحدة عامة UPDATE للمخوّلين، ويترك التطبيق التحقق من
-- الحقول المسموح بها لكل دور (لا نُعقّد قواعد الأعمدة على مستوى RLS)
drop policy if exists ca_update on public.content_approvals;
create policy ca_update on public.content_approvals for update
using ( is_admin() or my_role() = any(array['executive'::user_role,'supervisor'::user_role]) or is_scientific_director() )
with check ( is_admin() or my_role() = any(array['executive'::user_role,'supervisor'::user_role]) or is_scientific_director() );

-- ─── ٣) جدول partnership_decisions ─────────────────────────────────────────
create table if not exists public.partnership_decisions (
  id                    uuid primary key default gen_random_uuid(),
  title                 text not null,
  summary               text,
  why_now               text,
  scientific_impact     text,
  operational_impact    text,
  financial_impact      text,
  attachments           jsonb,
  status                text not null default 'draft',
  opened_by             uuid references auth.users(id) on delete set null,
  scientific_position   text,       -- approve|reject|request_edit
  scientific_note       text,
  scientific_by         uuid references auth.users(id) on delete set null,
  scientific_at         timestamptz,
  executive_position    text,
  executive_note        text,
  executive_by          uuid references auth.users(id) on delete set null,
  executive_at          timestamptz,
  final_decision        text,       -- approved|rejected|postponed
  finalized_at          timestamptz,
  created_at            timestamptz default now(),
  updated_at            timestamptz default now()
);

create index if not exists partnership_status_idx  on public.partnership_decisions(status);
create index if not exists partnership_created_idx on public.partnership_decisions(created_at desc);

comment on column public.partnership_decisions.status is 'draft|awaiting_scientific|awaiting_executive|awaiting_both|approved|rejected|postponed';

alter table public.partnership_decisions enable row level security;

-- قراءة/كتابة: للشركاء المؤسسين + المدير التنفيذي (admin/executive) + المدير العلمي
drop policy if exists pd_read on public.partnership_decisions;
create policy pd_read on public.partnership_decisions for select
using ( is_founding_partner() or is_scientific_director() or is_admin() or my_role() = 'executive'::user_role );

drop policy if exists pd_insert on public.partnership_decisions;
create policy pd_insert on public.partnership_decisions for insert
with check ( opened_by = auth.uid() and ( is_founding_partner() or is_scientific_director() or is_admin() or my_role() = 'executive'::user_role ) );

drop policy if exists pd_update on public.partnership_decisions;
create policy pd_update on public.partnership_decisions for update
using ( is_founding_partner() or is_scientific_director() or is_admin() or my_role() = 'executive'::user_role )
with check ( is_founding_partner() or is_scientific_director() or is_admin() or my_role() = 'executive'::user_role );

-- ملاحظة: بعد تشغيل هذا الملف، امنح نفسك الأعلام الأولى مرة واحدة:
--   update profiles set is_founding_partner = true, is_scientific_director = true where id = auth.uid();
-- أو للحساب المحدد بالبريد:
--   update profiles set is_founding_partner = true, is_scientific_director = true
--   where id = (select id from auth.users where email = '<your@email>');
