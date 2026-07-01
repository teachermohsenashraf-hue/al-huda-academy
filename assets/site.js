/* ============================================================
   أكاديمية الهدى — سلوك مشترك لكل صفحات الموقع التسويقي
   (بريلودر، ناف بار، الوضع الليلي، كشف عند التمرير، أنيميشن الهيرو،
    الأسئلة الشائعة، تبديل الأسعار، المساعد الذكي، زر واتساب)
   ============================================================ */

/* PRELOADER: تكوين اسم الأكاديمية حرفاً حرفاً */
(function(){
  const el = document.getElementById('preLogo');
  if(!el) return;
  const name = 'أكاديمية الهدى';
  let i = 0;
  function type(){
    if(i<=name.length){ el.innerHTML = name.slice(0,i)+'<span class="cursor"></span>'; i++; setTimeout(type,180); }
    else {
      setTimeout(()=>{
        const p = document.getElementById('preloader');
        if(p) p.classList.add('done');
        document.body.style.overflow = '';
      }, 650);
    }
  }
  document.body.style.overflow = 'hidden';
  setTimeout(type, 400);
})();

/* NAVBAR */
(function(){
  const nav = document.getElementById('nav'), burger = document.getElementById('burger'), navLinks = document.getElementById('navLinks');
  if(nav){ window.addEventListener('scroll', ()=>{ nav.classList.toggle('scrolled', window.scrollY>50); }, {passive:true}); }
  if(burger && navLinks){
    burger.addEventListener('click', ()=>{ burger.classList.toggle('open'); navLinks.classList.toggle('open'); });
    navLinks.querySelectorAll('a').forEach(a=>a.addEventListener('click', ()=>{ burger.classList.remove('open'); navLinks.classList.remove('open'); }));
  }
})();

/* الوضع الليلي */
(function(){
  const themeBtn = document.getElementById('themeBtn');
  if(!themeBtn) return;
  themeBtn.addEventListener('click', ()=>{
    document.documentElement.classList.toggle('dark');
    themeBtn.textContent = document.documentElement.classList.contains('dark') ? '☀️' : '🌙';
  });
})();

/* كشف العناصر عند التمرير */
(function(){
  const io = new IntersectionObserver((entries)=>{
    entries.forEach((e,idx)=>{ if(e.isIntersecting){ setTimeout(()=>e.target.classList.add('in'), (idx%4)*80); io.unobserve(e.target); } });
  }, {threshold:0.12, rootMargin:'0px 0px -50px 0px'});
  document.querySelectorAll('.reveal').forEach(el=>io.observe(el));
})();

/* أنيميشن الهيرو (بعد الـ preloader) — يعمل فقط إن وُجد h1 بكلمات .word */
window.addEventListener('load', ()=>{
  setTimeout(()=>{
    document.querySelectorAll('.hero h1 .word').forEach((w,i)=>{
      setTimeout(()=>{ w.style.transition='opacity .7s ease, transform .7s cubic-bezier(.22,.61,.36,1)'; w.style.opacity='1'; w.style.transform='translateY(0)'; }, i*180);
    });
    ['.hero-lead','.hero-cta','.hero-trust'].forEach((s,i)=>{
      const el=document.querySelector(s);
      if(el) setTimeout(()=>{ el.style.transition='opacity .8s ease'; el.style.opacity='1'; }, 500+i*150);
    });
  }, 2200);
});

/* FAQ */
document.querySelectorAll('.faq-item').forEach(item=>{
  const q = item.querySelector('.faq-q');
  if(!q) return;
  q.addEventListener('click', ()=>{
    const open = item.classList.contains('open');
    document.querySelectorAll('.faq-item').forEach(i=>i.classList.remove('open'));
    if(!open) item.classList.add('open');
  });
});

/* تبديل الأسعار (شهري/سنوي) — اختياري، فقط إن وُجد على الصفحة */
(function(){
  const sw = document.getElementById('priceSwitch'), lblM = document.getElementById('lblMonth'), lblY = document.getElementById('lblYear');
  if(!sw) return;
  const arNum = n => String(n).replace(/[0-9]/g, d=>'٠١٢٣٤٥٦٧٨٩'[d]);
  sw.addEventListener('click', ()=>{
    sw.classList.toggle('year');
    const isYear = sw.classList.contains('year');
    if(lblM) lblM.classList.toggle('on', !isYear);
    if(lblY) lblY.classList.toggle('on', isYear);
    document.querySelectorAll('.amt').forEach(a=>{
      a.textContent = arNum(isYear ? a.dataset.y : a.dataset.m);
      if(a.nextElementSibling) a.nextElementSibling.textContent = isYear ? ' ج/سنة' : ' ج/شهر';
    });
  });
})();

/* ============================================================
   المساعد الذكي — شات بوت عائم (أسئلة شائعة + تحويل واتساب)
   ============================================================ */
const CB_WHATSAPP = '201227958232';
const CHATBOT_FAQ = [
  { kw:['سعر','اسعار','تكلفه','فلوس','اشتراك شهري','رسوم','باقات'],
    a:'نظام رسوخ يبدأ من ٤٥٠ ج/شهر (٤ حصص)، والنظام المرن يبدأ من ٤٠٠ ج/شهر. التفاصيل الكاملة في صفحة كل نظام.' },
  { kw:['مسار','مسارات','جزء عم','الزهراوان','المفصل','ربع القران','نصف القران','قران كامل'],
    a:'عندنا ٦ مسارات لحفظ القرآن: جزء عمّ وتبارك، الزهراوان، المفصّل، ربع القرآن، نصف القرآن، والقرآن كاملاً — كل مسار متاح في نظام رسوخ والنظام المرن.' },
  { kw:['حصون','حصن','ورد','اوراد'],
    a:'نظام رسوخ قائم على خمسة حصون يومية (الحفظ الجديد، مراجعة القريب، القراءة اليومية، مراجعة البعيد، السماع)، والنظام المرن على ثلاثة حصون فقط (الحفظ، المراجعة، السماع).' },
  { kw:['فرق بين','رسوخ ولا مرن','اي الفرق','النظامين'],
    a:'نظام رسوخ أكثر شمولاً بخمسة حصون يومية وباقات تبدأ من ٤٥٠ ج، والنظام المرن أخف بثلاثة حصون أساسية وباقات تبدأ من ٤٠٠ ج — تقدر تشوف تفاصيل الاتنين من الصفحة الرئيسية.' },
  { kw:['تسجيل','انشاء حساب','ازاي اسجل','عايز اشترك','التحق'],
    a:'اضغط زر «ابدأ رحلتك الآن»، هتنشئ حساباً، تختار نظامك ومسارك، ترفع إيصال الدفع، وبعد تأكيد الإشراف تختار معلمك وتبدأ حلقتك.' },
  { kw:['حلقه فرديه','جماعيه','حصص كام','كام حصه','مدة الحصة'],
    a:'كل الحلقات فردية بالكامل (1:1)، ومدة الحصة ٣٠ دقيقة، مع تقارير يومية لمتابعة تقدمك.' },
  { kw:['فصل بين الجنسين','بنات وولاد','ذكور واناث'],
    a:'النظام بيراعي الفصل بين الجنسين تلقائياً: الطالب يُوجَّه لمعلمين ومشرفين من جنسه، والطالبة كذلك.' },
  { kw:['ولي الامر','متابعه ابني','ابني','بنتي'],
    a:'لوليّ الأمر لوحة خاصة يتابع منها حلقات أبنائه، حصصهم، تقاريرهم، وحصونهم اليومية أولاً بأول.' },
  { kw:['تواصل','دعم','مشرف','اكلمك ازاي','رقم واتساب'],
    a:'تقدر تكلّمنا مباشرة على واتساب من الأيقونة تحت 👇، أو من زر «تسجيل الدخول» لو عندك حساب بالفعل.' },
];
function cbNorm(t){
  return String(t||'').toLowerCase()
    .replace(/[أإآا]/g,'ا').replace(/ى/g,'ي').replace(/ة/g,'ه').replace(/[ؤئ]/g,'ي')
    .replace(/[ً-ْـ]/g,'').replace(/\s+/g,' ').trim();
}
function cbMatch(q){
  const nq = cbNorm(q);
  let best=null, bestScore=0;
  CHATBOT_FAQ.forEach(item=>{
    let score=0;
    item.kw.forEach(k=>{ if(nq.includes(cbNorm(k))) score++; });
    if(score>bestScore){ bestScore=score; best=item; }
  });
  return bestScore>0 ? best : null;
}
function cbEsc(t){ const d=document.createElement('div'); d.textContent=String(t||''); return d.innerHTML; }
let CB_OPEN=false;
let CB_LAST_QUESTION='';
function cbInit(){
  const host = document.getElementById('chatbotHost');
  if(!host) return;
  host.innerHTML = `
    <button class="cb-fab" id="cbFab" onclick="cbToggle()" aria-label="تواصل مع الشات"><span class="cb-avatar"><img src="assets/logo.jpg" alt="المساعد الذكي"><span class="cb-dot">💬</span></span><span class="cb-label">تواصل مع الشات</span></button>
    <div class="cb-panel" id="cbPanel">
      <div class="cb-head">
        <div><b>🤖 المساعد الذكي</b><span>هنا لأي سؤال عن أكاديمية الهدى</span></div>
        <button onclick="cbToggle()">×</button>
      </div>
      <div class="cb-body" id="cbBody"></div>
      <div class="cb-input">
        <input id="cbInput" placeholder="اكتب سؤالك هنا..." onkeydown="if(event.key==='Enter')cbSend()">
        <button onclick="cbSend()">➤</button>
      </div>
    </div>`;
  cbAppendBot('السلام عليكم! 👋 أنا مساعد أكاديمية الهدى، اسألني عن الأنظمة، المسارات، الأسعار، أو التسجيل.');
  const b = document.getElementById('cbBody');
  const chips = CHATBOT_FAQ.slice(0,4).map(f=>`<span class="cb-chip" onclick="cbAsk('${f.kw[0]}')">${f.kw[0]}</span>`).join('');
  if(b) b.insertAdjacentHTML('beforeend', `<div class="cb-chips">${chips}</div>`);
}
function cbToggle(){
  const p = document.getElementById('cbPanel'); if(!p) return;
  CB_OPEN = !CB_OPEN; p.classList.toggle('open', CB_OPEN);
  if(CB_OPEN){ const i=document.getElementById('cbInput'); if(i) setTimeout(()=>i.focus(),150); }
}
function cbAppendBot(text){
  const b = document.getElementById('cbBody'); if(!b) return;
  b.insertAdjacentHTML('beforeend', `<div class="cb-msg bot">${cbEsc(text).replace(/\n/g,'<br>')}</div>`);
  b.scrollTop = b.scrollHeight;
}
function cbAppendUser(text){
  const b = document.getElementById('cbBody'); if(!b) return;
  b.insertAdjacentHTML('beforeend', `<div class="cb-msg user">${cbEsc(text)}</div>`);
  b.scrollTop = b.scrollHeight;
}
function cbAsk(q){ const i=document.getElementById('cbInput'); if(i) i.value=q; cbSend(); }
function cbSend(){
  const i = document.getElementById('cbInput'); const q = (i?.value||'').trim();
  if(!q) return;
  cbAppendUser(q); if(i) i.value='';
  const hit = cbMatch(q);
  if(hit){
    setTimeout(()=>cbAppendBot(hit.a), 300);
  } else {
    setTimeout(()=>{
      cbAppendBot('معنديش إجابة جاهزة لسؤالك ده 🤔 حابب تكلّم فريق الإشراف على واتساب مباشرة؟');
      const b = document.getElementById('cbBody');
      CB_LAST_QUESTION = q;
      if(b) b.insertAdjacentHTML('beforeend', `<div class="cb-chips"><span class="cb-esc" onclick="cbEscalate()">🙋 تواصل واتساب</span></div>`);
      if(b) b.scrollTop = b.scrollHeight;
    }, 300);
  }
}
function cbEscalate(){
  window.open('https://wa.me/'+CB_WHATSAPP+'?text='+encodeURIComponent('السلام عليكم، عندي سؤال: '+CB_LAST_QUESTION), '_blank');
}
document.addEventListener('DOMContentLoaded', cbInit);
