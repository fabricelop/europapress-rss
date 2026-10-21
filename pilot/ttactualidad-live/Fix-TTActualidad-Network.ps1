#requires -Version 5.1
<#
TTActualidad: correccion temporal y reversible de ruta a Cloudflare desde Windows.
Afecta solo a ttactualidad-decisions-pilot.fabricelop.workers.dev.
No despliega, no modifica otros proyectos ni toca KV, secretos o Cloudflare.
-Revert elimina exclusivamente la entrada gestionada por este script.
#>
[CmdletBinding()]
param([switch]$Revert)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$hostname = 'ttactualidad-decisions-pilot.fabricelop.workers.dev'
$health = 'https://' + $hostname + '/health'
$hostsFile = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$marker = '# TTActualidad network workaround 2026-10-17'
$preferredIps = @('104.21.22.59','172.67.202.251')
function Probe([string]$ip) {
  $args = @('--silent','--show-error','--connect-timeout','5','--max-time','12','-4','--resolve',("{0}:443:{1}" -f $hostname,$ip),$health)
  $result = (& curl.exe @args 2>&1 | Out-String)
  return ($LASTEXITCODE -eq 0 -and $result.Contains('"ttactualidad-direct-live"') -and $result.Contains('"ok":true'))
}
Write-Host '=== TTActualidad: restaurar acceso de Windows SIN desplegar ===' -ForegroundColor Cyan
$chosen = $null
if(-not $Revert) {
  foreach($ip in $preferredIps) {
    Write-Host ('Comprobando ruta ' + $ip)
    if(Probe $ip){$chosen=$ip;break}
  }
  if(-not $chosen) {
    throw 'Ninguna ruta alternativa respondió correctamente. No se cambia el equipo.'
  }
  Write-Host ('Ruta alternativa verificada: '+$chosen) -ForegroundColor Green
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$admin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if(-not $admin) {
  Write-Host 'Se solicitara permiso de administrador para modificar SOLO hosts.' -ForegroundColor Yellow
  $argsText = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "'+$PSCommandPath+'"'
  if($Revert){$argsText+=' -Revert'}
  Start-Process -FilePath 'powershell.exe' -ArgumentList $argsText -Verb RunAs -Wait
  exit
}
if(-not (Test-Path -LiteralPath $hostsFile)){throw 'No se encuentra hosts'}
$backup = $hostsFile+'.before-TTActualidad-'+(Get-Date -Format 'yyyyMMdd-HHmmss')+'.bak'
Copy-Item -LiteralPath $hostsFile -Destination $backup -Force
$oldLines=[IO.File]::ReadAllLines($hostsFile,[Text.Encoding]::Default)
$lines = New-Object 'System.Collections.Generic.List[string]'
foreach($line in $oldLines) {
  if($line.Contains($marker)){continue}
  $lines.Add($line)
}
if(-not $Revert) {
  $lines.Add(('{0} {1} {2}' -f $chosen,$hostname,$marker))
}
[IO.File]::WriteAllLines($hostsFile,$lines,[Text.Encoding]::Default)
& ipconfig.exe /flushdns | Out-Null
if($Revert) {
  Write-Host 'Entrada de TTActualidad retirada; DNS normal restaurado.' -ForegroundColor Green
  Write-Host ('Copia previa: '+$backup)
  exit 0
}
$test = (& curl.exe -4 --silent --show-error --connect-timeout 5 --max-time 12 $health 2>&1 | Out-String)
$worked = ($LASTEXITCODE -eq 0 -and $test.Contains('"ttactualidad-direct-live"') -and $test.Contains('"ok":true'))
if(-not $worked) {
  Write-Warning 'El test normal no dio OK: se retira automaticamente nuestra entrada.'
  [IO.File]::WriteAllLines($hostsFile,$oldLines,[Text.Encoding]::Default)
  & ipconfig.exe /flushdns | Out-Null
  throw 'Prueba final fallida, cambios revertidos.'
}
Write-Host ('TTActualidad RESTAURADO EN WINDOWS: '+$health) -ForegroundColor Green
Write-Host ('IP funcional: '+$chosen)
Write-Host ('Copia previa: '+$backup)
Write-Host 'Cierra y vuelve a abrir el navegador. Cambios reversibles con -Revert.'
