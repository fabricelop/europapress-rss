Option Explicit
Dim shell, fso, baseDir, scriptPath, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
baseDir = fso.GetParentFolderName(WScript.ScriptFullName)
scriptPath = fso.BuildPath(baseDir, "watchdog.ps1")
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & scriptPath & """"
Dim exitCode
exitCode = shell.Run(cmd, 0, True)
WScript.Quit exitCode
