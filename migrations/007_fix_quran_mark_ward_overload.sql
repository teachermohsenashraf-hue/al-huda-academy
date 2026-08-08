-- ============================================================================
-- 007_fix_quran_mark_ward_overload.sql
--
-- خطأ حقيقي نتج عن migration 004: CREATE OR REPLACE FUNCTION في Postgres
-- لا "يستبدل" دالة موجودة إلا لو تطابقت قائمة المعاملات (الأنواع) بالضبط.
-- بما إن 004 أضافت معامل جديد (p_teacher_mastery)، النتيجة كانت دالتين
-- (overloads) لنفس الاسم quran_mark_ward بدل استبدال واحدة بأخرى — ده يعني
-- إن أي استدعاء من العميل مايبعتش p_teacher_mastery (وهي أغلب الاستدعاءات
-- الفعلية في index.html) بيبقى غامضاً بين النسختين، وPostgREST يرفضه بخطأ
-- "could not choose the best candidate function" بدل ما ينفّذه.
--
-- الإصلاح: حذف النسخة القديمة (١٣ معامل) صراحةً، والإبقاء على النسخة
-- الجديدة فقط (١٤ معامل، بها p_teacher_mastery اختياري افتراضه NULL، فكل
-- الاستدعاءات القديمة تفضل تشتغل بلا أي تغيير في الكود).
-- ============================================================================

drop function if exists quran_mark_ward(
  uuid, text, date, date, boolean, boolean, integer, integer, text, text, boolean, boolean, boolean
);
