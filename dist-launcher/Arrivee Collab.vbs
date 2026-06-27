' Lanceur masque (aucune fenetre console) : execute bootstrap.ps1 du meme dossier.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\bootstrap.ps1""", 0, False
