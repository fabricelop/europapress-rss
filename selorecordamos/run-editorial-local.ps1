# SeLoRecordamos: Windows Task -> ChatGPT Chrome/CDP usando el lanzador TT existente.
$ErrorActionPreference = 'Stop'
$BaseDir = 'C:\TTiTTulares'
$Runner = Join-Path $BaseDir 'Ejecutar.js'
$runtime = Join-Path $PSScriptRoot 'runtime'
New-Item -ItemType Directory -Force -Path $runtime | Out-Null
$log = Join-Path $runtime 'editorial-local.log'
$lock = Join-Path $runtime 'editorial-local.lock'
$handle = $null
function Log([string]$text) { ('['+(Get-Date -Format s)+'] '+$text) | Add-Content -LiteralPath $log -Encoding UTF8 }
# Registrar el inicio ANTES de cualquier exclusión o comprobación, incluso sin cola.
Log "START pid=$PID user=$([Security.Principal.WindowsIdentity]::GetCurrent().Name) script=$PSCommandPath"
try {
    $handle = [IO.File]::Open($lock,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
} catch {
    Log "SKIP: hay otra instancia que posee el candado de ejecución ($($_.Exception.Message))"
    exit 0
}
try {
    if (-not (Test-Path $Runner)) { throw 'Falta C:\TTiTTulares\Ejecutar.js' }
    $runnerText = Get-Content -LiteralPath $Runner -Raw -Encoding UTF8
    if (-not $runnerText.Contains('TT_CHAT_MESSAGE_B64') -or -not $runnerText.Contains('--enviar')) { throw 'Ejecutar.js no admite mensajes personalizados en modo envio real' }
    $repo = Split-Path -Parent $PSScriptRoot
    Set-Location $repo
    # Leer el estado Git remoto sin checkout, pull, rebase ni modificaciones del árbol compartido.
    & git fetch origin main --quiet
    if ($LASTEXITCODE -ne 0) { throw 'No se pudo consultar GitHub' }
    $snapshot = Join-Path $runtime 'editorial-snapshot'
    New-Item -ItemType Directory -Path $snapshot -Force | Out-Null
    foreach ($name in @('requests.json','assistant-state.json','assistant-output.json')) {
        $raw = & git show ("origin/main:selorecordamos/"+$name)
        if ($LASTEXITCODE -ne 0) { throw "No se pudo leer $name desde origin/main" }
        [IO.File]::WriteAllText((Join-Path $snapshot $name), ($raw -join "`n"), [Text.UTF8Encoding]::new($false))
    }
    $checkScript = @'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])
req=json.loads((p/"requests.json").read_text(encoding="utf-8")).get("requests",[])
st=set(json.loads((p/"assistant-state.json").read_text(encoding="utf-8")).get("processed",[]))
out={str(x.get("request_key")) for x in json.loads((p/"assistant-output.json").read_text(encoding="utf-8")).get("outputs",[]) if x.get("request_key") and x.get("send_to_telegram") is True}
def key(r):
  if r.get("type")=="evaluate": return "evaluate:"+str(r.get("tweet_id",""))
  if r.get("type")=="telegram_instruction": return "telegram_instruction:"+str(r.get("telegram_update_id",""))
  return ""
pending=sorted(set(key(r) for r in req if key(r) and key(r) not in st and key(r) not in out))
print(json.dumps({"count":len(pending),"keys":pending}))
'@
    $countText = $checkScript | python - $snapshot
    if ($LASTEXITCODE -ne 0) { throw 'Error leyendo la cola' }
    $pendingState = ($countText | Select-Object -Last 1) | ConvertFrom-Json
    $count = [int]$pendingState.count
    if ($count -eq 0) { Log 'DONE: no hay evaluaciones pendientes'; exit 0 }
    $fingerprint = (@($pendingState.keys) -join '|')
    Log "Pendientes: $count"
    # El chat puede tardar en redactar y persistir. No lanzar la misma cola
    # cada 15 minutos: la tarea vigila, sin duplicar mensajes en ChatGPT.
    $launchStateFile = Join-Path $runtime 'editorial-launch-state.json'
    if (Test-Path $launchStateFile) {
        try {
            $previous = Get-Content -LiteralPath $launchStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            $elapsed = ([DateTimeOffset]::UtcNow - [DateTimeOffset]::Parse([string]$previous.confirmed_at)).TotalMinutes
            if ([string]$previous.pending_fingerprint -eq $fingerprint -and $elapsed -ge 0 -and $elapsed -lt 60) {
                Log ("WAIT: la misma cola ya se envió a ChatGPT hace "+[math]::Round($elapsed,1)+" min (run="+$previous.run_id+"). Sin duplicar.")
                exit 0
            }
        } catch { Log ("AVISO: no se pudo leer el estado de espera: "+$_.Exception.Message) }
    }
    $node = Get-Command node.exe -ErrorAction Stop
    $commandId = 'sr-'+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $message = "SELORECORDAMOS_EDITORIAL_JOB_V1 $commandId | Ejecuta AHORA la pasada editorial de SeLoRecordamos. Lee primero selorecordamos/editorial-run-prompt.md y las solicitudes vigentes de selorecordamos/requests.json desde main. Procesa las pendientes, con cuatro propuestas A/B/C/D por evaluación, y persiste exclusivamente por el issue #16 mediante SELORECORDAMOS_OUTBOX_V2. Verifica la persistencia y no marques éxito sin confirmación. No invoques ImageGen ni cambies ninguna automatización."
    $old = $env:TT_CHAT_MESSAGE_B64
    $stdout = Join-Path $runtime ('editorial-launch-'+$commandId+'.log')
    $stderr = Join-Path $runtime ('editorial-launch-'+$commandId+'.err.log')
    try {
        $env:TT_CHAT_MESSAGE_B64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($message))
        # Este lanzador existente actualmente reconoce titulares/tendencias, no un proyecto SLR específico.
        # Transporte temporal compartido; no se modifica la configuración de TT.
        $proc = Start-Process -FilePath $node.Source -ArgumentList @($Runner,'titulares','--enviar') -WorkingDirectory $BaseDir -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        Log "Lanzador iniciado pid=$($proc.Id) comando=$commandId (ruta ChatGPT titulares)"
    } finally {
        if ($null -eq $old) { Remove-Item Env:TT_CHAT_MESSAGE_B64 -ErrorAction SilentlyContinue } else { $env:TT_CHAT_MESSAGE_B64=$old }
    }
    $confirmed = $false
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 750
        $text = ''
        if (Test-Path $stdout) { $text += [string](Get-Content $stdout -Raw -ErrorAction SilentlyContinue) }
        if (Test-Path $stderr) { $text += [string](Get-Content $stderr -Raw -ErrorAction SilentlyContinue) }
        if ($text -match 'MODO:\s*PRUEBA|ERROR:|CHAT MESSAGE TIMEOUT|Timeout CDP') { throw 'Ejecutar.js indicó error. Revisar logs editorial-launch' }
        if ($text -match 'MODO:\s*ENVIO REAL' -and $text -match 'MENSAJE ENVIADO|EJECUCION LANZADA|"generando"\s*:\s*true') { $confirmed=$true;break }
        if ($proc.HasExited) { break }
        $proc.Refresh()
    }
    if (-not $confirmed) { throw 'No se confirmó el envío real a ChatGPT; no se declara ejecutado' }
    # Solo registrar el último intento tras confirmación efectiva de envío.
    @{
        run_id = $commandId
        confirmed_at = [DateTimeOffset]::UtcNow.ToString('o')
        pending_count = $count
        pending_fingerprint = $fingerprint
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $launchStateFile -Encoding UTF8
    Log "LAUNCH CONFIRMED: mensaje ChatGPT $commandId; pendiente validación del outbox #16 y Telegram."
} catch {
    Log ('ERROR: '+$_.Exception.Message)
    exit 1
} finally { if ($handle) { $handle.Dispose() }; Log "END pid=$PID" }
