# Primer uso: autenticar UNA VEZ el perfil de imágenes (NO usa el editorial).
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:LOCALAPPDATA 'TTActualidadV2'
$profile = Join-Path $root 'ChromeProfileImages'
$chrome = Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
if (!(Test-Path -LiteralPath $chrome)) { throw 'Chrome no encontrado' }
New-Item -ItemType Directory -Path $profile -Force | Out-Null
Write-Host 'TT_V2_IMAGE_PROFILE=INDEPENDENT'
Write-Host 'Inicia sesión en ChatGPT en la ventana que se abrirá y ciérrala después.'
Write-Host 'El Chrome editorial y los Chrome V1 no se modifican.'
$args = @('--user-data-dir=' + $profile, '--no-first-run', 'https://chatgpt.com/')
Start-Process -FilePath $chrome -ArgumentList $args -Wait
Write-Host 'TT_V2_IMAGE_LOGIN_WINDOW_CLOSED=YES'
