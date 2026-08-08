// Supabase Edge Function: send-push
// تستقبل حدث إدراج صف جديد في جدول notifications (عبر Database Webhook)
// وتبعت Web Push حقيقي لكل اشتراكات هذا المستخدم، يوصل حتى لو المتصفح مقفول.
//
// النشر: supabase functions deploy send-push --no-verify-jwt
// وربطه: من لوحة Supabase → Database → Webhooks → أنشئ Webhook جديد
//   Table: notifications | Event: INSERT | Type: Supabase Edge Function | Function: send-push
//
// ⚠️ أمان: هذه الدالة تُنشر بـ --no-verify-jwt (بلا تحقق JWT عادي)، لأن
// Database Webhooks لا ترسل جلسة مستخدم. وهذا كان يعني أن أي شخص يعرف/يخمّن
// رابط الدالة يقدر يستدعيها مباشرة بأي user_id وعنوان/نص إشعار مفبرك — انتحال
// صفة الأكاديمية لإرسال إشعارات تصيّد. الحل: سرّ مشترك (shared secret) في
// رأس الطلب، لا يعرفه إلا Webhook الحقيقي.
//
// خطوات التفعيل (لازمة يدويًا، مرة واحدة):
//   1) supabase secrets set SEND_PUSH_WEBHOOK_SECRET=<قيمة عشوائية طويلة>
//   2) supabase functions deploy send-push --no-verify-jwt
//   3) في لوحة Supabase → Database → Webhooks → عدّل send-push webhook →
//      أضف HTTP Header: x-webhook-secret = <نفس القيمة بالضبط>

import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("SEND_PUSH_WEBHOOK_SECRET");

webpush.setVapidDetails("mailto:teachermohsenashraf@gmail.com", VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

Deno.serve(async (req) => {
  try {
    // لو السرّ مُهيَّأ (بعد تنفيذ خطوات التفعيل أعلاه)، أي طلب بلا الرأس الصحيح
    // يُرفض فورًا. لو لسه مش مُهيَّأ (قبل التفعيل اليدوي)، الدالة تعمل كالسابق
    // بلا كسر النشر الحالي — لكن هذا يبقى الوضع غير الآمن حتى تُنفَّذ الخطوات.
    if (WEBHOOK_SECRET) {
      const provided = req.headers.get("x-webhook-secret");
      if (provided !== WEBHOOK_SECRET) {
        return new Response(JSON.stringify({ ok: false, error: "unauthorized" }), { status: 401 });
      }
    }
    const payload = await req.json();
    // Database Webhook بيبعت الصف الجديد داخل payload.record
    const row = payload.record || payload;
    const userId = row.user_id;
    const title = row.title || "أكاديمية الهدى";
    const body = row.body || "";
    if (!userId) return new Response(JSON.stringify({ ok: false, error: "no user_id" }), { status: 400 });

    const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);
    const { data: subs, error } = await supabase
      .from("push_subscriptions")
      .select("*")
      .eq("user_id", userId);
    if (error) throw error;
    if (!subs || !subs.length) return new Response(JSON.stringify({ ok: true, sent: 0 }));

    const notifPayload = JSON.stringify({ title, body, url: "/index.html" });
    let sent = 0;
    for (const s of subs) {
      const subscription = { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } };
      try {
        await webpush.sendNotification(subscription, notifPayload);
        sent++;
      } catch (e) {
        // اشتراك منتهي أو باطل — نحذفه
        if (e && (e.statusCode === 404 || e.statusCode === 410)) {
          await supabase.from("push_subscriptions").delete().eq("id", s.id);
        }
      }
    }
    return new Response(JSON.stringify({ ok: true, sent }), { headers: { "Content-Type": "application/json" } });
  } catch (e) {
    return new Response(JSON.stringify({ ok: false, error: String(e) }), { status: 500 });
  }
});
