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
