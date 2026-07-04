# نشر إشعارات Push الحقيقية (تصل حتى لو المتصفح مقفول)

## الخطوات

1. ثبّت Supabase CLI (لو مش مثبت): `npm install -g supabase`
2. سجّل دخول: `supabase login`
3. اربط المشروع: `supabase link --project-ref <project-ref-بتاعك>` (تلاقيه في رابط لوحة Supabase)
4. حط مفاتيح VAPID كـ secrets (المفتاح الخاص بعته لك في المحادثة، متحطوش في أي ملف على الجهاز أو الكود):
   ```
   supabase secrets set VAPID_PUBLIC_KEY="BCAT8oyJMzKWSz9i9sIkM7jG9oEyP_g_vKa7sBKA0KbTZ8Qc9yoM1stncY33XIr4kl6OpkueQOrsUqyKBryKbxI"
   supabase secrets set VAPID_PRIVATE_KEY="<الصق المفتاح الخاص اللي بعته لك في الشات>"
   ```
5. انشر الدالة:
   ```
   supabase functions deploy send-push --no-verify-jwt
   ```
6. من لوحة Supabase → **Database → Webhooks** → **Create a new hook**:
   - Table: `notifications`
   - Events: `Insert`
   - Type: `Supabase Edge Functions`
   - Edge Function: `send-push`
7. شغّل `SETUP.sql` (في جذر المشروع) في **SQL Editor** لو لسّه ما شغّلتوش — فيه جدول `push_subscriptions` اللي الدالة بتقرأ منه.

## بعد كده
أي مستخدم يفتح الموقع ويوافق على إذن الإشعارات، هيتسجّل اشتراكه تلقائياً. وبمجرد ما يتحط صف جديد في `notifications` (زي تأكيد دفع، رسالة، إلخ)، الويب هوك هيشغّل الدالة، والدالة هتبعت Push حقيقي يظهر في ستارة إشعارات الهاتف حتى لو الموقع مقفول تماماً.
