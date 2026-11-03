#requires -Version 5.1
$ErrorActionPreference='Stop'
$base='C:\TTiTTulares'
$root=Join-Path $env:LOCALAPPDATA 'TTImageRelay'
$profile=Join-Path $root 'ChromeProfile'
function Note([string]$text){
 $file=Join-Path $base 'relay9234-guard.log'
 if((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 131072){$lines=@(Get-Content -LiteralPath $file -Tail 100);[IO.File]::WriteAllLines($file,$lines)}
 Add-Content -LiteralPath $file -Value ((Get-Date -Format o)+' '+$text)
}
function Available {
 try{$v=Invoke-RestMethod -Uri 'http://127.0.0.1:9234/json/version' -TimeoutSec 3;return [bool]$v.webSocketDebuggerUrl}catch{return $false}
}
$mutex=New-Object Threading.Mutex($false,'Local\TT_Relay9234_Boot')
if(-not $mutex.WaitOne(0)){$mutex.Dispose();exit 0}
try {
 if(Available){Note 'ALREADY_AVAILABLE';exit 0}
 if(-not(Test-Path -LiteralPath $profile)){Note 'EXISTING_PROFILE_MISSING';exit 0}
 $usingProfile=@(Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" | Where-Object {[string]$_.CommandLine -like ('*'+$profile+'*')})
 if($usingProfile.Count){Note 'PROFILE_BUSY_NO_RESTART';exit 0}
 $free=[int64](Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory * 1KB
 if($free -lt 3GB){Note ('LOW_RAM_GB='+[math]::Round($free/1GB,2));exit 0}
 $paths=@((Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),(Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),(Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe'))
 $chrome=$paths | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
 if(-not $chrome){Note 'CHROME_NOT_FOUND';exit 0}
 # Headless Chrome cannot flash a CMD/browser window. Reuse the EXISTING profile.
 $argsChrome=@('--headless=new','--remote-debugging-address=127.0.0.1','--remote-debugging-port=9234',('--user-data-dir="'+$profile+'"'),'--no-first-run','--no-default-browser-check','about:blank')
 Start-Process -FilePath $chrome -ArgumentList $argsChrome -WindowStyle Hidden | Out-Null
 for($i=0;$i -lt 8;$i++){if(Available){Note 'STARTED_HIDDEN';exit 0};Start-Sleep -Milliseconds 500}
 Note 'START_NOT_CONFIRMED_NO_KILL'
} catch {Note 'GUARD_FAILED_NO_RESTART'} finally {$mutex.ReleaseMutex();$mutex.Dispose()}
