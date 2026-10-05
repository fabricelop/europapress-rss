import fs from "node:fs";
import handler from "../../vercel-webhook/api/money-control-interpret.js";

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

function endpointAssert(cond,msg){if(!cond)throw new Error(msg)}
const endpointNorm=v=>String(v||"").normalize("NFD").replace(/[\u0300-\u036f]/g,"").toUpperCase().replace(/[^A-Z0-9]+/g," ").trim().replace(/\s+/g," ");

const exactText="Transferencia que viene de la cuenta de BBVA, hacia CI Comun: FECHA DE OPERACIÓN\tCONCEPTO\tFECHA VALOR\tIMPORTE\tSALDO\n05/10/2026\tTRANSF CTA DE:FABRICE LOPEZ ILL\t05/10/2026\t200,00 EUR\t6.793,01 EUR  Ya estaba en los movimientos de bbva. Estos son los ultimos de bbva: Resultado de la búsqueda\nFecha\nConcepto\nFraccionar\t\nImporte\nSaldo\nNotas\t\nArchivos adjuntos\t\nAcciones\t\nDetalle\n05 octubreOct\n2026\nAdeudo mensual de tarjeta\n4552232382975194\n−\n100\n,\n99\nEUR\n− 100,99 EUR\n1.029\n,\n18\nEUR\n1.029,18 EUR\n\n02 octubreOct\n2026\nTransferencia realizada\nFabrice lopez illac\n−\n200\n,\n00\nEUR\n− 200,00 EUR\n1.130\n,\n17\nEUR\n1.130,17 EUR";
let endpointStatus=0, endpointBody="";
const req={method:"POST",body:{text:exactText,today:"2026-10-05",defaultAccount:"",accounts:[{id:"1",name:"BBVA",group:"Cuentas"},{id:"2",name:"CI Comun",group:"Cuentas"}]}};
const res={status(n){endpointStatus=n;return this},setHeader(){},end(v){endpointBody=String(v||"");return this}};
await handler(req,res);
endpointAssert(endpointStatus===200,"El endpoint local debe responder 200, obtuvo "+endpointStatus+" "+endpointBody);
const payload=JSON.parse(endpointBody);
endpointAssert(payload.model==="deterministic-transfer-parser","Debe usar deterministic-transfer-parser, obtuvo "+payload.model);
const tm=(payload.interpretation.movements||[])[0];
endpointAssert(tm?.kind==="transfer","Debe devolver transferencia");
endpointAssert(endpointNorm(tm.account)==="BBVA"&&endpointNorm(tm.destinationAccount)==="CI COMUN","Debe interpretar BBVA -> CI Comun");
endpointAssert(Math.abs(Number(tm.amount))===200,"Debe interpretar 200 EUR");
endpointAssert(tm.existingSide==="source","Debe marcar la pata BBVA como existente");
endpointAssert(tm.sourceDate==="2026-10-02","Debe detectar 02/10/2026 como fecha origen, obtuvo "+tm.sourceDate);
endpointAssert(tm.destinationDate==="2026-10-05","Debe detectar 05/10/2026 como fecha destino");
const tb=(payload.interpretation.balances||[])[0];
endpointAssert(tb&&endpointNorm(tb.account)==="CI COMUN"&&Math.abs(Number(tb.balance)-6793.01)<0.001,"Debe detectar saldo CI Comun 6.793,01");
console.log("MONEY_CONTROL_ENDPOINT_TRANSFER_TEST_OK");
