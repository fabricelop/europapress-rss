export default async function handler(req,res){
  try{
    const token=process.env.TELEGRAM_BOT_TOKEN;
    const secret=process.env.TELEGRAM_WEBHOOK_SECRET;
    if(!token||!secret) return res.status(500).json({ok:false,error:"telegram env missing"});
    const webhook="https://europapress-rss.vercel.app/api/telegram-webhook";
    const r=await fetch(`https://api.telegram.org/bot${token}/setWebhook`,{
      method:"POST",
      headers:{"content-type":"application/json"},
      body:JSON.stringify({
        url:webhook,
        secret_token:secret,
        allowed_updates:["callback_query","message"],
        drop_pending_updates:false
      })
    });
    const set=await r.json();
    const i=await fetch(`https://api.telegram.org/bot${token}/getWebhookInfo`);
    const info=await i.json();
    return res.status(set.ok?200:500).json({ok:!!set.ok,set,webhook_info:{ok:info.ok,url:info?.result?.url||"",pending_update_count:info?.result?.pending_update_count||0,last_error_message:info?.result?.last_error_message||null}});
  }catch(e){return res.status(500).json({ok:false,error:String(e?.message||e)})}
}
