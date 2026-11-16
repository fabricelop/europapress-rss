param()
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'TTActualidadNoticiasV2'
$code=(Get-Content -LiteralPath (Join-Path $root 'active-code.txt') -Raw).Trim()
if(-not (Test-Path -LiteralPath (Join-Path $code 'v2\ttittulares\editorial_consumer_v2.py'))){throw 'Falta la instalación Noticias V2'}
if((Get-Content -LiteralPath (Join-Path $root 'editorial.enabled') -Raw).Trim() -ne 'TTN2_EDITORIAL_ENABLED=YES'){return}
$logdir=Join-Path $root 'logs'
New-Item -ItemType Directory -Path $logdir -Force | Out-Null
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$py=(Get-Command py.exe -ErrorAction Stop).Source
$process=Start-Process -FilePath $py -ArgumentList @('-3','-m','v2.ttittulares.editorial_consumer_v2','--root',('"'+$root+'"'),'--daemon') `
  -WorkingDirectory $code -WindowStyle Hidden -Wait -PassThru `
  -RedirectStandardOutput (Join-Path $logdir ('daemon-'+$stamp+'.stdout.log')) `
  -RedirectStandardError (Join-Path $logdir ('daemon-'+$stamp+'.stderr.log'))
exit $process.ExitCode
