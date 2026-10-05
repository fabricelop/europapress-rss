import fs from "node:fs";

const html=fs.readFileSync("vercel-webhook/money-control/index.html","utf8");
const slice=(a,b)=>{
  const i=html.indexOf(a),j=html.indexOf(b,i);
  if(i<0||j<0)throw new Error("No se puede extraer "+a);
  return html.slice(i,j);
};
const functions=[
  slice("function duplicateAssessment(","function resolveUpdateAccount("),
  slice("function semanticMovementImpact(","function renderIngestPreview()")
].join("\n");

const harness=`
const ACCOUNTS=[
  {id:1,name:"BBVA",balance:1029.18},
  {id:2,name:"CI Comun",balance:6593.01}
];
let TXS=[
  {id:101,gid:"LEGACY:BBVA:200",accountId:1,accountName:"BBVA",date:"2026-10-02",amount:-200,description:"Transferencia realizada Fabrice lopez illac",payee:"Fabrice lopez illac",kind:"TRANSFER_OUT"}
];
function allTxs(){return TXS}
function dayDiff(a,b){return Math.round(Math.abs(new Date(a+"T12:00:00")-new Date(b+"T12:00:00"))/86400000)}
function norm(v){return String(v||"").normalize("NFD").replace(/[\\u0300-\\u036f]/g,"").toUpperCase().replace(/\\b(RECIBO|SEPA|PAGO|TARJETA)\\b/g," ").replace(/[^A-Z0-9]+/g," ").trim().replace(/\\s+/g," ")}
function sim(a,b){a=norm(a);b=norm(b);if(!a||!b)return 0;if(a===b)return 1;const A=new Set(a.split(" ")),B=new Set(b.split(" "));let inter=0;A.forEach(x=>B.has(x)&&inter++);const j=inter/Math.max(1,new Set([...A,...B]).size);const bg=s=>{const z=new Set();for(let i=0;i<s.length-1;i++)z.add(s.slice(i,i+2));return z};const X=bg(a),Y=bg(b);let bi=0;X.forEach(x=>Y.has(x)&&bi++);const dice=2*bi/Math.max(1,X.size+Y.size);return Math.max(j,dice)}
function parseDateInput(s){s=String(s||"").trim();let m=s.match(/^(\\d{2})\\/(\\d{2})\\/(\\d{4})$/);if(m)return m[3]+"-"+m[2]+"-"+m[1];if(/^\\d{4}-\\d{2}-\\d{2}$/.test(s))return s;return null}
function semanticAccount(name,fallbackId=null){if(name){const n=norm(name);return ACCOUNTS.find(a=>norm(a.name)===n)||null}return ACCOUNTS.find(a=>a.id===fallbackId)||null}
function effectiveBalance(a){return Number(a.balance)}
function todayIso(){return "2026-10-05"}
${functions}

function assert(cond,msg){if(!cond)throw new Error(msg)}

const interp={
  summary:"Transferencia recibida en CI Comun desde BBVA; la salida de BBVA ya existe.",
  movements:[{
    account:"BBVA",
    date:"2026-10-05",
    amount:-200,
    description:"Transferencia BBVA a CI Comun",
    kind:"transfer",
    destinationAccount:"CI Comun",
    sourceDate:"2026-10-02",
    destinationDate:"2026-10-05",
    sourceDescription:"Transferencia realizada Fabrice lopez illac",
    destinationDescription:"TRANSF CTA DE:FABRICE LOPEZ ILL",
    existingSide:"source",
    confidence:1,
    note:"El usuario indica que la salida de BBVA ya estaba registrada."
  }],
  balances:[{account:"CI Comun",date:"2026-10-05",balance:6793.01,confidence:1,note:"Saldo observado"}],
  instructions:[],
  warnings:[]
};
const p=buildIngestPreview(interp,null);
const m=p.movements[0];
assert(m.status==="new","La transferencia debe ser aplicable");
assert(m.sourceMatch?.gid==="LEGACY:BBVA:200","Debe reutilizar el -200 existente de BBVA");
assert(m.createSource===false,"No debe crear otro -200 en BBVA");
assert(m.createDestination===true,"Debe crear solo el +200 en CI Comun");
assert(m.sourceDate==="2026-10-02","Debe conservar la fecha de la pata BBVA");
assert(m.destinationDate==="2026-10-05","Debe conservar la fecha de la pata CI Comun");
assert(p.balances[0].status==="matched","El saldo 6.793,01 debe cuadrar tras añadir solo +200");
assert(Math.abs(p.balances[0].diff)<0.001,"No debe proponer Ajuste cuando el saldo cuadra");

TXS=[];
const q=buildIngestPreview(interp,null);
assert(q.movements[0].status==="probable","Si el usuario dice que BBVA ya existe pero no se encuentra, debe bloquearse");
assert(q.movements[0].createSource===false&&q.movements[0].createDestination===false,"No debe inventar ninguna pata si falta la supuestamente existente");

const bothNew=JSON.parse(JSON.stringify(interp));
bothNew.movements[0].existingSide="none";
bothNew.balances=[];
const r=buildIngestPreview(bothNew,null);
assert(r.movements[0].status==="new"&&r.movements[0].createSource&&r.movements[0].createDestination,"Una transferencia realmente nueva debe crear ambas patas");

console.log("MONEY_CONTROL_PARTIAL_TRANSFER_TEST_OK");
`;
new Function(harness)();
