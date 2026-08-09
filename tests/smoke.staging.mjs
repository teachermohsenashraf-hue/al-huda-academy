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

  // ── 13) المرجع القرآني الحقيقي + القيود المبنية عليه (008/009) ──
  suite('13) مرجع القرآن (quran_surahs/quran_ayahs) + قيود الحدود');
  r = await rest(`/quran_surahs?select=surah_no&limit=1000`, {}, adminToken);
  assert(Array.isArray(r.body) && r.body.length === 114, 'quran_surahs فيه ١١٤ سورة فعليًا: ' + (r.body?.length));
  r = await rest(`/quran_ayahs?select=id&surah_no=eq.1`, {}, adminToken);
  assert(Array.isArray(r.body) && r.body.length === 7, 'الفاتحة فيها ٧ آيات فعليًا في المرجع: ' + (r.body?.length));
  // محاولة إدراج ورد برقم آية غير موجود فعليًا (سورة الفاتحة آية ٩٩ — الفاتحة ٧ آيات بس) — لازم القيد يرفضها
  r = await rest('/quran_plan_wards', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ plan_id: planId, planned_date: '2099-01-01', day_index: 999, fortress_code: 'new_hifz', surah_no: 1, ayah_from: 1, ayah_to: 99, amount_label: 'اختبار حد غير صالح' }) }, adminToken);
  assert(r.status >= 400 || r.body?.code, 'ورد بآية غير موجودة فعليًا (الفاتحة:٩٩) رُفض على مستوى القاعدة: status=' + r.status + ' ' + JSON.stringify(r.body).slice(0,150));

  // ── 14) تخفيف حجم الورد بنسبة — دقة حسابية حقيقية بمسافة معرّفات الآيات ──
  suite('14) quran_reduce_ward_load — دقة رياضية حقيقية');
  const reduceTestDate = '2099-02-01';
  r = await rest('/quran_plan_wards', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ plan_id: planId, planned_date: reduceTestDate, day_index: 998, fortress_code: 'new_hifz', surah_no: 78, surah_name: 'النبأ', ayah_from: 1, ayah_to: 20, amount_label: 'النبأ 1-20' }) }, adminToken);
  const reduceWardId = r.body?.[0]?.id;
  assert(!!reduceWardId, 'ورد اختبار التخفيف اتعمل: ' + JSON.stringify(r.body));
  r = await rpc('quran_reduce_ward_load', { p_plan_id: planId, p_percent: 50, p_reason: 'اختبار دخان' }, adminToken);
  assert(r.body?.ok === true && r.body?.affected_wards >= 1, 'quran_reduce_ward_load نجحت: ' + JSON.stringify(r.body));
  r = await rest(`/quran_plan_wards?id=eq.${reduceWardId}&select=ayah_to`, {}, adminToken);
  assert(r.body?.[0]?.ayah_to === 11, 'التخفيض ٥٠٪ لـ"النبأ ١-٢٠" أنتج ١-١١ بالضبط (نفس الحساب المُتحقَّق منه يدويًا وقت البناء): ' + JSON.stringify(r.body));

  // ── 15) أسبوع تثبيت — يوقف الحفظ الجديد فقط، لا المراجعة ──
  suite('15) quran_consolidation_week');
  const consStart = '2099-03-02'; // اثنين — يوم دراسة مضمون
  r = await rest('/quran_plan_wards', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ plan_id: planId, planned_date: consStart, day_index: 997, fortress_code: 'new_hifz', amount_label: 'اختبار تثبيت' }) }, adminToken);
  const consWardId = r.body?.[0]?.id;
  r = await rpc('quran_consolidation_week', { p_plan_id: planId, p_start_date: consStart, p_days: 3, p_reason: 'اختبار دخان' }, adminToken);
  assert(r.body?.ok === true, 'quran_consolidation_week نجحت: ' + JSON.stringify(r.body));
  r = await rest(`/quran_plan_wards?id=eq.${consWardId}&select=is_rest_day`, {}, adminToken);
  assert(r.body?.[0]?.is_rest_day === true, 'ورد الحفظ الجديد داخل أسبوع التثبيت تحوّل ليوم راحة فعليًا: ' + JSON.stringify(r.body));

  // ── 16) مركز الإنقاذ — توزيع المتأخرات (نفس الباگ اللي اكتُشف وأُصلح وقت البناء) ──
  suite('16) مركز الإنقاذ — quran_rescue_summary + quran_spread_lateness (توزيع صحيح فعليًا)');
  const lateDates = ['2020-01-06', '2020-01-07', '2020-01-08', '2020-01-09', '2020-01-10']; // أيام دراسة، كلها في الماضي البعيد
  const lateWardIds = [];
  for (const d of lateDates) {
    r = await rest('/quran_plan_wards', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ plan_id: planId, planned_date: d, day_index: 900 + lateWardIds.length, fortress_code: 'reading', page_from: 1, page_to: 2, amount_label: 'اختبار متأخر' }) }, adminToken);
    if (r.body?.[0]?.id) lateWardIds.push(r.body[0].id);
  }
  assert(lateWardIds.length === 5, '٥ أوراد متأخرة اختبارية اتعملت: ' + lateWardIds.length);
  r = await rpc('quran_rescue_summary', { p_plan_id: planId }, adminToken);
  assert(r.body?.ok === true && r.body?.total >= 5, 'quran_rescue_summary رصد المتأخرات فعليًا: ' + JSON.stringify(r.body));
  r = await rpc('quran_spread_lateness', { p_plan_id: planId, p_days: 3, p_reason: 'اختبار دخان' }, adminToken);
  assert(r.body?.ok === true, 'quran_spread_lateness نجحت: ' + JSON.stringify(r.body));
  r = await rest(`/quran_plan_wards?id=in.(${lateWardIds.join(',')})&select=planned_date`, {}, adminToken);
  const distinctDates = new Set((r.body || []).map(w => w.planned_date));
  // ملحوظة: الـ٥ أوراد كلهم من نفس نوع الحصن (reading) — وبما إن migration 014
  // بتمنع وردين من نفس النوع في نفس اليوم لنفس الخطة، التوزيع الصحيح فعليًا
  // هو ٥ أيام مختلفة (لا ٣) رغم إن p_days=3 — الدالة تمدّد فتحات هذا النوع
  // تلقائيًا لتفادي أي تصادم، وهو بالضبط سلوك الإصلاح في migration 016
  assert(distinctDates.size === 5, 'كل الأوراد المتأخرة (نفس النوع) اتوزّعت على أيام منفصلة تمامًا، بلا أي تصادم مع قيد منع التعارض: توزيع=' + JSON.stringify([...distinctDates]));
  const allFuture = [...(r.body || [])].every(w => new Date(w.planned_date) >= new Date());
  assert(allFuture, 'كل التواريخ الجديدة بعد اليوم فعليًا (لا توزيع على الماضي): ' + JSON.stringify(r.body));

  // ── 17) مراجعة علاجية + سجل تعديلات الخطة ──
  suite('17) quran_add_remedial_ward + quran_plan_edits');
  r = await rpc('quran_add_remedial_ward', { p_plan_id: planId, p_planned_date: '2099-04-01', p_fortress_code: 'review_near', p_amount_label: 'مراجعة علاجية اختبارية', p_reason: 'اختبار دخان' }, adminToken);
  assert(r.body?.ok === true && !!r.body?.ward_id, 'quran_add_remedial_ward نجحت: ' + JSON.stringify(r.body));
  r = await rest(`/quran_plan_edits?plan_id=eq.${planId}&action=eq.add_remedial_ward&select=id`, {}, adminToken);
  assert(r.body?.length > 0, 'إضافة المراجعة العلاجية سُجِّلت في سجل التعديلات تلقائيًا: ' + JSON.stringify(r.body));
  r = await rest(`/quran_plan_edits?plan_id=eq.${planId}&action=eq.reduced_ward_load&select=id`, {}, adminToken);
  assert(r.body?.length > 0, 'تخفيف حجم الورد (خطوة 14) سُجِّل هو الآخر في سجل التعديلات: ' + JSON.stringify(r.body));

  // ── 18) حالة "جزئي" أصبحت حالة مستقلة فعليًا، لا "تمّ" بدرجة أقل ──
  suite('18) status=partial حالة مستقلة حقيقية');
  r = await rest('/quran_plan_wards', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ plan_id: planId, planned_date: '2099-05-01', day_index: 996, fortress_code: 'new_hifz', amount_label: 'اختبار جزئي' }) }, adminToken);
  const partialWardId = r.body?.[0]?.id;
  r = await rpc('quran_mark_ward', { p_ward_id: partialWardId, p_status: 'partial', p_teacher_mastery: 65, p_teacher_approve: true, p_planned_for_date: '2099-05-01', p_actual_date: today }, adminToken);
  assert(r.body?.ok === true, 'تسجيل status=partial نجح: ' + JSON.stringify(r.body));
  r = await rest(`/quran_ward_progress?ward_id=eq.${partialWardId}&select=status`, {}, adminToken);
  assert(r.body?.[0]?.status === 'partial', 'الحالة المحفوظة = partial فعليًا (لا done): ' + JSON.stringify(r.body));
  // سبب عدم الإتمام — قيد CHECK يرفض قيمة غير معروفة
  r = await rest('/quran_plan_wards', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ plan_id: planId, planned_date: '2099-05-02', day_index: 995, fortress_code: 'new_hifz', amount_label: 'اختبار سبب' }) }, adminToken);
  const reasonWardId = r.body?.[0]?.id;
  r = await rpc('quran_mark_ward', { p_ward_id: reasonWardId, p_status: 'skipped', p_not_done_reason: 'time_pressure', p_planned_for_date: '2099-05-02', p_actual_date: today }, stuAToken);
  assert(r.body?.ok === true, 'تسجيل سبب عدم الإتمام نجح: ' + JSON.stringify(r.body));
  r = await rest(`/quran_ward_progress?ward_id=eq.${reasonWardId}&select=not_done_reason`, {}, adminToken);
  assert(r.body?.[0]?.not_done_reason === 'time_pressure', 'السبب محفوظ فعليًا: ' + JSON.stringify(r.body));

  // ── 19) طلبات المساعدة — الطالب ينشئ، لا يقدر يقفل طلبه بنفسه، المعلم يقدر ──
  suite('19) quran_help_requests');
  r = await rest('/quran_help_requests', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ ward_id: wardId, plan_id: planId, requested_by: stuALoginId, category: 'memorization_difficulty', note: 'اختبار دخان' }) }, stuAToken);
  const helpReqId = r.body?.[0]?.id;
  assert(!!helpReqId, 'الطالب قدر ينشئ طلب مساعدة لخطته هو: ' + JSON.stringify(r.body));
  // الطالب ب (مالوش علاقة بالخطة) لازم يترفض
  r = await rest('/quran_help_requests', { method: 'POST', body: JSON.stringify({ ward_id: wardId, plan_id: planId, requested_by: stuBLoginId, category: 'other' }) }, stuBToken);
  assert(r.status >= 400 || (Array.isArray(r.body) && r.body.length === 0), 'طالب مالوش علاقة بالخطة لا يقدر ينشئ طلب مساعدة عليها: status=' + r.status);
  // الطالب نفسه يحاول يقفل طلبه — لازم يترفض (RLS تقصر الإغلاق على المعلم/الإدارة)
  r = await rest(`/quran_help_requests?id=eq.${helpReqId}`, { method: 'PATCH', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ status: 'resolved' }) }, stuAToken);
  assert(!Array.isArray(r.body) || r.body.length === 0, 'الطالب لا يقدر يقفل طلب المساعدة بنفسه (لا صفوف اتأثرت): ' + JSON.stringify(r.body));
  r = await rest(`/quran_help_requests?id=eq.${helpReqId}&select=status`, {}, adminToken);
  assert(r.body?.[0]?.status === 'open', 'الطلب لسه مفتوح فعليًا بعد محاولة الطالب: ' + JSON.stringify(r.body));
  // المعلم/الإدارة يقفله — لازم ينجح
  r = await rest(`/quran_help_requests?id=eq.${helpReqId}`, { method: 'PATCH', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ status: 'resolved', resolved_by: adminId, resolved_at: new Date().toISOString() }) }, adminToken);
  assert(Array.isArray(r.body) && r.body[0]?.status === 'resolved', 'المعلم/الإدارة قدر يقفل الطلب: ' + JSON.stringify(r.body));

  // ── 20) قيد منع تعارض ورد بورد آخر لنفس اليوم ──
  suite('20) منع تعارض الأوراد لنفس اليوم');
  const conflictDate = '2099-06-01';
  r = await rest('/quran_plan_wards', { method: 'POST', headers: { Prefer: 'return=representation' }, body: JSON.stringify({ plan_id: planId, planned_date: conflictDate, day_index: 994, fortress_code: 'listening', page_from: 1, page_to: 2, amount_label: 'الأول' }) }, adminToken);
  assert(!!r.body?.[0]?.id, 'أول ورد سماع لليوم اتعمل بنجاح: ' + JSON.stringify(r.body));
  r = await rest('/quran_plan_wards', { method: 'POST', body: JSON.stringify({ plan_id: planId, planned_date: conflictDate, day_index: 993, fortress_code: 'listening', page_from: 3, page_to: 4, amount_label: 'الثاني (متعارض)' }) }, adminToken);
  assert(r.status >= 400, 'ورد سماع ثانٍ لنفس اليوم ونفس النوع رُفض على مستوى القاعدة (فهرس فريد جزئي): status=' + r.status + ' ' + JSON.stringify(r.body).slice(0,150));

  console.log(`\n────────────────────\n${pass} ناجح، ${fail} فاشل\n`);
  process.exit(fail > 0 ? 1 : 0);
}

main().catch(e => { console.error('SMOKE TEST CRASHED:', e); process.exit(1); });
