# Pure XML transformation; never registers or stops a process.
function ConvertTo-NewsHiddenTaskXml {
 [CmdletBinding()]
 param([Parameter(Mandatory=$true)][string]$Xml,
       [Parameter(Mandatory=$true)][string]$Runner,
       [Parameter(Mandatory=$true)][string]$Launcher,
       [Parameter(Mandatory=$true)][string]$Wscript)
 [xml]$doc=$Xml
 $ns=New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
 $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
 $actions=@($doc.SelectNodes('/t:Task/t:Actions/*',$ns))
 if($actions.Count -ne 1 -or $actions[0].LocalName -ne 'Exec'){throw 'NEWS_TASK_ACTION_UNKNOWN'}
 $exec=$actions[0]
 $command=$exec.SelectSingleNode('t:Command',$ns)
 $arguments=$exec.SelectSingleNode('t:Arguments',$ns)
 if(-not $command -or -not $arguments){throw 'NEWS_TASK_ACTION_INCOMPLETE'}
 $expectedOld='-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+$Runner+'"'
 $expectedNew='//B //Nologo "'+$Launcher+'" "'+$Runner+'"'
 $oldExecutable=[IO.Path]::GetFileName($command.InnerText)
 $knownOld=$oldExecutable -ieq 'powershell.exe' -and $arguments.InnerText -ceq $expectedOld
 $knownNew=$oldExecutable -ieq 'wscript.exe' -and $arguments.InnerText -ceq $expectedNew
 if(-not ($knownOld -or $knownNew)){throw 'NEWS_TASK_CUSTOM_ACTION_PRESERVED'}
 $command.InnerText=$Wscript
 $arguments.InnerText=$expectedNew
 $settings=$doc.SelectSingleNode('/t:Task/t:Settings',$ns)
 if(-not $settings){throw 'NEWS_TASK_SETTINGS_MISSING'}
 $hidden=$settings.SelectSingleNode('t:Hidden',$ns)
 if(-not $hidden){
  $hidden=$doc.CreateElement('Hidden',$ns.LookupNamespace('t'))
  [void]$settings.AppendChild($hidden)
 }
 $hidden.InnerText='true'
 return $doc.OuterXml
}
