' ============================================================
'  Arrivee Collaborateur - lanceur SANS fenetre console.
'  Demarre PowerShell masque en -STA (requis pour le presse-papiers
'  WinForms). Pas de .exe, pas d'elevation.
' ============================================================
Option Explicit
Dim shell, fso, scriptDir, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & scriptDir & "\arrivee collab.ps1"""
shell.Run cmd, 0, False
