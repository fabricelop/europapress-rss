$ErrorActionPreference="Stop"
$BaseDir="C:\TTiTTulares"
$Updater=Join-Path $BaseDir "TT-AutoUpdater.ps1"
$StartupDir=[Environment]::GetFolderPath("Startup")
$StartupCmd=Join-Path $StartupDir "TT Auto Updater.cmd"
$api="https://api.github.com/repos/fabricelop/europapress-rss/contents/windows/TT-AutoUpdater.ps1?ref=main&t="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$doc=Invoke-RestMethod -Uri $api -Headers @{"Accept"="application/vnd.github+json";"User-Agent"="TT-auto-updater-installer";"Cache-Control"="no-cache"} -TimeoutSec 20
if(-not $doc.content){throw "GitHub no devolvio TT-AutoUpdater.ps1"}
$raw=[Convert]::FromBase64String(([string]$doc.content -replace "\s",""))
[IO.File]::WriteAllBytes($Updater,$raw)
$t=$null;$e=$null
[Management.Automation.Language.Parser]::ParseFile($Updater,[ref]$t,[ref]$e)|Out-Null
if($e.Count -gt 0){throw "Auto-updater invalido: "+$e[0].Message}
$cmd='@echo off'+[Environment]::NewLine+'start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "'+$Updater+'"'
Set-Content -LiteralPath $StartupCmd -Value $cmd -Encoding ASCII
@(Get-CimInstance Win32_Process|Where-Object{($_.Name -ieq "powershell.exe" -or $_.Name -ieq "pwsh.exe") -and $_.CommandLine -like "*TT-AutoUpdater.ps1*"})|ForEach-Object{try{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}catch{}}
Start-Sleep -Milliseconds 500
$o=Join-Path $BaseDir "tt-auto-updater-stdout.log"
$er=Join-Path $BaseDir "tt-auto-updater-stderr.log"
$p=Start-Process powershell.exe -ArgumentList @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$Updater) -WindowStyle Hidden -RedirectStandardOutput $o -RedirectStandardError $er -PassThru
Start-Sleep -Seconds 2
$p.Refresh()
if($p.HasExited){throw "El auto-updater no quedo activo"}
Write-Host "AUTO-UPDATER TT ACTIVO" -ForegroundColor Green
Write-Host ("PID: "+$p.Id)
Write-Host "Intervalo: 10 minutos"
Write-Host ("Inicio con Windows: "+$StartupCmd)
Write-Host "Log: C:\TTiTTulares\tt-auto-updater.log"
