-- ============================================================================
-- 024_acquisition_source.sql
--
-- تتبع مصدر الاكتساب لكل طالب — يُغلق ثغرة الإفصاح في صفحة النمو والتسويق.
-- عمود بسيط على enroll_requests + students، مع قيمة افتراضية 'unknown'
-- للسجلات القديمة، وحقل «كيف عرفت عنّا؟» يظهر في نموذج التسجيل.
-- ============================================================================

alter table public.enroll_requests
  add column if not exists acquisition_source text default 'unknown';

alter table public.students
  add column if not exists acquisition_source text default 'unknown';

create index if not exists enroll_requests_source_idx on public.enroll_requests(acquisition_source);
create index if not exists students_source_idx on public.students(acquisition_source);

comment on column public.enroll_requests.acquisition_source is
  'كيف وصل الطالب: friend | facebook | instagram | tiktok | google | ad | school | mosque | other | unknown';
comment on column public.students.acquisition_source is
  'مصدر الاكتساب — يُنسخ من enroll_requests أو يُعيَّن يدويًا';
