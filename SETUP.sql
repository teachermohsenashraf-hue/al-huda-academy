-- ============================================================
-- ملف إعداد قاعدة البيانات — شغّله في Supabase → SQL Editor
-- (بند 2، 3، 4 اللي محتاجين خطوة يدوية برا الكود)
-- ============================================================

-- ملاحظة: في Supabase الإضافة دي بتتركّب افتراضياً في سكيمة extensions
-- مش public، فأي دالة بتحدد search_path=public بس مش هتلاقي gen_salt/crypt
-- (رسالة الخطأ: function gen_salt(unknown) does not exist). لو الإضافة
-- مركّبة بالفعل بسكيمة تانية، السطر ده بس بيتجاهلها من غير ما يغيّر مكانها.
create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------------
-- ٠-ل) 🔴 إصلاح حرج في الأداء: qCheckAndFireNotifications كانت تُدرج إشعاراً
--      جديداً في quran_notifications في كل مرة تُفتح فيها صفحة "التنبيهات"
--      بلا أي تحقّق من التكرار، فتراكمت صفوف مكرَّرة لنفس الحالة (late_wards
--      خصوصاً، لأنها شائعة) مع كل استخدام — وهو ما كان يجعل الصفحة تزداد بطئاً
--      تدريجياً حتى تتجاوز مهلة التحميل. ننظّف التكرار المتراكم فعلاً هنا،
--      ونضيف فهرساً يسرّع فحص "هل فُحص هذا مؤخراً؟" الجديد في الكود.
-- ------------------------------------------------------------
delete from quran_notifications a using quran_notifications b
where a.id < b.id and a.user_id=b.user_id and a.kind=b.kind
  and a.kind in ('late_wards','near_station_end','station_complete')
  and a.created_at < now() - interval '1 hour';
create index if not exists idx_quran_notifications_user_kind_created on quran_notifications(user_id, kind, created_at);

-- ------------------------------------------------------------
-- ٠-ي) تخفيض الرسوم: كان المبلغ مقفولاً على "نصف السعر" بلا أي هامش لتقدير
--      المشرف الفعلي لحالة كل أسرة، وبدون حقل "دخل الأسرة الشهري" في الاستبيان.
--      approved_fee على الطالب يخزّن المبلغ الفعلي الذي وافق عليه المشرف (قد
--      يختلف عن نصف السعر بالضبط)، ليقرأه محرك الدفع مباشرة بدل احتساب نصف
--      السعر من جديد كل مرة.
-- ------------------------------------------------------------
alter table students add column if not exists approved_fee numeric;
alter table join_requests add column if not exists monthly_income numeric;

-- ------------------------------------------------------------
-- ٠-ج) عمود عملة الدفعة — لتوحيد الباقة بسعر واحد يظهر بعملة كل دولة
--      (مصر جنيه، السعودية ريال، وأي دولة تانية دولار)، ولتقارير
--      التحصيل حسب الدولة في لوحة المدير/التنفيذي.
-- ------------------------------------------------------------
alter table payments add column if not exists currency_code text default 'EGP';

-- ------------------------------------------------------------
-- ٠-ح) 🔴 إصلاح حرج: مسار الطالب (track) كان يظهر كـ"الحفظ والتربية" معاً
--      لأي طالب سجّل عبر مسار الالتحاق الرئيسي، رغم أنه اشترك في الحفظ فقط،
--      لأن الإدراج في الكود ما كانش يحدد قيمة track صراحةً فيرجع للافتراضي
--      العام للجدول ('both'). ومسار "التربية" أصلاً غير مطروح للاشتراك بعد
--      (لسه "قريباً")، فأي طالب حالي بقيمة غير 'quran' الصريحة هو فعلياً طالب
--      حفظ فقط بلا استثناء — نصحّح البيانات القائمة بأثر رجعي هنا.
-- ------------------------------------------------------------
update students set track='quran' where track is null or track<>'quran';

-- ------------------------------------------------------------
-- ٠-و) حدود المحطة كبيانات حقيقية بدل نص حر — كانت quran_stations معتمدة
--      بالكامل على entry_conditions/exit_conditions (نص حر يكتبه المدير
--      بحرّية، زي "حفظ جزء عمّ")، فمحرك توليد الخطة (generatePlanSchedule)
--      ما كانش يعرف أصلاً حدود المحطة الفعلية، وكان بيكمّل الحفظ الجديد
--      لحد ما تنفد أيام الخطة المُعدّة أو يوصل لسورة الفاتحة، حتى لو
--      المحطة نفسها المفروض تقف عند سورة معيّنة (زي جزء عمّ يقف عند النبأ).
--      station_kind بيميّز محطة "حفظ" عن محطة "مراجعة بحتة" (اللي مفيهاش
--      حفظ جديد ولا مراجعة قريبة خالص — بس مراجعة بعيدة + سماع/قراءة).
-- ------------------------------------------------------------
alter table quran_stations add column if not exists station_kind text default 'hifz';
alter table quran_stations add column if not exists boundary_surah_from int;
alter table quran_stations add column if not exists boundary_surah_to int;
do $$ begin
  if not exists (select 1 from pg_constraint where conname='quran_stations_kind_check') then
    alter table quran_stations add constraint quran_stations_kind_check check (station_kind in ('hifz','review'));
  end if;
end $$;

-- ------------------------------------------------------------
-- ٠-ط) بداية الاشتراك تُحسب من لحظة تأكيد الدفع مباشرة، فأي تأخير لاحق في
--      اختيار المعلم أو إنشاء الحلقة (ممكن ياخد أيام) كان يقتطع من أيام
--      اشتراك الطالب الفعلية رغم إنه لسه ما بدأش يتلقّى حصصاً. sub_anchored
--      تتبع هل تاريخ البداية اتثبَّت فعلاً على أول حصة حقيقية أم لسه مؤقت.
-- ------------------------------------------------------------
alter table students add column if not exists sub_anchored boolean default true;

-- ------------------------------------------------------------
-- ٠-ز) 🔴 إصلاح حرج: تعبئة station_kind/boundary_surah_from/to الفعلية لكل
--      محطات المسارات الستة المزروعة مسبقاً (قسم "تعبئة المحطات الحقيقية"
--      بالأسفل في هذا الملف). الأعمدة أُضيفت بعد إدخال هذه المحطات، فبقيت
--      كل محطة موجودة فعلاً على القيم الافتراضية: station_kind='hifz'
--      وحدود NULL — وهو السبب الحقيقي وراء تجاهل محرك توليد الخطة لنوع/حدود
--      المحطة عمليًا رغم صحة كود generatePlanSchedule نفسه: البيانات نفسها
--      لم تكن معبّأة قط. الحدود هنا مستخرجة حرفيًا من اسم كل محطة (نفس
--      الأسماء المُدخلة أعلاه)، ومطابقة بمفتاح (مسار + ترتيب المحطة) للدقة
--      بدل مطابقة نصية هشة. أرقام السور حسب ترتيبها في القرآن (١=الفاتحة
--      ... ١١٤=الناس)، راجع QURAN_SURAHS في index.html لو احتجت التأكد.
--      ملحوظة: محطات الزهراوين (تقسيم نصف/نصف داخل نفس السورة) لا يملك
--      النطاق الحالي (سورة→سورة) دقة على مستوى الآية، فمحطتا "بداية/إتمام"
--      لنفس السورة يُسجَّلان بنفس حدود السورة الواحدة؛ الفصل بينهما لسه
--      معتمد على تقييم المعلم (current_ayah_no) عند اعتماد الانتقال بينهما.
-- ------------------------------------------------------------
update quran_stations st set
  station_kind = b.kind,
  boundary_surah_from = b.lo,
  boundary_surah_to = b.hi
from quran_systems qs, (values
  -- جزء عمّ وتبارك (amma)
  ('amma'::text, 1, 'hifz'::text, 78, 114),
  ('amma', 2, 'hifz', 67, 77),
  ('amma', 3, 'review', 67, 114),
  -- المفصّل (mufassal)
  ('mufassal', 1, 'hifz', 67, 114),
  ('mufassal', 2, 'hifz', 58, 66),
  ('mufassal', 3, 'hifz', 50, 57),
  ('mufassal', 4, 'review', 50, 114),
  -- ربع القرآن (quarter)
  ('quarter', 1, 'hifz', 67, 114),
  ('quarter', 2, 'hifz', 50, 66),
  ('quarter', 3, 'hifz', 46, 49),
  ('quarter', 4, 'hifz', 42, 45),
  ('quarter', 5, 'hifz', 39, 41),
  ('quarter', 6, 'hifz', 36, 38),
  ('quarter', 7, 'review', 50, 114),
  ('quarter', 8, 'review', 36, 49),
  ('quarter', 9, 'review', 36, 114),
  -- نصف القرآن (half)
  ('half', 1, 'hifz', 50, 114),
  ('half', 2, 'hifz', 36, 49),
  ('half', 3, 'hifz', 29, 36),
  ('half', 4, 'hifz', 25, 28),
  ('half', 5, 'hifz', 21, 24),
  ('half', 6, 'hifz', 18, 20),
  ('half', 7, 'review', 36, 114),
  ('half', 8, 'review', 18, 35),
  ('half', 9, 'review', 18, 114),
  -- الزهراوان (zahrawan) — ترتيب طبيعي (غير عكسي)
  ('zahrawan', 1, 'hifz', 2, 2),
  ('zahrawan', 2, 'hifz', 2, 2),
  ('zahrawan', 3, 'review', 2, 2),
  ('zahrawan', 4, 'hifz', 3, 3),
  ('zahrawan', 5, 'hifz', 3, 3),
  ('zahrawan', 6, 'review', 3, 3),
  ('zahrawan', 7, 'review', 2, 3),
  -- القرآن كامل (full)
  ('full', 1, 'hifz', 50, 114),
  ('full', 2, 'hifz', 2, 3),
  ('full', 3, 'hifz', 36, 49),
  ('full', 4, 'hifz', 25, 35),
  ('full', 5, 'hifz', 18, 24),
  ('full', 6, 'hifz', 10, 17),
  ('full', 7, 'hifz', 6, 9),
  ('full', 8, 'hifz', 1, 5),
  ('full', 9, 'review', 36, 114),
  ('full', 10, 'review', 18, 35),
  ('full', 11, 'review', 8, 17),
  ('full', 12, 'review', 2, 6),
  ('full', 13, 'review', 1, 114)
) as b(path_key, order_index, kind, lo, hi)
where st.system_id = qs.id and qs.path_key = b.path_key and st.order_index = b.order_index;

-- ------------------------------------------------------------
-- ٠-ك) 🔴 إصلاح محطة الزهراوين: كانت لها قيدان معماريان تركا أثراً في التوليد:
--      (أ) تقسيم "بداية/إتمام" نفس السورة لم يكن ممكناً بحدود سورة→سورة فقط،
--      فمحطتا "بداية البقرة" و"إتمام البقرة" كانتا بنفس الحدود (٢-٢) بلا أي
--      فارق بينهما فعلياً. الحل: boundary_ayah_from/to يحصران المدى داخل
--      نفس السورة (يُستخدَمان فقط لما تكون السورة من/إلى واحدة).
--      (ب) محطة "الزهراوان" داخل مسار "القرآن كامل" (ترتيبه عكسي بالكامل) كانت
--      سترث نفس اتجاه الحفظ العكسي فتبدأ بآل عمران وتنزل للبقرة، بينما
--      التقليد الثابت للزهراوين محفوظ دائماً بالترتيب الطبيعي (البقرة ثم آل
--      عمران) بصرف النظر عن اتجاه بقية المسار. force_forward يفرض الترتيب
--      الطبيعي لمحطة بعينها متجاوزاً اتجاه المسار العام.
-- ------------------------------------------------------------
alter table quran_stations add column if not exists boundary_ayah_from int;
alter table quran_stations add column if not exists boundary_ayah_to int;
alter table quran_stations add column if not exists force_forward boolean default false;

update quran_stations st set boundary_ayah_from=b.afrom, boundary_ayah_to=b.ato
from quran_systems qs, (values
  ('zahrawan'::text, 1, 1, 141),    -- بداية البقرة
  ('zahrawan', 2, 142, 286),        -- إتمام البقرة
  ('zahrawan', 4, 1, 92),           -- بداية آل عمران
  ('zahrawan', 5, 93, 200)          -- إتمام آل عمران
) as b(path_key, order_index, afrom, ato)
where st.system_id = qs.id and qs.path_key = b.path_key and st.order_index = b.order_index;

update quran_stations st set force_forward=true
from quran_systems qs
where st.system_id = qs.id and qs.path_key='full' and st.order_index=2;

-- ------------------------------------------------------------
-- ٠-د) sub_start/sub_end كانت من نوع date بس (بدون وقت)، فلحظة تفعيل
--      الاشتراك الحقيقية (بالساعة والدقيقة) كانت بتتقطع لتاريخ بس، وبعد كده
--      لما تتقرأ في المتصفح كـ "منتصف الليل UTC" بتترجم لمنطقة القاهرة/الرياض
--      كساعة 2 أو 3 صباحاً وهمية مش هي وقت التفعيل الحقيقي. التحويل لـ
--      timestamptz بيحافظ على الوقت الفعلي للحظة التأكيد.
-- ------------------------------------------------------------
alter table students alter column sub_start type timestamptz using sub_start::timestamptz;
alter table students alter column sub_end type timestamptz using sub_end::timestamptz;

-- ------------------------------------------------------------
-- ٠-هـ) جدول payments أصلاً ملوش عمود created_at، فمفيش أي وقت مسجَّل للحظة
--      إرسال الطالب لطلب الدفع (paid_at بيتسجّل بس وقت تأكيد المشرف له، مش وقت
--      الإرسال) — فصفحة "تأكيد المدفوعات" كانت تعرض وقت إرسال فارغ دائماً.
--      كمان paid_at كان من نوع date بس (بدون وقت)، نفس مشكلة sub_start/sub_end.
-- ------------------------------------------------------------
alter table payments add column if not exists created_at timestamptz default now();
alter table payments alter column paid_at type timestamptz using paid_at::timestamptz;

-- ------------------------------------------------------------
-- ٠-ب) دالة حساب عدد طلاب كل معلم (لصفحة "اختر معلمك")
--      المشكلة: الطالب اللي بيسجّل ولسه ملوش صلاحيات كاملة، سياسات RLS بتمنعه
--      من قراءة صفوف طلاب تانيين أو كل جدول الحلقات، فأي حساب في المتصفح كان
--      بيرجع صفر دايماً. الدالة دي بتشتغل بصلاحيات أعلى على السيرفر (security definer)
--      وترجّع بس الرقم الإجمالي لكل معلم، من غير ما تكشف أي بيانات حساسة عن الطلاب.
-- ------------------------------------------------------------
drop function if exists get_teacher_loads();
create or replace function get_teacher_loads()
returns table(teacher_id uuid, student_count bigint)
language sql
security definer
set search_path = public
as $$
  with linked as (
    select s.id as student_id, coalesce(s.chosen_teacher_id, g.teacher_id) as teacher_id
    from students s
    left join groups g on g.id = s.group_id
    where s.chosen_teacher_id is not null or g.teacher_id is not null
  )
  select p.id as teacher_id, count(distinct linked.student_id) as student_count
  from profiles p
  left join linked on linked.teacher_id = p.id
  where p.role = 'teacher'
  group by p.id;
$$;
grant execute on function get_teacher_loads() to authenticated;

-- ------------------------------------------------------------
-- ٠-أ) صلاحيات رفع صور إيصالات الدفع (Storage) — كانت ناقصة تماماً،
--      فكل رفع إيصال كان بيفشل بصمت والكود القديم كان بيخزّن الصورة
--      كنص base64 عملاق في قاعدة البيانات بدل الرفع الفعلي للـ Storage.
-- ------------------------------------------------------------
-- باكيت الإيصالات كان public بالكامل (أي حد يعرف/يخمّن الرابط يشوف إيصال دفع أي طالب،
-- بما فيه اسمه ورقم مرجعه) — حوّلناه private، والقراءة بقت مقصورة على الطاقم الإداري
-- أو وليّ أمر/طالب الإيصال نفسه فقط (عبر Signed URL يُنشأ وقت العرض، راجع resolveReceiptUrls في index.html).
insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', false)
on conflict (id) do update set public = false;

drop policy if exists "authenticated upload receipts" on storage.objects;
create policy "authenticated upload receipts" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'receipts');

drop policy if exists "authenticated update own receipts" on storage.objects;
create policy "authenticated update own receipts" on storage.objects
  for update to authenticated
  using (bucket_id = 'receipts')
  with check (bucket_id = 'receipts');

-- اسم الملف بصيغة "{student_id}_{timestamp}.{ext}" — نستخرج student_id من أول الاسم
-- ونتحقّق إن طالب الإيصال ده مرتبط بالمستخدم الطالب لهذا الإيصال، أو المستخدم من الطاقم الإداري
drop policy if exists "public read receipts" on storage.objects;
drop policy if exists "staff or owner read receipts" on storage.objects;
create policy "staff or owner read receipts" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'receipts'
    and (
      exists (select 1 from profiles where id = auth.uid() and role in ('admin','executive','supervisor'))
      or exists (
        select 1 from students s
        where name ~ '^[0-9]+_'
          and s.id = split_part(name,'_',1)::bigint
          and (s.login_id = auth.uid() or s.parent_id = auth.uid())
      )
    )
  );

-- ------------------------------------------------------------
-- ٠) السماح لصاحب الرسالة بتعديل رسالته في المحادثات
--    (كانت السياسة الموجودة تسمح بالإرسال والقراءة فقط، فالتعديل كان يفشل بصمت)
-- ------------------------------------------------------------
drop policy if exists "sender can update own messages" on messages;
create policy "sender can update own messages" on messages
  for update to authenticated
  using (sender_id = auth.uid())
  with check (sender_id = auth.uid());

-- ------------------------------------------------------------
-- ١) جدول طلبات نقل الطلاب بين المعلمين (يتطلب قبول المعلم الجديد)
-- ------------------------------------------------------------
create table if not exists student_transfers(
  id uuid primary key default gen_random_uuid(),
  student_id bigint references students(id) on delete cascade,
  from_teacher_id uuid references profiles(id),
  to_teacher_id uuid references profiles(id),
  requested_by uuid references profiles(id),
  reason text,
  status text default 'pending',
  created_at timestamptz default now()
);
alter table student_transfers enable row level security;
drop policy if exists "allow all to authenticated" on student_transfers;
create policy "allow all to authenticated" on student_transfers for all to authenticated using (true) with check (true);

-- ------------------------------------------------------------
-- ٢) جدول اشتراكات إشعارات الدفع الحقيقية (Web Push)
-- ------------------------------------------------------------
create table if not exists push_subscriptions(
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id) on delete cascade,
  endpoint text unique not null,
  p256dh text not null,
  auth text not null,
  created_at timestamptz default now()
);
alter table push_subscriptions enable row level security;
drop policy if exists "user manages own subscriptions" on push_subscriptions;
create policy "user manages own subscriptions" on push_subscriptions for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
-- Edge Function بتستخدم service role key فبتتخطى RLS تلقائياً — مش محتاجة policy إضافية.

-- ------------------------------------------------------------
-- ٣) دالة إعادة تعيين كلمة سر مستخدم (يستخدمها المدير/التنفيذي/المشرف)
--    بنمسحها الأول لو موجودة بشكل مختلف (رجّعت خطأ عندك)، عشان النسخة الجديدة تتحط مكانها بأمان.
-- ------------------------------------------------------------
drop function if exists admin_reset_password(text, text);
create or replace function admin_reset_password(target_email text, new_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  target_user_id uuid;
  caller_role text;
begin
  select role into caller_role from profiles where id = auth.uid();
  if caller_role is null or caller_role not in ('admin','executive','supervisor') then
    return jsonb_build_object('ok', false, 'error', 'غير مصرح لك بهذا الإجراء');
  end if;

  select id into target_user_id from auth.users where email = target_email;
  if target_user_id is null then
    return jsonb_build_object('ok', false, 'error', 'لا يوجد مستخدم بهذا البريد');
  end if;

  update auth.users
  set encrypted_password = crypt(new_password, gen_salt('bf')),
      updated_at = now()
  where id = target_user_id;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function admin_reset_password(text, text) to authenticated;

-- ------------------------------------------------------------
-- ٤) دالة إنشاء حساب حقيقي مرتبط (ابن/ولي أمر) بكلمة سر فعلية
--    نفس الملحوظة: بنمسحها الأول لو موجودة بشكل مختلف.
-- ------------------------------------------------------------
drop function if exists create_linked_account(text, text, text, text, bigint);
create or replace function create_linked_account(
  p_email text, p_password text, p_name text, p_role text, p_student_id bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  new_user_id uuid;
  existing_id uuid;
begin
  -- قفل استشاري (advisory lock) مفتاحه البريد نفسه: يمنع تنفيذ طلبين متزامنين
  -- بنفس البريد في نفس اللحظة من عبور فحص "البريد غير مستخدم" معاً قبل ما
  -- يكتب أي منهما فعلياً (Race Condition) — القفل يُفكّ تلقائياً آخر المعاملة.
  perform pg_advisory_xact_lock(hashtext(lower(p_email)));

  select id into existing_id from auth.users where email = p_email;
  if existing_id is not null then
    return jsonb_build_object('ok', false, 'error', 'هذا البريد مستخدم بالفعل');
  end if;

  new_user_id := gen_random_uuid();

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data, is_super_admin, confirmation_token
  ) values (
    new_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    p_email, crypt(p_password, gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', p_name, 'role', p_role),
    false, ''
  );

  insert into auth.identities (
    id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(), new_user_id, new_user_id::text,
    jsonb_build_object('sub', new_user_id::text, 'email', p_email),
    'email', now(), now(), now()
  );

  insert into profiles (id, role, full_name, email)
  values (new_user_id, p_role::user_role, p_name, p_email)
  on conflict (id) do update set role=excluded.role, full_name=excluded.full_name, email=excluded.email;

  if p_role = 'student' and p_student_id is not null then
    update students set login_id = new_user_id where id = p_student_id;
  elsif p_role = 'parent' and p_student_id is not null then
    update students set parent_id = new_user_id where id = p_student_id;
  end if;

  return jsonb_build_object('ok', true, 'user_id', new_user_id);
exception
  -- خط دفاع أخير: لو نجح طلب متزامن آخر بنفس البريد رغم القفل (نادر جداً)،
  -- نرجع رسالة عربية واضحة بدل انهيار الدالة بخطأ SQL خام غير مفهوم للمستخدم
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'هذا البريد مستخدم بالفعل');
end;
$$;
grant execute on function create_linked_account(text, text, text, text, bigint) to authenticated;

-- ============================================================
-- ==========  البنية التحتية المستقبلية للدفع والتجارة  ==========
-- ============================================================
-- كل الجداول هنا جديدة تماماً، ومفيش أي جدول أو كود شغّال حالياً
-- بيقرأ منها أو يكتب فيها. يعني تشغيل القسم ده لا يغيّر ولا يأثّر
-- على طريقة الدفع الحالية (فودافون كاش + رفع الإيصال + تأكيد المشرف)
-- بأي شكل — دي جداول فاضية (أو معبّأة ببيانات مرجعية بس) قاعدة جنب
-- النظام الحالي، لحد ما يتقرر الانتقال الفعلي لها لاحقاً.

-- ------------------------------------------------------------
-- العملات المدعومة (بدل الاعتماد على نص حر currency_code في كل مكان)
-- ------------------------------------------------------------
create table if not exists currencies(
  code text primary key,
  name_ar text not null,
  symbol text not null,
  is_active boolean not null default true
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table currencies add column if not exists name_ar text;
alter table currencies add column if not exists symbol text;
alter table currencies add column if not exists is_active boolean default true;
create unique index if not exists ux_currencies_code on currencies(code);
insert into currencies (code, name_ar, symbol) values
  ('EGP','جنيه مصري','ج.م'),
  ('SAR','ريال سعودي','ر.س'),
  ('USD','دولار أمريكي','$')
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- المسارات (بديل مستقبلي لثابت QURAN_PATHS الموجود في الكود)
-- ------------------------------------------------------------
create table if not exists courses(
  id bigint generated always as identity primary key,
  code text unique not null,
  name_ar text not null,
  description text,
  is_active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table courses add column if not exists code text;
alter table courses add column if not exists name_ar text;
alter table courses add column if not exists description text;
alter table courses add column if not exists is_active boolean default true;
alter table courses add column if not exists sort_order int default 0;
alter table courses add column if not exists created_at timestamptz default now();
create unique index if not exists ux_courses_code on courses(code);
insert into courses (code, name_ar, description, sort_order) values
  ('amma','جزء عمّ وتبارك','حفظ جزأي عمّ وتبارك (٢٩ و٣٠) بإتقان وتجويد',1),
  ('zahrawan','الزهراوان','حفظ سورتي البقرة وآل عمران',2),
  ('mufassal','المفصّل','من سورة ق إلى الناس',3),
  ('quarter','ربع القرآن','٧.٥ أجزاء من يس إلى الناس',4),
  ('half','نصف القرآن','١٥ جزءاً',5),
  ('full','القرآن كاملاً','٣٠ جزءاً كاملة',6)
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- أنظمة التعلّم (بديل مستقبلي لثابت PLAN_SYSTEMS)
-- ------------------------------------------------------------
create table if not exists learning_systems(
  id bigint generated always as identity primary key,
  code text unique not null,
  name_ar text not null,
  description text,
  default_sessions_per_week int not null default 3,
  default_session_minutes int not null default 30,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table learning_systems add column if not exists code text;
alter table learning_systems add column if not exists name_ar text;
alter table learning_systems add column if not exists description text;
alter table learning_systems add column if not exists default_sessions_per_week int default 3;
alter table learning_systems add column if not exists default_session_minutes int default 30;
alter table learning_systems add column if not exists is_active boolean default true;
alter table learning_systems add column if not exists created_at timestamptz default now();
create unique index if not exists ux_learning_systems_code on learning_systems(code);
insert into learning_systems (code, name_ar, description) values
  ('rasokh','نظام رسوخ','خمسة حصون يومية — الأكثر شمولاً وضبطاً'),
  ('flexible','النظام المرن','ثلاثة حصون أساسية — أخف وأكثر مرونة')
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- خطط الأسعار الحالية المعروضة (منفصلة عن السعر المجمَّد وقت الدفع
-- الفعلي، عشان تغيير السعر مستقبلاً لا يأثّر على فواتير قديمة)
-- ------------------------------------------------------------
create table if not exists pricing_plans(
  id bigint generated always as identity primary key,
  currency_code text not null references currencies(code),
  amount numeric(10,2) not null,
  sessions_per_week int not null default 3,
  session_minutes int not null default 30,
  is_active boolean not null default true,
  effective_from timestamptz not null default now(),
  effective_to timestamptz,
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table pricing_plans add column if not exists currency_code text references currencies(code);
alter table pricing_plans add column if not exists amount numeric(10,2);
alter table pricing_plans add column if not exists sessions_per_week int default 3;
alter table pricing_plans add column if not exists session_minutes int default 30;
alter table pricing_plans add column if not exists is_active boolean default true;
alter table pricing_plans add column if not exists effective_from timestamptz default now();
alter table pricing_plans add column if not exists effective_to timestamptz;
alter table pricing_plans add column if not exists created_at timestamptz default now();
insert into pricing_plans (currency_code, amount)
  select code, amount from (values ('EGP',450.00),('SAR',105.00),('USD',30.00)) as v(code, amount)
  where not exists (select 1 from pricing_plans p where p.currency_code = v.code and p.is_active);

-- ------------------------------------------------------------
-- الكوبونات (تُنشأ قبل الطلبات لأن الطلب ممكن يشير لكوبون)
-- ------------------------------------------------------------
create table if not exists coupons(
  id bigint generated always as identity primary key,
  code text unique not null,
  description text,
  discount_type text not null check (discount_type in ('percent','fixed')),
  discount_value numeric(10,2) not null,
  currency_code text references currencies(code),
  max_redemptions int,
  redemptions_count int not null default 0,
  min_order_amount numeric(10,2),
  valid_from timestamptz not null default now(),
  valid_to timestamptz,
  is_active boolean not null default true,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table coupons add column if not exists code text;
alter table coupons add column if not exists description text;
alter table coupons add column if not exists discount_type text;
alter table coupons add column if not exists discount_value numeric(10,2);
alter table coupons add column if not exists currency_code text references currencies(code);
alter table coupons add column if not exists max_redemptions int;
alter table coupons add column if not exists redemptions_count int default 0;
alter table coupons add column if not exists min_order_amount numeric(10,2);
alter table coupons add column if not exists valid_from timestamptz default now();
alter table coupons add column if not exists valid_to timestamptz;
alter table coupons add column if not exists is_active boolean default true;
alter table coupons add column if not exists created_by uuid references profiles(id);
alter table coupons add column if not exists created_at timestamptz default now();

-- ------------------------------------------------------------
-- التسجيل الفعلي — كل صف = اشتراك واحد لمتعلّم في مسار ونظام.
-- متعلّم واحد ممكن يكون له عدة صفوف = دعم حقيقي لتعدد المسارات
-- (بديل مستقبلي لأعمدة quran_path/plan_type/enrollment_status
-- الموجودة حالياً داخل جدول students نفسه).
-- ------------------------------------------------------------
create table if not exists enrollments(
  id bigint generated always as identity primary key,
  student_id bigint not null references students(id) on delete cascade,
  course_id bigint not null references courses(id),
  system_id bigint not null references learning_systems(id),
  teacher_id uuid references profiles(id),
  group_id bigint references groups(id),
  status text not null default 'pending_payment'
    check (status in ('pending_payment','awaiting_confirmation','active','paused','expired','cancelled')),
  sessions_per_week int not null default 3,
  session_minutes int not null default 30,
  is_subsidized boolean not null default false,
  subsidy_percent int,
  current_period_start timestamptz,
  current_period_end timestamptz,
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table enrollments add column if not exists student_id bigint references students(id) on delete cascade;
alter table enrollments add column if not exists course_id bigint references courses(id);
alter table enrollments add column if not exists system_id bigint references learning_systems(id);
alter table enrollments add column if not exists teacher_id uuid references profiles(id);
alter table enrollments add column if not exists group_id bigint references groups(id);
alter table enrollments add column if not exists status text default 'pending_payment';
alter table enrollments add column if not exists sessions_per_week int default 3;
alter table enrollments add column if not exists session_minutes int default 30;
alter table enrollments add column if not exists is_subsidized boolean default false;
alter table enrollments add column if not exists subsidy_percent int;
alter table enrollments add column if not exists current_period_start timestamptz;
alter table enrollments add column if not exists current_period_end timestamptz;
alter table enrollments add column if not exists created_at timestamptz default now();
create index if not exists idx_enrollments_student on enrollments(student_id);
create index if not exists idx_enrollments_status on enrollments(status);

-- ------------------------------------------------------------
-- الطلب المالي — يمثّل نية الدفع (اشتراك جديد/تجديد/ترقية)،
-- منفصل عن محاولة الدفع الفعلية عشان تعدد المحاولات ووسائل الدفع
-- يجيان مجاناً بدون أي تعديل مستقبلي في الجداول.
-- ------------------------------------------------------------
create table if not exists orders(
  id bigint generated always as identity primary key,
  student_id bigint not null references students(id) on delete cascade,
  enrollment_id bigint references enrollments(id),
  order_type text not null default 'new' check (order_type in ('new','renewal','upgrade')),
  currency_code text not null references currencies(code),
  subtotal_amount numeric(10,2) not null,
  discount_amount numeric(10,2) not null default 0,
  total_amount numeric(10,2) not null,
  coupon_id bigint references coupons(id),
  status text not null default 'pending'
    check (status in ('pending','awaiting_payment','paid','failed','refunded','cancelled')),
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table orders add column if not exists student_id bigint references students(id) on delete cascade;
alter table orders add column if not exists enrollment_id bigint references enrollments(id);
alter table orders add column if not exists order_type text default 'new';
alter table orders add column if not exists currency_code text references currencies(code);
alter table orders add column if not exists subtotal_amount numeric(10,2);
alter table orders add column if not exists discount_amount numeric(10,2) default 0;
alter table orders add column if not exists total_amount numeric(10,2);
alter table orders add column if not exists coupon_id bigint references coupons(id);
alter table orders add column if not exists status text default 'pending';
alter table orders add column if not exists created_at timestamptz default now();
create index if not exists idx_orders_student on orders(student_id);
create index if not exists idx_orders_enrollment on orders(enrollment_id);
create index if not exists idx_orders_status on orders(status);

-- ------------------------------------------------------------
-- وسائل الدفع المتاحة — إضافة بوابة دفع مستقبلاً (Paymob/Stripe/
-- PayPal) = صف جديد هنا بس، بدون أي تعديل في بنية أي جدول.
-- ------------------------------------------------------------
create table if not exists payment_methods(
  id bigint generated always as identity primary key,
  code text unique not null,
  display_name_ar text not null,
  is_gateway boolean not null default false,
  is_active boolean not null default true,
  sort_order int not null default 0
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table payment_methods add column if not exists code text;
alter table payment_methods add column if not exists display_name_ar text;
alter table payment_methods add column if not exists is_gateway boolean default false;
alter table payment_methods add column if not exists is_active boolean default true;
alter table payment_methods add column if not exists sort_order int default 0;
create unique index if not exists ux_payment_methods_code on payment_methods(code);
insert into payment_methods (code, display_name_ar, is_gateway, sort_order) values
  ('vodafone','فودافون كاش',false,1),
  ('international_manual','تحويل دولي يدوي',false,2)
on conflict (code) do nothing;

-- ------------------------------------------------------------
-- محاولات الدفع الفعلية — كل محاولة (سواء يدوية أو عبر بوابة
-- مستقبلاً) صف جديد، فإعادة المحاولة بعد الفشل تتم تلقائياً بدون
-- أي تعديل. عمود idempotency_key يحمي من معالجة نفس عملية الدفع
-- مرتين لو بوابة دفع مستقبلية أرسلت نفس الإشعار أكتر من مرة.
-- ------------------------------------------------------------
create table if not exists payment_transactions(
  id bigint generated always as identity primary key,
  order_id bigint not null references orders(id) on delete cascade,
  payment_method_id bigint not null references payment_methods(id),
  provider text not null default 'manual',
  provider_reference text,
  idempotency_key text unique,
  amount numeric(10,2) not null,
  currency_code text not null references currencies(code),
  status text not null default 'pending'
    check (status in ('pending','processing','succeeded','failed','refunded','cancelled')),
  receipt_url text,
  reference_number text,
  gateway_raw_response jsonb,
  failure_reason text,
  reviewed_by uuid references profiles(id),
  reviewed_at timestamptz,
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table payment_transactions add column if not exists order_id bigint references orders(id) on delete cascade;
alter table payment_transactions add column if not exists payment_method_id bigint references payment_methods(id);
alter table payment_transactions add column if not exists provider text default 'manual';
alter table payment_transactions add column if not exists provider_reference text;
alter table payment_transactions add column if not exists idempotency_key text;
alter table payment_transactions add column if not exists amount numeric(10,2);
alter table payment_transactions add column if not exists currency_code text references currencies(code);
alter table payment_transactions add column if not exists status text default 'pending';
alter table payment_transactions add column if not exists receipt_url text;
alter table payment_transactions add column if not exists reference_number text;
alter table payment_transactions add column if not exists gateway_raw_response jsonb;
alter table payment_transactions add column if not exists failure_reason text;
alter table payment_transactions add column if not exists reviewed_by uuid references profiles(id);
alter table payment_transactions add column if not exists reviewed_at timestamptz;
alter table payment_transactions add column if not exists created_at timestamptz default now();
create index if not exists idx_paytx_order on payment_transactions(order_id);
create index if not exists idx_paytx_status on payment_transactions(status);

-- ------------------------------------------------------------
-- سجل تدقيق كامل لكل تغيّر حالة دفع — صفوف تُضاف فقط ولا تُعدَّل
-- أبداً، عشان يفضل فيه تاريخ حقيقي حتى لو حد غيّر الحالة بالغلط.
-- ------------------------------------------------------------
create table if not exists payment_status_history(
  id bigint generated always as identity primary key,
  payment_transaction_id bigint not null references payment_transactions(id) on delete cascade,
  from_status text,
  to_status text not null,
  changed_by uuid references profiles(id),
  note text,
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table payment_status_history add column if not exists payment_transaction_id bigint references payment_transactions(id) on delete cascade;
alter table payment_status_history add column if not exists from_status text;
alter table payment_status_history add column if not exists to_status text;
alter table payment_status_history add column if not exists changed_by uuid references profiles(id);
alter table payment_status_history add column if not exists note text;
alter table payment_status_history add column if not exists created_at timestamptz default now();
create index if not exists idx_paytx_history_tx on payment_status_history(payment_transaction_id);

-- ------------------------------------------------------------
-- الاستردادات — مرتبطة بمحاولة الدفع الناجحة تحديداً، مش بالطلب
-- كله (لأن الطلب ممكن يحتوي محاولة فاشلة وواحدة ناجحة).
-- ------------------------------------------------------------
create table if not exists refunds(
  id bigint generated always as identity primary key,
  payment_transaction_id bigint not null references payment_transactions(id),
  amount numeric(10,2) not null,
  reason text,
  status text not null default 'requested'
    check (status in ('requested','approved','processed','rejected')),
  provider_refund_id text,
  requested_by uuid references profiles(id),
  processed_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table refunds add column if not exists payment_transaction_id bigint references payment_transactions(id);
alter table refunds add column if not exists amount numeric(10,2);
alter table refunds add column if not exists reason text;
alter table refunds add column if not exists status text default 'requested';
alter table refunds add column if not exists provider_refund_id text;
alter table refunds add column if not exists requested_by uuid references profiles(id);
alter table refunds add column if not exists processed_by uuid references profiles(id);
alter table refunds add column if not exists created_at timestamptz default now();
create index if not exists idx_refunds_tx on refunds(payment_transaction_id);

-- ------------------------------------------------------------
-- الفواتير الرسمية القابلة للطباعة/التصدير مستقبلاً
-- ------------------------------------------------------------
create table if not exists invoices(
  id bigint generated always as identity primary key,
  order_id bigint not null references orders(id) on delete cascade,
  invoice_number text unique not null,
  billing_name text,
  billing_email text,
  billing_country text,
  pdf_url text,
  issued_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table invoices add column if not exists order_id bigint references orders(id) on delete cascade;
alter table invoices add column if not exists invoice_number text;
alter table invoices add column if not exists billing_name text;
alter table invoices add column if not exists billing_email text;
alter table invoices add column if not exists billing_country text;
alter table invoices add column if not exists pdf_url text;
alter table invoices add column if not exists issued_at timestamptz default now();
create index if not exists idx_invoices_order on invoices(order_id);

-- ------------------------------------------------------------
-- استخدام فعلي لكوبون — جدول منفصل بدل عدّاد بسيط على الكوبون،
-- عشان يمنع تكرار العدّ لو حصل تزامن، ويسجّل مين استخدم إيه بالظبط.
-- ------------------------------------------------------------
create table if not exists coupon_redemptions(
  id bigint generated always as identity primary key,
  coupon_id bigint not null references coupons(id) on delete cascade,
  order_id bigint not null references orders(id) on delete cascade,
  student_id bigint not null references students(id),
  discount_applied numeric(10,2) not null,
  redeemed_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table coupon_redemptions add column if not exists coupon_id bigint references coupons(id) on delete cascade;
alter table coupon_redemptions add column if not exists order_id bigint references orders(id) on delete cascade;
alter table coupon_redemptions add column if not exists student_id bigint references students(id);
alter table coupon_redemptions add column if not exists discount_applied numeric(10,2);
alter table coupon_redemptions add column if not exists redeemed_at timestamptz default now();
create index if not exists idx_coupon_redemptions_coupon on coupon_redemptions(coupon_id);

-- ------------------------------------------------------------
-- الاشتراكات الدورية — غير مستخدمة الآن (التجديد حالياً يدوي)،
-- جاهزة فقط ليوم ما بوابة دفع تدعم التحصيل التلقائي الحقيقي.
-- ------------------------------------------------------------
create table if not exists subscriptions(
  id bigint generated always as identity primary key,
  enrollment_id bigint not null references enrollments(id) on delete cascade,
  payment_method_id bigint references payment_methods(id),
  provider_subscription_id text,
  billing_cycle text not null default 'monthly' check (billing_cycle in ('monthly','quarterly','yearly')),
  amount numeric(10,2) not null,
  currency_code text not null references currencies(code),
  next_billing_at timestamptz,
  status text not null default 'active' check (status in ('active','paused','cancelled')),
  created_at timestamptz not null default now()
);
-- تحصين إضافي: لو الجدول كان موجود بالفعل بشكل جزئي من قبل، الأسطر دي
-- بتضمن وجود كل الأعمدة المطلوبة بدون ما تأثّر على أي بيانات موجودة.
alter table subscriptions add column if not exists enrollment_id bigint references enrollments(id) on delete cascade;
alter table subscriptions add column if not exists payment_method_id bigint references payment_methods(id);
alter table subscriptions add column if not exists provider_subscription_id text;
alter table subscriptions add column if not exists billing_cycle text default 'monthly';
alter table subscriptions add column if not exists amount numeric(10,2);
alter table subscriptions add column if not exists currency_code text references currencies(code);
alter table subscriptions add column if not exists next_billing_at timestamptz;
alter table subscriptions add column if not exists status text default 'active';
alter table subscriptions add column if not exists created_at timestamptz default now();
create index if not exists idx_subscriptions_enrollment on subscriptions(enrollment_id);

-- ------------------------------------------------------------
-- تفعيل الحماية (RLS) على كل الجداول الجديدة — حتى وهي غير
-- مستخدمة الآن، لازم تكون محمية من أول لحظة بدل ما نفتكر لاحقاً.
-- الكتالوج (عملات/مسارات/أنظمة/أسعار/وسائل دفع) قراءة عامة للمسجّلين
-- دخول، والتعديل للإدارة فقط. البيانات المالية (طلبات/دفعات/فواتير)
-- كل مستخدم يشوف بياناته الشخصية بس، والإدارة تشوف كل حاجة.
-- ------------------------------------------------------------
alter table currencies enable row level security;
alter table courses enable row level security;
alter table learning_systems enable row level security;
alter table pricing_plans enable row level security;
alter table payment_methods enable row level security;
alter table coupons enable row level security;
alter table enrollments enable row level security;
alter table orders enable row level security;
alter table payment_transactions enable row level security;
alter table payment_status_history enable row level security;
alter table refunds enable row level security;
alter table invoices enable row level security;
alter table coupon_redemptions enable row level security;
alter table subscriptions enable row level security;

drop policy if exists "catalog read authenticated" on currencies;
create policy "catalog read authenticated" on currencies for select to authenticated using (true);
drop policy if exists "catalog read authenticated" on courses;
create policy "catalog read authenticated" on courses for select to authenticated using (true);
drop policy if exists "catalog read authenticated" on learning_systems;
create policy "catalog read authenticated" on learning_systems for select to authenticated using (true);
drop policy if exists "catalog read authenticated" on pricing_plans;
create policy "catalog read authenticated" on pricing_plans for select to authenticated using (true);
drop policy if exists "catalog read authenticated" on payment_methods;
create policy "catalog read authenticated" on payment_methods for select to authenticated using (true);

drop policy if exists "staff manage catalog" on currencies;
create policy "staff manage catalog" on currencies for all to authenticated
  using (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')))
  with check (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')));
drop policy if exists "staff manage catalog" on courses;
create policy "staff manage catalog" on courses for all to authenticated
  using (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')))
  with check (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')));
drop policy if exists "staff manage catalog" on learning_systems;
create policy "staff manage catalog" on learning_systems for all to authenticated
  using (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')))
  with check (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')));
drop policy if exists "staff manage catalog" on pricing_plans;
create policy "staff manage catalog" on pricing_plans for all to authenticated
  using (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')))
  with check (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')));
drop policy if exists "staff manage catalog" on payment_methods;
create policy "staff manage catalog" on payment_methods for all to authenticated
  using (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')))
  with check (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive')));

drop policy if exists "staff manage coupons" on coupons;
create policy "staff manage coupons" on coupons for all to authenticated
  using (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor')))
  with check (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor')));

drop policy if exists "owner or staff read enrollments" on enrollments;
create policy "owner or staff read enrollments" on enrollments for select to authenticated using (
  exists(select 1 from students s where s.id=enrollments.student_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or teacher_id=auth.uid()
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "staff manage enrollments" on enrollments;
create policy "staff manage enrollments" on enrollments for insert to authenticated with check (
  exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "staff update enrollments" on enrollments;
create policy "staff update enrollments" on enrollments for update to authenticated using (
  exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);

drop policy if exists "owner or staff read orders" on orders;
create policy "owner or staff read orders" on orders for select to authenticated using (
  exists(select 1 from students s where s.id=orders.student_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "owner or staff write orders" on orders;
create policy "owner or staff write orders" on orders for insert to authenticated with check (
  exists(select 1 from students s where s.id=orders.student_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "staff update orders" on orders;
create policy "staff update orders" on orders for update to authenticated using (
  exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);

drop policy if exists "owner or staff read paytx" on payment_transactions;
create policy "owner or staff read paytx" on payment_transactions for select to authenticated using (
  exists(select 1 from orders o join students s on s.id=o.student_id where o.id=payment_transactions.order_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "owner or staff write paytx" on payment_transactions;
create policy "owner or staff write paytx" on payment_transactions for insert to authenticated with check (
  exists(select 1 from orders o join students s on s.id=o.student_id where o.id=payment_transactions.order_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "staff update paytx" on payment_transactions;
create policy "staff update paytx" on payment_transactions for update to authenticated using (
  exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);

drop policy if exists "staff manage paytx history" on payment_status_history;
create policy "staff manage paytx history" on payment_status_history for all to authenticated
  using (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor')))
  with check (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor')));

drop policy if exists "owner or staff read refunds" on refunds;
create policy "owner or staff read refunds" on refunds for select to authenticated using (
  exists(select 1 from payment_transactions t join orders o on o.id=t.order_id join students s on s.id=o.student_id
         where t.id=refunds.payment_transaction_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "staff manage refunds" on refunds;
create policy "staff manage refunds" on refunds for insert to authenticated with check (
  exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "staff update refunds" on refunds;
create policy "staff update refunds" on refunds for update to authenticated using (
  exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);

drop policy if exists "owner or staff read invoices" on invoices;
create policy "owner or staff read invoices" on invoices for select to authenticated using (
  exists(select 1 from orders o join students s on s.id=o.student_id where o.id=invoices.order_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "staff manage invoices" on invoices;
create policy "staff manage invoices" on invoices for insert to authenticated with check (
  exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);

drop policy if exists "owner or staff read coupon redemptions" on coupon_redemptions;
create policy "owner or staff read coupon redemptions" on coupon_redemptions for select to authenticated using (
  exists(select 1 from students s where s.id=coupon_redemptions.student_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "staff manage coupon redemptions" on coupon_redemptions;
create policy "staff manage coupon redemptions" on coupon_redemptions for insert to authenticated with check (
  exists(select 1 from students s where s.id=coupon_redemptions.student_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);

drop policy if exists "owner or staff read subscriptions" on subscriptions;
create policy "owner or staff read subscriptions" on subscriptions for select to authenticated using (
  exists(select 1 from enrollments e join students s on s.id=e.student_id where e.id=subscriptions.enrollment_id and (s.login_id=auth.uid() or s.parent_id=auth.uid()))
  or exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor'))
);
drop policy if exists "staff manage subscriptions" on subscriptions;
create policy "staff manage subscriptions" on subscriptions for all to authenticated
  using (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor')))
  with check (exists(select 1 from profiles p where p.id=auth.uid() and p.role in ('admin','executive','supervisor')));

-- ------------------------------------------------------------
-- توسيع جدول الإشعارات العام (الموجود بالفعل) ليقدر يشير لأي حدث
-- دفع مستقبلاً، بدل إنشاء جدول إشعارات جديد مخصّص للدفع فقط
-- (تجنّباً لتكرار نفس البنية في جدولين).
-- ------------------------------------------------------------
alter table notifications add column if not exists related_type text;
alter table notifications add column if not exists related_id bigint;

-- ============================================================
-- موعد الحلقة كبيانات منظّمة بدل النص الحر (meet_time)
-- ------------------------------------------------------------
-- meet_time كان نص حر ("السبت والثلاثاء ٥م")، فمفيش طريقة نولّد بيها
-- حصص الأسبوع تلقائياً أو نبني جدول حصص حقيقي للمعلم. الأعمدة الجديدة
-- دي بتحفظ نفس المعنى بشكل منظّم، وبنفضل نملأ meet_time كنص عرض
-- تلقائي من نفس البيانات عشان أي مكان قديم بيعرض meet_time يفضل شغّال
-- من غير أي تعديل إضافي.
-- ------------------------------------------------------------
alter table groups add column if not exists schedule_days int[];
alter table groups add column if not exists schedule_time text;
alter table groups add column if not exists schedule_duration_min int default 30;
-- وقت مستقل لكل يوم من أيام الحلقة (مرونة كاملة بدل موعد واحد موحّد لكل الأيام)
-- شكل البيانات: {"1":"16:00","3":"18:30"} — المفتاح رقم اليوم (١=الأحد..٧=السبت)
alter table groups add column if not exists schedule_times jsonb default '{}'::jsonb;

-- ============================================================
-- إلغاء "الاختبار الإلزامي" من محطات أنظمة القرآن — القرار انتقال
-- الطالب للمحطة التالية بقى معتمداً على نسبة الإنجاز/الإتقان فقط
-- ------------------------------------------------------------
alter table quran_stations alter column requires_exam set default false;
update quran_stations set requires_exam = false;

-- ============================================================
-- تعبئة المحطات الحقيقية للمسارات الستة (نفس المحتوى في نظامي رسوخ
-- والمرن، لأن المحطات تصف تقدّم المحتوى نفسه بغضّ النظر عن عدد الحصون).
-- مدة كل محطة موزّعة من إجمالي مدة المسار المُراجَعة سابقاً بدقة (بند
-- مراجعة المدد الفعلية)، بالنسبة لحجم محتوى كل محطة (الحفظ الجديد أبطأ
-- من المراجعة). الأرقام قابلة للتعديل لاحقاً من واجهة إدارة المحطات
-- مباشرة — النقل هنا فقط لتوفير بيانات واقعية بدل محطات فارغة.
-- كل إدراج مشروط بعدم وجود محطات للنظام أصلاً، فتشغيل الملف أكتر من
-- مرة لن يكرّر المحطات.
-- ------------------------------------------------------------

-- ١) جزء عمّ وتبارك — إجمالي ~٩ أسابيع
insert into quran_stations (system_id, order_index, name, description, expected_duration_days, min_completion_pct, min_mastery_pct)
select qs.id, v.order_index, v.name, v.description, v.duration_days, 80, 70
from quran_systems qs, (values
  (1,'جزء عمّ','حفظ جزء عمّ كاملاً',26),
  (2,'جزء تبارك','حفظ جزء تبارك كاملاً',26),
  (3,'مراجعة جزء عمّ وتبارك كاملاً','مراجعة شاملة للجزأين معاً وضبط الحفظ',11)
) as v(order_index,name,description,duration_days)
where qs.path_key='amma' and not exists (select 1 from quran_stations x where x.system_id=qs.id);

-- ٢) المفصّل — إجمالي ~٢٠ أسبوع
insert into quran_stations (system_id, order_index, name, description, expected_duration_days, min_completion_pct, min_mastery_pct)
select qs.id, v.order_index, v.name, v.description, v.duration_days, 80, 70
from quran_systems qs, (values
  (1,'جزء عمّ وتبارك','حفظ الجزأين الأخيرين',41),
  (2,'جزء قد سمع','حفظ جزء قد سمع',41),
  (3,'الجزء السابع والعشرون (من الحديد إلى ق)','حفظ من سورة الحديد إلى سورة ق',41),
  (4,'مراجعة المفصّل كاملاً','مراجعة شاملة لكل المفصّل وضبط الحفظ',17)
) as v(order_index,name,description,duration_days)
where qs.path_key='mufassal' and not exists (select 1 from quran_stations x where x.system_id=qs.id);

-- ٣) ربع القرآن — إجمالي ~٤١ أسبوع
insert into quran_stations (system_id, order_index, name, description, expected_duration_days, min_completion_pct, min_mastery_pct)
select qs.id, v.order_index, v.name, v.description, v.duration_days, 80, 70
from quran_systems qs, (values
  (1,'جزء عمّ وتبارك','حفظ الجزأين الأخيرين',20),
  (2,'من سورة ق إلى سورة التحريم','حفظ هذا القسم',49),
  (3,'من سورة الأحقاف إلى سورة الحجرات','حفظ هذا القسم',41),
  (4,'من سورة الشورى إلى سورة الجاثية','حفظ هذا القسم',41),
  (5,'من سورة الزمر إلى سورة فصلت','حفظ هذا القسم',41),
  (6,'من سورة يس إلى سورة ص','حفظ هذا القسم',41),
  (7,'مراجعة من سورة ق إلى سورة الناس','مراجعة شاملة لهذا القسم',16),
  (8,'مراجعة من سورة يس إلى سورة الحجرات','مراجعة شاملة لهذا القسم',16),
  (9,'مراجعة ربع القرآن كاملاً','مراجعة شاملة نهائية لكل ربع القرآن',21)
) as v(order_index,name,description,duration_days)
where qs.path_key='quarter' and not exists (select 1 from quran_stations x where x.system_id=qs.id);

-- ٤) نصف القرآن — إجمالي ~٧٢ أسبوع
insert into quran_stations (system_id, order_index, name, description, expected_duration_days, min_completion_pct, min_mastery_pct)
select qs.id, v.order_index, v.name, v.description, v.duration_days, 80, 70
from quran_systems qs, (values
  (1,'المفصّل (من سورة ق إلى سورة الناس)','حفظ المفصّل كاملاً',92),
  (2,'من سورة يس إلى سورة الحجرات','حفظ هذا القسم',62),
  (3,'من سورة العنكبوت إلى سورة يس','حفظ هذا القسم',62),
  (4,'من سورة القصص إلى سورة الفرقان','حفظ هذا القسم',62),
  (5,'من سورة النور إلى سورة الأنبياء','حفظ هذا القسم',62),
  (6,'من سورة الكهف إلى سورة طه','حفظ هذا القسم',62),
  (7,'مراجعة ربع القرآن (من يس إلى الناس)','مراجعة شاملة لهذا الربع',31),
  (8,'مراجعة من سورة الكهف إلى سورة فاطر','مراجعة شاملة لهذا القسم',31),
  (9,'مراجعة نصف القرآن كاملاً','مراجعة شاملة نهائية لنصف القرآن',43)
) as v(order_index,name,description,duration_days)
where qs.path_key='half' and not exists (select 1 from quran_stations x where x.system_id=qs.id);

-- ٥) الزهراوان — إجمالي ~٤.٥ أشهر
insert into quran_stations (system_id, order_index, name, description, expected_duration_days, min_completion_pct, min_mastery_pct)
select qs.id, v.order_index, v.name, v.description, v.duration_days, 80, 70
from quran_systems qs, (values
  (1,'بداية البقرة (١–١٤١)','حفظ الجزء الأول من سورة البقرة',30),
  (2,'إتمام البقرة (١٤٢–٢٨٦)','إتمام حفظ سورة البقرة',30),
  (3,'مراجعة سورة البقرة كاملة','مراجعة شاملة لسورة البقرة',12),
  (4,'بداية آل عمران (١–٩٢)','حفظ الجزء الأول من سورة آل عمران',21),
  (5,'إتمام آل عمران (٩٣–٢٠٠)','إتمام حفظ سورة آل عمران',21),
  (6,'مراجعة سورة آل عمران كاملة','مراجعة شاملة لسورة آل عمران',9),
  (7,'مراجعة الزهراوين كاملتين','مراجعة شاملة نهائية للسورتين معاً',12)
) as v(order_index,name,description,duration_days)
where qs.path_key='zahrawan' and not exists (select 1 from quran_stations x where x.system_id=qs.id);

-- ٦) القرآن كامل (يشترط إتمام نصف القرآن على الأقل) — إجمالي ~٣٦ شهراً
insert into quran_stations (system_id, order_index, name, description, expected_duration_days, min_completion_pct, min_mastery_pct)
select qs.id, v.order_index, v.name, v.description, v.duration_days, 80, 70
from quran_systems qs, (values
  (1,'المفصّل','حفظ المفصّل كاملاً',123),
  (2,'الزهراوان','حفظ سورتي البقرة وآل عمران',164),
  (3,'من سورة يس إلى سورة الحجرات','حفظ هذا القسم',82),
  (4,'من سورة الفرقان إلى سورة فاطر','حفظ هذا القسم',82),
  (5,'من سورة الكهف إلى سورة النور','حفظ هذا القسم',82),
  (6,'من سورة يونس إلى سورة الإسراء','حفظ هذا القسم',82),
  (7,'من سورة الأنعام إلى سورة التوبة','حفظ هذا القسم',82),
  (8,'من سورة الفاتحة إلى سورة المائدة','حفظ هذا القسم',107),
  (9,'مراجعة ربع القرآن','مراجعة شاملة لربع القرآن',41),
  (10,'مراجعة من سورة فاطر إلى سورة الكهف','مراجعة شاملة لهذا القسم',41),
  (11,'مراجعة من سورة الأنفال إلى سورة الإسراء','مراجعة شاملة لهذا القسم',41),
  (12,'مراجعة من سورة البقرة إلى سورة الأنعام','مراجعة شاملة لهذا القسم',66),
  (13,'مراجعة القرآن الكريم كاملاً','مراجعة شاملة نهائية للقرآن كله',99)
) as v(order_index,name,description,duration_days)
where qs.path_key='full' and not exists (select 1 from quran_stations x where x.system_id=qs.id);

-- تفعيل تلقائي لإعدادات الحصون الافتراضية لكل محطة جديدة اتزرعت هنا،
-- بنفس منطق qSaveStation في الكود (نسخ من QURAN_DEFAULT_FORTRESSES حسب
-- حصون كل نظام الفعلية بدل قيم ثابتة، فلو النظام معطّل فيه حصن معيّن
-- (المرن) الإعداد بياخد نفس حالة التفعيل الموجودة على مستوى النظام).
insert into quran_station_fortress_config (station_id, fortress_id, daily_amount, unit, is_enabled)
select st.id, f.id,
  case f.code when 'new_hifz' then 5 when 'review_near' then 10 when 'review_far' then 10 when 'reading' then 2 when 'listening' then 2 else 5 end,
  f.default_unit, f.is_enabled
from quran_stations st
join quran_fortresses f on f.system_id = st.system_id
where not exists (select 1 from quran_station_fortress_config c where c.station_id=st.id and c.fortress_id=f.id);

-- ============================================================
-- تمديد الخطة تلقائياً عند غياب الطالب — عمود لضمان فحص الغياب مرة
-- واحدة فقط في اليوم لكل خطة (بدل ما يتزحزح نفس اليوم أكتر من مرة)
-- ------------------------------------------------------------
alter table quran_student_plans add column if not exists last_absence_check date;

-- ============================================================
-- حقول إضافية في استبيان الالتحاق: حالة الحفظ/المراجعة الحالية،
-- ومستوى التلاوة/السماع لطلاب نظام رسوخ تحديداً (لمساعدة المعلم
-- على وضع خطة مناسبة من أول يوم بدل التخمين)
-- ------------------------------------------------------------
alter table join_requests add column if not exists memorization_status text;
alter table join_requests add column if not exists review_status text;
alter table join_requests add column if not exists reading_level text;
alter table join_requests add column if not exists listening_level text;

-- ============================================================
-- صورة شخصية للمعلم — تُرفع من "إتاحتي وسيرتي" وتظهر للطلاب/أولياء
-- الأمور في صفحة اختيار المعلم بدل الأفاتار الحرفي فقط
-- ------------------------------------------------------------
alter table profiles add column if not exists avatar_url text;

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do update set public = true;

drop policy if exists "authenticated upload avatars" on storage.objects;
create policy "authenticated upload avatars" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars');

drop policy if exists "authenticated update own avatars" on storage.objects;
create policy "authenticated update own avatars" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars')
  with check (bucket_id = 'avatars');

drop policy if exists "public read avatars" on storage.objects;
create policy "public read avatars" on storage.objects
  for select to public
  using (bucket_id = 'avatars');

-- ============================================================
-- إصلاح: صفحة "أنظمة القرآن" عند المشرف كانت تظهر "لا أنظمة" رغم وجود
-- كل الأنظمة والمسارات والمحطات فعلياً عند المدير — سببه على الأغلب أن
-- سياسات RLS على جداول قسم القرآن مقصورة على المدير فقط. المشرف يحتاج
-- رؤية نفس البيانات كاملة (قراءة فقط) عشان يقدر يشرف على المعلم والطالب
-- بمعرفة تفصيلية بالأنظمة والمسارات القائمة، فنضيف سياسة قراءة عامة لكل
-- الموظفين المسجّلين (بدون التأثير على صلاحيات الكتابة/التعديل الحالية).
-- ------------------------------------------------------------
do $$
declare
  tbl text;
begin
  for tbl in select unnest(array[
    'quran_systems','quran_stations','quran_fortresses','quran_station_fortress_config',
    'quran_student_plans','quran_plan_wards','quran_ward_progress',
    'quran_student_assessment','quran_plan_fortress_rates','quran_system_audit'
  ])
  loop
    execute format('alter table %I enable row level security', tbl);
    execute format('drop policy if exists "staff read %I" on %I', tbl, tbl);
    execute format('create policy "staff read %I" on %I for select to authenticated using (true)', tbl, tbl);
  end loop;
end $$;

-- ============================================================
-- عرض دور المرسل (طالب/ولي أمر/معلم/مشرف/مدير...) بجانب اسمه في الرسائل
-- ------------------------------------------------------------
alter table messages add column if not exists sender_role text;

-- ============================================================
-- إصلاح جذري: إشعارات الرسائل (وأي إشعار عموماً) كانت بتتبعت من غير ما توصل
-- فعلياً — الرسالة نفسها كانت بتتبعت (جدول messages مسموح)، لكن إدراج صف
-- الإشعار للطرف الآخر في جدول notifications كان يفشل بصمت لأن سياسة RLS
-- (لو مفعّلة من قبل عبر لوحة Supabase) بتفترض إن المستخدم بيكتب لنفسه بس
-- (user_id = auth.uid())، بينما الإشعار أصلاً المفروض يتبعت لمستخدم *تاني*
-- (المُرسَل إليه). ده بيحصل بغض النظر عن دور المرسل أو المستقبل، فكانت
-- المشكلة عامة على كل الأدوار والصفحات مش خاصة بدور معيّن.
-- ------------------------------------------------------------
alter table notifications enable row level security;

drop policy if exists "any authenticated can insert notifications" on notifications;
create policy "any authenticated can insert notifications" on notifications
  for insert to authenticated
  with check (true);

drop policy if exists "user reads own notifications" on notifications;
create policy "user reads own notifications" on notifications
  for select to authenticated
  using (user_id = auth.uid());

drop policy if exists "user updates own notifications" on notifications;
create policy "user updates own notifications" on notifications
  for update to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- ============================================================
-- إصلاحات أمنية حرجة (من فحص شامل) — ثلاث ثغرات كانت تسمح بتصعيد
-- صلاحيات كامل والتلاعب بمبالغ الدفع من طرف العميل مباشرة.
-- ============================================================

-- ------------------------------------------------------------
-- ثغرة #1: أي مستخدم مسجّل كان يقدر يغيّر دوره الخاص لـ 'admin' مباشرة
-- من كونسول المتصفح (sb.from('profiles').update({role:'admin'})...)
-- لأن الكود الأمامي نفسه كان يعتمد على نجاح هذا الاستعلام في مسار دعوات
-- الربط (processLinkInvites). الحل: Trigger يمنع تغيير عمود role نهائياً
-- إلا في حالتين: (أ) استدعاء عبر دالة SECURITY DEFINER موثوقة تفعّل علم
-- تجاوز مؤقت لمعاملة واحدة، أو (ب) المُنفّذ نفسه له دور admin/executive
-- بالفعل (لتغيير أدوار الطاقم من لوحة الإدارة).
-- ------------------------------------------------------------
create or replace function prevent_role_self_escalation()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if NEW.role is distinct from OLD.role then
    if current_setting('app.bypass_role_guard', true) = 'true' then
      return NEW;
    end if;
    if exists (select 1 from profiles where id = auth.uid() and role in ('admin','executive')) then
      return NEW;
    end if;
    raise exception 'غير مسموح بتغيير حقل role مباشرة — استخدم الدالة المخصّصة لذلك';
  end if;
  return NEW;
end;
$$;

drop trigger if exists guard_role_change on profiles;
create trigger guard_role_change
before update on profiles
for each row execute function prevent_role_self_escalation();

-- الدالة الوحيدة المسموح لها بتغيير دور المستخدم لنفسه، ضمن مسار دعوة
-- ربط شرعية (وليّ أمر↔ابنه) بعد التحقق من ملكية البريد فعلياً
create or replace function accept_link_invite(p_invite_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  inv record;
  caller_email text;
begin
  select email into caller_email from auth.users where id = auth.uid();
  if caller_email is null then
    return jsonb_build_object('ok', false, 'error', 'لا يوجد مستخدم موثّق');
  end if;

  select * into inv from link_invites
    where id = p_invite_id and invite_email = caller_email and status = 'pending';
  if inv is null then
    return jsonb_build_object('ok', false, 'error', 'دعوة غير صالحة أو غير موجّهة لبريدك');
  end if;

  perform set_config('app.bypass_role_guard', 'true', true);

  if inv.inviter_role = 'parent' then
    update profiles set role = 'student' where id = auth.uid();
    if inv.student_id is not null then
      update students set login_id = auth.uid() where id = inv.student_id;
    end if;
  elsif inv.inviter_role = 'student' then
    update profiles set role = 'parent' where id = auth.uid();
    if inv.student_id is not null then
      update students set parent_id = auth.uid() where id = inv.student_id;
    end if;
  end if;

  perform set_config('app.bypass_role_guard', 'false', true);

  update link_invites set status = 'linked' where id = p_invite_id;

  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function accept_link_invite(bigint) to authenticated;

-- ------------------------------------------------------------
-- ثغرة #2: مبلغ الدفعة كان يُرسَل كما هو من المتصفح بدون أي تحقق خلفي —
-- أي طالب يقدر يبعت مبلغاً وهمياً (مثلاً ١ جنيه) مع أي صورة كإيصال.
-- الحل: Trigger يحسب المبلغ المتوقَّع فعلياً من سعر الباقة الموحّد لكل
-- عملة، ومن حالة التخفيض *الحقيقية* المسجّلة على الطالب (وليس القيمة
-- التي أرسلها العميل نفسه ضمن صف الدفعة)، ويرفض أي دفعة لا تطابقه.
-- ------------------------------------------------------------
create or replace function validate_payment_amount()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  full_fee numeric;
  student_subsidized boolean;
  expected numeric;
begin
  full_fee := case coalesce(NEW.currency_code, 'EGP')
    when 'SAR' then 105
    when 'USD' then 30
    else 450
  end;
  select is_subsidized into student_subsidized from students where id = NEW.student_id;
  expected := case when coalesce(student_subsidized, false) then round(full_fee / 2.0) else full_fee end;
  if NEW.amount is distinct from expected then
    raise exception 'المبلغ المُرسَل (%) لا يطابق سعر الباقة الفعلي (%) — رُفضت العملية', NEW.amount, expected;
  end if;
  return NEW;
end;
$$;

drop trigger if exists guard_payment_amount on payments;
create trigger guard_payment_amount
before insert on payments
for each row execute function validate_payment_amount();

-- ============================================================
-- ثغرة #4 (اكتُشفت من فحص سياسات RLS الفعلية على جدول students) —
-- أخطر من ثغرة مبلغ الدفع نفسها: سياسة "students write" كانت تسمح
-- لصاحب الحساب (parent_id/login_id/chosen_teacher_id/معلم الحلقة) بتعديل
-- *أي عمود* في صف الطالب بما فيها enrollment_status و is_subsidized —
-- يعني أي طالب/ولي أمر يقدر يفتح الكونسول وينفّذ:
--   sb.from('students').update({enrollment_status:'active'})...
-- ويُفعِّل اشتراكه مجاناً بالكامل، متخطياً نظام الدفع كله من الأساس —
-- حتى بدون الحاجة لاستغلال ثغرة مبلغ الدفع (#2)، لأنه ببساطة مش محتاج
-- يمرّ على جدول payments إطلاقاً. نفس الأمر لتفعيل التخفيض (is_subsidized).
-- الحل: يسمح بهذين التحوّلين (إلى 'active' أو is_subsidized=true) فقط لو
-- المُنفّذ إداري/تنفيذي/مشرف، مع ترك كل تحوّلات الحالة الأخرى (تقديم طلب
-- التحاق، رفع إيصال) شغّالة كالمعتاد لأصحاب الحساب.
-- ------------------------------------------------------------
create or replace function guard_student_enrollment_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  is_staff boolean;
begin
  is_staff := exists (
    select 1 from profiles
    where id = auth.uid() and role in ('admin','executive','supervisor')
  );
  if not is_staff then
    if NEW.enrollment_status = 'active' and OLD.enrollment_status is distinct from 'active' then
      raise exception 'تفعيل الاشتراك يتطلّب تأكيد المشرف/الإدارة، لا يمكن تفعيله ذاتياً';
    end if;
    if NEW.is_subsidized = true and coalesce(OLD.is_subsidized, false) = false then
      raise exception 'تفعيل التخفيض يتطلّب موافقة المشرف، لا يمكن تفعيله ذاتياً';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists guard_student_enrollment on students;
create trigger guard_student_enrollment
before update on students
for each row execute function guard_student_enrollment_fields();

-- ============================================================
-- ثغرة #5 (اكتُشفت من فحص RLS): تسريب بيانات كل المستخدمين والحلقات
-- لأي زائر غير مسجّل دخول عبر مفتاح anon المكشوف أصلاً في الكود الأمامي.
-- السياستان "profiles read" و"groups read" كانتا للدور public (يشمل حتى
-- من لم يسجّل دخول إطلاقاً)، فأي طرف يملك الـ anon key (وهو ظاهر بشكل
-- طبيعي في index.html، وآمن فقط بافتراض RLS سليمة) كان يقدر يستدعي
-- Supabase REST API مباشرة (بدون فتح الموقع حتى) ويسحب:
--   • profiles: كل الأسماء والبريد والهاتف والدور لكل مستخدم في المنصة
--   • groups: كل الحلقات، ربط كل حلقة بطالبها، وملاحظات المعلم الخاصة
-- الحل: تقييد القراءة على المستخدمين المسجّلين دخول فعلياً (authenticated)
-- بدل الجميع (public) — بدون أي تغيير على وظائف التطبيق الحالية، لأن كل
-- الاستعلامات الفعلية في الكود تُنفَّذ أصلاً من مستخدم مسجّل دخول.
-- ------------------------------------------------------------
drop policy if exists "profiles read" on profiles;
create policy "profiles read" on profiles for select to authenticated using (true);

drop policy if exists "groups read" on groups;
create policy "groups read" on groups for select to authenticated using (true);

-- ============================================================
-- ثغرة #6: أي مستخدم مسجّل دخول (حتى طالب أو وليّ أمر) كان يقدر يتلاعب
-- بجدول طلبات نقل الطلاب بالكامل — يزوّر طلب نقل، يقبل/يرفض طلبات مش
-- بتاعته، أو يمسح السجل. السياسة القديمة "allow all to authenticated"
-- كانت USING(true)/WITH CHECK(true) بلا أي قيد، كحل سريع مؤقت لم يُضبَط.
-- الحل: تقييد كل عملية حسب علاقة المستخدم الفعلية بطلب النقل.
-- ------------------------------------------------------------
drop policy if exists "allow all to authenticated" on student_transfers;
drop policy if exists "transfers see" on student_transfers;
drop policy if exists "transfers insert" on student_transfers;
drop policy if exists "transfers update" on student_transfers;
drop policy if exists "transfers delete" on student_transfers;

create policy "transfers see" on student_transfers for select to authenticated using (
  exists (select 1 from profiles where id = auth.uid() and role in ('admin','executive','supervisor'))
  or from_teacher_id = auth.uid()
  or to_teacher_id = auth.uid()
  or requested_by = auth.uid()
);

create policy "transfers insert" on student_transfers for insert to authenticated with check (
  exists (select 1 from profiles where id = auth.uid() and role in ('admin','executive','supervisor','teacher'))
);

create policy "transfers update" on student_transfers for update to authenticated using (
  exists (select 1 from profiles where id = auth.uid() and role in ('admin','executive','supervisor'))
  or to_teacher_id = auth.uid()
) with check (
  exists (select 1 from profiles where id = auth.uid() and role in ('admin','executive','supervisor'))
  or to_teacher_id = auth.uid()
);

create policy "transfers delete" on student_transfers for delete to authenticated using (
  exists (select 1 from profiles where id = auth.uid() and role in ('admin','executive','supervisor'))
);

-- ============================================================
-- تشديد إضافي: أي معلم كان يقدر يعدّل خطة أو تقدّم أي طالب "تاني" (مش
-- طالبه) عبر استدعاء مباشر لقاعدة البيانات من الكونسول، حتى لو الطالب ده
-- مش ظاهر له في الواجهة أصلاً — لأن السياستين القديمتين كانتا تسمحان لأي
-- مستخدم دوره 'teacher' بشكل عام، بدل ربط الصلاحية بملكية الخطة الفعلية
-- (teacher_id = auth.uid()). المشرف (supervisor) يحتفظ بصلاحية الاطّلاع/
-- التعديل الإشرافي الكاملة كما كانت، لأن هذا دوره الطبيعي.
-- ------------------------------------------------------------
drop policy if exists "qplans_teacher" on quran_student_plans;
create policy "qplans_teacher" on quran_student_plans for all to public
using (
  teacher_id = auth.uid()
  or exists (select 1 from profiles where id = auth.uid() and role = 'supervisor')
)
with check (
  teacher_id = auth.uid()
  or exists (select 1 from profiles where id = auth.uid() and role in ('supervisor','admin','executive'))
);

drop policy if exists "qprog_teacher" on quran_ward_progress;
create policy "qprog_teacher" on quran_ward_progress for all to public
using (
  exists (
    select 1 from quran_plan_wards w
    join quran_student_plans p on p.id = w.plan_id
    where w.id = quran_ward_progress.ward_id
    and (p.teacher_id = auth.uid() or exists (select 1 from profiles where id = auth.uid() and role = 'supervisor'))
  )
)
with check (
  exists (
    select 1 from quran_plan_wards w
    join quran_student_plans p on p.id = w.plan_id
    where w.id = quran_ward_progress.ward_id
    and (p.teacher_id = auth.uid() or exists (select 1 from profiles where id = auth.uid() and role = 'supervisor'))
  )
);

-- ------------------------------------------------------------
-- ثغرة/فجوة مكتشفة: quran_plan_wards معاها سياسة قراءة بس (wards scoped
-- read)، ومفيش أي سياسة insert/update/delete خالص — عكس الجدولين الشقيقين
-- quran_student_plans وquran_ward_progress اللي كل واحد فيهم عنده سياسة
-- "for all". فكل تعديل مباشر على الورد نفسه (تعديل ورد يوم واحد، توليد
-- الخطة الأولي، الترحيل بسبب غياب، إعادة الجدولة، الاستدراك، الانتقال
-- لمحطة تالية) كان بيفشل بصمت (Supabase بترجع نجاح بدون خطأ وبدون أي صف
-- متأثر لو الـ RLS رفضت الشرط) — وهو بالظبط سبب "تعديل ورد اليوم عند
-- المعلم مبيعملش حاجة".
-- ------------------------------------------------------------
drop policy if exists "qwards_teacher" on quran_plan_wards;
create policy "qwards_teacher" on quran_plan_wards for all to public
using (
  exists (
    select 1 from quran_student_plans p
    where p.id = quran_plan_wards.plan_id
    and (p.teacher_id = auth.uid() or exists (select 1 from profiles where id = auth.uid() and role = 'supervisor'))
  )
)
with check (
  exists (
    select 1 from quran_student_plans p
    where p.id = quran_plan_wards.plan_id
    and (p.teacher_id = auth.uid() or exists (select 1 from profiles where id = auth.uid() and role in ('supervisor','admin','executive')))
  )
);

-- ============================================================
-- مراجعة RLS شاملة على كل الجداول (٥٤ جدولاً) — اكتُشفت ٣ ثغرات حقيقية،
-- كلها ناتجة من سياسات "قراءة مفتوحة" (authenticated, using(true)) أُضيفت
-- في جولات سابقة لحل مشاكل عرض بيانات (مثل "لا أنظمة" عند المشرف)، وكانت
-- بتلغي فعلياً منطق التقييد الدقيق الموجود في سياسات أخرى على نفس الجدول،
-- لأن السياسات الـPERMISSIVE في Postgres تُجمع بـOR: تكفي واحدة "true"
-- عشان تفتح الجدول بالكامل بغض النظر عن باقي السياسات الدقيقة.
-- ------------------------------------------------------------

-- ---------- ١) profiles: كانت "true" للجميع — تكشف تليفون/إيميل/دولة كل
-- مستخدم (بما فيهم بيانات القُصّر) لأي حساب مسجّل دخول ----------
drop policy if exists "profiles read" on profiles;
create policy "profiles read" on profiles for select to authenticated using (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or role = 'teacher'  -- دليل المعلمين يبقى مرئياً للجميع: مطلوب لصفحة اختيار المعلم وكروت الحلقات
  or id = auth.uid()
  or exists (
    -- المعلم يشوف بروفايل ولي أمر/حساب طلابه هو فقط (مش أي طالب في المنصة)
    -- وكذلك ولي الأمر/الطالب يشوفوا بروفايل بعض (الحساب المرتبط بيهم)
    select 1 from students s
    where (s.parent_id = profiles.id or s.login_id = profiles.id)
      and (
        s.parent_id = auth.uid() or s.login_id = auth.uid()
        or s.chosen_teacher_id = auth.uid()
        or exists (select 1 from groups g where g.id = s.group_id and g.teacher_id = auth.uid())
      )
  )
);

-- ---------- ٢) groups: كانت "true" للجميع — تكشف كل الحلقات الخاصة وربط
-- معلم-طالب. السياسة "groups see" الموجودة أصلاً كافية ودقيقة، فمجرد حذف
-- السياسة المفتوحة كفيل بإغلاق الثغرة بلا أي فقد وظيفي ----------
drop policy if exists "groups read" on groups;

-- ---------- ٣) خطط القرآن الشخصية لكل طالب: أربع سياسات "staff read true"
-- كانت بتلغي التقييد الدقيق (qplans_teacher/qprog_teacher/قراءة الطالب
-- والولي) — أي حساب مسجّل كان يقدر يشوف خطة/تقدّم/تقييم أي طالب في
-- المنصة. السياسات الدقيقة الموجودة أصلاً (قبل هذا التعديل) تغطي كل
-- الاستخدامات الشرعية (معلم/مشرف/إدارة/الطالب نفسه/وليّ أمره)، فحذف
-- السياسات المفتوحة الأربعة هو الإصلاح الكامل والكافي ----------
drop policy if exists "staff read quran_student_plans" on quran_student_plans;
drop policy if exists "staff read quran_plan_wards" on quran_plan_wards;
drop policy if exists "staff read quran_ward_progress" on quran_ward_progress;
drop policy if exists "staff read quran_student_assessment" on quran_student_assessment;

-- ---------- ٤) سجل تدقيق النظام: سجل تعديلات إدارية، الأصح يقتصر على
-- admin/executive (متاح أصلاً عبر qaud_admin_all) بدل الجميع ----------
drop policy if exists "staff read quran_system_audit" on quran_system_audit;

-- ملاحظة: الجداول التالية أُبقيت على سياسة "true" الواسعة عمداً لأنها بيانات
-- مناهج/كتالوج عامة غير شخصية (مثل كتالوج كورسات)، مش بيانات طالب فردية:
-- quran_systems, quran_stations, quran_fortresses, quran_station_fortress_config,
-- quran_plan_fortress_rates, programs, app_settings, content, teacher_slots.

-- ---------- ٥) notifications: كان أي مستخدم مسجّل يقدر يُدرج إشعاراً
-- لأي user_id بأي محتوى — باب انتحال شخصية/تصيّد داخل المنصة. نربط
-- الإذن بوجود علاقة فعلية بين المُرسِل والمُستقبِل (نفس المحادثة، أو
-- معلم↔طالبه/وليّ أمره) بدل فتحه بلا أي قيد ----------
drop policy if exists "any authenticated can insert notifications" on notifications;
drop policy if exists "notif insert scoped" on notifications;
create policy "notif insert scoped" on notifications for insert to authenticated with check (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or user_id = auth.uid()
  or exists (
    select 1 from chats c where auth.uid() = any(c.party_ids) and notifications.user_id = any(c.party_ids)
  )
  or exists (
    select 1 from students s
    where (s.login_id = notifications.user_id or s.parent_id = notifications.user_id)
      and (
        s.chosen_teacher_id = auth.uid()
        or exists (select 1 from groups g where g.id = s.group_id and g.teacher_id = auth.uid())
      )
  )
  or exists (
    select 1 from students s
    where (s.login_id = auth.uid() or s.parent_id = auth.uid())
      and (
        s.chosen_teacher_id = notifications.user_id
        or exists (select 1 from groups g where g.id = s.group_id and g.teacher_id = notifications.user_id)
      )
  )
);

-- ---------- ٦) placement_tests: سياسة الإدراج كان فيها مخرج "auth.uid()
-- IS NOT NULL" يسمح لأي مستخدم مسجّل بإضافة نتيجة اختبار تصنيف منسوبة
-- لأي وليّ أمر — تكامل بيانات ضعيف. نربطها بنفس شرط "place see" ----------
drop policy if exists "place new" on placement_tests;
create policy "place new" on placement_tests for insert to public with check (
  is_admin() or my_role() = any(array['supervisor','executive','teacher']::user_role[])
  or parent_id = auth.uid()
);

-- ============================================================
-- تحقق حجم/نوع الملف على مستوى الـStorage نفسه (دفاع حقيقي) — التحقق في
-- الواجهة (accept="image/*"، فحص f.size في JS) اقتراح للمتصفح بس وقابل
-- للتخطي بسهولة عبر استدعاء مباشر لـ storage API؛ تحديد الحد هنا على
-- مستوى الـbucket هو التطبيق الفعلي غير القابل للتحايل ----------
update storage.buckets set file_size_limit = 8388608, allowed_mime_types = array['image/jpeg','image/png','image/webp','image/heic','image/heif']
where id in ('receipts','avatars');

-- ============================================================
-- فهارس على الأعمدة الساخنة (Foreign Keys اللي بتتفلتر عليها كل الصفحات
-- تقريباً عبر .eq()/.in()) — الفهارس الـ12 الموجودة سابقاً كلها على جداول
-- تجارية غير مستخدَمة (orders/enrollments/...)، بينما الجداول الحقيقية
-- (students/groups/payments/messages/sessions/quran_*) بلا أي فهرس غير
-- المفتاح الأساسي. مع نمو البيانات هذه أول نقطة بطء حقيقية في الاستعلامات.
-- ------------------------------------------------------------
create index if not exists idx_students_group_id on students(group_id);
create index if not exists idx_students_parent_id on students(parent_id);
create index if not exists idx_students_login_id on students(login_id);
create index if not exists idx_students_chosen_teacher_id on students(chosen_teacher_id);
create index if not exists idx_students_enrollment_status on students(enrollment_status);

create index if not exists idx_groups_teacher_id on groups(teacher_id);
create index if not exists idx_groups_student_id on groups(student_id);

create index if not exists idx_payments_student_id on payments(student_id);
create index if not exists idx_payments_status on payments(status);
create index if not exists idx_payments_join_request_id on payments(join_request_id);

create index if not exists idx_messages_chat_id on messages(chat_id);
create index if not exists idx_messages_sender_id on messages(sender_id);

create index if not exists idx_sessions_teacher_id on sessions(teacher_id);
create index if not exists idx_sessions_group_id on sessions(group_id);
create index if not exists idx_sessions_student_id on sessions(student_id);
create index if not exists idx_sessions_status on sessions(status);

create index if not exists idx_session_ratings_teacher_id on session_ratings(teacher_id);
create index if not exists idx_session_ratings_student_id on session_ratings(student_id);

create index if not exists idx_join_requests_student_id on join_requests(student_id);
create index if not exists idx_join_requests_parent_id on join_requests(parent_id);
create index if not exists idx_join_requests_status on join_requests(status);

create index if not exists idx_notifications_user_id on notifications(user_id);

create index if not exists idx_student_transfers_from_teacher on student_transfers(from_teacher_id);
create index if not exists idx_student_transfers_to_teacher on student_transfers(to_teacher_id);

create index if not exists idx_qplans_teacher_id on quran_student_plans(teacher_id);
create index if not exists idx_qplans_login_id on quran_student_plans(login_id);
create index if not exists idx_qward_progress_ward_id on quran_ward_progress(ward_id);
create index if not exists idx_qplan_wards_plan_id on quran_plan_wards(plan_id);

-- ============================================================
-- تصحيح: صفحة "الطاقم والإدارة" (admin_staff) مشتركة بين admin وexecutive
-- (PAGES.executive_staff تستدعي PAGES.admin_staff نفسها في index.html)، لكن
-- سياسة "profiles admin all" كانت مقصورة على is_admin() فقط — يعني المدير
-- التنفيذي (executive) كان يفتح نفس صفحة إدارة الطاقم لكن أي محاولة تعديل/
-- حذف عضو طاقم كانت بترفضها RLS بصمت. نوسّع السياسة لتشمل executive أيضاً
-- بنفس النمط المستخدم في كل سياسات الجلسة دي.
-- ------------------------------------------------------------
drop policy if exists "profiles admin all" on profiles;
create policy "profiles admin all" on profiles for all to public
using (is_admin() or my_role() = 'executive'::user_role)
with check (is_admin() or my_role() = 'executive'::user_role);

-- ============================================================
-- نقل فصل الجنس من فلترة جافاسكريبت (filterByMyGender في الواجهة) إلى
-- قاعدة البيانات نفسها. قبل كده: أي مشرف (supervisor) كانت سياسات RLS
-- بتديه رؤية كاملة لكل الطلاب/الحلقات/المعلمين بغضّ النظر عن الجنس،
-- وسياسة "فصل الجنسين" كانت بس فلتر في الواجهة (filterByMyGender) —
-- يعني مشرف يفتح Console ويستدعي sb.from('students').select('*') مباشرة
-- كان يشوف طلاب/معلمين الجنس التاني كمان، رغم إن الواجهة بتخفيهم عنه.
-- المدير (admin) والتنفيذي (executive) يشوفوا الكل دايماً زي seesAllGenders()
-- في الواجهة؛ المشرف فقط مقيّد بجنسه.
-- ------------------------------------------------------------
-- ملاحظة: بلا "drop function if exists" هنا عمداً — بعد الإصلاح الطارئ
-- بقت سياسات كتير في آخر الملف بتعتمد على my_gender()، فحذفها هنا (حتى لو
-- مؤقتاً في نفس تشغيلة السكربت) بيفشل بخطأ "other objects depend on it".
-- create or replace كافية تماماً لتحديث تعريف الدالة بدون حذفها.
create or replace function my_gender()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select gender from profiles where id = auth.uid();
$$;
grant execute on function my_gender() to authenticated;

-- ---------- students: رؤية/تعديل المشرف مقصورة على نفس جنسه (أو مفتوح الجنس) ----------
drop policy if exists "students see" on students;
create policy "students see" on students for select to public using (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (gender is null or gender = my_gender()))
  or parent_id = auth.uid()
  or login_id = auth.uid()
  or chosen_teacher_id = auth.uid()
  or is_my_group(group_id)
);

drop policy if exists "students write" on students;
create policy "students write" on students for all to public using (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (gender is null or gender = my_gender()))
  or parent_id = auth.uid()
  or login_id = auth.uid()
  or chosen_teacher_id = auth.uid()
  or is_my_group(group_id)
) with check (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (gender is null or gender = my_gender()))
  or parent_id = auth.uid()
  or login_id = auth.uid()
  or chosen_teacher_id = auth.uid()
  or is_my_group(group_id)
);

-- ---------- groups: رؤية/تعديل المشرف مقصورة على حلقات معلمين من نفس جنسه ----------
drop policy if exists "groups see" on groups;
create policy "groups see" on groups for select to public using (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (
    teacher_id is null
    or (select gender from profiles where id = groups.teacher_id) is null
    or (select gender from profiles where id = groups.teacher_id) = my_gender()
  ))
  or teacher_id = auth.uid()
  or (is_private and owns_private_group(student_id))
  or my_student_in_group(id)
);

drop policy if exists "groups delete" on groups;
create policy "groups delete" on groups for delete to public using (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (
    teacher_id is null
    or (select gender from profiles where id = groups.teacher_id) is null
    or (select gender from profiles where id = groups.teacher_id) = my_gender()
  ))
  or teacher_id = auth.uid()
);

drop policy if exists "groups insert" on groups;
create policy "groups insert" on groups for insert to public with check (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (
    teacher_id is null
    or (select gender from profiles where id = groups.teacher_id) is null
    or (select gender from profiles where id = groups.teacher_id) = my_gender()
  ))
  or teacher_id = auth.uid()
);

drop policy if exists "groups update" on groups;
create policy "groups update" on groups for update to public using (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (
    teacher_id is null
    or (select gender from profiles where id = groups.teacher_id) is null
    or (select gender from profiles where id = groups.teacher_id) = my_gender()
  ))
  or teacher_id = auth.uid()
) with check (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (
    teacher_id is null
    or (select gender from profiles where id = groups.teacher_id) is null
    or (select gender from profiles where id = groups.teacher_id) = my_gender()
  ))
  or teacher_id = auth.uid()
);

drop policy if exists "groups teacher" on groups;
create policy "groups teacher" on groups for update to public using (
  teacher_id = auth.uid()
  or is_admin()
  or (my_role() = 'supervisor'::user_role and (
    teacher_id is null
    or (select gender from profiles where id = groups.teacher_id) is null
    or (select gender from profiles where id = groups.teacher_id) = my_gender()
  ))
);

-- ---------- profiles: دليل المعلمين يبقى مقصوراً على نفس جنس المشرف؛
-- باقي الأدوار (أهل/طلاب يختارون معلماً) يفضل مفتوحاً كما هو ----------
drop policy if exists "profiles read" on profiles;
create policy "profiles read" on profiles for select to authenticated using (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (role <> 'teacher'::user_role or gender is null or gender = my_gender()))
  or (role = 'teacher'::user_role and my_role() <> 'supervisor'::user_role)
  or id = auth.uid()
  or exists (
    select 1 from students s
    where (s.parent_id = profiles.id or s.login_id = profiles.id)
      and (
        s.parent_id = auth.uid() or s.login_id = auth.uid()
        or s.chosen_teacher_id = auth.uid()
        or exists (select 1 from groups g where g.id = s.group_id and g.teacher_id = auth.uid())
      )
  )
);

-- ---------- join_requests: طلبات مشرف مقصورة على طلاب من نفس جنسه (أو
-- طلب لسه بلا طالب مرتبط — قبل التسجيل الفعلي) ----------
drop policy if exists "jr_see" on join_requests;
create policy "jr_see" on join_requests for select to public using (
  is_admin()
  or my_role() = 'executive'::user_role
  or (my_role() = 'supervisor'::user_role and (
    student_id is null
    or exists (select 1 from students s where s.id = join_requests.student_id and (s.gender is null or s.gender = my_gender()))
  ))
  or applicant_id = auth.uid()
  or parent_id = auth.uid()
  or exists (select 1 from students s where s.id = join_requests.student_id and s.chosen_teacher_id = auth.uid())
);

drop policy if exists "jr_write" on join_requests;
create policy "jr_write" on join_requests for all to public using (
  is_admin()
  or (my_role() = 'supervisor'::user_role and (
    student_id is null
    or exists (select 1 from students s where s.id = join_requests.student_id and (s.gender is null or s.gender = my_gender()))
  ))
  or applicant_id = auth.uid()
  or parent_id = auth.uid()
) with check (
  is_admin()
  or (my_role() = 'supervisor'::user_role and (
    student_id is null
    or exists (select 1 from students s where s.id = join_requests.student_id and (s.gender is null or s.gender = my_gender()))
  ))
  or applicant_id = auth.uid()
  or parent_id = auth.uid()
);

-- ============================================================
-- 🔴 إصلاح طارئ: سياسة "profiles read" الجديدة (اللي فيها my_gender()
-- ومنطق فصل دليل المعلمين عن المشرف) سبّبت خطأ 403 يمنع **كل مستخدم من
-- قراءة بروفايله هو نفسه** عند تسجيل الدخول — يعني المنصة كانت بتفشل في
-- الدخول بالكامل لأي حساب. رجّعنا "profiles read" لآخر نسخة مؤكَّد نجاحها
-- (بدون my_gender()) فوراً لاستعادة الدخول لكل المستخدمين. فصل جنس دليل
-- المعلمين للمشرف يحتاج تشخيصاً أعمق قبل أي محاولة تانية.
-- ------------------------------------------------------------
-- تعديل: دليل المشرفين لازم يكون مرئياً لكل مستخدم مسجّل دخول (زي دليل المعلمين
-- بالظبط)، لأن الطالب/ولي الأمر محتاج يشوف اسم المشرف عشان يقدر يبدأ محادثة معه
-- من "محادثة جديدة" — بدونها كانت newChatModal بترجع "لا يوجد من يمكن مراسلته"
-- فارغة تماماً لأي طالب/ولي أمر رغم إن الكود بيحاول يضيف المشرف صراحةً.
drop policy if exists "profiles read" on profiles;
create policy "profiles read" on profiles for select to authenticated using (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or role = any(array['teacher','supervisor']::user_role[])
  or id = auth.uid()
  or exists (
    select 1 from students s
    where (s.parent_id = profiles.id or s.login_id = profiles.id)
      and (
        s.parent_id = auth.uid() or s.login_id = auth.uid()
        or s.chosen_teacher_id = auth.uid()
        or exists (select 1 from groups g where g.id = s.group_id and g.teacher_id = auth.uid())
      )
  )
);

-- نفس الإصلاح الطارئ: التراجع عن نسخ students/groups/join_requests المعتمدة
-- على my_gender() لآخر نسخة مؤكَّدة من مراجعة RLS الشاملة، لحين تشخيص
-- المشكلة الحقيقية في my_gender() بدقة قبل إعادة محاولة فصل الجنس فيهم
drop policy if exists "students see" on students;
create policy "students see" on students for select to public using (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or parent_id = auth.uid() or login_id = auth.uid() or chosen_teacher_id = auth.uid()
  or is_my_group(group_id)
);

drop policy if exists "students write" on students;
create policy "students write" on students for all to public using (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or parent_id = auth.uid() or login_id = auth.uid() or chosen_teacher_id = auth.uid()
  or is_my_group(group_id)
) with check (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or parent_id = auth.uid() or login_id = auth.uid() or chosen_teacher_id = auth.uid()
  or is_my_group(group_id)
);

drop policy if exists "groups see" on groups;
create policy "groups see" on groups for select to public using (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or teacher_id = auth.uid()
  or (is_private and owns_private_group(student_id))
  or my_student_in_group(id)
);

drop policy if exists "groups delete" on groups;
create policy "groups delete" on groups for delete to public using (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or teacher_id = auth.uid()
);

drop policy if exists "groups insert" on groups;
create policy "groups insert" on groups for insert to public with check (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or teacher_id = auth.uid()
);

drop policy if exists "groups update" on groups;
create policy "groups update" on groups for update to public using (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or teacher_id = auth.uid()
) with check (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or teacher_id = auth.uid()
);

drop policy if exists "groups teacher" on groups;
create policy "groups teacher" on groups for update to public using (
  teacher_id = auth.uid() or is_admin() or my_role() = 'supervisor'::user_role
);

drop policy if exists "jr_see" on join_requests;
create policy "jr_see" on join_requests for select to public using (
  is_admin() or my_role() = any(array['supervisor','executive']::user_role[])
  or applicant_id = auth.uid() or parent_id = auth.uid()
  or exists (select 1 from students s where s.id = join_requests.student_id and s.chosen_teacher_id = auth.uid())
);

drop policy if exists "jr_write" on join_requests;
create policy "jr_write" on join_requests for all to public using (
  is_admin() or my_role() = 'supervisor'::user_role
  or applicant_id = auth.uid() or parent_id = auth.uid()
) with check (
  is_admin() or my_role() = 'supervisor'::user_role
  or applicant_id = auth.uid() or parent_id = auth.uid()
);

-- ============================================================
-- ==========  تحصين أمني حرج — إغلاق ٣ ثغرات (يجب أن يبقى في آخر الملف)  ==========
-- هذا القسم في آخر الملف عمداً حتى تكسب سياساته على أي تعريف أقدم أعلاه.
-- ============================================================

-- ------------------------------------------------------------
-- 🔴 حرج (١): تسريب أفقي لبيانات الطلاب
-- الحلقة أعلى في الملف (staff read ... using(true)) كانت تكشف خطط وتقييمات
-- وأوراد وتقدّم كل الطلاب لأي مستخدم مسجّل (بما فيهم أي طالب أو ولي أمر آخر).
-- نعيد تحديد القراءة على الجداول المحتوية على بيانات طالب بعينه فقط، مع إبقاء
-- جداول المناهج العامة (systems/stations/fortresses/config/audit) مقروءة للجميع
-- كما هي لأنها إعدادات مشتركة لا تخص طالباً بعينه.
-- ------------------------------------------------------------

-- خطط الطلاب: صاحبها (الطالب/ولي أمره)، معلمها، والإدارة/التنفيذي/المشرف فقط
drop policy if exists "staff read quran_student_plans" on quran_student_plans;
drop policy if exists "plans scoped read" on quran_student_plans;
create policy "plans scoped read" on quran_student_plans for select to authenticated using (
  is_admin()
  or my_role() = any(array['executive','supervisor']::user_role[])
  or teacher_id = auth.uid()
  or login_id = auth.uid()
  or exists (select 1 from students s where s.id = quran_student_plans.student_id
             and (s.login_id = auth.uid() or s.parent_id = auth.uid()))
);

-- أوراد الخطة: عبر الخطة الأم
drop policy if exists "staff read quran_plan_wards" on quran_plan_wards;
drop policy if exists "wards scoped read" on quran_plan_wards;
create policy "wards scoped read" on quran_plan_wards for select to authenticated using (
  exists (select 1 from quran_student_plans qp
    where qp.id = quran_plan_wards.plan_id and (
      is_admin() or my_role() = any(array['executive','supervisor']::user_role[])
      or qp.teacher_id = auth.uid() or qp.login_id = auth.uid()
      or exists (select 1 from students s where s.id = qp.student_id
                 and (s.login_id = auth.uid() or s.parent_id = auth.uid()))
    ))
);

-- تقدّم الأوراد: صاحبها مباشرة (student_login_id) أو عبر الخطة الأم
drop policy if exists "staff read quran_ward_progress" on quran_ward_progress;
drop policy if exists "progress scoped read" on quran_ward_progress;
create policy "progress scoped read" on quran_ward_progress for select to authenticated using (
  student_login_id = auth.uid()
  or exists (select 1 from quran_plan_wards w
      join quran_student_plans qp on qp.id = w.plan_id
      where w.id = quran_ward_progress.ward_id and (
        is_admin() or my_role() = any(array['executive','supervisor']::user_role[])
        or qp.teacher_id = auth.uid() or qp.login_id = auth.uid()
        or exists (select 1 from students s where s.id = qp.student_id
                   and (s.login_id = auth.uid() or s.parent_id = auth.uid()))
      ))
);

-- تقييم الطالب: عبر الخطة الأم
drop policy if exists "staff read quran_student_assessment" on quran_student_assessment;
drop policy if exists "assessment scoped read" on quran_student_assessment;
create policy "assessment scoped read" on quran_student_assessment for select to authenticated using (
  exists (select 1 from quran_student_plans qp
    where qp.id = quran_student_assessment.plan_id and (
      is_admin() or my_role() = any(array['executive','supervisor']::user_role[])
      or qp.teacher_id = auth.uid() or qp.login_id = auth.uid()
      or exists (select 1 from students s where s.id = qp.student_id
                 and (s.login_id = auth.uid() or s.parent_id = auth.uid()))
    ))
);

-- معدلات الحصون المخصّصة للطالب: عبر الخطة الأم
drop policy if exists "staff read quran_plan_fortress_rates" on quran_plan_fortress_rates;
drop policy if exists "rates scoped read" on quran_plan_fortress_rates;
create policy "rates scoped read" on quran_plan_fortress_rates for select to authenticated using (
  exists (select 1 from quran_student_plans qp
    where qp.id = quran_plan_fortress_rates.plan_id and (
      is_admin() or my_role() = any(array['executive','supervisor']::user_role[])
      or qp.teacher_id = auth.uid() or qp.login_id = auth.uid()
      or exists (select 1 from students s where s.id = qp.student_id
                 and (s.login_id = auth.uid() or s.parent_id = auth.uid()))
    ))
);

-- ------------------------------------------------------------
-- 🔴 حرج (٢): سياسات المحادثات/الرسائل لم تكن موثّقة في هذا الملف
-- (كانت تُنشأ يدوياً في لوحة Supabase — غير قابلة للمراجعة، وقد تكون فضفاضة).
-- نمسح كل سياسة موجودة على الجدولين ديناميكياً، ثم نبني مجموعة قانونية واحدة
-- مقصورة على أطراف المحادثة فقط، فيصبح هذا الملف هو المصدر الوحيد للحقيقة.
-- ------------------------------------------------------------
alter table chats enable row level security;
alter table messages enable row level security;
do $$
declare pol record;
begin
  for pol in select policyname, tablename from pg_policies
             where schemaname='public' and tablename in ('chats','messages') loop
    execute format('drop policy if exists %I on %I', pol.policyname, pol.tablename);
  end loop;
end $$;

-- المحادثة: يقرأها/ينشئها/يعدّلها أطرافها فقط (party_ids)
create policy "chats party read" on chats for select to authenticated
  using (auth.uid() = any(party_ids));
create policy "chats party insert" on chats for insert to authenticated
  with check (auth.uid() = any(party_ids));
create policy "chats party update" on chats for update to authenticated
  using (auth.uid() = any(party_ids)) with check (auth.uid() = any(party_ids));

-- الرسائل: يقرأها أطراف المحادثة، ويرسلها المرسل نفسه داخل محادثة هو طرف فيها،
-- ويعدّل كلٌّ رسالته هو فقط
create policy "messages party read" on messages for select to authenticated using (
  sender_id = auth.uid()
  or exists (select 1 from chats c where c.id = messages.chat_id and auth.uid() = any(c.party_ids))
);
create policy "messages party insert" on messages for insert to authenticated with check (
  sender_id = auth.uid()
  and exists (select 1 from chats c where c.id = messages.chat_id and auth.uid() = any(c.party_ids))
);
create policy "messages sender update" on messages for update to authenticated
  using (sender_id = auth.uid()) with check (sender_id = auth.uid());

-- ------------------------------------------------------------
-- 🔴 حرج (٣): تصعيد صلاحيات عبر create_linked_account
-- الدالة كانت متاحة لأي authenticated بلا تحقق من دور المُستدعي ولا تقييد للدور
-- المُنشأ، فكان بإمكان أي مستخدم (حتى طالب) استدعاؤها بـ p_role='admin' وإنشاء
-- حساب مدير لنفسه. كما كان بإمكانه اختطاف طالب قائم بربط نفسه به.
-- الإصلاح: (أ) قصر الدور المُنشأ على student/parent فقط، (ب) منع الربط بخانة
-- مشغولة إلا للموظفين. (البنية الأعمق — الكتابة المباشرة في auth.users — تبقى
-- كما هي مؤقتاً؛ نقلها لـ Edge Function بمفتاح service_role خطوة منفصلة تحتاج
-- صلاحية نشر عبر Supabase CLI.)
-- ------------------------------------------------------------
create or replace function create_linked_account(
  p_email text, p_password text, p_name text, p_role text, p_student_id bigint,
  p_gender text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  new_user_id uuid;
  existing_id uuid;
  caller_role text;
  existing_link uuid;
begin
  -- (أ) قصر الدور المُنشأ: يُمنع تماماً إنشاء admin/executive/supervisor/teacher عبر هذه الدالة
  if p_role not in ('student','parent') then
    return jsonb_build_object('ok', false, 'error', 'هذه الدالة تنشئ حسابات الطلاب وأولياء الأمور فقط');
  end if;

  -- (ب) منع اختطاف طالب مرتبط بالفعل: لو الخانة المستهدفة مشغولة، فقط الموظفون يغيّرونها
  select role into caller_role from profiles where id = auth.uid();
  if p_student_id is not null then
    if p_role = 'student' then
      select login_id into existing_link from students where id = p_student_id;
    else
      select parent_id into existing_link from students where id = p_student_id;
    end if;
    if existing_link is not null
       and (caller_role is null or caller_role not in ('admin','executive','supervisor')) then
      return jsonb_build_object('ok', false, 'error', 'هذا الطالب مرتبط بحساب بالفعل');
    end if;
  end if;

  -- قفل استشاري بمفتاح البريد لمنع تنفيذ طلبين متزامنين بنفس البريد (Race Condition)
  perform pg_advisory_xact_lock(hashtext(lower(p_email)));

  select id into existing_id from auth.users where email = p_email;
  if existing_id is not null then
    return jsonb_build_object('ok', false, 'error', 'هذا البريد مستخدم بالفعل');
  end if;

  new_user_id := gen_random_uuid();

  insert into auth.users (
    id, instance_id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    raw_app_meta_data, raw_user_meta_data, is_super_admin,
    confirmation_token, recovery_token, email_change,
    email_change_token_new, email_change_token_current,
    phone_change, phone_change_token, reauthentication_token
  ) values (
    new_user_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
    p_email, crypt(p_password, gen_salt('bf')),
    now(), now(), now(),
    '{"provider":"email","providers":["email"]}', jsonb_build_object('full_name', p_name, 'role', p_role),
    false,
    '', '', '', '', '', '', '', ''
  );

  insert into auth.identities (
    id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
  ) values (
    gen_random_uuid(), new_user_id, new_user_id::text,
    jsonb_build_object('sub', new_user_id::text, 'email', p_email),
    'email', now(), now(), now()
  );

  insert into profiles (id, role, full_name, email, gender)
  values (new_user_id, p_role::user_role, p_name, p_email, p_gender)
  on conflict (id) do update set role=excluded.role, full_name=excluded.full_name, email=excluded.email, gender=coalesce(excluded.gender, profiles.gender);

  if p_role = 'student' and p_student_id is not null then
    update students set login_id = new_user_id, gender = coalesce(p_gender, gender) where id = p_student_id;
  elsif p_role = 'parent' and p_student_id is not null then
    update students set parent_id = new_user_id where id = p_student_id;
  end if;

  return jsonb_build_object('ok', true, 'user_id', new_user_id);
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'هذا البريد مستخدم بالفعل');
end;
$$;
-- الدالة تغيّر توقيعها (أُضيف p_gender)، فنُسقط أي نسخة قديمة بتوقيع ٥ معاملات
-- باقية من تشغيلات سابقة للملف قبل إضافة هذا المعامل، لمنع ازدواج الدالة
drop function if exists create_linked_account(text, text, text, text, bigint);
grant execute on function create_linked_account(text, text, text, text, bigint, text) to authenticated;

-- ------------------------------------------------------------
-- 🔴 إصلاح حرج: حسابات أُنشئت سابقاً عبر create_linked_account (قبل هذا
-- الإصلاح) بقيت بأعمدة NULL في recovery_token/email_change/... مما يُسقط
-- تسجيل الدخول بخطأ "Database error querying schema" من خادم المصادقة —
-- هذا التحديث يُصلح كل الحسابات المتأثرة الموجودة فعلاً بأثر رجعي.
-- ------------------------------------------------------------
update auth.users set
  confirmation_token = coalesce(confirmation_token, ''),
  recovery_token = coalesce(recovery_token, ''),
  email_change = coalesce(email_change, ''),
  email_change_token_new = coalesce(email_change_token_new, ''),
  email_change_token_current = coalesce(email_change_token_current, ''),
  phone_change = coalesce(phone_change, ''),
  phone_change_token = coalesce(phone_change_token, ''),
  reauthentication_token = coalesce(reauthentication_token, '')
where confirmation_token is null or recovery_token is null or email_change is null
   or email_change_token_new is null or email_change_token_current is null
   or phone_change is null or phone_change_token is null or reauthentication_token is null;
