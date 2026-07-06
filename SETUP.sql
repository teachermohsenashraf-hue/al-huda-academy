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
-- ٠-ج) عمود عملة الدفعة — لتوحيد الباقة بسعر واحد يظهر بعملة كل دولة
--      (مصر جنيه، السعودية ريال، وأي دولة تانية دولار)، ولتقارير
--      التحصيل حسب الدولة في لوحة المدير/التنفيذي.
-- ------------------------------------------------------------
alter table payments add column if not exists currency_code text default 'EGP';

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
insert into storage.buckets (id, name, public)
values ('receipts', 'receipts', true)
on conflict (id) do update set public = true;

drop policy if exists "authenticated upload receipts" on storage.objects;
create policy "authenticated upload receipts" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'receipts');

drop policy if exists "authenticated update own receipts" on storage.objects;
create policy "authenticated update own receipts" on storage.objects
  for update to authenticated
  using (bucket_id = 'receipts')
  with check (bucket_id = 'receipts');

drop policy if exists "public read receipts" on storage.objects;
create policy "public read receipts" on storage.objects
  for select to public
  using (bucket_id = 'receipts');

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
  values (new_user_id, p_role, p_name, p_email)
  on conflict (id) do update set role=excluded.role, full_name=excluded.full_name, email=excluded.email;

  if p_role = 'student' and p_student_id is not null then
    update students set login_id = new_user_id where id = p_student_id;
  elsif p_role = 'parent' and p_student_id is not null then
    update students set parent_id = new_user_id where id = p_student_id;
  end if;

  return jsonb_build_object('ok', true, 'user_id', new_user_id);
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
