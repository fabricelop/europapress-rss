# Repairs only the exact V1 executor guard; never starts Chrome or a job.
[CmdletBinding()]
param([string]$BaseDir='C:\TTiTTulares')
$ErrorActionPreference='Stop'

function Get-V1ExecutorGuard {
$guardText=@'
// TT_V1_EXECUTOR_GUARD_20261116_SLR_SAFE_V2
{
  const __ttv1args = process.argv.slice(2);
  const __ttv1legacy = __ttv1args.some(x => /^(titulares|tendencias)$/i.test(x));
  let __ttv1slr = false;
  if (__ttv1args[0] === 'titulares' && !__ttv1args.some(x => /^tendencias$/i.test(x))) {
    const __ttv1b64 = String(process.env.TT_CHAT_MESSAGE_B64 || '');
    if (__ttv1b64.length > 0 && __ttv1b64.length <= 65536) {
      try {
        const __ttv1bytes = Buffer.from(__ttv1b64, 'base64');
        const __ttv1message = __ttv1bytes.toString('utf8');
        __ttv1slr = __ttv1bytes.toString('base64') === __ttv1b64 && Buffer.from(__ttv1message, 'utf8').equals(__ttv1bytes) &&
          /^SELORECORDAMOS_EDITORIAL_JOB_V1 sr-[0-9]{10,20} \| Ejecuta AHORA la pasada editorial de SeLoRecordamos\./.test(__ttv1message);
      } catch (_) {}
    }
  }
  if (__ttv1legacy && !__ttv1slr) { console.log('TT_V1_CHATGPT_DISABLED'); process.exit(0); }
}
'@
return $guardText + "`n"
}

$runner=Join-Path $BaseDir 'Ejecutar.js'
if(-not (Test-Path -LiteralPath $runner -PathType Leaf)){throw "No existe $runner"}
$source=[IO.File]::ReadAllText($runner)
$guard=Get-V1ExecutorGuard
if($source.Contains($guard)){
  Write-Host 'SELORECORDAMOS_TRANSPORTE=YA_COMPATIBLE_CON_PARADA_V1'
  exit 0
}
$oldLine="if (process.argv.slice(2).some(x => /^(titulares|tendencias)$/i.test(x))) { console.log('TT_V1_CHATGPT_DISABLED'); process.exit(0); }"
$pattern=[regex]::Escape('// TT_V1_EXECUTOR_GUARD_20261116')+"\r?\n"+[regex]::Escape($oldLine)+"\r?\n"
$matches=[regex]::Matches($source,$pattern)
if($matches.Count -ne 1){throw 'Guardia antigua no encontrada de forma exacta y unica; no se modifica ningun archivo.'}
$node=Get-Command node.exe -ErrorAction Stop
$fixed=[regex]::Replace($source,$pattern,[Text.RegularExpressions.MatchEvaluator]{param($match) $guard})
$backup=Join-Path $BaseDir ('Backup-Guardia-SLR-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Path $backup | Out-Null
$original=Join-Path $backup 'Ejecutar.js'
Copy-Item -LiteralPath $runner -Destination $original
$temporary=Join-Path $BaseDir ('Ejecutar.slr-guard-'+[Guid]::NewGuid().ToString('N')+'.js')
try{
  [IO.File]::WriteAllText($temporary,$fixed,(New-Object Text.UTF8Encoding($false)))
  & $node.Source --check $temporary
  if($LASTEXITCODE -ne 0){throw 'Validacion Node fallida; Ejecutar.js original conservado.'}
  if((Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash){
    throw 'Ejecutar.js cambio durante la reparacion; no se sobrescribe.'
  }
  Move-Item -LiteralPath $temporary -Destination $runner -Force
}finally{
  if(Test-Path -LiteralPath $temporary){Remove-Item -LiteralPath $temporary}
}
@{at=(Get-Date).ToString('o');runner=$runner;backup=$original;
  original_sha256=(Get-FileHash -LiteralPath $original -Algorithm SHA256).Hash;
  repaired_sha256=(Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash;
  operation='replace_exact_legacy_guard_only';jobs_launched=0;browsers_stopped=0;
  explanation='Permite solo el mensaje editorial SeLoRecordamos autentico por el transporte compartido titulares; V1 sigue bloqueado.'} |
  ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'result.json') -Encoding UTF8
Write-Host ('COPIA_SEGURIDAD='+$backup)
Write-Host 'SELORECORDAMOS_TRANSPORTE=GUARDIA_CORREGIDA_V1_SIGUE_BLOQUEADO'

