'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {spawnSync}=require('node:child_process');
const source='https://raw.githubusercontent.com/fabricelop/europapress-rss/98c529bc3ff8eb044c8f2b810b01b83b5f280c12/windows/';
const files=[
 ['TTendenciasWebImages.cjs','bc94a77f3a6516cce4e1b3feb21e3b7ae354b30e278f379d53fc8d12125eb1c4','0fa7529a5dcc9696ac9562bd4ffccf268d87c151cb1b770772c8d0c10520b0e5'],
 ['TTiTTularesWebImages.cjs','e442633ab0c7e0fd8a773607413361bb764f391aae8c1ce6f2181091c50ffdc0','738dd97e84bacba93ac93407b663ec5de83a02941e15abda300279bfec7abdb5']
];
const hash=b=>crypto.createHash('sha256').update(b).digest('hex');
function validateCurrent(bytes,oldHash,newHash){
 if(![oldHash,newHash].includes(hash(bytes)))throw Error('VERSION_LOCAL_NO_RECONOCIDA');
 if(!bytes.toString('utf8').includes("return {status:'waiting',reason:'manual_approval_required'}"))throw Error('FALTA_PAUSA_ASOCIACION');
}
async function main(){
 if(process.platform!=='win32')throw Error('WINDOWS_REQUIRED');
 const base='C:\\TTiTTulares',staged=[];
 const backup=path.join(base,'user-bubble-backup-'+Date.now());fs.mkdirSync(backup);
 for(const [name,oldHash,newHash] of files){
  const dest=path.join(base,name),original=fs.readFileSync(dest);validateCurrent(original,oldHash,newHash);
  const response=await fetch(source+name,{signal:AbortSignal.timeout(30000)});if(!response.ok)throw Error('DOWNLOAD_HTTP_'+response.status);
  const bytes=Buffer.from(await response.arrayBuffer());if(hash(bytes)!==newHash)throw Error('DESCARGA_HASH_INVALIDO');
  validateCurrent(bytes,oldHash,newHash);
  const temp=dest+'.bubble-update-'+process.pid+'.cjs';fs.writeFileSync(temp,bytes);
  const check=spawnSync(process.execPath,['--check',temp],{windowsHide:true,timeout:15000});if(check.status!==0)throw Error('SINTAXIS_INVALIDA');
  fs.writeFileSync(path.join(backup,name),original);staged.push({dest,temp,name,oldHash,newHash});
 }
 // Validate both destinations again before replacing either; no browser or job is stopped.
 for(const item of staged)validateCurrent(fs.readFileSync(item.dest),item.oldHash,item.newHash);
 const changed=[];
 try{for(const item of staged){fs.renameSync(item.temp,item.dest);changed.push(item)}}
 catch(e){for(const item of changed){const tmp=item.dest+'.rollback-'+process.pid;fs.copyFileSync(path.join(backup,item.name),tmp);fs.renameSync(tmp,item.dest)}throw e}
 console.log('LECTORES ACTUALIZADOS: Noticias y Tendencias. Asociacion automatica sigue pausada.');
 console.log('Tarea oculta, receptor y generacion conservados. Backup: '+backup);
 console.log('La recepcion real debe comprobarse en el siguiente ciclo; este instalador no aprueba ni publica.');
}
module.exports={validateCurrent,hash};
if(require.main===module)main().catch(e=>{console.error('ACTUALIZACION_NO_COMPLETADA: '+e.message);process.exitCode=1});
