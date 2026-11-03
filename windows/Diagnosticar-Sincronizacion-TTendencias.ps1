#requires -Version 5.1
# Read-only: compare an immutable GitHub radar/feed snapshot with the live Site API.
# Does not touch iPhone, editorial decisions, images, browsers or tasks.
param(
 [string]$SiteBase = 'https://ttactualidad.rainyraven22.chatgpt.site',
 [ValidateRange(5,60)][int]$TimeoutSeconds = 20,
 [switch]$SelfTest
)
$ErrorActionPreference='Stop'
# PowerShell 5.1 may decode .Content as ISO-8859-1 when charset is absent,
# turning e.g. U+00FA into the two visible characters U+00C3 U+00BA.
# Always decode the original response bytes as strict UTF-8 instead.
function ConvertFrom-UTF8JsonBytes([byte[]]$bytes) {
 if($null -eq $bytes -or $bytes.Length -eq 0){throw 'RESPUESTA_JSON_VACIA'}
 $utf8=New-Object System.Text.UTF8Encoding($false,$true)
 return ($utf8.GetString($bytes) | ConvertFrom-Json)
}
function Read-Json([string]$uri) {
 $answer=Invoke-WebRequest -UseBasicParsing -Uri $uri -TimeoutSec $TimeoutSeconds -Headers @{'Cache-Control'='no-cache';'Pragma'='no-cache'}
 if([int]$answer.StatusCode -ne 200){throw ('HTTP '+[int]$answer.StatusCode)}
 if($null -eq $answer.RawContentStream){throw 'RESPUESTA_SIN_BYTES'}
 return (ConvertFrom-UTF8JsonBytes ([byte[]]$answer.RawContentStream.ToArray()))
}
if($SelfTest){
 $expected='Jes'+[char]0x00FA+'s de Miguel'
 $json='{"items":[{"rank":1,"name":"'+$expected+'"}]}'
 $value=ConvertFrom-UTF8JsonBytes ([Text.Encoding]::UTF8.GetBytes($json))
 if([string]$value.items[0].name -cne $expected){throw 'SELFTEST_UTF8_FAILED'}
 $invalid=([byte[]]@(0x7B,0x22,0x78,0x22,0x3A,0x22,0xC3,0x28,0x22,0x7D))
 $rejected=$false
 try { $null=ConvertFrom-UTF8JsonBytes $invalid }catch {$rejected=$true}
 if(-not $rejected){throw 'SELFTEST_INVALID_UTF8_ACCEPTED'}
 Write-Host 'SELFTEST_UTF8_OK'
 return
}
function Rows-From([object]$doc) {
 if($null -eq $doc){return @()}
 $candidates=@()
 $candidates+=,($doc)
 foreach($key in @('data','result','feed','current','top30','trends','payload')) {
  if($null -ne $doc.$key){$candidates+=,($doc.$key)}
 }
 $more=@($candidates)
 foreach($candidate in $more){
  foreach($key in @('top30','trends','items','rows','data')) {
   if($null -ne $candidate -and $null -ne $candidate.$key){$candidates+=,($candidate.$key)}
  }
 }
 foreach($candidate in $candidates){
  $rows=@()
  if($candidate -is [array]){$rows=@($candidate)}
  elseif($null -ne $candidate.items){$rows=@($candidate.items)}
  elseif($null -ne $candidate.rows){$rows=@($candidate.rows)}
  $valid=@($rows | Where-Object {
   $null -ne $_ -and [string]$_.name -ne '' -and [string]$_.rank -match '^\d+$' -and
   [int]$_.rank -ge 1 -and [int]$_.rank -le 30
  })
  if($valid.Count -ge 25){
   return @($valid | Sort-Object {[int]$_.rank})
  }
 }
 return @()
}
$commit=Read-Json 'https://api.github.com/repos/fabricelop/europapress-rss/commits/main'
$sha=[string]$commit.sha
if($sha -notmatch '^[0-9a-f]{40}$'){throw 'No se pudo fijar una revision GitHub inmutable.'}
$raw='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$sha+'/trends/'
$radar=Read-Json ($raw+'recent.json')
$feed=Read-Json ($raw+'site-top30-current.json')
$radarRows=@($radar.items | Sort-Object {[int]$_.rank})
$feedRows=@($feed.items | Sort-Object {[int]$_.rank})
$diff=@()
for($i=0;$i -lt [Math]::Min($radarRows.Count,$feedRows.Count);$i++){
 foreach($key in @('rank','name','movement','movement_version','previous_rank','rank_delta','last_changed_at','entered_top30_at')){
  if([string]$radarRows[$i].$key -cne [string]$feedRows[$i].$key){$diff+=('{0}: {1}' -f ($i+1),$key)}
 }
}
Write-Host ('GitHub main commit: '+$sha)
Write-Host ('Captura radar: '+$radar.captured_at)
Write-Host ('Captura feed web: '+$feed.radar_captured_at)
Write-Host ('Generacion feed web: '+$feed.generated_at)
Write-Host ('Radar/feed: '+$radarRows.Count+'/'+$feedRows.Count+' filas, diferencias de campos='+$diff.Count)
if($diff.Count){Write-Host ('Primeras diferencias: '+(@($diff | Select-Object -First 10) -join ', '))}
$nonce=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$base=$SiteBase.TrimEnd('/')
try {
 $site=Read-Json ($base+'/api/trends?ttdiagnostic='+$nonce)
 Write-Host 'Web /api/trends: HTTP 200'
 $siteRows=@(Rows-From $site)
 if($siteRows.Count -eq 0){
  Write-Host 'Respuesta de Site sin Top30 reconocible; no declarar paridad. Claves:'
  Write-Host ((@($site.PSObject.Properties.Name) | Select-Object -First 15) -join ', ')
 } else {
  $mismatches=@()
  for($i=0;$i -lt [Math]::Min(30,$siteRows.Count);$i++){
   $expected=$feedRows[$i];$actual=$siteRows[$i]
   if([int]$actual.rank -ne [int]$expected.rank -or [string]$actual.name -cne [string]$expected.name){
    $mismatches+=('{0}: Site={1}, GitHub={2}' -f ($i+1),$actual.name,$expected.name)
   }
  }
  Write-Host ('Site/feed: '+$siteRows.Count+'/'+$feedRows.Count+' filas, posiciones distintas='+$mismatches.Count)
  foreach($line in @($mismatches | Select-Object -First 12)){Write-Host $line}
  if(-not $mismatches.Count -and $siteRows.Count -eq 30){Write-Host 'PARIDAD DE RANKING WEB CONFIRMADA para este instante.'}
 }
 foreach($key in @('radar_captured_at','captured_at','generated_at','updated_at','stale')){
  if($null -ne $site.$key){Write-Host ('Web '+$key+': '+$site.$key)}
  elseif($null -ne $site.data -and $null -ne $site.data.$key){Write-Host ('Web '+$key+': '+$site.data.$key)}
 }
}catch{
 Write-Host ('Web /api/trends: NO VERIFICABLE - '+$_.Exception.GetType().Name)
}
Write-Host 'La version instalada en el iPhone y su ultima descarga no pueden comprobarse desde este PC.'
