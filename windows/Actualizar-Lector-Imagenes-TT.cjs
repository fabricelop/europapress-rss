'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {spawnSync}=require('node:child_process');
const source='https://raw.githubusercontent.com/fabricelop/europapress-rss/98c529bc3ff8eb044c8f2b810b01b83b5f280c12/windows/';
const files=[
 ['TTendenciasWebImages.cjs','595425bcb143776ae378a7d7a5e37bdabe0aa496631da39a9214adadb3580774','a67d8e90ae3c9aac6167687d05ee76f0323c40e5dfc1f0440a5ce9a2f15b2f0b'],
 ['TTiTTularesWebImages.cjs','8ef3c4c1da5e4dfa0556c1f83e2db8e3f862a1ff028a168199dd562553e0467c','daf8574088b31b0e058619fb72a1ed8925209224773cdc843a9d1d4d6f036e66']
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
