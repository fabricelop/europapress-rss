# Recover-TT-Execution.ps1
# Limpia listeners antiguos/duplicados y deja una sola pareja dedicada actual.
# No toca datos editoriales ni el auto-updater.

$ErrorActionPreference = "Stop"
$BaseDir = "C:\TTiTTulares"
$Startup = [Environment]::GetFolderPath("Startup")

function Get-MainFile([string]$RepoPath,[string]$OutFile) {
  $api = "https://api.github.com/repos/fabricelop/europapress-rss/contents/" + $RepoPath + "?ref=main&t=" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $doc = Invoke-RestMethod -Uri $api -Headers @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "TT-execution-recovery"
    "Cache-Control" = "no-cache"
  } -TimeoutSec 20
  if (-not $doc.content) { throw "GitHub API sin contenido para $RepoPath" }
  [IO.File]::WriteAllBytes($OutFile,[Convert]::FromBase64String(([string]$doc.content -replace "\s","")))
}

function Validate-Ps([string]$File) {
  $t=$null;$e=$null
  [Management.Automation.Language.Parser]::ParseFile($File,[ref]$t,[ref]$e)|Out-Null
  if($e.Count -gt 0){throw "PowerShell invalido: $($e[0].Message)"}
}

New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null

$trend = Join-Path $BaseDir "TTendenciasDedicatedListener.ps1"
$title = Join-Path $BaseDir "TTiTTularesDedicatedListener.ps1"
$tmpTrend = $trend + ".recover.new.ps1"
$tmpTitle = $title + ".recover.new.ps1"

Get-MainFile "windows/TTendenciasDedicatedListener.ps1" $tmpTrend
Get-MainFile "windows/TTiTTularesDedicatedListener.ps1" $tmpTitle
Validate-Ps $tmpTrend
Validate-Ps $tmpTitle

$trendTxt = Get-Content $tmpTrend -Raw -Encoding UTF8
$titleTxt = Get-Content $tmpTitle -Raw -Encoding UTF8
if(-not $trendTxt.Contains("Ensure-RunnerNewChatCompatibility")){throw "Listener TTendencias sin compatibilidad New chat"}
if(-not $titleTxt.Contains("Ensure-RunnerNewChatCompatibility")){throw "Listener TTiTTulares sin compatibilidad New chat"}

Move-Item $tmpTrend $trend -Force
Move-Item $tmpTitle $title -Force

# Repara también Ejecutar.js para la UI actual de ChatGPT.
# La portada del proyecto puede no mostrar compositor; se usa un chat semilla existente.
$seedPatch = Join-Path $BaseDir "Fix-Ejecutar-ProjectSeed-V1.ps1"
Get-MainFile "windows/Fix-Ejecutar-ProjectSeed-V1.ps1" $seedPatch
Validate-Ps $seedPatch
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $seedPatch
if ($LASTEXITCODE -ne 0) { throw "No se pudo aplicar Fix-Ejecutar-ProjectSeed-V1.ps1" }

# Mata cualquier listener TT antiguo o agregado que pueda competir por los mismos triggers.
$patterns = @(
  "TTendenciasDedicatedListener.ps1",
  "TTiTTularesDedicatedListener.ps1",
  "TTendenciasMobileChatTriggerListener.ps1",
  "TTiTTularesMobileChatTriggerListener.ps1",
  "MobileChatTriggerListener.ps1"
)
$killed=@()
$procs = @(Get-CimInstance Win32_Process | Where-Object {
  $_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe"
})
foreach($p in $procs){
  $cmd=[string]$p.CommandLine
  $match=$false
  foreach($pat in $patterns){ if($cmd -like "*$pat*"){$match=$true;break} }
  if($match){
    try{Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop;$killed+=$p.ProcessId}catch{}
  }
}

# Desactiva accesos de Inicio antiguos que relancen listeners obsoletos.
$disabled=@()
if(Test-Path $Startup){
  foreach($f in @(Get-ChildItem -LiteralPath $Startup -File -ErrorAction SilentlyContinue)){
    if($f.Name -eq "TT Auto Updater.cmd"){continue}
    $txt=""
    try{$txt=Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue}catch{}
    $old=$false
    foreach($pat in @("MobileChatTriggerListener.ps1","TTendenciasMobileChatTriggerListener.ps1","TTiTTularesMobileChatTriggerListener.ps1")){
      if($txt -like "*$pat*"){$old=$true;break}
    }
    if($old){
      $new=$f.FullName+".disabled"
      Move-Item -LiteralPath $f.FullName -Destination $new -Force
      $disabled+=$new
    }
  }
}

Start-Sleep -Milliseconds 900
$trendOut=Join-Path $BaseDir "ttendencias-dedicated-stdout.log"
$trendErr=Join-Path $BaseDir "ttendencias-dedicated-stderr.log"
$titleOut=Join-Path $BaseDir "ttittulares-dedicated-stdout.log"
$titleErr=Join-Path $BaseDir "ttittulares-dedicated-stderr.log"

$tp=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$trend) -WindowStyle Hidden -RedirectStandardOutput $trendOut -RedirectStandardError $trendErr -PassThru
$hp=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$title) -WindowStyle Hidden -RedirectStandardOutput $titleOut -RedirectStandardError $titleErr -PassThru
Start-Sleep -Seconds 4
$tp.Refresh();$hp.Refresh()
if($tp.HasExited){throw "TTendencias listener no quedó activo"}
if($hp.HasExited){throw "TTiTTulares listener no quedó activo"}

Write-Host "RECUPERACION TT ACTIVA" -ForegroundColor Green
Write-Host "Procesos antiguos detenidos: $($killed.Count)"
Write-Host "Inicio antiguo desactivado: $($disabled.Count)"
Write-Host "TTendencias PID: $($tp.Id)"
Write-Host "TTiTTulares PID: $($hp.Id)"
Write-Host "Ejecutar.js: New chat opcional + chat semilla del proyecto activos"
