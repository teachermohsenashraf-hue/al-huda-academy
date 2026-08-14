-- ============================================================================
-- 025_generic_programs.sql
--
-- محرك أنظمة تعليمية عام — ليس مقصورًا على القرآن.
-- يتيح تصميم أي برنامج (حفظ، تجويد، تربية، لغة، دورة شرعية، تأهيل معلمين…)
-- بمرونة كاملة: مسارات + محطات + أنشطة + شروط انتقال + حالات اعتماد.
--
-- استخدمنا بادئة edu_ لعدم التصادم مع جدول programs القديم (رسوم/جلسات).
-- الاعتماد العلمي يمر عبر content_approvals كـ kind='program' (لا تكرار).
-- ============================================================================

create table if not exists public.edu_programs (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  description    text,
  domain         text not null default 'general',
  audience       text default 'students',
  age_range      text,
  pricing_model  text default 'free',
  icon           text,
  cover_color    text default '#2E7D5B',
  structure_type text default 'tracks_stations',
  status         text not null default 'draft',
  version        text default '1.0',
  parent_program_id uuid references public.edu_programs(id) on delete set null,
  template_key   text,
  completion_rule text,
  passing_score_pct integer default 60,
  requires_scientific_approval boolean default true,
  requires_ops_setup boolean default true,
  ops_config     jsonb default '{}'::jsonb,
  created_by     uuid references auth.users(id) on delete set null,
  approved_by    uuid references auth.users(id) on delete set null,
  approved_at    timestamptz,
  published_at   timestamptz,
  archived_at    timestamptz,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now()
);
create index if not exists edu_programs_status_idx on public.edu_programs(status);
create index if not exists edu_programs_domain_idx on public.edu_programs(domain);

comment on column public.edu_programs.domain is 'quran|tajweed|tarbiya|shariah|arabic|teacher_training|general|custom';
comment on column public.edu_programs.status is 'draft|in_review|needs_edit|scientifically_approved|awaiting_ops|ready|published|paused|archived';

create table if not exists public.edu_program_tracks (
  id           uuid primary key default gen_random_uuid(),
  program_id   uuid not null references public.edu_programs(id) on delete cascade,
  name         text not null,
  description  text,
  order_index  integer not null default 0,
  target_audience text,
  duration_weeks integer,
  is_optional  boolean default false,
  created_at   timestamptz default now()
);
create index if not exists edu_tracks_program_idx on public.edu_program_tracks(program_id, order_index);

create table if not exists public.edu_program_stations (
  id           uuid primary key default gen_random_uuid(),
  program_id   uuid not null references public.edu_programs(id) on delete cascade,
  track_id     uuid references public.edu_program_tracks(id) on delete cascade,
  name         text not null,
  description  text,
  order_index  integer not null default 0,
  duration_days integer,
  mastery_threshold_pct integer default 70,
  requires_exam boolean default false,
  advance_rule text default 'auto',
  created_at   timestamptz default now()
);
create index if not exists edu_stations_program_idx on public.edu_program_stations(program_id, order_index);
create index if not exists edu_stations_track_idx   on public.edu_program_stations(track_id, order_index);

create table if not exists public.edu_program_activities (
  id             uuid primary key default gen_random_uuid(),
  station_id     uuid not null references public.edu_program_stations(id) on delete cascade,
  kind           text not null default 'lesson',
  title          text not null,
  description    text,
  content_url    text,
  content_text   text,
  quran_ref      jsonb,
  points         integer default 1,
  is_required    boolean default true,
  order_index    integer not null default 0,
  created_at     timestamptz default now()
);
create index if not exists edu_activities_station_idx on public.edu_program_activities(station_id, order_index);

comment on column public.edu_program_activities.kind is
  'lesson|video|pdf|audio|link|assignment|test|oral_eval|live_session|reading|memorize|review|recite|behavior|reflection|custom + quran: quran_memorize|quran_review|quran_recite|quran_listen|quran_tajweed_eval';

alter table public.edu_programs           enable row level security;
alter table public.edu_program_tracks     enable row level security;
alter table public.edu_program_stations   enable row level security;
alter table public.edu_program_activities enable row level security;

drop policy if exists prog_read on public.edu_programs;
create policy prog_read on public.edu_programs for select
using (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role,'teacher'::user_role])
  or (status = 'published' and exists(select 1 from students s where s.login_id = auth.uid() and s.enrollment_status = 'active'))
);

drop policy if exists prog_insert on public.edu_programs;
create policy prog_insert on public.edu_programs for insert
with check ( created_by = auth.uid() and (is_admin() or is_scientific_director() or my_role() = 'executive'::user_role) );

drop policy if exists prog_update on public.edu_programs;
create policy prog_update on public.edu_programs for update
using ( is_admin() or is_scientific_director() or my_role() = 'executive'::user_role )
with check ( is_admin() or is_scientific_director() or my_role() = 'executive'::user_role );

drop policy if exists prog_delete on public.edu_programs;
create policy prog_delete on public.edu_programs for delete
using ( is_admin() or is_scientific_director() );

drop policy if exists tracks_all on public.edu_program_tracks;
create policy tracks_all on public.edu_program_tracks for all
using ( exists(select 1 from public.edu_programs p where p.id = program_id and (is_admin() or is_scientific_director() or my_role() = 'executive'::user_role)) )
with check ( exists(select 1 from public.edu_programs p where p.id = program_id and (is_admin() or is_scientific_director() or my_role() = 'executive'::user_role)) );

drop policy if exists stations_all on public.edu_program_stations;
create policy stations_all on public.edu_program_stations for all
using ( exists(select 1 from public.edu_programs p where p.id = program_id and (is_admin() or is_scientific_director() or my_role() = 'executive'::user_role)) )
with check ( exists(select 1 from public.edu_programs p where p.id = program_id and (is_admin() or is_scientific_director() or my_role() = 'executive'::user_role)) );

drop policy if exists acts_all on public.edu_program_activities;
create policy acts_all on public.edu_program_activities for all
using ( exists(select 1 from public.edu_program_stations st join public.edu_programs p on p.id=st.program_id where st.id = station_id and (is_admin() or is_scientific_director() or my_role() = 'executive'::user_role)) )
with check ( exists(select 1 from public.edu_program_stations st join public.edu_programs p on p.id=st.program_id where st.id = station_id and (is_admin() or is_scientific_director() or my_role() = 'executive'::user_role)) );
