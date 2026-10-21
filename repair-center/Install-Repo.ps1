#requires -Version 5.1
# Envia codigo del Centro de Reparaciones a un PR aislado. NO modifica produccion.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
foreach($cmd in 'git','gh'){
 if(-not (Get-Command $cmd -ErrorAction SilentlyContinue)){throw "Falta $cmd (Git y GitHub CLI deben estar instalados y autorizados)"}
}
& gh auth status
if($LASTEXITCODE -ne 0){throw 'Primero autoriza gh auth login'}
$repo='fabricelop/europapress-rss'
$tmp=Join-Path $env:TEMP ('rc-repo-'+[guid]::NewGuid().ToString('N'))
& gh repo clone $repo $tmp -- --depth 1
if($LASTEXITCODE -ne 0){throw 'No se pudo clonar el repositorio'}
Push-Location $tmp
try{
 $branch='feature/centro-reparaciones-'+(Get-Date -Format 'yyyyMMdd-HHmmss')
 & git switch -c $branch
 if($LASTEXITCODE -ne 0){throw 'No se pudo abrir rama aislada'}
 $dst=Join-Path $tmp 'repair-center'
 New-Item -ItemType Directory -Force -Path $dst | Out-Null
 $files=@('README.md','catalog.mjs','diag.mjs','auth.mjs','worker.mjs','dispatch.py','schema.sql','wrangler.example.toml','Install-Repo.ps1')
 foreach($p in $files){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $p) -Destination (Join-Path $dst $p) -Force}
 foreach($sub in @('public','windows','tests')){
   Copy-Item -LiteralPath (Join-Path $PSScriptRoot $sub) -Destination (Join-Path $dst $sub) -Recurse -Force
 }
 New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.github/workflows') | Out-Null
 Copy-Item -LiteralPath (Join-Path $PSScriptRoot '.github/workflows/repair-center.yml') -Destination (Join-Path $tmp '.github/workflows/repair-center.yml') -Force
 & git add -- repair-center .github/workflows/repair-center.yml
 $gitUser=(& git config user.name); $gitMail=(& git config user.email)
 if(-not $gitUser -or -not $gitMail){throw 'Configura tu identidad Git: git config --global user.name y user.email'}
 & git commit -m 'Agregar centro de reparaciones bajo demanda (sin activar)'
 if($LASTEXITCODE -ne 0){throw 'No se pudo preparar commit'}
 & git push -u origin $branch
 if($LASTEXITCODE -ne 0){throw 'No se pudo publicar rama; no hubo cambios en main'}
 & gh pr create --repo $repo --base main --head $branch --title 'Centro de Reparaciones seguro (requiere configuración Google/Cloudflare)' --body 'Código completo y tests. Sin cron, sin borrado de datos, sin despliegue automático. Requiere revisión antes de combinar con main.'
 if($LASTEXITCODE -ne 0){throw 'Rama subida, pero no se creó PR: créalo desde GitHub'}
 Write-Host 'PR creado. MAIN no se ha modificado. Revisa y combina cuando proceda.' -ForegroundColor Green
}finally{Pop-Location}
