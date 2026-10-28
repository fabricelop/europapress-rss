# Removes ONLY the legacy TTActualidad Cloudflare Worker, not iPhone/Windows.
# Execute from a machine already authenticated with Cloudflare Wrangler.
# Inspect the production service and confirm Windows works before -Execute.
[CmdletBinding()]
param([switch]$Execute)
$ErrorActionPreference = 'Stop'
$worker = 'ttactualidad-decisions-pilot'
Write-Host 'Legacy TTActualidad web Worker:' $worker
Write-Host 'IMPORTANT: This deletes the web endpoint and its cloud resources; it does not affect native iOS or the Windows EXE.'
Write-Host 'Do NOT delete shared GitHub Pages, unrelated Workers or KV namespaces.'
$wrangler = Get-Command wrangler -ErrorAction SilentlyContinue
if ($wrangler) {
  $cmd = $wrangler.Source
  $prefix = @()
} else {
  $npx = Get-Command npx -ErrorAction SilentlyContinue
  if (-not $npx) { throw 'Wrangler/npx not found. Install Wrangler or retire the Worker through the Cloudflare dashboard.' }
  $cmd = $npx.Source
  $prefix = @('--yes','wrangler')
}
& $cmd @prefix whoami
if ($LASTEXITCODE -ne 0) { throw 'Cloudflare account is not connected; no resources deleted.' }
if (-not $Execute) {
  Write-Host 'PREVIEW ONLY: verifying exact target through wrangler --dry-run.'
  & $cmd @prefix delete --name $worker --dry-run
  Write-Host 'No deletion performed. Once TTActualidad.exe is tested, rerun with -Execute.'
  exit 0
}
$answer = Read-Host 'Confirm you have tested Windows and type RETIRAR-TTACTUALIDAD to delete ONLY this Worker'
if ($answer -cne 'RETIRAR-TTACTUALIDAD') { throw 'Cancelled; nothing deleted.' }
& $cmd @prefix delete --name $worker
if ($LASTEXITCODE -ne 0) { throw 'Cloudflare did not confirm Worker deletion. Do not assume removal.' }
Write-Host 'Worker removal command finished. Verify the service no longer appears in the Cloudflare dashboard.'
