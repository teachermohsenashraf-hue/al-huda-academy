-- ============================================================================
-- 003_secure_send_push_trigger.sql
--
-- استكمال تأمين send-push: اكتشفنا أن هذا المشروع لا يستخدم "Database
-- Webhooks" من لوحة Supabase (Integrations → Database Webhooks كانت فارغة
-- تمامًا)، بل Trigger مخصّص موجود بالفعل (trigger_send_push على جدول
-- notifications) يستدعي net.http_post مباشرة. لذلك خطوة "أضف Header من لوحة
-- الـ Webhooks" في الشرح السابق لا تنطبق على هذا الإعداد إطلاقًا — هذا الملف
-- هو التصحيح الصحيح: يضيف نفس السرّ (المُفعَّل بالفعل كـ Edge Function secret
-- باسم SEND_PUSH_WEBHOOK_SECRET) كـ header فعلي يرسله الـ trigger نفسه، عبر
-- Supabase Vault بدل تضمينه كنص صريح داخل جسم الدالة.
--
-- آمن للتشغيل: يستبدل تعريف trigger_send_push() فقط (لا يمسّ الـ trigger
-- نفسه ولا صفوف notifications)، ويضيف صف واحد في vault.secrets.
-- ============================================================================

-- إدخال السرّ في Vault مرة واحدة فقط (لو كان موجودًا بالفعل، هذا الجزء يتخطّاه
-- بأمان بدل ما يفشل بخطأ تكرار)
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'send_push_webhook_secret') then
    perform vault.create_secret(
      'a46ef45918f51a4a3e56d4f87af596f05462d5c96b1ca88f43d39842cb9b838e',
      'send_push_webhook_secret',
      'سرّ مشترك يرسله trigger_send_push في رأس x-webhook-secret، ونفس القيمة مضبوطة كـ Edge Function secret باسم SEND_PUSH_WEBHOOK_SECRET'
    );
  end if;
end $$;

create or replace function trigger_send_push()
returns trigger
language plpgsql
security definer
as $$
declare
  v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'send_push_webhook_secret';
  perform net.http_post(
    url := 'https://yvloiecymqbhpoizfucl.supabase.co/functions/v1/send-push',
    headers := jsonb_build_object('Content-Type','application/json','x-webhook-secret', v_secret),
    body := jsonb_build_object('record', to_jsonb(NEW))
  );
  return NEW;
end;
$$;
