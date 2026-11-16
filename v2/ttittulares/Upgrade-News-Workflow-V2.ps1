# Cooperatively drain only News V2. Never kill Chrome or touch Trends/SeLo/V1.
$ErrorActionPreference='Stop'
$root=Join-Path $env:LOCALAPPDATA 'TTActualidadNoticiasV2'
$tasks=@('TTActualidadNoticiasV2-Editorial','TTActualidadNoticiasV2-Images')
foreach($name in $tasks){
 $task=Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 if($task){Disable-ScheduledTask -TaskName $name|Out-Null}
}
$utf8=New-Object Text.UTF8Encoding($false)
if(Test-Path $root){
 [IO.File]::WriteAllText((Join-Path $root 'editorial.enabled'),'TTN2_EDITORIAL_ENABLED=NO',$utf8)
 [IO.File]::WriteAllText((Join-Path $root 'images.enabled'),'TTN2_IMAGES_ENABLED=NO',$utf8)
}
$until=(Get-Date).AddMinutes(25)
do{
 $active=@(Get-CimInstance Win32_Process|Where-Object {
  $_.Name -match '^(python|pythonw|py)\.exe$' -and [string]$_.CommandLine -match 'v2\.ttittulares\.(editorial_consumer_v2|news_images_v2)'
 })
 if(-not $active.Count){break}
 if((Get-Date) -gt $until){throw 'Noticias V2 sigue trabajando. No se fuerza cierre ni se reemplaza codigo.'}
 Write-Host ('TTN2_WAIT_OWN_WORKERS='+$active.Count)
 Start-Sleep -Seconds 10
}while($true)
$install=Join-Path $env:TEMP 'Install-News-Editorial-V2.ps1'
Invoke-WebRequest -UseBasicParsing -Uri 'https://raw.githubusercontent.com/fabricelop/europapress-rss/feature/ttactualidad-v2-clean/v2/ttittulares/Install-News-Editorial-V2.ps1' -OutFile $install
& $install -EnableImages
