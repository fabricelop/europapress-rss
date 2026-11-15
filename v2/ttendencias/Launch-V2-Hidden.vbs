Option Explicit
' WScript nunca crea una ventana de consola. Ejecuta PowerShell oculto.
' La tarea original mantiene sus triggers y estado, y recibe su exit code.
Dim shell, script, binary, cmd, result
If WScript.Arguments.Count <> 1 Then WScript.Quit 2
script = WScript.Arguments(0)
Set shell = CreateObject("WScript.Shell")
binary = shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
cmd = """" & binary & """ -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & Replace(script, """", "") & """"
result = shell.Run(cmd, 0, True)
WScript.Quit result
