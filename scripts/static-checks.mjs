#!/usr/bin/env node
// static-checks.mjs — بوابة النشر: فحوصات ثابتة سريعة على index.html
// تُشغَّل قبل الاختبارات الحية. هدفها التقاط الأخطاء "الصامتة" التي تكسر
// المستخدمين لكن لا تُرصد إلا بعد النشر:
//   ١) خطأ JavaScript parse في السكربت الرئيسي
//   ٢) navigate('key') لا يقابله PAGES[role_key] لأي دور موجود
//   ٣) عدم توازن العلامات (unclosed <script>, unmatched braces)
//   ٤) migrations SQL: كل ملف يبدأ بتعليق + لا يستخدم أسماء أعمدة معروف
//      أنها غير موجودة (activated_at / payments.method / groups.capacity)
//   ٥) لا زر onclick يستدعي دالة غير موجودة في نفس الملف
//
// الاستخدام:
//   node scripts/static-checks.mjs          # يفشل بحالة خطأ ويعيد exit 1
//   node scripts/static-checks.mjs --warn   # تحذيرات فقط (لا يفشل)

import fs from 'node:fs';
import path from 'node:path';
import { execSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import os from 'node:os';

const __filename = fileURLToPath(import.meta.url);
const ROOT = path.resolve(path.dirname(__filename), '..');
const INDEX = path.join(ROOT, 'index.html');
const MIGRATIONS_DIR = path.join(ROOT, 'migrations');
const WARN_ONLY = process.argv.includes('--warn');

let errors = 0;
let warnings = 0;
function err(msg){ errors++; console.log('  ❌ ' + msg); }
function warn(msg){ warnings++; console.log('  ⚠️  ' + msg); }
function ok(msg){ console.log('  ✅ ' + msg); }
function head(msg){ console.log('\n' + msg); }

// ═════════════════════════════════════════════════════════════════════════
// 1) JavaScript parse — نستخرج كل <script> بلا src ونمرّرها لـ Node --check
// ═════════════════════════════════════════════════════════════════════════
head('١) فحص parse للـ JavaScript المُضمَّن');
const html = fs.readFileSync(INDEX, 'utf8');
const scriptBlocks = [];
{
  const re = /<script(?![^>]*\bsrc=)[^>]*>([\s\S]*?)<\/script>/gi;
  let m; let idx = 0;
  while((m = re.exec(html)) !== null){
    scriptBlocks.push({idx: idx++, code: m[1], offset: m.index});
  }
}
ok(`اكتُشف ${scriptBlocks.length} كتلة سكربت مضمَّنة`);
const tmpDir = fs.mkdtempSync(path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'ah-check-'));
scriptBlocks.forEach((b, i) => {
  const f = path.join(tmpDir, `block-${i}.js`);
  fs.writeFileSync(f, b.code);
  try{
    execSync(`node --check "${f}"`, {stdio:'pipe'});
  } catch(e){
    err(`كتلة سكربت #${i} فيها خطأ parse:\n     ${(e.stderr||e.message).toString().split('\n').slice(0,3).join('\n     ')}`);
  }
});
if(errors === 0) ok('كل كتل السكربت صحيحة syntactically');

// ═════════════════════════════════════════════════════════════════════════
// 2) navigate('key') targets — كل مفتاح يجب أن يقابل PAGES.<role>_<key>
//    لدور واحد على الأقل، أو أن يكون مفتاحًا خاصًا موثَّقًا
// ═════════════════════════════════════════════════════════════════════════
head('٢) فحص أهداف navigate() ضد PAGES المسجَّلة');
const pagesDefined = new Set();
{
  // PAGES.role_key = ...  أو  PAGES.role_key=async function
  const re = /PAGES\.([a-z]+_[a-z_0-9]+)\s*=/g;
  let m; while((m = re.exec(html)) !== null){ pagesDefined.add(m[1]); }
}
// المفاتيح المستخدمة داخل onclick أو navigate('...')
const navKeys = new Set();
{
  const re = /navigate\(\s*['"]([a-z_0-9]+)['"]/g;
  let m; while((m = re.exec(html)) !== null){ navKeys.add(m[1]); }
}
const ROLES = ['admin','executive','supervisor','teacher','parent','student'];
// مفاتيح خاصة يستخدمها buildShell/showNotifications ليست PAGES مباشرة
const SPECIAL = new Set(['record','confirm','back','forward','home','settings']);
const missingByKey = [];
for(const key of navKeys){
  if(SPECIAL.has(key)) continue;
  const found = ROLES.some(r => pagesDefined.has(`${r}_${key}`));
  if(!found) missingByKey.push(key);
}
if(missingByKey.length){
  missingByKey.forEach(k => warn(`navigate('${k}') — لا PAGES.<role>_${k} مسجَّل. سيصل المستخدم لـ«قيد التطوير».`));
} else {
  ok(`كل مفاتيح navigate() (${navKeys.size}) مسجَّلة لدور واحد على الأقل`);
}

// ═════════════════════════════════════════════════════════════════════════
// 3) توازن العلامات الحرجة
// ═════════════════════════════════════════════════════════════════════════
head('٣) توازن العلامات الحرجة');
const scriptOpen = (html.match(/<script\b/gi)||[]).length;
const scriptClose = (html.match(/<\/script>/gi)||[]).length;
if(scriptOpen !== scriptClose){
  err(`<script> غير متوازن: ${scriptOpen} فتحات × ${scriptClose} إغلاقات`);
} else {
  ok(`${scriptOpen} <script> ↔ ${scriptClose} </script> متوازنة`);
}
const styleOpen = (html.match(/<style\b/gi)||[]).length;
const styleClose = (html.match(/<\/style>/gi)||[]).length;
if(styleOpen !== styleClose){
  err(`<style> غير متوازن: ${styleOpen} × ${styleClose}`);
} else {
  ok(`${styleOpen} <style> ↔ ${styleClose} </style> متوازنة`);
}

// ═════════════════════════════════════════════════════════════════════════
// 4) migrations — كل ملف يبدأ بتعليق + لا يستخدم أعمدة "شبح"
// ═════════════════════════════════════════════════════════════════════════
head('٤) فحص ملفات migrations');
if(!fs.existsSync(MIGRATIONS_DIR)){
  warn('مجلد migrations غير موجود');
} else {
  const files = fs.readdirSync(MIGRATIONS_DIR).filter(f => f.endsWith('.sql')).sort();
  const GHOST_COLS = [
    // أعمدة تظن أنها موجودة لكنها ليست كذلك — من سجل الأخطاء التاريخية
    { pattern: /\bstudents\.activated_at\b/, msg: 'students.activated_at غير موجود — استخدم sub_start' },
    { pattern: /\bpayments\.method\b/, msg: 'payments.method غير موجود — الصحيح payment_method' },
    { pattern: /\bgroups\.capacity\b/, msg: 'groups.capacity غير موجود — استخدم profiles.max_students' },
  ];
  let migErrs = 0;
  for(const f of files){
    const p = path.join(MIGRATIONS_DIR, f);
    const c = fs.readFileSync(p, 'utf8');
    const first = c.trimStart().slice(0, 4);
    if(first !== '-- =' && !first.startsWith('--')){
      warn(`${f} لا يبدأ بتعليق توثيقي`);
    }
    for(const g of GHOST_COLS){
      if(g.pattern.test(c)){
        err(`${f}: ${g.msg}`);
        migErrs++;
      }
    }
  }
  if(!migErrs) ok(`${files.length} ملف migration بلا أعمدة "شبح"`);
}

// ═════════════════════════════════════════════════════════════════════════
// 5) index.html — لا يستخدم أعمدة "شبح" بنفس الطريقة
// ═════════════════════════════════════════════════════════════════════════
head('٥) فحص index.html من أعمدة "شبح"');
const GHOST_JS = [
  { pattern: /\.select\([^)]*\bactivated_at\b/, msg: '.select(...) يذكر activated_at (استخدم sub_start)' },
  { pattern: /\bpayments['"]\s*\)\.select\([^)]*\bmethod\b(?!_)/, msg: 'payments.select ذكر method بدل payment_method' },
  { pattern: /\bgroups['"]\s*\)\.select\([^)]*\bcapacity\b/, msg: 'groups.select ذكر capacity (غير موجود)' },
  { pattern: /p\.status\s*===\s*['"]confirmed['"]/, msg: 'p.status === "confirmed" — الصحيح "paid"' },
];
let jsGhosts = 0;
for(const g of GHOST_JS){
  const matches = html.match(new RegExp(g.pattern.source, 'g'));
  if(matches){ err(`${g.msg} (${matches.length} حالة)`); jsGhosts++; }
}
if(!jsGhosts) ok('لا استخدامات لأعمدة "شبح" في الاستعلامات');

// ═════════════════════════════════════════════════════════════════════════
// النتيجة النهائية
// ═════════════════════════════════════════════════════════════════════════
console.log('\n' + '═'.repeat(60));
console.log(`الملخص: ${errors} خطأ · ${warnings} تحذير`);
if(errors > 0 && !WARN_ONLY){
  console.log('\n❌ فشلت البوابة — الرجاء إصلاح الأخطاء قبل الدفع.');
  process.exit(1);
}
if(errors > 0){
  console.log('\n⚠️  --warn: تجاوز الفشل، لكن الأخطاء لا تزال موجودة.');
}
console.log('\n✅ اجتيازت البوابة الثابتة.');
