# تفعيل بوابة CI

الـPAT المستخدَم لدفع الكود من هذه الجلسة لا يملك صلاحية `workflow`،
فلا يستطيع إنشاء أو تعديل ملفات داخل `.github/workflows/`. الملف
`CI_WORKFLOW_TO_INSTALL.yml` جاهز في جذر المستودع — انقله يدويًا.

## طريقة ١ — GitHub Web UI (الأسرع، دقيقة)

1. افتح المستودع في GitHub → تبويب **Actions**
2. اضغط **"New workflow"** → **"set up a workflow yourself"**
3. غيّر اسم الملف من `main.yml` إلى `ci.yml`
4. الصق محتوى `CI_WORKFLOW_TO_INSTALL.yml` (موجود في الجذر)
5. **Commit** → سيبدأ العمل فورًا على كل push و PR

## طريقة ٢ — token بصلاحية workflow

من [github.com/settings/tokens](https://github.com/settings/tokens) —
أنشئ PAT جديد وضع علامة على `repo` **و** `workflow`. ثم:

```bash
mv CI_WORKFLOW_TO_INSTALL.yml .github/workflows/ci.yml
git add .github/workflows/ci.yml
git commit -m "CI: enable static-checks + smoke tests gate"
git push
```

## ماذا يفعل هذا الـworkflow؟

- **`static`** (يعمل أولًا، ~ثانية واحدة):
  - JavaScript parse لكل `<script>` مضمَّن في `index.html`
  - كل `navigate('X')` عنده صفحة مسجَّلة
  - توازن `<script>/<style>`
  - migrations SQL بلا أعمدة "شبح"
  - index.html بلا أعمدة "شبح" ولا `status='confirmed'` خاطئ

- **`smoke`** (يعمل بعد نجاح static، ~دقائق):
  - اختبارات دخان حقيقية على مشروع Supabase **staging** منفصل
  - RLS + RPCs + triggers

## بعد التفعيل

لن يُقبَل أي push يفشل في الفحوصات (استخدم Branch Protection Rules
لجعل نجاح CI شرطًا للـmerge). محليًا، شغّل قبل كل push:

```bash
node scripts/static-checks.mjs
```

لو `0 خطأ` فأنت آمن.
