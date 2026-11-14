# One-shot authenticated upload and deploy of original 1254x1254 V2 pilot image.
# Requires user to save the generated image in Downloads under the exact filename.
$ErrorActionPreference = 'Stop'
$expected = '1d0d2b730ac1a8e910b3f01755771320b2c1e44b4aecde22873b1ab30bca9163'
$file = Join-Path (Join-Path $env:USERPROFILE 'Downloads') 'TTActualidad-JordiWild-HD.webp'
if (!(Test-Path -LiteralPath $file)) { throw 'IMAGE_NOT_DOWNLOADED' }
$hash=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -ne $expected) { throw 'IMAGE_SHA256_MISMATCH' }
if (!(Get-Command gh.exe -ErrorAction SilentlyContinue)) { throw 'GH_CLI_UNAVAILABLE' }
$token=(& gh.exe auth token | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $token.Length -lt 15) { throw 'GH_AUTH_NOT_CONFIGURED' }
$path='v2/private-worker/web-source/pilot/jordi-wild.webp'
$branch='feature/ttactualidad-v2-private-worker-20261114'
$uri='https://api.github.com/repos/fabricelop/europapress-rss/contents/'+$path
$headers=@{'Authorization'=('Bearer '+$token);'Accept'='application/vnd.github+json';'X-GitHub-Api-Version'='2022-11-28';'User-Agent'='TTActualidadV2-Private-Image'}
$existing=$null
try{$existing=Invoke-RestMethod -Method Get -Uri ($uri+'?ref='+[uri]::EscapeDataString($branch)) -Headers $headers -TimeoutSec 30}catch{if(!$_.Exception.Response -or [int]$_.Exception.Response.StatusCode -ne 404){throw}}
$payload=@{branch=$branch;message='V2 private: install original 1254px Jordi Wild visual';content=[Convert]::ToBase64String([IO.File]::ReadAllBytes($file))}
if($existing -and $existing.sha){$payload.sha=$existing.sha}
$body=$payload|ConvertTo-Json -Compress -Depth 3
$uploaded=Invoke-RestMethod -Method Put -Uri $uri -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 90
if(!$uploaded.content.sha){throw 'GITHUB_IMAGE_WRITE_UNCONFIRMED'}
Remove-Variable token,body,payload -ErrorAction SilentlyContinue
$dir=Join-Path $env:TEMP 'ttactualidad-v2-private'
if(!(Test-Path (Join-Path $dir '.git'))){throw 'LOCAL_REPO_MISSING'}
Push-Location $dir
try{
 $branchName=(& git.exe branch --show-current | Out-String).Trim()
 if($branchName -ne $branch){throw 'WRONG_BRANCH'}
 # Git normal stderr is informational in PowerShell; redirect to file from cmd.
 $log=Join-Path $env:TEMP 'v2-jordi-git-fetch.log'
 & cmd.exe /d /c "git pull --ff-only origin feature/ttactualidad-v2-private-worker-20261114 > $log 2>&1"
 if($LASTEXITCODE -ne 0){throw 'GIT_PULL_FAILED'}
 Set-Location (Join-Path $dir 'v2\private-worker')
 & npm.cmd run build
 if($LASTEXITCODE -ne 0){throw 'BUILD_FAILED'}
 $dist=Join-Path (Get-Location).Path 'dist\pilot\jordi-wild.webp'
 if(!(Test-Path $dist)){throw 'IMAGE_NOT_PACKAGED'}
 if((Get-FileHash $dist -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected){throw 'IMAGE_DIST_HASH_MISMATCH'}
 & npx.cmd wrangler deploy --keep-vars
 if($LASTEXITCODE -ne 0){throw 'DEPLOY_FAILED'}
 Write-Output 'TT_V2_JORDI_HD_DEPLOYED=YES'
}finally{Pop-Location}
