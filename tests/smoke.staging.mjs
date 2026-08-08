// اختبارات دخان حقيقية — تُشغَّل ضد مشروع Supabase منفصل تمامًا (staging)
// وليس ضد الإنتاج إطلاقًا. تستخدم REST API الحقيقي بنفس الطريقة اللي
// index.html بيستخدمها (sb.auth / sb.from / sb.rpc) عبر fetch مباشرة، بلا
// أي مكتبات خارجية، عشان تفحص السلوك الفعلي (RLS، RPCs، الـ triggers) لا مجرد
// افتراضات عن الكود.
//
// التشغيل: node tests/smoke.staging.mjs
//
// STAGING_URL/STAGING_ANON مشروع اختبار منفصل (nwfgsaumkubferjjsuny) —
// anon key مُصمَّم ليكون علنيًا أصلاً (نفس مبدأ المفتاح المضمَّن في index.html)،
// ولا قيمة حساسة هنا. لا صلة إطلاقًا بمشروع الإنتاج (yvloiecymqbhpoizfucl).

const BASE = 'https://nwfgsaumkubferjjsuny.supabase.co';
const ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im53ZmdzYXVta3ViZmVyampzdW55Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODIwNzQ4NDcsImV4cCI6MjA5NzY1MDg0N30.JfrOa3rSNpKPHWtj-_sGvE6QIw0gAgM9HC2A6KDwe0U';
// service_role مُستخدَم فقط هنا (سكربت اختبار مستقل ضد بيئة staging) لضمان أن
// السكربت قابل لإعادة التشغيل بلا اعتماد على "أول حساب في القاعدة" — الطريقة
// دي مش مستخدمة إطلاقًا في تطبيق الإنتاج نفسه (index.html ميعرفش بيها خالص)
const SERVICE = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im53ZmdzYXVta3ViZmVyampzdW55Iiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MjA3NDg0NywiZXhwIjoyMDk3NjUwODQ3fQ.Xhn6ScDAqrmiBAaHZgHTW0N2gPetNsRulS8huipSXM8';

let pass = 0, fail = 0;
function assert(cond, label) {
  if (cond) { pass++; console.log('  ✅', label); }
  else { fail++; console.log('  ❌', label); }
}
function suite(name) { console.log('\n' + name); }

async function authFetch(path, opts = {}, token) {
  const res = await fetch(BASE + path, {
    ...opts,
    headers: {
      'apikey': ANON,
      'Authorization': 'Bearer ' + (token || ANON),
      'Content-Type': 'application/json',
      ...(opts.headers || {}),
    },
  });
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch { json = text; }
  return { status: res.status, body: json };
}

async function signUp(email, password, meta) {
  return authFetch('/auth/v1/signup', { method: 'POST', body: JSON.stringify({ email, password, data: meta }) });
}
async function signIn(email, password) {
  return authFetch('/auth/v1/token?grant_type=password', { method: 'POST', body: JSON.stringify({ email, password }) });
}
async function rest(path, opts, token) { return authFetch('/rest/v1' + path, opts, token); }
async function rpc(name, params, token) { return authFetch('/rest/v1/rpc/' + name, { method: 'POST', body: JSON.stringify(params || {}) }, token); }

const stamp = 'smoke' + Math.floor(Math.random() * 1e9); // مُمرَّر خارجيًا وليس Date.now()/Math.random() داخل بيئة الإنتاج — هنا سكربت اختبار مستقل مسموح
const PASS = 'TestPass123!';

async function cleanupPreviousRuns() {
  // تنظيف أفضل-محاولة (best-effort) لحسابات الاختبارات السابقة (نمط البريد
  // @example.com فقط، ولا يمسّ أي حساب حقيقي) — حسابات ليها بيانات مرتبطة
  // (خطط/حلقات كمعلم) هيرفضها قيد المفتاح الأجنبي وده متوقّع وصحيح، نتجاهله
  // ونكمل؛ الهدف تقليل التراكم لا ضمان صفر بيانات
  let page = 1, deleted = 0;
  while (true) {
    const r = await authFetch(`/auth/v1/admin/users?page=${page}&per_page=200`, {}, SERVICE);
    const users = r.body?.users || [];
    if (!users.length) break;
    for (const u of users) {
      if (u.email && u.email.endsWith('@example.com')) {
        const rd = await authFetch(`/auth/v1/admin/users/${u.id}`, { method: 'DELETE' }, SERVICE);
        if (rd.status === 200) deleted++;
      }
    }
    page++;
    if (page > 20) break;
  }
  if (deleted) console.log(`🧹 تنظيف: حُذف ${deleted} حساب اختبار (بلا بيانات مرتبطة) من تشغيلات سابقة`);
}

async function main() {
  await cleanupPreviousRuns();

  // ── 1) حساب Admin ثابت دائم لهذه البيئة (بدل الاعتماد على "أول حساب في
  // القاعدة"، وهو أسلوب هش لا يصلح لإعادة التشغيل المتكرر) — أُنشئ مرة واحدة
  // مباشرة عبر SQL (نفس تقنية bypass_role_guard اللي تستخدمها accept_link_invite
  // نفسها)، ونكتفي هنا بتسجيل الدخول به ──
  suite('1) تسجيل الدخول بحساب Admin الثابت');
  const permanentAdminEmail = 'permanent.admin@smoketest.local';
  let r = await signIn(permanentAdminEmail, 'SmokeAdmin123!');
  assert(r.status === 200 && !!r.body.access_token, 'تسجيل الدخول نجح: ' + JSON.stringify(r.body).slice(0, 150));
  const adminToken = r.body.access_token;
  const adminId = r.body.user?.id;
  r = await rest(`/profiles?id=eq.${adminId}&select=role`, {}, adminToken);
  assert(r.body?.[0]?.role === 'admin', 'الحساب الثابت role=admin فعليًا: ' + JSON.stringify(r.body));

  // ── 2) محاولة تسجيل ذاتي بدور teacher بعد وجود admin — لازم يتخفّض لـ parent تلقائيًا ──
  suite('2) حارس تصعيد الصلاحيات عبر التسجيل الذاتي (admin موجود بالفعل)');
  const fakeTeacherEmail = `${stamp}.faketeacher@example.com`;
  r = await signUp(fakeTeacherEmail, PASS, { role: 'teacher', full_name: 'محاولة معلم مزيّف' });
  const fakeTeacherToken = r.body.access_token, fakeTeacherId = r.body.user?.id;
  r = await rest(`/profiles?id=eq.${fakeTeacherId}&select=role`, {}, fakeTeacherToken);
  assert(r.body?.[0]?.role === 'parent', 'التسجيل الذاتي بدور teacher تحوّل تلقائيًا لـ parent (وليس teacher): ' + JSON.stringify(r.body));

  // ── 3) الأدمن ينشئ معلماً حقيقياً عبر create_staff_account ──
  suite('3) إنشاء معلم حقيقي عبر RPC مقصورة على الأدمن');
  const teacherEmail = `${stamp}.teacher@example.com`;
  r = await rpc('create_staff_account', { p_email: teacherEmail, p_password: PASS, p_name: 'أ. معلم تجريبي', p_role: 'teacher', p_gender: 'male' }, adminToken);
  assert(r.body?.ok === true, 'create_staff_account نجحت: ' + JSON.stringify(r.body));
  const teacherId = r.body?.user_id;
  r = await rest(`/profiles?id=eq.${teacherId}&select=role,must_change_password`, {}, adminToken);
  assert(r.body?.[0]?.role === 'teacher', 'دور المعلم صحيح: ' + JSON.stringify(r.body));
  assert(r.body?.[0]?.must_change_password === true, 'must_change_password=true لحساب أُنشئ بكلمة مرور مؤقتة: ' + JSON.stringify(r.body));
  // نفس المحاولة من غير أدمن يجب أن تُرفض
  r = await rpc('create_staff_account', { p_email: `${stamp}.rogue@example.com`, p_password: PASS, p_name: 'X', p_role: 'admin' }, fakeTeacherToken);
  assert(r.body?.ok === false, 'مستخدم عادي لا يقدر ينشئ حساب admin عبر نفس RPC: ' + JSON.stringify(r.body));

  // ── 4) تسجيل طالبين حقيقيين، والتحقق من كل الحقول (اختبار إصلاح afterAuth/handle_new_user) ──
  suite('4) تسجيل طالب — تكامل كل الحقول (الاسم، الجنس، الهاتف، الدولة، الدور)');
  const stuAEmail = `${stamp}.studentA@example.com`;
  r = await signUp(stuAEmail, PASS, { role: 'student', full_name: 'طالب اختبار أ', gender: 'male', phone: '+20 100000001', country: 'مصر', governorate: 'القاهرة', chosen_track: 'quran' });
  const stuAToken = r.body.access_token, stuALoginId = r.body.user?.id;
  r = await rest(`/profiles?id=eq.${stuALoginId}&select=*`, {}, stuAToken);
  const profA = r.body?.[0] || {};
  assert(profA.role === 'student', 'دور الطالب أ صحيح: ' + profA.role);
  assert(profA.full_name === 'طالب اختبار أ', 'الاسم الكامل محفوظ صح: ' + profA.full_name);
  assert(profA.gender === 'male', 'الجنس محفوظ صح: ' + profA.gender);
  assert(profA.phone === '+20 100000001', 'الهاتف محفوظ صح: ' + profA.phone);
  assert(profA.country === 'مصر', 'الدولة محفوظة صح: ' + profA.country);

  const stuBEmail = `${stamp}.studentB@example.com`;
  r = await signUp(stuBEmail, PASS, { role: 'student', full_name: 'طالب اختبار ب', gender: 'female' });
  const stuBToken = r.body.access_token, stuBLoginId = r.body.user?.id;

  // ── 5) الأدمن يربط صفّي students حقيقيين بحسابي الدخول (محاكاة لما يفعله chooseTeacher/addToGroupModal) ──
  suite('5) إنشاء صفوف students مرتبطة + معلم مسؤول');
  r = await rest('/students', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ full_name: 'طالب اختبار أ', login_id: stuALoginId, gender: 'male', quran_path: 'amma', plan_type: 'rasokh', enrollment_status: 'active', chosen_teacher_id: teacherId }) }, adminToken);
  const studentAId = r.body?.[0]?.id;
  assert(!!studentAId, 'صفّ الطالب أ اتعمل: ' + JSON.stringify(r.body));
  r = await rest('/students', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ full_name: 'طالب اختبار ب', login_id: stuBLoginId, gender: 'female', enrollment_status: 'active' }) }, adminToken);
  const studentBId = r.body?.[0]?.id;
  assert(!!studentBId, 'صفّ الطالب ب اتعمل: ' + JSON.stringify(r.body));

  // ── 6) بناء خطة حقيقية مبسّطة (نظام مزروع بالفعل من 2026 migration + محطة اختبار واحدة) ──
  suite('6) بناء خطة حفظ حقيقية ووَرد لليوم');
  r = await rest(`/quran_systems?path_key=eq.amma&plan_type=eq.rasokh&select=id&limit=1`, {}, adminToken);
  const systemId = r.body?.[0]?.id;
  assert(!!systemId, 'نظام "عمّ — رسوخ" المزروع تلقائيًا موجود: ' + JSON.stringify(r.body));
  r = await rest('/quran_stations', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ system_id: systemId, order_index: 1, name: 'محطة اختبار الدخان', station_kind: 'hifz' }) }, adminToken);
  const stationId = r.body?.[0]?.id;
  assert(!!stationId, 'محطة اختبار اتعملت: ' + JSON.stringify(r.body));
  r = await rest('/quran_student_plans', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ student_id: studentAId, login_id: stuALoginId, system_id: systemId, current_station_id: stationId, teacher_id: teacherId, start_date: new Date().toISOString().slice(0, 10), status: 'active' }) }, adminToken);
  const planId = r.body?.[0]?.id;
  assert(!!planId, 'خطة الطالب أ اتعملت: ' + JSON.stringify(r.body));
  const today = new Date().toISOString().slice(0, 10);
  r = await rest('/quran_plan_wards', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ plan_id: planId, planned_date: today, day_index: 1, fortress_code: 'new_hifz', amount_label: 'اختبار دخان' }) }, adminToken);
  const wardId = r.body?.[0]?.id;
  assert(!!wardId, 'ورد اليوم اتعمل: ' + JSON.stringify(r.body));

  // ── 7) الطالب يعلّم ورده "تمّ" — وأثبتنا قبل شوية إن هذه بالذات هي الاستدعاء اللي كان مكسورًا فعليًا على الإنتاج ──
  suite('7) quran_mark_ward — نفس الاستدعاء اللي كان مكسورًا على الإنتاج قبل الإصلاح');
  r = await rpc('quran_mark_ward', { p_ward_id: wardId, p_status: 'done', p_planned_for_date: today, p_actual_date: today }, stuAToken);
  assert(r.status === 200 && r.body?.ok === true, 'الطالب علّم الورد "تمّ" بنجاح (بلا خطأ تضارب overload): ' + JSON.stringify(r.body));
  r = await rest(`/quran_ward_progress?ward_id=eq.${wardId}&select=status,marked_by_role`, {}, stuAToken);
  assert(r.body?.[0]?.status === 'done', 'الحالة المحفوظة فعليًا = done: ' + JSON.stringify(r.body));
  assert(r.body?.[0]?.marked_by_role === 'student', 'من علّمه محسوب صح = student (محسوب سيرفريًا، لا يرسله العميل): ' + JSON.stringify(r.body));

  // ── 8) المعلم يعتمد نفس الورد — من علّمه لازم يتحوّل teacher ──
  suite('8) اعتماد المعلم للورد');
  r = await rpc('quran_mark_ward', { p_ward_id: wardId, p_teacher_approve: true, p_teacher_mastery: 95 }, adminToken /* الأدمن يتصرف كموظف staff */);
  assert(r.status === 200 && r.body?.ok === true, 'اعتماد المعلم/الإدارة نجح: ' + JSON.stringify(r.body));
  r = await rest(`/quran_ward_progress?ward_id=eq.${wardId}&select=marked_by_role,teacher_approved_at,teacher_mastery`, {}, adminToken);
  assert(r.body?.[0]?.marked_by_role === 'teacher', 'من علّمه اتغيّر لـ teacher بعد الاعتماد: ' + JSON.stringify(r.body));
  assert(r.body?.[0]?.teacher_mastery === 95, 'teacher_mastery اتسجّل صح (كان العمود ده بلا أي معامل قبل migration 004): ' + JSON.stringify(r.body));

  // ── 9) عزل RLS: الطالب ب (مالوش علاقة) لازم مايشوفش خطة/ورد الطالب أ إطلاقًا ──
  suite('9) عزل RLS بين طالبين غير مرتبطين');
  r = await rest(`/quran_plan_wards?id=eq.${wardId}`, {}, stuBToken);
  assert(Array.isArray(r.body) && r.body.length === 0, 'الطالب ب مايقدرش يشوف ورد الطالب أ (صفوف راجعة = 0): ' + JSON.stringify(r.body));
  r = await rest(`/quran_student_plans?id=eq.${planId}`, {}, stuBToken);
  assert(Array.isArray(r.body) && r.body.length === 0, 'الطالب ب مايقدرش يشوف خطة الطالب أ: ' + JSON.stringify(r.body));

  // ── 10) تأكيد الدفع الذرّي — RPC واحدة تحدّث payments + students معًا ──
  suite('10) تأكيد الدفع الذرّي (confirm_payment)');
  r = await rest('/payments', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ student_id: studentAId, amount: 450, status: 'pending', payment_method: 'vodafone_cash', reference_number: 'SMOKE123' }) }, adminToken);
  const paymentId = r.body?.[0]?.id;
  assert(!!paymentId, 'دفعة تجريبية اتعملت: ' + JSON.stringify(r.body));
  r = await rpc('confirm_payment', { p_payment_id: paymentId }, adminToken);
  assert(r.body?.ok === true, 'confirm_payment نجحت: ' + JSON.stringify(r.body));
  r = await rest(`/payments?id=eq.${paymentId}&select=status`, {}, adminToken);
  assert(r.body?.[0]?.status === 'paid', 'حالة الدفع تحدّثت لـ paid: ' + JSON.stringify(r.body));
  r = await rest(`/students?id=eq.${studentAId}&select=enrollment_status,sub_end`, {}, adminToken);
  assert(r.body?.[0]?.enrollment_status === 'active' && !!r.body?.[0]?.sub_end, 'تفعيل الاشتراك + تاريخ الانتهاء اتحدّثوا في نفس العملية: ' + JSON.stringify(r.body));
  // إعادة استدعاء نفس الدفعة تاني لازم تترفض (race-condition guard)
  r = await rpc('confirm_payment', { p_payment_id: paymentId }, adminToken);
  assert(r.body?.ok === false, 'تأكيد نفس الدفعة مرتين مرفوض (لا تكرار تفعيل): ' + JSON.stringify(r.body));

  // ── 11) رفض طلب دعم مالي — يرجع بيانات التواصل الصحيحة ──
  suite('11) reject_subsidy');
  r = await rest('/join_requests', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ student_id: studentAId, request_type: 'subsidy', status: 'pending', full_name: 'طالب اختبار أ' }) }, adminToken);
  const jrId = r.body?.[0]?.id;
  r = await rpc('reject_subsidy', { p_request_id: jrId }, adminToken);
  assert(r.body?.ok === true && r.body?.login_id === stuALoginId, 'reject_subsidy نجحت ورجّعت بيانات التواصل الصحيحة: ' + JSON.stringify(r.body));
  r = await rest(`/join_requests?id=eq.${jrId}&select=status`, {}, adminToken);
  assert(r.body?.[0]?.status === 'rejected', 'حالة الطلب اتحدّثت لـ rejected: ' + JSON.stringify(r.body));

  // ── 12) حذف ناعم للطالب + سجل تدقيق ──
  suite('12) soft_delete_student + admin_actions_log');
  r = await rpc('soft_delete_student', { p_student_id: studentBId, p_reason: 'اختبار دخان' }, adminToken);
  assert(r.body?.ok === true, 'soft_delete_student نجحت: ' + JSON.stringify(r.body));
  r = await rest(`/students?id=eq.${studentBId}&select=deleted_at,delete_reason`, {}, adminToken);
  assert(!!r.body?.[0]?.deleted_at, 'deleted_at اتسجّل (بلا حذف نهائي فعلي للصف): ' + JSON.stringify(r.body));
  r = await rest(`/admin_actions_log?target_id=eq.${studentBId}&action=eq.soft_delete_student&select=action,details`, {}, adminToken);
  assert(r.body?.length > 0, 'سجل التدقيق اتسجّل فعليًا: ' + JSON.stringify(r.body));
  // معلم (مش staff) يحاول يحذف — لازم يترفض
  r = await rpc('soft_delete_student', { p_student_id: studentAId, p_reason: 'محاولة غير مصرح بها' }, stuAToken);
  assert(r.body?.ok === false, 'حساب طالب عادي لا يقدر يحذف طالباً: ' + JSON.stringify(r.body));

  console.log(`\n────────────────────\n${pass} ناجح، ${fail} فاشل\n`);
  process.exit(fail > 0 ? 1 : 0);
}

main().catch(e => { console.error('SMOKE TEST CRASHED:', e); process.exit(1); });
