' TTendencias-XContext invisible Windows Task Scheduler launcher.
' Only this task: no shared Chrome, SeLoRecordamos or editorial side effects.
Option Explicit
Dim fso, shell, here, runner, root, cmd, exitCode
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")
here = fso.GetParentFolderName(WScript.ScriptFullName)
runner = fso.BuildPath(here, "Run-TTendencias-X-Local.ps1")
root = fso.GetParentFolderName(here)
If WScript.Arguments.Count > 0 Then
    If LCase(CStr(WScript.Arguments(0))) = "--self-test" Then
        If Not fso.FileExists(runner) Then WScript.Quit 2
        WScript.Echo "TT_X_INVISIBLE_LAUNCHER_OK"
        WScript.Quit 0
    End If
End If
If Not fso.FileExists(runner) Then WScript.Quit 2
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & runner & """ -RepoRoot """ & root & """"
exitCode = shell.Run(cmd, 0, True)
WScript.Quit exitCode
