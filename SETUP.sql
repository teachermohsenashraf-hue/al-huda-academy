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
