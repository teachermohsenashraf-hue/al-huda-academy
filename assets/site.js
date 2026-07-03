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
  if(nav){
    let lastY = window.scrollY;
    window.addEventListener('scroll', ()=>{
      const y = window.scrollY;
      nav.classList.toggle('scrolled', y>50);
      if(navLinks && navLinks.classList.contains('open')){ lastY = y; return; }
      if(y>lastY && y>120) nav.classList.add('hide'); else nav.classList.remove('hide');
      lastY = y;
    }, {passive:true});
  }
  if(burger && navLinks){
    burger.addEventListener('click', ()=>{
      const open = burger.classList.toggle('open'); navLinks.classList.toggle('open', open);
      burger.setAttribute('aria-expanded', open ? 'true':'false');
    });
    navLinks.querySelectorAll('a').forEach(a=>a.addEventListener('click', ()=>{ burger.classList.remove('open'); navLinks.classList.remove('open'); burger.setAttribute('aria-expanded','false'); }));
  }
})();

/* الوضع الليلي */
(function(){
  const themeBtn = document.getElementById('themeBtn');
  if(!themeBtn) return;
  themeBtn.addEventListener('click', ()=>{
    const isDark = document.documentElement.classList.toggle('dark');
    themeBtn.textContent = isDark ? '☀️' : '🌙';
    themeBtn.setAttribute('aria-label', isDark ? 'التبديل للوضع النهاري' : 'التبديل للوضع الليلي');
  });
})();

/* كشف العناصر عند التمرير */
(function(){
  const io = new IntersectionObserver((entries)=>{
    entries.forEach((e,idx)=>{ if(e.isIntersecting){ setTimeout(()=>e.target.classList.add('in'), (idx%4)*80); io.unobserve(e.target); } });
  }, {threshold:0.12, rootMargin:'0px 0px -50px 0px'});
  document.querySelectorAll('.reveal').forEach(el=>io.observe(el));
})();

/* عدّاد تصاعدي للأرقام عند الظهور في الشاشة */
(function(){
  const els = document.querySelectorAll('[data-count]');
  if(!els.length) return;
  const easeOut = t => 1 - Math.pow(1-t, 3);
  function animate(el){
    const target = parseInt(el.dataset.count, 10);
    if(isNaN(target)) return;
    const dur = 900, start = performance.now();
    el.textContent = '0';
    function step(now){
      const p = Math.min((now-start)/dur, 1);
      el.textContent = String(Math.round(target * easeOut(p)));
      if(p<1) requestAnimationFrame(step); else el.textContent = String(target);
    }
    requestAnimationFrame(step);
  }
  const io = new IntersectionObserver((entries)=>{
    entries.forEach(e=>{ if(e.isIntersecting){ animate(e.target); io.unobserve(e.target); } });
  }, {threshold:0.5});
  els.forEach(el=>io.observe(el));
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
  const a = item.querySelector('.faq-a');
  if(!q) return;
  q.setAttribute('role','button'); q.setAttribute('tabindex','0'); q.setAttribute('aria-expanded','false');
  const toggle = ()=>{
    const open = item.classList.contains('open');
    document.querySelectorAll('.faq-item').forEach(i=>{ i.classList.remove('open'); const qq=i.querySelector('.faq-q'); if(qq) qq.setAttribute('aria-expanded','false'); });
    if(!open){ item.classList.add('open'); q.setAttribute('aria-expanded','true'); }
  };
  q.addEventListener('click', toggle);
  q.addEventListener('keydown', (e)=>{ if(e.key==='Enter'||e.key===' '){ e.preventDefault(); toggle(); } });
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
      if(a.nextElementSibling) a.nextElementSibling.textContent = isYear ? ' ج.م/سنة' : ' ج.م/شهر';
    });
  });
})();

/* Modal مقارنة الباقات */
let CMP_LAST_FOCUS = null;
function openCompare(){
  const m = document.getElementById('compareModal'); if(!m) return;
  CMP_LAST_FOCUS = document.activeElement;
  m.classList.add('open');
  document.body.style.overflow = 'hidden';
  const closeBtn = m.querySelector('.compare-head button');
  if(closeBtn) setTimeout(()=>closeBtn.focus(), 50);
}
function closeCompare(){
  const m = document.getElementById('compareModal'); if(!m) return;
  m.classList.remove('open');
  document.body.style.overflow = '';
  if(CMP_LAST_FOCUS) CMP_LAST_FOCUS.focus();
}
document.addEventListener('keydown', (e)=>{
  if(e.key==='Escape'){ const m=document.getElementById('compareModal'); if(m && m.classList.contains('open')) closeCompare(); }
});
document.addEventListener('click', (e)=>{
  if(e.target.id==='compareModal') closeCompare();
});

/* ============================================================
   المساعد الذكي — شات بوت عائم (أسئلة شائعة + تحويل واتساب)
   ============================================================ */
const CB_WHATSAPP = '201227958232';
const CHATBOT_FAQ = [
  { topic:'الأسعار', kw:['سعر','اسعار','تكلفه','فلوس','اشتراك شهري','رسوم','باقات','كام السعر','بكام'],
    a:'نظام رسوخ يبدأ من ٤٥٠ ج.م/شهر (٤ حصص)، والنظام المرن يبدأ من ٤٠٠ ج.م/شهر. في ٣ باقات في كل نظام حسب عدد الحصص أسبوعياً — التفاصيل الكاملة في صفحة كل نظام أو من زر «قارن الباقات».' },
  { topic:'المسارات', kw:['مسار','مسارات','جزء عم','الزهراوان','المفصل','ربع القران','نصف القران','قران كامل','كام مسار'],
    a:'عندنا ٦ مسارات لحفظ القرآن: جزء عمّ وتبارك، الزهراوان، المفصّل، ربع القرآن، نصف القرآن، والقرآن كاملاً — كل مسار متاح في نظام رسوخ والنظام المرن، وتقدر تختار المسار المناسب لمستواك وهدفك.' },
  { topic:'الحصون', kw:['حصون','حصن','ورد','اوراد','منهج الحفظ'],
    a:'نظام رسوخ قائم على خمسة حصون يومية (الحفظ الجديد، مراجعة القريب، القراءة اليومية، مراجعة البعيد، السماع)، والنظام المرن على ثلاثة حصون فقط (الحفظ، المراجعة، السماع).' },
  { topic:'الفرق بين النظامين', kw:['فرق بين','رسوخ ولا مرن','اي الفرق','النظامين','اختار نظام ايه'],
    a:'نظام رسوخ أكثر شمولاً بخمسة حصون يومية وباقات تبدأ من ٤٥٠ ج.م، والنظام المرن أخف بثلاثة حصون أساسية وباقات تبدأ من ٤٠٠ ج.م — تقدر تشوف تفاصيل الاتنين من الصفحة الرئيسية.' },
  { topic:'التسجيل', kw:['تسجيل','انشاء حساب','ازاي اسجل','عايز اشترك','التحق','ازاي ابدا'],
    a:'اضغط زر «ابدأ رحلتك الآن»، هتنشئ حساباً، تختار نظامك ومسارك، ترفع إيصال الدفع، وبعد تأكيد الإشراف تختار معلمك وتبدأ حلقتك.' },
  { topic:'شكل الحلقة', kw:['حلقه فرديه','جماعيه','حصص كام','كام حصه','مدة الحصة','طول الحصة'],
    a:'كل الحلقات فردية بالكامل (1:1)، ومدة الحصة ٣٠ دقيقة، مع تقارير يومية لمتابعة تقدمك.' },
  { topic:'الفصل بين الجنسين', kw:['فصل بين الجنسين','بنات وولاد','ذكور واناث','معلمه للبنات'],
    a:'النظام بيراعي الفصل بين الجنسين تلقائياً: الطالب يُوجَّه لمعلمين ومشرفين من جنسه، والطالبة كذلك.' },
  { topic:'متابعة ولي الأمر', kw:['ولي الامر','متابعه ابني','ابني','بنتي','لوحة ولي الامر'],
    a:'لوليّ الأمر لوحة خاصة يتابع منها حلقات أبنائه، حصصهم، تقاريرهم، وحصونهم اليومية أولاً بأول.' },
  { topic:'التواصل', kw:['تواصل','دعم','مشرف','اكلمك ازاي','رقم واتساب','رقم تليفون'],
    a:'تقدر تكلّمنا مباشرة على واتساب من زر «تواصل معنا» تحت 👇، أو من زر «تسجيل الدخول» لو عندك حساب بالفعل.' },
  { topic:'حصة تجريبية', kw:['حصه تجريبيه','تجربه مجانيه','اجرب الاول','حصة مجانية'],
    a:'حالياً مفيش حصة تجريبية مجانية منفصلة، لكن أول حصة بعد التسجيل والتفعيل مخصّصة لتقييم مستواك وضبط خطتك مع المعلّم، فهي عمليّاً بدايتك الفعلية معاه.' },
  { topic:'طرق الدفع', kw:['طريقة الدفع','ادفع ازاي','فودافون كاش','انستاباي','تحويل بنكي','وسائل الدفع'],
    a:'الدفع بييتم برفع إيصال تحويل (فودافون كاش / انستاباي / تحويل بنكي) من صفحة الاشتراك، وبعد مراجعة المشرف بيتفعّل اشتراكك خلال وقت قصير.' },
  { topic:'الإلغاء والاسترجاع', kw:['استرجاع الفلوس','الغاء الاشتراك','لو مش عاجبني','استرداد'],
    a:'تقدر توقف تجديد اشتراكك في أي وقت من لوحتك. لتفاصيل استرجاع مبلغ حصص لم تُستخدم بعد، تواصل مع فريق الدعم على واتساب وهيوضحولك السياسة بالتفصيل.' },
  { topic:'تعويض حصة فائتة', kw:['فاتتني حصه','تعويض حصة','الغاء حصة','اجلت الحصة'],
    a:'لو حصل ظرف وفاتتك حصّة، بلّغ معلّمك أو المشرف بأسرع وقت لترتيب موعد تعويض مناسب — السياسة بتختلف شوية حسب النظام، معلّمك هيوضحهالك أول حصة.' },
  { topic:'مؤهلات المعلمين', kw:['المعلمين مؤهلين','اجازة في القران','شهادة المعلم','خبرة المعلمين'],
    a:'كل المعلمين يمرّون بفلترة وتقييم قبل الانضمام (حفظ متقن وسند/إجازة أو ما يعادلها، وخبرة في التدريس)، وبيتابعهم مشرف داخلي لضمان جودة الأداء باستمرار.' },
  { topic:'خصم الإخوة', kw:['خصم اخوه','اكتر من طفل','عندي طفلين','خصم عائلي'],
    a:'لو عندك أكتر من ابن هيسجّلوا، تواصل معنا على واتساب وهنشوفلك أنسب ترتيب للباقات — أحياناً بيكون في عروض خاصة لتسجيل أكتر من طالب من نفس الأسرة.' },
  { topic:'المتطلبات التقنية', kw:['محتاج ايه','جهاز','تطبيق','برنامج المكالمة','النت لازم يكون قوي'],
    a:'محتاج بس إنترنت مستقر ومتصفح أو تطبيق مكالمات (زي جوجل ميت أو زوم بيحدده معلمك)، وموبايل أو كمبيوتر بكاميرا ومايك. مفيش تطبيق خاص لازم تنزّله.' },
  { topic:'تغيير المعلم', kw:['تغيير المعلم','مش مرتاح للمعلم','عايز غير معلمي'],
    a:'تقدر تطلب تغيير المعلّم في أي وقت من لوحتك أو بالتواصل مع المشرف، وهيتم ترشيح معلّم بديل مناسب لمستواك ووقتك.' },
  { topic:'مرونة المواعيد', kw:['مواعيد الحصص','اقدر اغير الميعاد','مرونة الجدول','امتى الحصص'],
    a:'مواعيد الحصص بتتحدد بالاتفاق بينك وبين معلّمك مباشرة بما يناسب جدولك، وتقدر تطلب تعديلها لو ظروفك اتغيّرت.' },
  { topic:'رواية الحفظ', kw:['رواية حفص','رواية ورش','اي رواية','رواية القراءة'],
    a:'الحفظ والتلقين بيكونوا برواية حفص عن عاصم، وهي الأكثر انتشاراً. لو محتاج رواية مختلفة، اتواصل معنا للتأكد من توفّر معلّم متخصص فيها.' },
  { topic:'الشهادة بعد الإتمام', kw:['شهادة اتمام','اجازة بعد الحفظ','سيرتفيكيت'],
    a:'عند إتمام مسارك بنجاح يوثّق معلّمك ومشرفك إنجازك، وبعض المسارات (خصوصاً القرآن كاملاً) بتؤهّلك لمتابعة إجازة سند لو رغبت مستقبلاً.' },
  { topic:'سياسة الغياب', kw:['غياب كتير','لو غبت','سياسة الحضور'],
    a:'الغياب المتكرر بيتم التواصل بخصوصه من المشرف لفهم السبب ومساعدتك على الانتظام، لأن الانتظام هو أساس نجاح الحفظ.' },
  { topic:'التواصل خارج الحصة', kw:['اتواصل مع المعلم امتى','اسأل المعلم بره الحصة','شات مع المعلم'],
    a:'في شات مباشر بينك وبين معلّمك داخل لوحتك للأسئلة والمتابعة بين الحصص، غير مكالمة الحصة نفسها.' },
  { topic:'اختبار المستوى', kw:['اختبار مستوى','تقييم قبل البدء','هيحددوا مستواي ازاي'],
    a:'أول حصة مع معلّمك بتكون تقييم بسيط لمستواك ومقدار حفظك الحالي، عشان يبني خطتك على أساسه من أول يوم.' },
];
function cbNorm(t){
  return String(t||'').toLowerCase()
    .replace(/[أإآا]/g,'ا').replace(/ى/g,'ي').replace(/ة/g,'ه').replace(/[ؤئ]/g,'ي')
    .replace(/[ً-ْـ]/g,'').replace(/\s+/g,' ').trim();
}
const CB_GREETINGS = ['سلام','السلام عليكم','اهلا','هاي','هلا','مرحبا','صباح الخير','مساء الخير'];
const CB_THANKS = ['شكرا','مشكور','تسلم','جزاك الله خير','ثانكس'];
function cbIsGreeting(nq){ return CB_GREETINGS.some(g=>nq.includes(cbNorm(g))) && nq.length<25; }
function cbIsThanks(nq){ return CB_THANKS.some(g=>nq.includes(cbNorm(g))); }
let CB_LAST_TOPIC = null;
function cbMatch(q){
  const nq = cbNorm(q);
  let best=null, bestScore=0, second=null, secondScore=0;
  CHATBOT_FAQ.forEach(item=>{
    let score=0;
    item.kw.forEach(k=>{
      const nk = cbNorm(k);
      if(nq.includes(nk)) score += nk.split(' ').length; /* عبارات أطول = تطابق أدق ووزن أعلى */
    });
    if(score>bestScore){ second=best; secondScore=bestScore; best=item; bestScore=score; }
    else if(score>secondScore){ second=item; secondScore=score; }
  });
  if(bestScore>0){ CB_LAST_TOPIC = best; return { item:best, confident:bestScore>=2, alt:secondScore>0?second:null }; }
  return null;
}
function cbEsc(t){ const d=document.createElement('div'); d.textContent=String(t||''); return d.innerHTML; }
const CB_WHATSAPP_LINK = 'https://wa.me/'+CB_WHATSAPP;
let CB_STATE = 'closed'; /* closed | launcher | chat */
let CB_LAST_QUESTION='';
function cbInit(){
  const host = document.getElementById('chatbotHost');
  if(!host) return;
  host.innerHTML = `
    <button class="cb-fab" id="cbFab" onclick="cbFabClick()" aria-label="افتح قائمة التواصل" aria-haspopup="true" aria-expanded="false"><span class="cb-avatar"><img src="assets/logo.webp" alt="" loading="lazy"><span class="cb-dot">💬</span></span><span class="cb-label">تواصل معنا</span></button>
    <div class="cb-launcher" id="cbLauncher" role="menu">
      <a class="cb-launch-opt" role="menuitem" href="${CB_WHATSAPP_LINK}" target="_blank" rel="noopener"><span class="clo-ic wa" aria-hidden="true"><svg viewBox="0 0 32 32" width="19" height="19" fill="currentColor"><path d="M16.01 3C9.38 3 4 8.38 4 15.01c0 2.35.62 4.55 1.7 6.46L4 29l7.73-1.65a11.9 11.9 0 0 0 4.28.79h.01c6.63 0 12.01-5.38 12.01-12.01C28.03 8.38 22.65 3 16.01 3zm0 21.87h-.01a9.9 9.9 0 0 1-5.05-1.39l-.36-.21-3.79.81.81-3.7-.24-.38a9.86 9.86 0 0 1-1.51-5.28c0-5.47 4.45-9.92 9.93-9.92 2.65 0 5.14 1.04 7.01 2.91a9.85 9.85 0 0 1 2.9 7.01c0 5.47-4.45 9.92-9.9 9.92l.21.23zm5.44-7.43c-.3-.15-1.76-.87-2.03-.97-.27-.1-.47-.15-.67.15-.2.3-.77.97-.94 1.17-.17.2-.35.22-.65.07-.3-.15-1.25-.46-2.38-1.47-.88-.78-1.47-1.75-1.65-2.05-.17-.3-.02-.46.13-.61.13-.13.3-.35.45-.52.15-.17.2-.3.3-.5.1-.2.05-.37-.02-.52-.07-.15-.67-1.62-.92-2.22-.24-.58-.49-.5-.67-.51h-.57c-.2 0-.52.07-.79.37-.27.3-1.04 1.02-1.04 2.48s1.06 2.88 1.21 3.08c.15.2 2.09 3.19 5.07 4.47.71.31 1.26.49 1.69.62.71.23 1.36.2 1.87.12.57-.08 1.76-.72 2.01-1.41.25-.7.25-1.29.17-1.41-.07-.13-.27-.2-.57-.35z"/></svg></span><span>تواصل عبر واتساب</span></a>
      <button class="cb-launch-opt" role="menuitem" type="button" onclick="cbOpenChat()"><span class="clo-ic" aria-hidden="true">🤖</span><span>المساعد الذكي</span></button>
    </div>
    <div class="cb-panel" id="cbPanel">
      <div class="cb-head">
        <div><b>🤖 المساعد الذكي</b><span>هنا لأي سؤال عن أكاديمية الهدى</span></div>
        <button onclick="cbClose()" aria-label="إغلاق المحادثة">×</button>
      </div>
      <div class="cb-body" id="cbBody"></div>
      <div class="cb-input">
        <input id="cbInput" placeholder="اكتب سؤالك هنا..." aria-label="اكتب سؤالك هنا" onkeydown="if(event.key==='Enter')cbSend()">
        <button onclick="cbSend()" aria-label="إرسال">➤</button>
      </div>
    </div>`;
  cbAppendBot('السلام عليكم! 👋 أنا مساعد أكاديمية الهدى، اسألني عن الأنظمة، المسارات، الأسعار، أو التسجيل.');
  const b = document.getElementById('cbBody');
  const chips = CHATBOT_FAQ.slice(0,4).map(f=>`<span class="cb-chip" onclick="cbAsk('${f.kw[0]}')">${f.kw[0]}</span>`).join('');
  if(b) b.insertAdjacentHTML('beforeend', `<div class="cb-chips">${chips}</div>`);
  document.addEventListener('click', (e)=>{
    if(CB_STATE!=='launcher') return;
    if(!e.target.closest('#cbLauncher') && !e.target.closest('#cbFab')) cbSetState('closed');
  });
}
function cbSetState(state){
  CB_STATE = state;
  const fab = document.getElementById('cbFab');
  const launcher = document.getElementById('cbLauncher');
  const panel = document.getElementById('cbPanel');
  if(launcher) launcher.classList.toggle('open', state==='launcher');
  if(panel) panel.classList.toggle('open', state==='chat');
  if(fab) fab.setAttribute('aria-expanded', state!=='closed' ? 'true':'false');
}
function cbFabClick(){ cbSetState(CB_STATE==='closed' ? 'launcher' : 'closed'); }
function cbOpenChat(){ cbSetState('chat'); const i=document.getElementById('cbInput'); if(i) setTimeout(()=>i.focus(),150); }
function cbClose(){ cbSetState('closed'); }
function cbToggle(){ cbFabClick(); }
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
  const nq = cbNorm(q);
  if(cbIsGreeting(nq)){ setTimeout(()=>cbAppendBot('وعليكم السلام! 👋 اسألني عن الأنظمة، المسارات، الأسعار، أو أي حاجة عن الأكاديمية.'), 300); return; }
  if(cbIsThanks(nq)){ setTimeout(()=>cbAppendBot('العفو! 🌱 أي وقت محتاج مساعدة، أنا موجود.'), 300); return; }
  const hit = cbMatch(q);
  if(hit){
    setTimeout(()=>{
      cbAppendBot(hit.item.a);
      if(!hit.confident && hit.alt){
        const b = document.getElementById('cbBody');
        if(b) b.insertAdjacentHTML('beforeend', `<div class="cb-chips"><span class="cb-chip" onclick="cbAsk('${hit.alt.kw[0]}')">${hit.alt.kw[0]}</span></div>`);
        if(b) b.scrollTop = b.scrollHeight;
      }
    }, 300);
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

/* حالة تحميل عند الضغط على أزرار الاشتراك/التسجيل */
document.querySelectorAll('a[href*="index.html#signup"]').forEach(a=>{
  a.addEventListener('click', function(e){
    if(this.dataset.loading) return;
    e.preventDefault();
    this.dataset.loading = '1';
    this.dataset.origHtml = this.innerHTML;
    this.innerHTML = '<span class="btn-spinner" aria-hidden="true"></span> جاري التحميل...';
    this.setAttribute('aria-busy','true');
    const href = this.href;
    setTimeout(()=>{ window.location.href = href; }, 550);
  });
});

/* ============================================================
   عرض الأسعار حسب دولة الزائر — مصر بالجنيه، أي دولة تانية بالريال
   ملحوظة: سعر الصرف تقريبي وثابت في الكود (EGP_TO_SAR)، لازم يُحدَّث
   دورياً يدوياً لأن الموقع ساكن وملوش اتصال بسعر صرف حي.
   ============================================================ */
const EGP_TO_SAR = 0.076; /* تقريباً 13.2 جنيه = 1 ريال — حدّث الرقم ده لما سعر الصرف يتغيّر بشكل واضح */
function applyLocalizedPricing(){
  fetch('https://ipapi.co/json/', { cache:'no-store' })
    .then(r=>r.ok ? r.json() : null)
    .then(info=>{
      const cc = info && (info.country_code || info.country);
      if(!cc || cc === 'EG') return; /* مصر أو تعذّر التحديد: يفضل الجنيه المصري كما هو */
      document.querySelectorAll('[data-egp]').forEach(el=>{
        const egp = parseFloat(el.getAttribute('data-egp'));
        if(isNaN(egp)) return;
        const sar = Math.round(egp * EGP_TO_SAR);
        el.textContent = arNum(sar);
        const label = el.closest('[data-price-wrap]')?.querySelector('.cur-label') || el.parentElement?.querySelector('.cur-label');
        if(label) label.textContent = label.textContent.replace(/ج\.م/g, 'ر.س');
      });
    })
    .catch(()=>{ /* فشل تحديد الموقع: يفضل الجنيه المصري كإعداد افتراضي آمن */ });
}
function arNum(n){ return String(n).replace(/[0-9]/g, d=>'٠١٢٣٤٥٦٧٨٩'[d]); }
document.addEventListener('DOMContentLoaded', applyLocalizedPricing);

/* ============================================================
   جسر النيّة الموحّد — يوصّل اختيار (نظام + مسار + باقة) من أي صفحة
   تسويقية إلى تطبيق index.html، فيوجَّه الزائر تلقائياً لخطوة
   الاستبيان/الدفع الصحيحة بعد التسجيل أو الدخول، بدل ما يقع في
   لوحة فاضية تايه فيها.
   يخزّن نفس الشكل اللي يقرأه index.html بالظبط: pending_intent
   ============================================================ */
function goEnroll(pathId, system, sessions, fee, type){
  const intent = {
    pathId: pathId || null,
    type: type || 'full',
    plan: { type: system || 'rasokh', sessions: sessions || null, fee: fee || null },
    ts: Date.now()
  };
  try{ sessionStorage.setItem('pending_intent', JSON.stringify(intent)); }catch(e){}
  window.location.href = 'index.html#signup';
}

/* ============================================================
   قسم "اختر نظامك وباقتك" في نهاية صفحة كل مسار — مكوّن واحد
   مشترك يُستخدم في كل صفحات المسارات الستة بدل تكرار نفس الأقسام.
   لو الزائر جاي من صفحة نظام معيّن (?system=rasokh|flexible) يظهر
   له الباقات الثلاثة مباشرة، ولو جاي من الصفحة الرئيسية يختار
   نظامه الأول.
   ============================================================ */
const MKT_SYSTEMS = {
  rasokh:{ name:'نظام رسوخ', desc:'خمسة حصون يومية — الأكثر شمولاً وضبطاً',
    icon:'<svg viewBox="0 0 24 24" width="30" height="30" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l8 3.5v5.2c0 5-3.4 8.4-8 9.8-4.6-1.4-8-4.8-8-9.8V6.5z"/><path d="M8.5 12.2l2.3 2.3 4.5-4.7"/></svg>',
    packages:[ {sessions:4,fee:450}, {sessions:8,fee:700,popular:true}, {sessions:12,fee:850} ] },
  flexible:{ name:'النظام المرن', desc:'ثلاثة حصون أساسية — أخف وأكثر مرونة',
    icon:'<svg viewBox="0 0 24 24" width="30" height="30" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M9 3h3.5a1 1 0 0 1 1 1v2a2 2 0 1 0 0 4v2a1 1 0 0 1-1 1H10a2 2 0 1 1-4 0H4.5a1 1 0 0 1-1-1V9a2 2 0 1 0 0-4V3.5a1 1 0 0 1 1-1H8a2 2 0 0 1 1 0"/><path d="M14 15h5.5a1 1 0 0 1 1 1V20a1 1 0 0 1-1 1H14"/></svg>',
    packages:[ {sessions:4,fee:400}, {sessions:8,fee:650,popular:true}, {sessions:12,fee:800} ] },
};
function pkgLabel(n){ return arNum(n)+' '+(n===12?'حصة':'حصص')+' شهرياً'; }
function initPathEnroll(){
  const box = document.getElementById('pathEnrollBox');
  if(!box) return;
  const pathId = box.closest('[data-path-id]')?.dataset.pathId;
  const params = new URLSearchParams(location.search);
  const sys = params.get('system');
  if(sys && MKT_SYSTEMS[sys]){ renderPathPackages(box, pathId, sys); mountFunnelStepper(2); }
  else { renderPathSystemChooser(box, pathId); mountFunnelStepper(1); }
}
function renderPathSystemChooser(box, pathId){
  box.innerHTML = `
    <div class="sec-head reveal">
      <div class="tag">الاشتراك</div>
      <h2>اختر نظامك لهذا المسار</h2>
      <p>مسار واحد، ونظامان لإتقانه — اختر ما يناسب وتيرتك.</p>
    </div>
    <div class="systems-grid">
      ${Object.keys(MKT_SYSTEMS).map(key=>{ const s=MKT_SYSTEMS[key]; return `
      <div class="system-card sys-choice reveal" onclick="choosePathSystem('${pathId}','${key}')">
        <div class="sc-icon sys-choice-ic">${s.icon}</div>
        <div class="sc-body">
          <h3>${s.name}</h3>
          <p class="sc-desc">${s.desc}</p>
          <span class="btn-primary" style="width:100%;justify-content:center;display:flex">اختر ${s.name} لهذا المسار</span>
        </div>
      </div>`; }).join('')}
    </div>`;
  revealBoxNow(box);
}
function choosePathSystem(pathId, sys){
  const url = new URL(location.href);
  url.searchParams.set('system', sys);
  history.replaceState(null, '', url);
  const box = document.getElementById('pathEnrollBox');
  renderPathPackages(box, pathId, sys);
  mountFunnelStepper(2);
  box.scrollIntoView({behavior:'smooth', block:'start'});
}
function renderPathPackages(box, pathId, sys){
  const s = MKT_SYSTEMS[sys];
  box.innerHTML = `
    <div class="sec-head reveal">
      <div class="tag">${s.name}</div>
      <h2>باقات ${s.name} الشهرية لهذا المسار</h2>
      <p>مدة الحصة 30 دقيقة، وكل الباقات تشمل تقارير يومية لوليّ الأمر. <a href="javascript:void(0)" onclick="clearPathSystem()" style="color:var(--emerald);font-weight:700">تغيير النظام ←</a></p>
    </div>
    <div class="pricing-grid">
      ${s.packages.map(pk=>`
      <div class="price-card ${pk.popular?'pop':''} reveal">
        <div class="pc-name">${pkgLabel(pk.sessions)}</div>
        <div class="pc-price"><span class="amt" data-egp="${pk.fee}">${pk.fee}</span><small class="cur-label"> ج.م/شهر</small></div>
        <ul class="pc-feats">
          <li><span class="ck">✓</span> حلقة فرديّة خاصّة (30 دقيقة)</li>
          <li><span class="ck">✓</span> متابعة وتقارير يومية</li>
          <li><span class="ck">✓</span> معلّم مخصّص حسب مستواك</li>
        </ul>
        <a class="btn-primary" href="javascript:void(0)" onclick="goEnroll('${pathId}','${sys}',${pk.sessions},${pk.fee},'full')">اشترك الآن</a>
      </div>`).join('')}
    </div>
    <p style="text-align:center;margin-top:20px;font-size:13.5px;color:var(--ink-soft)">الاشتراك أعلى من إمكانياتك؟ <a href="javascript:void(0)" onclick="goEnroll('${pathId}','${sys}',${s.packages[0].sessions},${s.packages[0].fee},'subsidy')" style="color:var(--emerald);font-weight:700">اطلب تخفيضاً</a></p>`;
  applyLocalizedPricing();
  revealBoxNow(box);
}
/* العناصر اللي بتتحقن ديناميكياً بعد تحميل الصفحة (زي الباقات هنا) بيفوتها
   مراقب الظهور (IntersectionObserver) اللي بيشتغل مرة واحدة وقت تحميل السكربت،
   فتفضل بـ opacity:0 للأبد. بنظهرها فوراً بدل ما نستنى تمريرة مايجيش أبداً. */
function revealBoxNow(box){
  box.querySelectorAll('.reveal').forEach(el=>el.classList.add('in'));
}
function clearPathSystem(){
  const url = new URL(location.href);
  url.searchParams.delete('system');
  history.replaceState(null, '', url);
  initPathEnroll();
}
document.addEventListener('DOMContentLoaded', initPathEnroll);

/* ============================================================
   شريط الرحلة المرئي — يظهر في كل صفحات القمع (نظام/مسار)
   ليطمئن الزائر إنه في مكانه الصحيح ويوريه الخطوات الباقية،
   نفس منطق شريط "sj-steps" الموجود جوّه لوحة الطالب بـ index.html.
   ============================================================ */
const FUNNEL_STEPS = ['اختر نظامك','اختر مسارك','اختر باقتك','سجّل دخولك','ادفع','اختر معلمك'];
const FS_CHECK = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="M20 6L9 17l-5-5"/></svg>';
function mountFunnelStepper(activeIdx){
  const el = document.getElementById('funnelStepper');
  if(!el) return;
  el.innerHTML = `<div class="fs-track">${FUNNEL_STEPS.map((label,i)=>{
    const state = i<activeIdx?'done':(i===activeIdx?'active':'');
    const dot = i<activeIdx?FS_CHECK:(i+1);
    const line = i<FUNNEL_STEPS.length-1?`<div class="fs-line ${i<activeIdx?'done':''}"></div>`:'';
    return `<div class="fs-step ${state}"><div class="fs-dot">${dot}</div><span>${label}</span></div>${line}`;
  }).join('')}</div>`;
}
function initFunnelStepper(){
  const el = document.getElementById('funnelStepper');
  if(!el || el.dataset.step===undefined) return;
  mountFunnelStepper(+el.dataset.step);
}
document.addEventListener('DOMContentLoaded', initFunnelStepper);
