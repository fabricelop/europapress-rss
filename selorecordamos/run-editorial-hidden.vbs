Option Explicit
' SeLoRecordamos: wrapper completamente oculto, como los listeners existentes.
Dim shell, fso, baseDir, scriptPath, powershell, cmd, exitCode
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(baseDir, "run-editorial-local.ps1")
powershell = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = Chr(34) & powershell & Chr(34) & " -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File " & Chr(34) & scriptPath & Chr(34)
exitCode = shell.Run(cmd, 0, True)
WScript.Quit exitCode
