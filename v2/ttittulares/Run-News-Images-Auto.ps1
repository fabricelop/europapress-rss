# Only News V2 images; separate daemon lock, flag and per-job Chrome profiles.
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'TTActualidadNoticiasV2'
if(-not (Test-Path -LiteralPath (Join-Path $root 'images.enabled'))){return}
if((Get-Content -LiteralPath (Join-Path $root 'images.enabled') -Raw).Trim() -ne 'TTN2_IMAGES_ENABLED=YES'){return}
$imageCode=Join-Path $root 'image-active-code.txt'
$codeFile=if(Test-Path -LiteralPath $imageCode){$imageCode}else{Join-Path $root 'active-code.txt'}
$code=(Get-Content -LiteralPath $codeFile -Raw).Trim()
if(-not (Test-Path -LiteralPath (Join-Path $code 'v2\ttittulares\news_images_v2.py'))){throw 'NEWS_IMAGES_CODE_MISSING'}
$logs=Join-Path $root 'image-logs'
New-Item -ItemType Directory -Path $logs -Force|Out-Null
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$py=(Get-Command py.exe -ErrorAction Stop).Source
$p=Start-Process -FilePath $py -WorkingDirectory $code -ArgumentList @('-3','-m','v2.ttittulares.news_images_v2','--root',('"'+$root+'"'),'--daemon') -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $logs ($stamp+'.stdout.log')) -RedirectStandardError (Join-Path $logs ($stamp+'.stderr.log'))
exit $p.ExitCode
