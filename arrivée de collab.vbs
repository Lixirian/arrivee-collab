' Lanceur portable pour arrivee collab.ps1 (sans ?l?vation)
Option Explicit

Dim WShell, FSO, CurrentPath, ScriptFile, PowerShellExe

Set WShell = CreateObject("WScript.Shell")
Set FSO = CreateObject("Scripting.FileSystemObject")

CurrentPath = FSO.GetParentFolderName(WScript.ScriptFullName) & "\"
ScriptFile = CurrentPath & "arrivee collab.ps1"
PowerShellExe = "powershell.exe"

If Not FSO.FileExists(ScriptFile) Then
    MsgBox "Erreur : Le fichier 'arrivee collab.ps1' est introuvable dans " & CurrentPath, vbCritical, "Fichier manquant"
    WScript.Quit
End If

WShell.Run """" & PowerShellExe & """ -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File """ & ScriptFile & """", 0, False

Set FSO = Nothing
Set WShell = Nothing
