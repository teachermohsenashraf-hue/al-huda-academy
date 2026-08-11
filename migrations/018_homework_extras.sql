-- ============================================================================
-- 018_homework_extras.sql
--
-- توسيع جدول الواجبات (assignments) ليدعم متطلبات القسم ٨ من مواصفات المعلم:
--   ١) هل يتطلب الواجب رفع إثبات (رابط) من الطالب أم مجرد إتمام؟
--   ٢) رابط الإثبات المرفوع من الطالب.
--   ٣) رؤية الواجب: للطالب فقط، أم للطالب وولي الأمر معاً.
--   ٤) تدفق المراجعة من المعلم: null → معلّق، approved → معتمد،
--      needs_revision → يحتاج إعادة. مستقل عن status العام (pending/done/missed)
--      حتى لا نُبعثر معنى "أنجزه الطالب" مع "اعتمده المعلم".
--   ٥) وقت + من قام بالمراجعة، للتدقيق.
-- كل الأعمدة NULLABLE بلا قيمة افتراضية (لكل ما يهم للطلاب الحاليين)، ما عدا
-- requires_proof الذي يأخذ default false حتى لا تكسر واجبات قديمة كانت
-- تُعامَل تلقائياً كـ "أُتِمَّت بضغطة" بلا رفع إثبات.
-- ============================================================================

alter table public.assignments
  add column if not exists requires_proof boolean not null default false,
  add column if not exists proof_url text,
  add column if not exists visibility text,          -- 'student' أو 'student_and_parent'
  add column if not exists review_status text,       -- 'approved' | 'needs_revision' | null
  add column if not exists reviewed_at timestamptz,
  add column if not exists reviewed_by uuid references auth.users(id) on delete set null;

-- لا نضع CHECK صارماً على visibility أو review_status حتى تُضاف قيم جديدة من
-- كود التطبيق بدون migration جديد. التغطية عبر Smoke test عند إضافتها.

comment on column public.assignments.requires_proof is 'إذا true، الطالب لا يستطيع إتمام الواجب بضغطة، بل يجب أن يُرفَق رابط إثبات';
comment on column public.assignments.proof_url      is 'رابط الإثبات الذي رفعه الطالب (إن كان الواجب يتطلب إثباتاً)';
comment on column public.assignments.visibility     is 'من يرى الواجب: student | student_and_parent (افتراضياً الاثنان معاً في التطبيق)';
comment on column public.assignments.review_status  is 'قرار المعلم بعد إنجاز الطالب: approved | needs_revision | null (معلَّق)';
comment on column public.assignments.reviewed_at    is 'وقت المراجعة';
comment on column public.assignments.reviewed_by    is 'المستخدم الذي راجع الواجب (المعلم)';
