'use strict';
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {spawnSync}=require('node:child_process');
const source='https://raw.githubusercontent.com/fabricelop/europapress-rss/be5ba9e63c0a3ff4f21428ef0bdb8b5270ad43f8/windows/';
const files=[
 ['TTendenciasWebImages.cjs','a67d8e90ae3c9aac6167687d05ee76f0323c40e5dfc1f0440a5ce9a2f15b2f0b','8b920e1b2034f1ee18c544ed15f16ca4d58d4c2c6b8422406af15ac66f9c6d01'],
 ['TTiTTularesWebImages.cjs','daf8574088b31b0e058619fb72a1ed8925209224773cdc843a9d1d4d6f036e66','8e7142b10da30f16db84dcd335cc92392a32a4736cd70480ffd99cb981a66e7b']
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
