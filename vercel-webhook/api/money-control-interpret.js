const MAX_TEXT=24000;
const MAX_IMAGE_CHARS=5_500_000;
const MODEL="openai/gpt-5.6-sol";

function reply(res,status,body){
  res.status(status);
  res.setHeader("content-type","application/json; charset=utf-8");
  res.setHeader("cache-control","no-store");
  res.setHeader("x-content-type-options","nosniff");
  return res.end(JSON.stringify(body));
}

function cleanAccounts(input){
  if(!Array.isArray(input))return[];
  return input.slice(0,100).map(a=>({
    id:String(a?.id??"").slice(0,80),
    name:String(a?.name??"").slice(0,160),
    group:String(a?.group??"").slice(0,80)
  })).filter(a=>a.name);
}

function norm(v){
  return String(v||"").normalize("NFD").replace(/[\u0300-\u036f]/g,"").toUpperCase().replace(/[^A-Z0-9]+/g," ").trim().replace(/\s+/g," ");
}

function parseMoneyInput(v){
  let x=String(v||"").replace(/\u00a0/g," ").trim().replace(/\b(EUR|USD|GBP|CHF)\b/gi,"").replace(/[€$£]/g,"").replace(/\s/g,"");
  if(!x)return null;
  if(x.includes(","))x=x.replace(/\./g,"").replace(",",".");
  else if(/^[-+]?\d{1,3}(\.\d{3})+$/.test(x))x=x.replace(/\./g,"");
  const n=Number(x);
  return Number.isFinite(n)?n:null;
}

function resolveKnownAccount(label,accounts,defaultAccount=""){
  const wanted=norm(label||defaultAccount);
  if(!wanted)return null;
  const exact=accounts.filter(a=>norm(a.name)===wanted);
  if(exact.length===1)return exact[0];
  const fuzzy=accounts.filter(a=>{
    const n=norm(a.name);
    return n&&(n.includes(wanted)||wanted.includes(n));
  });
  return fuzzy.length===1?fuzzy[0]:null;
}

function parseSimpleBalances(text,accounts,defaultAccount,today){
  const src=String(text||"").replace(/\u00a0/g," ").trim();
  if(!src)return null;
  const amount="([+-]?(?:\\d{1,3}(?:\\.\\d{3})+(?:,\\d{1,2})?|\\d+[.,]\\d{1,2}|\\d+))";
  const patterns=[
    new RegExp("(?:el\\s+)?saldo\\s+(?:actual\\s+)?(?:de|en)?\\s*([^=;:\\n]+?)\\s*(?:ahora\\s*)?(?:=|:|\\bes\\b)\\s*"+amount+"\\s*(?:€|eur)?","gi"),
    new RegExp("(?:^|[.;]\\s*|\\n+)de\\s+([^=;:\\n]+?)\\s*(?:ahora\\s*)?(?:=|:|\\bes\\b)\\s*"+amount+"\\s*(?:€|eur)?","gi")
  ];
  const balances=[],ranges=[],seen=new Set();
  for(const re of patterns){
    let m;
    while((m=re.exec(src))){
      const account=resolveKnownAccount(m[1],accounts,"");
      const balance=parseMoneyInput(m[2]);
      if(!account||balance===null)continue;
      const key=account.id+"|"+balance;
      if(!seen.has(key)){
        seen.add(key);
        balances.push({account:account.name,date:today,balance,confidence:1,note:"Saldo indicado por el usuario"});
      }
      ranges.push([m.index,m.index+m[0].length]);
    }
  }
  if(defaultAccount){
    const re=new RegExp("(?:el\\s+)?(?:saldo|balance)\\s*(?:actual\\s*)?(?:=|:|\\bes\\b)\\s*"+amount+"\\s*(?:€|eur)?","gi");
    let m;
    while((m=re.exec(src))){
      if(ranges.some(([a,b])=>m.index<b&&m.index+m[0].length>a))continue;
      const account=resolveKnownAccount("",accounts,defaultAccount);
      const balance=parseMoneyInput(m[1]);
      if(!account||balance===null)continue;
      const key=account.id+"|"+balance;
      if(!seen.has(key)){
        seen.add(key);
        balances.push({account:account.name,date:today,balance,confidence:1,note:"Saldo indicado por el usuario"});
      }
      ranges.push([m.index,m.index+m[0].length]);
    }
  }
  if(!balances.length)return null;
  let rest=src.split("");
  for(const [a,b] of ranges)for(let i=a;i<b;i++)rest[i]=" ";
  const residual=rest.join("")
    .replace(/[.;,\s]+/g," ")
    .replace(/\b(?:y|e|and|et|tambien|también)\b/gi," ")
    .replace(/\s+/g," ")
    .trim();
  if(residual)return null;
  return{
    summary:"He entendido una actualización de saldos.",
    movements:[],
    balances,
    instructions:[],
    warnings:[]
  };
}

const schema={
  type:"object",
  additionalProperties:false,
  properties:{
    summary:{type:"string"},
    movements:{
      type:"array",
      items:{
        type:"object",
        additionalProperties:false,
        properties:{
          account:{type:"string"},
          date:{type:"string"},
          amount:{type:"number"},
          description:{type:"string"},
          kind:{type:"string",enum:["income","expense","transfer","unknown"]},
          destinationAccount:{type:"string"},
          sourceDate:{type:"string"},
          destinationDate:{type:"string"},
          sourceDescription:{type:"string"},
          destinationDescription:{type:"string"},
          existingSide:{type:"string",enum:["none","source","destination","both","unknown"]},
          confidence:{type:"number"},
          note:{type:"string"}
        },
        required:["account","date","amount","description","kind","destinationAccount","sourceDate","destinationDate","sourceDescription","destinationDescription","existingSide","confidence","note"]
      }
    },
    balances:{
      type:"array",
      items:{
        type:"object",
        additionalProperties:false,
        properties:{
          account:{type:"string"},
          date:{type:"string"},
          balance:{type:"number"},
          confidence:{type:"number"},
          note:{type:"string"}
        },
        required:["account","date","balance","confidence","note"]
      }
    },
    instructions:{
      type:"array",
      items:{
        type:"object",
        additionalProperties:false,
        properties:{
          type:{type:"string",enum:["note","correction","ignore","rename","other"]},
          account:{type:"string"},
          text:{type:"string"},
          confidence:{type:"number"}
        },
        required:["type","account","text","confidence"]
      }
    },
    warnings:{type:"array",items:{type:"string"}}
  },
  required:["summary","movements","balances","instructions","warnings"]
};

export default async function handler(req,res){
  if(req.method!=="POST"){
    res.setHeader("allow","POST");
    return reply(res,405,{ok:false,error:"method_not_allowed"});
  }
  try{
    let body=req.body;
    if(typeof body==="string")body=JSON.parse(body);
    if(!body||typeof body!=="object")return reply(res,400,{ok:false,error:"invalid_body"});

    const userText=String(body.text||"").slice(0,MAX_TEXT).trim();
    const imageDataUrl=String(body.imageDataUrl||"").trim();
    if(!userText&&!imageDataUrl)return reply(res,400,{ok:false,error:"empty_input"});
    if(imageDataUrl&&(!/^data:image\/(png|jpeg|jpg|webp);base64,/i.test(imageDataUrl)||imageDataUrl.length>MAX_IMAGE_CHARS)){
      return reply(res,413,{ok:false,error:"image_too_large_or_invalid"});
    }

    const accounts=cleanAccounts(body.accounts);
    const today=/^\d{4}-\d{2}-\d{2}$/.test(String(body.today||""))?String(body.today):new Date().toISOString().slice(0,10);
    const defaultAccount=String(body.defaultAccount||"").slice(0,160);

    if(userText&&!imageDataUrl){
      const simple=parseSimpleBalances(userText,accounts,defaultAccount,today);
      if(simple)return reply(res,200,{ok:true,model:"deterministic-balance-parser",interpretation:simple});
    }

    const instructions=[
      "You interpret personal-finance updates for Money Control.",
      "The user may write in Spanish, French or English, paste arbitrary bank tables, semi-natural text, explanations, corrections, or attach a screenshot.",
      "Infer structure from meaning, not from fixed columns.",
      "Known accounts are provided. Prefer their exact names. If the user does not name an account and a default account is supplied, use that default account.",
      "Never invent a movement, amount, date, account or balance not supported by the input.",
      "Relative dates such as hoy, ayer, today, yesterday must be resolved using the supplied current date.",
      "Amounts may use comma or dot as decimal separator. Interpret 73.24 as seventy-three euros and twenty-four cents; interpret 3.489,49 as Spanish thousands plus decimals.",
      "Expenses must have negative amounts and income positive.",
      "If the user supplies only a final/current balance, return it only in balances. Do NOT invent an adjustment movement; Money Control computes any residual adjustment itself.",
      "If a bank row contains both operation date and value date, use operation date unless the user explicitly says otherwise.",
      "If a screenshot/table has a SALDO column, those are observed balances, not movements.",
      "Do not duplicate the same visible transaction just because it appears in both text and image.",
      "Distinguish NEW DATA from CONTEXT/HISTORY. Rows introduced with phrases such as 'ya estaba', 'ya existe', 'estos son los últimos movimientos', 'historial', 'como referencia' or equivalent are evidence about movements already present in Money Control, not additional new movements to import.",
      "For transfers between known accounts use kind=transfer, source account in account, destination in destinationAccount, and amount as a negative number representing money leaving the source.",
      "For every transfer, sourceDate and destinationDate are the dates for each bank side when known; otherwise use the main transfer date. sourceDescription and destinationDescription are the bank-side concepts when known; otherwise use the general description.",
      "For non-transfer movements set sourceDate, destinationDate, sourceDescription and destinationDescription to empty strings and existingSide='none'.",
      "If the user explicitly says one side of a transfer already exists in Money Control, encode it in existingSide: source, destination, or both. Use existingSide='unknown' only when the user says a side exists but it is unclear which one. Otherwise use 'none'.",
      "Example: user says a +200 row arrived in CI Comun from BBVA and says the -200 BBVA movement was already there. Return ONE transfer BBVA -> CI Comun, existingSide='source'; do not return the historical BBVA row as a separate expense.",
      "An incoming bank-table row can have a positive amount even though transfer.amount must be negative because it represents money leaving the source; infer direction from the user's prose and account context.",
      "Return dates as YYYY-MM-DD. Confidence is 0..1.",
      "If uncertain, preserve the candidate with lower confidence and explain in warnings; do not fabricate certainty."
    ].join("\n");

    const context=[
      "Current date: "+today,
      "Default account: "+(defaultAccount||"(none)"),
      "Known accounts:",
      ...accounts.map(a=>"- "+a.name+" ["+a.group+"]")
    ].join("\n");

    const aiContent=[
      {type:"text",text:context+"\n\nUser input:\n"+(userText||"(image only)")}
    ];
    if(imageDataUrl)aiContent.push({type:"image",image:imageDataUrl});

    const prompt=[
      instructions,
      "",
      "Return ONLY valid JSON matching exactly this shape:",
      JSON.stringify(schema),
      "",
      "Do not wrap the JSON in markdown fences."
    ].join("\n");

    const {generateText}=await import("ai");
    const result=await generateText({
      model:MODEL,
      instructions:prompt,
      messages:[{role:"user",content:aiContent}],
      reasoning:"medium",
      maxOutputTokens:3000
    });

    let text=String(result.text||"").trim();
    if(!text)return reply(res,502,{ok:false,error:"empty_interpretation"});
    text=text.replace(/^\x60\x60\x60(?:json)?\s*/i,"").replace(/\s*\x60\x60\x60$/,"").trim();
    let parsed;
    try{parsed=JSON.parse(text)}catch(e){
      console.error("money-control-interpret json",text.slice(0,800));
      return reply(res,502,{ok:false,error:"invalid_interpretation"});
    }
    return reply(res,200,{ok:true,model:MODEL,interpretation:parsed});
  }catch(error){
    console.error("money-control-interpret",error);
    return reply(res,500,{ok:false,error:"interpretation_error",detail:String(error?.message||error).slice(0,240)});
  }
}
