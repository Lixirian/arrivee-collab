' ============================================================
'  Arrivee Collaborateur - lanceur des raccourcis, SANS console.
'  Copie installee dans %LOCALAPPDATA%\Arrivee-Collab\launcher\.
'  Execute bootstrap.ps1 (reparation si besoin, puis lancement).
' ============================================================
Option Explicit
Dim shell, fso, scriptDir, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
' Chemin absolu de powershell.exe (jamais resolu par le PATH).
cmd = """" & shell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDir & "\bootstrap.ps1"""
shell.Run cmd, 0, False
