-- ============================================================================
-- 026_program_enrollments.sql
--
-- ربط الطلاب/الحلقات بأنظمة edu_programs — يُكمل دورة الحياة من التصميم للنشر
-- إلى الاستخدام الفعلي. نُبقي جدولًا بسيطًا مرنًا كي لا نلزم أنفسنا بنموذج
-- ثقيل قبل ما نحتاجه.
-- ============================================================================

create table if not exists public.edu_program_enrollments (
  id           uuid primary key default gen_random_uuid(),
  program_id   uuid not null references public.edu_programs(id) on delete cascade,
  track_id     uuid references public.edu_program_tracks(id) on delete set null,
  student_id   bigint references public.students(id) on delete cascade,
  group_id     bigint references public.groups(id) on delete set null,
  status       text not null default 'active',   -- active|paused|completed|withdrawn
  enrolled_at  timestamptz default now(),
  completed_at timestamptz,
  progress_pct integer default 0,
  current_station_id uuid references public.edu_program_stations(id) on delete set null,
  notes        text,
  enrolled_by  uuid references auth.users(id) on delete set null,
  created_at   timestamptz default now(),
  updated_at   timestamptz default now(),
  unique(program_id, student_id)   -- طالب واحد لكل نظام (يمكن إعادة تفعيل)
);
create index if not exists edu_enr_prog_idx   on public.edu_program_enrollments(program_id);
create index if not exists edu_enr_stud_idx   on public.edu_program_enrollments(student_id);
create index if not exists edu_enr_group_idx  on public.edu_program_enrollments(group_id);
create index if not exists edu_enr_status_idx on public.edu_program_enrollments(status);

comment on column public.edu_program_enrollments.status is 'active|paused|completed|withdrawn';

alter table public.edu_program_enrollments enable row level security;

-- قراءة: الطاقم يرى الكل، الطالب/الولي يرى الخاصة به
drop policy if exists enr_read on public.edu_program_enrollments;
create policy enr_read on public.edu_program_enrollments for select
using (
  is_admin() or is_scientific_director() or is_founding_partner()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role,'teacher'::user_role])
  or exists (select 1 from students s where s.id = student_id and (s.login_id = auth.uid() or s.parent_id = auth.uid()))
);

-- كتابة: طاقم إداري
drop policy if exists enr_write on public.edu_program_enrollments;
create policy enr_write on public.edu_program_enrollments for all
using (
  is_admin() or is_scientific_director()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role])
)
with check (
  is_admin() or is_scientific_director()
  or my_role() = any(array['executive'::user_role,'supervisor'::user_role])
);
