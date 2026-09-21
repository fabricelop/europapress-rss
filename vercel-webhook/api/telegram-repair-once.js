export default async function handler(req,res){
    const key=String(req.query?.key||"");
    if(key!=="tt-repair-20260921-1210") return res.status(404).json({ok:false});
    const token=process.env.TELEGRAM_BOT_TOKEN;
    const secret=process.env.TELEGRAM_WEBHOOK_SECRET;
    if(!token||!secret) return res.status(500).json({ok:false,error:"missing env"});
    const base=`https://api.telegram.org/bot${token}`;
    const url="https://europapress-rss.vercel.app/api/telegram-webhook";
    const r=await fetch(base+"/setWebhook",{method:"POST",headers:{"content-type":"application/json"},body:JSON.stringify({
      url,secret_token:secret,allowed_updates:["message","callback_query"],drop_pending_updates:false
    })});
    const set=await r.json();
    const g=await fetch(base+"/getWebhookInfo");
    const info=await g.json();
    return res.status(r.ok?200:502).json({set,info:{url:info?.result?.url||"",pending_update_count:info?.result?.pending_update_count||0,last_error_message:info?.result?.last_error_message||null}});
  }