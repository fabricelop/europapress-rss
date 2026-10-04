import { generateText } from "ai";
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

function outputText(x){
  if(typeof x?.output_text==="string"&&x.output_text.trim())return x.output_text.trim();
  const parts=[];
  for(const item of x?.output||[]){
    for(const c of item?.content||[]){
      if(typeof c?.text==="string")parts.push(c.text);
      else if(typeof c?.output_text==="string")parts.push(c.output_text);
    }
  }
  return parts.join("").trim();
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
          confidence:{type:"number"},
          note:{type:"string"}
        },
        required:["account","date","amount","description","kind","destinationAccount","confidence","note"]
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

    const instructions=[
      "You interpret personal-finance updates for Money Control.",
      "The user may write in Spanish, French or English, paste arbitrary bank tables, semi-natural text, explanations, corrections, or attach a screenshot.",
      "Infer structure from meaning, not from fixed columns.",
      "Known accounts are provided. Prefer their exact names. If the user does not name an account and a default account is supplied, use that default account.",
      "Never invent a movement, amount, date, account or balance not supported by the input.",
      "Relative dates such as hoy, ayer, today, yesterday must be resolved using the supplied current date.",
      "Spanish number formatting uses dot for thousands and comma for decimals.",
      "Expenses must have negative amounts and income positive.",
      "If the user supplies only a final/current balance, return it only in balances. Do NOT invent an adjustment movement; Money Control computes any residual adjustment itself.",
      "If a bank row contains both operation date and value date, use operation date unless the user explicitly says otherwise.",
      "If a screenshot/table has a SALDO column, those are observed balances, not movements.",
      "Do not duplicate the same visible transaction just because it appears in both text and image.",
      "For transfers between known accounts use kind=transfer, source account in account, destination in destinationAccount, and amount as a negative number representing money leaving the source.",
      "Return dates as YYYY-MM-DD. Confidence is 0..1.",
      "If uncertain, preserve the candidate with lower confidence and explain in warnings; do not fabricate certainty."
    ].join("\n");

    const context=[
      "Current date: "+today,
      "Default account: "+(defaultAccount||"(none)"),
      "Known accounts:",
      ...accounts.map(a=>"- "+a.name+" ["+a.group+"]")
    ].join("\n");

    const content=[
      {type:"input_text",text:context+"\n\nUser input:\n"+(userText||"(image only)")}
    ];
    if(imageDataUrl)content.push({type:"input_image",image_url:imageDataUrl,detail:"high"});

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
