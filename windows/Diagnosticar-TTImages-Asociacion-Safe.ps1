#requires -Version 5.1
<#
 TTImages - diagnostico de asociacion, SOLO LECTURA.
 No reinicia Chrome, no llama a ImageGen, no edita archivos, no reenvia jobs,
 no publica ni imprime tokens/secretos/contenido editorial privado.
 Ejecutar como usuario habitual de Windows; no necesita permisos de administrador.
#>
[CmdletBinding()]
param(
  [ValidatePattern('^[A-Za-z0-9_-]{6,80}$')]
  [string]$NewsId = 'a3068af1c5fe',
  [ValidatePattern('^[A-Za-z0-9_-]{6,80}$')]
  [string]$TrendId = '82f5a317d5c7',
  [switch]$OnlyLocal
)
$ErrorActionPreference='Continue'
$BaseDir='C:\TTiTTulares'
function Emit([string]$Label,[string]$Status,[string]$Info=''){
  $clean=($Info -replace '(?i)(authorization|token|secret|password|api[_-]?key)\s*[:=]\s*[^\s,;]+','$1=[OCULTO]')
  $clean=($clean -replace 'https?://\S+','[url]')
  if($clean.Length -gt 140){$clean=$clean.Substring(0,140)}
  Write-Host ('TTIMAGE_DIAG '+$Label+' '+$Status+' '+$clean)
}
function SafeStamp([object]$Value){
  $v=[string]$Value
  if($v -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'){return $v.Substring(0,[Math]::Min(30,$v.Length))}
  return ''
}
function LocalFiles([string]$Project,[string]$TargetId){
  $component=if($Project -eq 'NEWS'){'TTiTTularesWebImages.cjs'}else{'TTendenciasWebImages.cjs'}
  Emit ($Project+'_CONSUMER') $(if(Test-Path -LiteralPath (Join-Path $BaseDir $component)){'INSTALLED'}else{'ABSENT'}) $component
  $dir=Join-Path $BaseDir $(if($Project -eq 'NEWS'){'ttittulares-web-images'}else{'ttendencias-web-images'})
  if(-not (Test-Path -LiteralPath $dir)){Emit ($Project+'_RECEIPT') 'NO_DIRECTORY';return}
  $receipts=@(Get-ChildItem -LiteralPath $dir -File -Filter '*.json' -ErrorAction SilentlyContinue)
  $hits=0
  foreach($file in $receipts){
    try {
      $r=Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
      if(([string]$r.target_id) -ne $TargetId){continue}
      $hits++
      $cmd=[string]$r.command_id
      if($cmd -notmatch '^[A-Za-z0-9_-]{6,160}$'){Emit ($Project+'_RECEIPT') 'INVALID_COMMAND';continue}
      $st=[string]$r.status
      if($st -notmatch '^[A-Za-z0-9_-]{1,48}$'){$st='UNKNOWN'}
      $reason=[string]$r.reason
      if($reason -notmatch '^[A-Za-z0-9_:-]{1,120}$'){$reason='unavailable'}
      Emit ($Project+'_RECEIPT') $st ('command='+$cmd+' revision='+[string]$r.revision+' reason='+$reason+' checked='+[string](SafeStamp $r.checked_at))
      $originalDir=Join-Path $dir 'originals'
      $files=if(Test-Path -LiteralPath $originalDir){@(Get-ChildItem -LiteralPath $originalDir -File -Filter ($cmd+'-*') -ErrorAction SilentlyContinue)}else{@()}
      $total=0
      foreach($original in $files){$total+=$original.Length}
      Emit ($Project+'_LOCAL_ORIGINAL') $(if($files.Count -gt 0){'PRESENT'}else{'ABSENT'}) ('files='+$files.Count+' bytes='+$total)
    } catch {Emit ($Project+'_RECEIPT') 'UNREADABLE'}
  }
  if($hits -eq 0){Emit ($Project+'_RECEIPT') 'NO_MATCH' ('id='+$TargetId)}
}
function ReadPublicJob([string]$Project,[string]$TargetId){
  $branch=if($Project -eq 'NEWS'){'control/ttittulares-run-trigger-v2'}else{'control/ttendencias-run-trigger'}
  $folder=if($Project -eq 'NEWS'){'ttittulares'}else{'trends'}
  $uri='https://raw.githubusercontent.com/fabricelop/europapress-rss/'+$branch+'/'+$folder+'/image-runs/jobs/'+$TargetId+'.json?t='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  try{
    $j=Invoke-RestMethod -Method Get -Uri $uri -TimeoutSec 10 -Headers @{'Cache-Control'='no-cache';'User-Agent'='TTImages-ReadOnly-Diagnostic'} -ErrorAction Stop
    if(([string]$j.target_id) -ne $TargetId){Emit ($Project+'_JOB') 'IDENTITY_MISMATCH';return}
    $status=[string]$j.status
    if($status -notmatch '^[A-Za-z0-9_-]{1,40}$'){$status='UNKNOWN'}
    $stage=[string]$j.web_image.stage
    if($stage -notmatch '^[A-Za-z0-9_-]{1,40}$'){$stage='NONE'}
    $sha=if([string]$j.upload_sha256 -match '^[0-9a-fA-F]{64}$'){'yes'}else{'no'}
    Emit ($Project+'_JOB') $status ('revision='+[string]$j.revision+' sha256='+$sha+' receipt='+$stage+' updated='+[string](SafeStamp $j.updated_at))
  } catch {Emit ($Project+'_JOB') 'UNAVAILABLE_OR_NOT_CREATED'}
}
function CheckCdp([int]$Port){
  try{
    $uri='http://127.0.0.1:'+ $Port +'/json/list'
    $pages=@(Invoke-RestMethod -Uri $uri -TimeoutSec 4 -ErrorAction Stop)
    $chat=@($pages|Where-Object{[string]$_.type -eq 'page' -and [string]$_.url -like 'https://chatgpt.com/*'})
    Emit ('CDP'+$Port) 'AVAILABLE' ('tabs='+$pages.Count+' chat_tabs='+$chat.Count)
  }catch{Emit ('CDP'+$Port) 'UNAVAILABLE'}
}
Emit 'START' 'READ_ONLY' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
Emit 'ROOT' $(if(Test-Path -LiteralPath $BaseDir){'PRESENT'}else{'ABSENT'})
LocalFiles 'NEWS' $NewsId
LocalFiles 'TRENDS' $TrendId
CheckCdp 9223
CheckCdp 9234
if(-not $OnlyLocal){
  ReadPublicJob 'NEWS' $NewsId
  ReadPublicJob 'TRENDS' $TrendId
}
Emit 'END' 'NO_CHANGES'
