-- ============================================================
-- ملف إعداد قاعدة البيانات — شغّله في Supabase → SQL Editor
-- (بند 2، 3، 4 اللي محتاجين خطوة يدوية برا الكود)
-- ============================================================

create extension if not exists pgcrypto;

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
set search_path = public
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
set search_path = public
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
