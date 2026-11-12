'use strict';
// V2 5B: ciclo de vida aislado. El adaptador de navegador real se conectará
// después de comprobar el perfil de autenticación. Sin dependencias de V1.
async function runOne({job, browserFactory, persistAndVerify, timeoutMs=15*60_000}) {
  if (!job || !job.trend_id || !job.token || !Number.isInteger(job.revision)) throw Error('invalid_job');
  if (typeof browserFactory !== 'function' || typeof persistAndVerify !== 'function') throw Error('invalid_adapters');
  let browser;
  let result;
  let failure;
  let timer;
  try {
    browser = await browserFactory({job, isolated:true});
    if (!browser || typeof browser.execute !== 'function' || typeof browser.close !== 'function') {
      throw Error('invalid_browser');
    }
    const controller = new AbortController();
    const timeout = new Promise((_,reject)=>{
      timer=setTimeout(()=>{controller.abort();reject(Error('editorial_timeout'));},timeoutMs);
    });
    const answer = await Promise.race([browser.execute(job,{signal:controller.signal}),timeout]);
    if (typeof answer !== 'string' || !answer.trim()) throw Error('empty_editorial_result');
    const confirmed = await persistAndVerify({job,text:answer.trim()});
    if (confirmed !== true) throw Error('result_not_verified');
    result={status:'ready',trend_id:job.trend_id,revision:job.revision};
  } catch (e) {
    failure=e;
  } finally {
    if (timer) clearTimeout(timer);
    if (browser) {
      try { await browser.close(); }
      catch (closeError) {
        if (failure) failure=new AggregateError([failure,closeError],'editorial_and_browser_close_failed');
        else failure=closeError;
      }
    }
  }
  if (failure) throw failure;
  return result;
}
module.exports={runOne};
