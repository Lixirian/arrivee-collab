# --- Lanceur VBS portable sans élévation pour l'arrivée collab ---

# Nom du script principal à lancer (ici le script d'arrivée collab)
$mainScriptName = "arrivee collab.ps1"

# Récupérer le dossier courant du script principal
$scriptDirectory = Split-Path -Parent -Path $MyInvocation.MyCommand.Path

# Vérifier que le script principal existe
$mainScriptPath = Join-Path -Path $scriptDirectory -ChildPath $mainScriptName
if (-not (Test-Path $mainScriptPath)) {
    Write-Error "Le script principal '$mainScriptName' est introuvable dans le dossier '$scriptDirectory'."
    exit 1
}

# Nom du fichier VBS à générer
$vbsLauncherName = "arrivée de collab.vbs"
$vbsLauncherPath = Join-Path -Path $scriptDirectory -ChildPath $vbsLauncherName

# Contenu du lanceur VBS sans élévation
$vbsContent = @"
' Lanceur portable pour $mainScriptName (sans élévation)
Option Explicit

Dim WShell, FSO, CurrentPath, ScriptFile, PowerShellExe

Set WShell = CreateObject("WScript.Shell")
Set FSO = CreateObject("Scripting.FileSystemObject")

CurrentPath = FSO.GetParentFolderName(WScript.ScriptFullName) & "\"
ScriptFile = CurrentPath & "$mainScriptName"
PowerShellExe = "powershell.exe"

If Not FSO.FileExists(ScriptFile) Then
    MsgBox "Erreur : Le fichier '$mainScriptName' est introuvable dans " & CurrentPath, vbCritical, "Fichier manquant"
    WScript.Quit
End If

WShell.Run """" & PowerShellExe & """ -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File """ & ScriptFile & """", 0, False

Set FSO = Nothing
Set WShell = Nothing
"@

# Création du VBS avec encodage ASCII
Set-Content -Path $vbsLauncherPath -Value $vbsContent -Encoding ASCII

if (Test-Path $vbsLauncherPath) {
    Write-Host "`nLanceur VBS portable créé avec succès : $vbsLauncherPath" -ForegroundColor Green
    Write-Host "Ce lanceur est totalement portable, et ne demande pas de droits administrateur." -ForegroundColor Cyan
    Write-Host "Double-cliquez sur '$vbsLauncherName' pour lancer le script d'arrivée collaborateur." -ForegroundColor Cyan

    # Si une icône est présente, informer l'utilisateur sur la méthode manuelle
    $iconPath = Join-Path -Path $scriptDirectory -ChildPath "arrivee-collab.ico"
    if (Test-Path $iconPath) {
        Write-Host "Note : pour attribuer une icône, clic droit > Propriétés > Changer d'icône... > choisissez 'arrivee-collab.ico'." -ForegroundColor Yellow
    }
} else {
    Write-Error "Erreur lors de la création du lanceur VBS!"
}