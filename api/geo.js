// Vercel Edge Function — بيرجّع دولة الزائر مباشرة من نفس الطلب (Vercel بتحدّدها تلقائياً
// لكل طلب، من غير أي خدمة خارجية، من غير أي حد على عدد الطلبات، وبسرعة فورية).
export const config = { runtime: 'edge' };

export default function handler(req) {
  const country = req.headers.get('x-vercel-ip-country') || null;
  return new Response(JSON.stringify({ country }), {
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
      'access-control-allow-origin': '*',
    },
  });
}
