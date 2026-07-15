// Supabase Edge Function: passkey
// ─────────────────────────────────────────────────────────────────────────
// خادم التحقق الرسمي من WebAuthn / Passkeys لأكاديمية الهدى.
// طبقة مستقلة تماماً فوق نظام الدخول الحالي (بريد + كلمة مرور يبقى الأساس).
// لا تُخزَّن أي بيانات بيومترية — فقط المفتاح العام ومُعرّف الاعتماد وعدّاد التوقيع.
//
// النشر (مرة واحدة، مثل send-push بالضبط):
//   supabase functions deploy passkey --no-verify-jwt
// المتغيّرات المطلوبة (SUPABASE_URL و SUPABASE_SERVICE_ROLE_KEY متوفّرة تلقائياً
// في بيئة Edge Functions؛ الباقي اضبطه عبر):
//   supabase secrets set WEBAUTHN_RP_ID=al-huda-academy.vercel.app \
//     WEBAUTHN_ORIGINS=https://al-huda-academy.vercel.app \
//     WEBAUTHN_RP_NAME="أكاديمية الهدى"
// ─────────────────────────────────────────────────────────────────────────
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  generateRegistrationOptions,
  verifyRegistrationResponse,
  generateAuthenticationOptions,
  verifyAuthenticationResponse,
} from "npm:@simplewebauthn/server@10.0.1";
import { isoBase64URL, isoUint8Array } from "npm:@simplewebauthn/server@10.0.1/helpers";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RP_ID = Deno.env.get("WEBAUTHN_RP_ID") || "al-huda-academy.vercel.app";
const RP_NAME = Deno.env.get("WEBAUTHN_RP_NAME") || "أكاديمية الهدى";
// أصول مسموح بها (الإنتاج + localhost للتطوير) — يمنع Origin مزيّف
const ORIGINS = (Deno.env.get("WEBAUTHN_ORIGINS") || `https://${RP_ID}`)
  .split(",").map((s) => s.trim()).filter(Boolean);
const ALLOWED_ORIGINS = [...ORIGINS, "http://localhost:5500", "http://localhost:3000"];
const CHALLENGE_TTL_MS = 5 * 60 * 1000; // مهلة قصيرة (٥ دقائق) لتحدّي واحد الاستخدام

const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false } });

const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "authorization, content-type, apikey, x-client-info",
  "access-control-allow-methods": "POST, OPTIONS",
  "content-type": "application/json",
};
const json = (obj: unknown, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: CORS });

// مُعرّف المستخدم الحالي من رأس Authorization (لعمليات التسجيل — المستخدم داخل بالفعل)
async function userFromAuthHeader(req: Request) {
  const auth = req.headers.get("authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
  if (!token) return null;
  const { data, error } = await admin.auth.getUser(token);
  if (error) return null;
  return data.user;
}

async function storeChallenge(userId: string | null, email: string | null, challenge: string, purpose: "register" | "authenticate") {
  await admin.from("webauthn_challenges").insert({
    user_id: userId, email, challenge, purpose,
    expires_at: new Date(Date.now() + CHALLENGE_TTL_MS).toISOString(),
  });
}
// جلب أحدث تحدٍّ صالح غير مُستهلَك، ثم استهلاكه فوراً (منع Replay)
async function consumeChallenge(match: Record<string, unknown>, purpose: string) {
  const { data } = await admin.from("webauthn_challenges").select("*")
    .match({ ...match, purpose }).is("consumed_at", null)
    .gt("expires_at", new Date().toISOString())
    .order("created_at", { ascending: false }).limit(1);
  const row = data?.[0];
  if (!row) return null;
  await admin.from("webauthn_challenges").update({ consumed_at: new Date().toISOString() }).eq("id", row.id);
  return row;
}
async function audit(userId: string | null, event: string, detail: unknown, req: Request) {
  try {
    await admin.from("auth_audit_log").insert({
      user_id: userId, event, detail,
      ip: req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() || null,
      ua: req.headers.get("user-agent") || null,
    });
  } catch { /* التدقيق لا يجب أن يُفشل العملية الأساسية */ }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  const url = new URL(req.url);
  const action = url.searchParams.get("action");
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* بعض الطلبات بلا جسم */ }

  try {
    // ═══ تسجيل Passkey جديد — الخطوة ١: توليد الخيارات (المستخدم داخل بالفعل) ═══
    if (action === "register-options") {
      const user = await userFromAuthHeader(req);
      if (!user) return json({ error: "unauthorized" }, 401);
      const { data: creds } = await admin.from("webauthn_credentials")
        .select("credential_id, transports").eq("user_id", user.id).eq("is_active", true);
      const options = await generateRegistrationOptions({
        rpName: RP_NAME, rpID: RP_ID,
        userID: isoUint8Array.fromUTF8String(user.id),
        userName: user.email || user.id,
        attestationType: "none",
        excludeCredentials: (creds || []).map((c: any) => ({
          id: c.credential_id, transports: c.transports || undefined,
        })),
        authenticatorSelection: {
          residentKey: "preferred", userVerification: "preferred",
          authenticatorAttachment: "platform", // نُفضّل مصادِق الجهاز (بصمة/وجه)
        },
      });
      await storeChallenge(user.id, user.email || null, options.challenge, "register");
      return json({ options });
    }

    // ═══ تسجيل Passkey — الخطوة ٢: التحقق وحفظ المفتاح العام فقط ═══
    if (action === "register-verify") {
      const user = await userFromAuthHeader(req);
      if (!user) return json({ error: "unauthorized" }, 401);
      const ch = await consumeChallenge({ user_id: user.id }, "register");
      if (!ch) return json({ error: "challenge_expired" }, 400);
      const verification = await verifyRegistrationResponse({
        response: body.attestation as any,
        expectedChallenge: ch.challenge,
        expectedOrigin: ALLOWED_ORIGINS,
        expectedRPID: RP_ID,
        requireUserVerification: false,
      });
      if (!verification.verified || !verification.registrationInfo) {
        await audit(user.id, "passkey_register_failed", null, req);
        return json({ error: "verification_failed" }, 400);
      }
      const cred = verification.registrationInfo.credential;
      const d = (body.device || {}) as Record<string, string>;
      await admin.from("webauthn_credentials").insert({
        user_id: user.id,
        credential_id: cred.id,
        public_key: isoBase64URL.fromBuffer(cred.publicKey),
        counter: cred.counter,
        transports: cred.transports || null,
        aaguid: verification.registrationInfo.aaguid || null,
        device_label: d.label || null, device_type: d.type || null,
        os: d.os || null, browser: d.browser || null,
        last_used_at: new Date().toISOString(),
      });
      await audit(user.id, "passkey_registered", { device: d.label || null }, req);
      return json({ ok: true });
    }

    // ═══ الدخول بالبصمة — الخطوة ١: خيارات المصادقة لبريد معيّن ═══
    if (action === "auth-options") {
      const email = String(body.email || "").trim().toLowerCase();
      if (!email) return json({ error: "email_required" }, 400);
      const { data: uid } = await admin.rpc("webauthn_user_by_email", { p_email: email });
      // لا نكشف وجود/عدم وجود الحساب: نُرجع خيارات فارغة بنفس الشكل لو لا مفاتيح
      let allow: any[] = [];
      if (uid) {
        const { data: creds } = await admin.from("webauthn_credentials")
          .select("credential_id, transports").eq("user_id", uid).eq("is_active", true);
        allow = (creds || []).map((c: any) => ({ id: c.credential_id, transports: c.transports || undefined }));
      }
      const options = await generateAuthenticationOptions({
        rpID: RP_ID, userVerification: "preferred", allowCredentials: allow,
      });
      await storeChallenge((uid as string) || null, email, options.challenge, "authenticate");
      return json({ options, hasPasskey: allow.length > 0 });
    }

    // ═══ الدخول بالبصمة — الخطوة ٢: التحقق ثم إصدار جلسة Supabase حقيقية ═══
    if (action === "auth-verify") {
      const email = String(body.email || "").trim().toLowerCase();
      const assertion = body.assertion as any;
      if (!email || !assertion) return json({ error: "bad_request" }, 400);
      const ch = await consumeChallenge({ email }, "authenticate");
      if (!ch) return json({ error: "challenge_expired" }, 400);
      const credIdB64 = assertion.id; // base64url
      const { data: rows } = await admin.from("webauthn_credentials")
        .select("*").eq("credential_id", credIdB64).eq("is_active", true).limit(1);
      const stored = rows?.[0];
      if (!stored) { await audit(null, "passkey_auth_unknown_cred", { email }, req); return json({ error: "unknown_credential" }, 400); }

      const verification = await verifyAuthenticationResponse({
        response: assertion,
        expectedChallenge: ch.challenge,
        expectedOrigin: ALLOWED_ORIGINS,
        expectedRPID: RP_ID,
        credential: {
          id: stored.credential_id,
          publicKey: isoBase64URL.toBuffer(stored.public_key),
          counter: Number(stored.counter),
          transports: stored.transports || undefined,
        },
        requireUserVerification: false,
      });
      if (!verification.verified) {
        await audit(stored.user_id, "passkey_auth_failed", null, req);
        return json({ error: "verification_failed" }, 400);
      }
      // تحديث عدّاد التوقيع (كشف الاستنساخ) + آخر استخدام
      await admin.from("webauthn_credentials").update({
        counter: verification.authenticationInfo.newCounter,
        last_used_at: new Date().toISOString(),
      }).eq("id", stored.id);

      // إصدار جلسة Supabase حقيقية بعد إثبات الملكية تشفيرياً — بلا كلمة مرور.
      // generateLink لا يُرسل أي بريد، فقط يولّد رمزاً نتحقق منه في العميل.
      const { data: link, error: linkErr } = await admin.auth.admin.generateLink({
        type: "magiclink", email,
      });
      if (linkErr || !link?.properties) {
        await audit(stored.user_id, "passkey_auth_session_failed", { msg: linkErr?.message }, req);
        return json({ error: "session_issue" }, 500);
      }
      await audit(stored.user_id, "passkey_auth_success", null, req);
      return json({
        ok: true,
        token_hash: link.properties.hashed_token,
        email_otp: link.properties.email_otp,
      });
    }

    return json({ error: "unknown_action" }, 404);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
