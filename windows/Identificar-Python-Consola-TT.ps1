#requires -Version 5.1
# Solo lectura: atribuye procesos PowerShell a sus procesos Python padres.
# No muestra lineas de comandos completas ni datos de autenticacion.
[CmdletBinding()]
param([ValidateRange(5,60)][int]$Segundos=15)
$ErrorActionPreference='Stop'

function Nombre-Script([string]$command) {
  if(-not $command){return '-'}
  $hits=[regex]::Matches($command,'(?i)[\w.()_-]+\.pyw?(?=["\s]|$)')
  if($hits.Count -gt 0){return [string]$hits[$hits.Count-1].Value}
  if($command -match '(?i)(?:^|\s)-m\s+([\w.]+)'){return ('modulo:'+ $Matches[1])}
  if($command -match '(?i)(?:^|\s)-c(?:\s|$)'){return 'codigo-inline'}
  return 'sin-script-visible'
}
function Proceso([int]$processId) {
  try { return Get-CimInstance Win32_Process -Filter ("ProcessId=$processId") -ErrorAction Stop }
  catch { return $null }
}
function Python([int]$processId) {
  $proc=Proceso $processId
  if($proc -and [string]$proc.Name -match '^(?i:python|pythonw)\.exe$'){return $proc}
  return $null
}

Write-Host 'TT_PYTHON_CONSOLA=SOLO_LECTURA'
Write-Host '=== PYTHON ACTIVOS ==='
$rows=@()
try {
  foreach($proc in @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='pythonw.exe'" -ErrorAction Stop)){
    $parent=Proceso ([int]$proc.ParentProcessId)
    $rows += [pscustomobject]@{
      PID=[int]$proc.ProcessId
      PadrePID=[int]$proc.ParentProcessId
      Padre=if($parent){[string]$parent.Name}else{'no-activo'}
      Script=Nombre-Script ([string]$proc.CommandLine)
      Inicio=([datetime]$proc.CreationDate).ToString('HH:mm:ss')
    }
  }
  if($rows.Count){$rows | Format-Table -AutoSize | Out-String -Width 165 | Write-Host}
  else{Write-Host 'NO_HAY_PYTHON_ACTIVOS'}
}catch{Write-Host ('ERROR_LISTANDO_PYTHON='+$_.Exception.Message)}

Write-Host ('=== OBSERVACION DE NUEVOS POWERSHELL: '+$Segundos+' SEGUNDOS ===')
$counts=@{}
$source='TT_Identificar_Python_'+[guid]::NewGuid().ToString('N')
$subscribed=$false
try{
  Register-WmiEvent -Class Win32_ProcessStartTrace -SourceIdentifier $source -ErrorAction Stop | Out-Null
  $subscribed=$true
  $until=(Get-Date).AddSeconds($Segundos)
  while((Get-Date) -lt $until){
    $event=Wait-Event -SourceIdentifier $source -Timeout 1
    if($null -eq $event){continue}
    try{
      $e=$event.SourceEventArgs.NewEvent
      if([string]$e.ProcessName -notmatch '^(?i:powershell|pwsh)\.exe$'){continue}
      $parentId=[int]$e.ParentProcessID
      $parent=Python $parentId
      if(-not $parent){continue}
      $key=[string]$parentId
      if(-not $counts.ContainsKey($key)){$counts[$key]=0}
      $counts[$key]++
    }finally{Remove-Event -EventIdentifier $event.EventIdentifier -ErrorAction SilentlyContinue}
  }
}catch{Write-Host ('MONITOR_NO_DISPONIBLE='+$_.Exception.Message)}
finally{if($subscribed){Unregister-Event -SourceIdentifier $source -ErrorAction SilentlyContinue}}

if($counts.Count){
  foreach($key in @($counts.Keys | Sort-Object {-$counts[$_]})){
    $proc=Python ([int]$key)
    $script=if($proc){Nombre-Script ([string]$proc.CommandLine)}else{'proceso-finalizado'}
    Write-Host ('ORIGEN_POWERSHELL PID_PYTHON='+$key+' SCRIPT='+$script+' LANZAMIENTOS='+$counts[$key])
  }
}else{Write-Host 'NINGUN_POWERSHELL_NUEVO_DESDE_PYTHON_EN_LA_MUESTRA'}
Write-Host 'TT_PYTHON_CONSOLA_FIN=SI; SIN_CAMBIOS'
