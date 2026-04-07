Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- Barre de titre sombre Windows 10/11 ---
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class DarkTitleBar {
    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("uxtheme.dll", EntryPoint = "#135")]
    private static extern int SetPreferredAppMode(int mode);
    [DllImport("uxtheme.dll", EntryPoint = "#136")]
    private static extern void FlushMenuThemes();
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
    public static extern int SetWindowTheme(IntPtr hwnd, string subAppName, string subIdList);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string AppID);
    [DllImport("user32.dll")]
    private static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string className, string windowName);
    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(IntPtr hwnd, EnumChildProc callback, IntPtr lParam);
    private delegate bool EnumChildProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    [DllImport("user32.dll")]
    private static extern bool UnhookWinEvent(IntPtr hWinEventHook);
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
    private delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
    private static WinEventDelegate _hookDelegate;
    private static IntPtr _hookHandle;
    public static void SetAppId(string appId) {
        SetCurrentProcessExplicitAppUserModelID(appId);
    }
    public static void Enable(IntPtr handle) {
        int val = 1;
        DwmSetWindowAttribute(handle, 20, ref val, 4);
    }
    public static void EnableAppDarkMode() {
        SetPreferredAppMode(1);
        FlushMenuThemes();
    }
    public static void ApplyDarkScrollbar(IntPtr handle) {
        SetWindowTheme(handle, "DarkMode_Explorer", null);
    }
    private static void ApplyDarkToWindow(IntPtr hwnd) {
        int val = 1;
        DwmSetWindowAttribute(hwnd, 20, ref val, 4);
        SetWindowTheme(hwnd, "DarkMode_Explorer", null);
        EnumChildWindows(hwnd, (child, lp) => {
            SetWindowTheme(child, "DarkMode_Explorer", null);
            return true;
        }, IntPtr.Zero);
    }
    public static void HookCalendarPopup() {
        _hookDelegate = new WinEventDelegate((hook, evType, hwnd, idObj, idChild, thread, time) => {
            var sb = new System.Text.StringBuilder(256);
            GetClassName(hwnd, sb, 256);
            string cls = sb.ToString();
            if (cls == "SysMonthCal32" || cls == "DropDown") {
                ApplyDarkToWindow(hwnd);
            }
        });
        uint pid = (uint)System.Diagnostics.Process.GetCurrentProcess().Id;
        _hookHandle = SetWinEventHook(0x0003, 0x0003, IntPtr.Zero, _hookDelegate, pid, 0, 0);
    }
}
"@
try { [DarkTitleBar]::EnableAppDarkMode() } catch {}
try { [DarkTitleBar]::SetAppId("SNCF.ArriveeCollaborateur") } catch {}
try { [DarkTitleBar]::HookCalendarPopup() } catch {}

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

# Détermination du bon dossier de base, que ce soit .ps1 ou .exe ou terminal ouvert ailleurs
if ([System.AppDomain]::CurrentDomain.FriendlyName -like '*.exe') {
    $baseDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
} elseif ($PSScriptRoot) {
    $baseDir = $PSScriptRoot
} else {
    $baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# Chemins dossiers et fichiers importants
$resourcesFolder = Join-Path $baseDir "Resources"
$motDePasseFolder = Join-Path $baseDir "Mot de passe"
$archiveFolder = Join-Path $baseDir "Archive message"

# --- Palette de couleurs (thème sombre style LixiSpace) ---
$cBgMain       = [Drawing.Color]::FromArgb(30, 30, 30)
$cBgSecondary  = [Drawing.Color]::FromArgb(37, 37, 38)
$cSurface      = [Drawing.Color]::FromArgb(45, 45, 48)
$cBorder       = [Drawing.Color]::FromArgb(62, 62, 66)
$cAccentViolet = [Drawing.Color]::FromArgb(155, 89, 182)
$cAccentVioletHover = [Drawing.Color]::FromArgb(142, 68, 173)
$cAccentBlue   = [Drawing.Color]::FromArgb(0, 122, 204)
$cAccentBlueHover = [Drawing.Color]::FromArgb(0, 90, 158)
$cDanger       = [Drawing.Color]::FromArgb(231, 76, 60)
$cSuccess      = [Drawing.Color]::FromArgb(39, 174, 96)
$cWarning      = [Drawing.Color]::FromArgb(243, 156, 18)
$cTextPrimary  = [Drawing.Color]::FromArgb(204, 204, 204)
$cTextSecondary= [Drawing.Color]::FromArgb(128, 128, 128)
$cWhite        = [Drawing.Color]::White

function Show-AlertDialog {
    param(
        [string]$message,
        [string]$title="IMPORTANT",
        [switch]$withCancel,
        [string]$buttonYesText="Oui",
        [string]$buttonNoText="Non"
    )
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = $title
    $dlg.Size = New-Object Drawing.Size(620, 320)
    $dlg.StartPosition = "CenterScreen"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.BackColor = $cBgMain
    $dlg.ForeColor = $cTextPrimary
    $dlg.Font = [Drawing.Font]::new("Segoe UI", 10)
    $dlgIconPath = Join-Path $baseDir "image-arrivee-collab.ico"
    if (Test-Path $dlgIconPath) { try { $dlg.Icon = New-Object Drawing.Icon($dlgIconPath) } catch {} }
    $dlg.Add_Shown({
        try {
            [DarkTitleBar]::Enable($this.Handle)
            [DarkTitleBar]::ApplyDarkScrollbar($rtbM.Handle)
        } catch {}
    })

    # Barre d'accent violette en haut
    $bar = New-Object Windows.Forms.Panel
    $bar.Dock = "Top"; $bar.Height = 3; $bar.BackColor = $cAccentViolet

    # Titre
    $lblT = New-Object Windows.Forms.Label
    $lblT.Text = $title
    $lblT.Font = [Drawing.Font]::new("Segoe UI", 15, [Drawing.FontStyle]::Bold)
    $lblT.ForeColor = $cAccentViolet
    $lblT.Location = New-Object Drawing.Point(25, 15)
    $lblT.AutoSize = $true

    # Corps du message (scrollable, dark scrollbar)
    $rtbM = New-Object Windows.Forms.RichTextBox
    $rtbM.Text = $message
    $rtbM.BackColor = $cBgMain
    $rtbM.ForeColor = $cTextPrimary
    $rtbM.Font = [Drawing.Font]::new("Segoe UI", 10)
    $rtbM.Location = New-Object Drawing.Point(25, 55)
    $rtbM.Size = New-Object Drawing.Size(555, 160)
    $rtbM.ReadOnly = $true
    $rtbM.BorderStyle = 'None'

    # Panneau boutons
    $bp = New-Object Windows.Forms.Panel
    $bp.Dock = "Bottom"; $bp.Height = 55; $bp.BackColor = $cBgSecondary

    if ($withCancel) {
        $btnY = New-Object Windows.Forms.Button
        $btnY.Text = $buttonYesText
        $btnY.DialogResult = [Windows.Forms.DialogResult]::Yes
        $btnY.Size = New-Object Drawing.Size(170, 35)
        $btnY.Location = New-Object Drawing.Point(250, 10)
        $btnY.FlatStyle = 'Flat'
        $btnY.FlatAppearance.BorderSize = 0
        $btnY.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
        $btnY.BackColor = $cAccentViolet
        $btnY.ForeColor = $cWhite
        $btnY.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
        $btnY.Cursor = [Windows.Forms.Cursors]::Hand
        $bp.Controls.Add($btnY)
        $dlg.AcceptButton = $btnY

        $btnN = New-Object Windows.Forms.Button
        $btnN.Text = $buttonNoText
        $btnN.DialogResult = [Windows.Forms.DialogResult]::No
        $btnN.Size = New-Object Drawing.Size(170, 35)
        $btnN.Location = New-Object Drawing.Point(430, 10)
        $btnN.FlatStyle = 'Flat'
        $btnN.FlatAppearance.BorderSize = 0
        $btnN.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(78, 78, 82)
        $btnN.BackColor = $cBorder
        $btnN.ForeColor = $cTextPrimary
        $btnN.Font = [Drawing.Font]::new("Segoe UI", 10)
        $btnN.Cursor = [Windows.Forms.Cursors]::Hand
        $bp.Controls.Add($btnN)
        $dlg.CancelButton = $btnN
    } else {
        $btnO = New-Object Windows.Forms.Button
        $btnO.Text = "OK"
        $btnO.DialogResult = [Windows.Forms.DialogResult]::OK
        $btnO.Size = New-Object Drawing.Size(120, 35)
        $btnO.Location = New-Object Drawing.Point([int](($dlg.ClientSize.Width - 120) / 2), 10)
        $btnO.FlatStyle = 'Flat'
        $btnO.FlatAppearance.BorderSize = 0
        $btnO.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
        $btnO.BackColor = $cAccentViolet
        $btnO.ForeColor = $cWhite
        $btnO.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
        $btnO.Cursor = [Windows.Forms.Cursors]::Hand
        $bp.Controls.Add($btnO)
        $dlg.AcceptButton = $btnO
    }

    $dlg.Controls.AddRange(@($rtbM, $lblT, $bar, $bp))
    return $dlg.ShowDialog()
}

# Vérification du dossier Resources
if (-not (Test-Path $resourcesFolder)) {
    Show-AlertDialog -message "Le dossier Resources n'a pas été trouvé dans : $baseDir`nVérifiez la présence du dossier et relancez." -title "Dossier Resources manquant"
    exit
}

# Création automatique des sous-dossiers si nécessaire
foreach ($folder in @($motDePasseFolder, $archiveFolder)) {
    if (-not (Test-Path $folder)) { New-Item -Path $folder -ItemType Directory | Out-Null }
}

# Chemins des images
$cheminHeader = Join-Path $resourcesFolder 'image arrivee collab.jpg'
$cheminSignature = Join-Path $resourcesFolder 'Signature.png'

# Vérification de la présence des images
$imagesManquantes = @()
if (-not (Test-Path $cheminHeader)) { $imagesManquantes += "image arrivee collab.jpg" }
if (-not (Test-Path $cheminSignature)) { $imagesManquantes += "Signature.png" }
if ($imagesManquantes.Count -gt 0) {
    $msg = "Les fichiers suivants sont manquants dans le dossier Resources:`n" + ($imagesManquantes -join "`n")
    Show-AlertDialog -message $msg -title "Fichiers manquants"
}

function Show-BeneficiaireDialog {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = "Informations bénéficiaire"
    $dlg.Size = New-Object Drawing.Size(650, 280)
    $dlg.StartPosition = "CenterScreen"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $cBgMain; $dlg.ForeColor = $cTextPrimary
    $dlg.Font = [Drawing.Font]::new("Segoe UI", 10)
    $dlgIconPath = Join-Path $baseDir "image-arrivee-collab.ico"
    if (Test-Path $dlgIconPath) { try { $dlg.Icon = New-Object Drawing.Icon($dlgIconPath) } catch {} }
    $dlg.Add_Shown({ try { [DarkTitleBar]::Enable($this.Handle) } catch {} })

    $bar = New-Object Windows.Forms.Panel
    $bar.Dock = "Top"; $bar.Height = 3; $bar.BackColor = $cAccentViolet

    $lblT = New-Object Windows.Forms.Label
    $lblT.Text = "Informations bénéficiaire"
    $lblT.Font = [Drawing.Font]::new("Segoe UI", 13, [Drawing.FontStyle]::Bold)
    $lblT.ForeColor = $cAccentViolet
    $lblT.Location = New-Object Drawing.Point(25, 15); $lblT.AutoSize = $true

    $lblEmailB = New-Object Windows.Forms.Label
    $lblEmailB.Text = "Adresse de messagerie du bénéficiaire :"
    $lblEmailB.Location = New-Object Drawing.Point(25, 55); $lblEmailB.AutoSize = $true
    $lblEmailB.ForeColor = $cTextSecondary

    $txtEmailB = New-Object Windows.Forms.TextBox
    $txtEmailB.Location = New-Object Drawing.Point(25, 78); $txtEmailB.Width = 585
    $txtEmailB.BackColor = $cSurface; $txtEmailB.ForeColor = $cTextPrimary
    $txtEmailB.BorderStyle = 'FixedSingle'; $txtEmailB.Font = [Drawing.Font]::new("Segoe UI", 10)

    $lblOU = New-Object Windows.Forms.Label
    $lblOU.Text = "OU (Organizational Unit) :"
    $lblOU.Location = New-Object Drawing.Point(25, 115); $lblOU.AutoSize = $true
    $lblOU.ForeColor = $cTextSecondary

    $cboOU = New-Object Windows.Forms.ComboBox
    $cboOU.Location = New-Object Drawing.Point(25, 138); $cboOU.Width = 585
    $cboOU.BackColor = $cSurface; $cboOU.ForeColor = $cTextPrimary
    $cboOU.FlatStyle = 'Flat'
    $cboOU.Font = [Drawing.Font]::new("Segoe UI", 10)
    $cboOU.DropDownStyle = 'DropDownList'
    $ouMap = [ordered]@{
        "GaresEtConnexions"        = "COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/GaresEtConnexions/Utilisateurs"
        "HEXAFRET"                 = "COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/HEXAFRET/Utilisateurs"
        "OPTIMSERVICES"            = "COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/OPTIMSERVICES/Utilisateurs"
        "SARESEAU"                 = "COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/SARESEAU/Utilisateurs"
        "SASNCF"                   = "COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/SASNCF/Utilisateurs"
        "SAVOYAGEURS"              = "COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/SAVOYAGEURS/Utilisateurs"
        "SudAzur"                  = "COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/SudAzur/Utilisateurs"
        "SudMobilitesTechnologies" = "COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/SudMobilitesTechnologies/Utilisateurs"
        "TECHNIS"                  = "COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/TECHNIS/Utilisateurs"
    }
    $cboOU.Items.AddRange(@($ouMap.Keys))
    $cboOU.SelectedIndex = 7

    $bp = New-Object Windows.Forms.Panel
    $bp.Dock = "Bottom"; $bp.Height = 55; $bp.BackColor = $cBgSecondary

    $btnOK = New-Object Windows.Forms.Button
    $btnOK.Text = "Valider"
    $btnOK.DialogResult = [Windows.Forms.DialogResult]::OK
    $btnOK.Size = New-Object Drawing.Size(150, 35)
    $btnOK.Location = New-Object Drawing.Point(310, 10)
    $btnOK.FlatStyle = 'Flat'
    $btnOK.FlatAppearance.BorderSize = 0
    $btnOK.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
    $btnOK.BackColor = $cAccentViolet; $btnOK.ForeColor = $cWhite
    $btnOK.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $btnOK.Cursor = [Windows.Forms.Cursors]::Hand
    $bp.Controls.Add($btnOK); $dlg.AcceptButton = $btnOK

    $btnCancel = New-Object Windows.Forms.Button
    $btnCancel.Text = "Passer"
    $btnCancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $btnCancel.Size = New-Object Drawing.Size(150, 35)
    $btnCancel.Location = New-Object Drawing.Point(470, 10)
    $btnCancel.FlatStyle = 'Flat'
    $btnCancel.FlatAppearance.BorderSize = 0
    $btnCancel.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(78, 78, 82)
    $btnCancel.BackColor = $cBorder; $btnCancel.ForeColor = $cTextPrimary
    $btnCancel.Font = [Drawing.Font]::new("Segoe UI", 10)
    $btnCancel.Cursor = [Windows.Forms.Cursors]::Hand
    $bp.Controls.Add($btnCancel); $dlg.CancelButton = $btnCancel

    $dlg.Controls.AddRange(@($bar, $lblT, $lblEmailB, $txtEmailB, $lblOU, $cboOU, $bp))
    $result = $dlg.ShowDialog()
    if ($result -eq [Windows.Forms.DialogResult]::OK) {
        return @{ Email = $txtEmailB.Text.Trim(); OU = $ouMap[$cboOU.SelectedItem] }
    }
    return $null
}

function Generate-Password {
    $l=12
    $pool = (48..57)+(65..90)+(97..122)+(33..38) | ForEach-Object {[char]$_}
    -join (1..$l | ForEach-Object { $pool | Get-Random })
}
function Copy-Clipboard ($txt) { [System.Windows.Forms.Clipboard]::SetText($txt) }
function Creer-FichierMotDePasse ($pw, $nomPrenom) {
    $f = Join-Path $motDePasseFolder "$nomPrenom-motdepasse.txt"
    Set-Content -Path $f -Value $pw
    return $f
}
function Creer-Zip ($txt, $nomPrenom) {
    $z = Join-Path $motDePasseFolder "$nomPrenom.zip"
    $d = Join-Path $env:TEMP "tempZipSNCF"
    if (Test-Path $z) { Remove-Item $z -Force }
    if (Test-Path $d) { Remove-Item $d -Force -Recurse }
    New-Item $d -ItemType Directory | Out-Null
    Copy-Item $txt -Destination (Join-Path $d "mot_de_passe.txt")
    [System.IO.Compression.ZipFile]::CreateFromDirectory($d, $z)
    Remove-Item $d -Force -Recurse
    return $z
}
function Creer-FichierMsg ($sujet, $dest, $htmlBody, $zipPath, $sortie) {
    try {
        $outlook = New-Object -ComObject Outlook.Application
        $mail = $outlook.CreateItem(0)
        $mail.Subject = $sujet
        $mail.To = $dest
        $mail.BodyFormat = 2
        if ($zipPath -and (Test-Path $zipPath)) { $mail.Attachments.Add($zipPath) }
        $mail.HTMLBody = $htmlBody
        $mail.SaveAs($sortie, 3)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($mail)
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($outlook)
        [GC]::Collect()
        return $true
    } catch {
        Show-AlertDialog -message "Erreur lors de la création du message : $_" -title "Erreur"
        return $false
    }
}
function Attendre-FermetureOutlookEtDeplacer($cheminMsg) {
    $watcherScript = @"
    Start-Sleep -Seconds 5
    `$fileToWatch = '$cheminMsg'
    `$archiveFolder = '$archiveFolder'
    `$fileName = [System.IO.Path]::GetFileName(`$fileToWatch)
    `$archivePath = [System.IO.Path]::Combine(`$archiveFolder, `$fileName)
    `$maxAttempts = 30
    `$attempts = 0
    `$success = `$false
    while (-not `$success -and `$attempts -lt `$maxAttempts) {
        try {
            `$fileStream = [System.IO.File]::Open(`$fileToWatch, 'Open', 'ReadWrite', 'None')
            `$fileStream.Close()
            `$fileStream.Dispose()
            if (Test-Path `$fileToWatch) {
                if (Test-Path `$archivePath) { Remove-Item `$archivePath -Force }
                Move-Item -Path `$fileToWatch -Destination `$archiveFolder -Force
                `$success = `$true
            } else { `$success = `$true }
        } catch {
            Start-Sleep -Seconds 2
            `$attempts++
        }
    }
"@
    $tempScriptPath = [System.IO.Path]::GetTempFileName() + ".ps1"
    Set-Content -Path $tempScriptPath -Value $watcherScript
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$tempScriptPath`"" -WindowStyle Hidden
}

function Get-CorpsMessageHTML_Preview {
    param($objet, $nom, $prenom, $cheminHeader, $cheminSignature)
    return @"
<html>
<head>
<meta charset='UTF-8'>
<style>
    body { font-family: Segoe UI, Arial, sans-serif; font-size: 14px; margin: 0; padding: 0; background: #1E1E1E;
        scrollbar-base-color: #1E1E1E; scrollbar-face-color: #555; scrollbar-track-color: #252526;
        scrollbar-arrow-color: #808080; scrollbar-highlight-color: #555; scrollbar-shadow-color: #1E1E1E;
        scrollbar-3dlight-color: #252526; scrollbar-darkshadow-color: #1E1E1E; }
    .sujet-preview { background: #2D2D30; border-left: 3px solid #9B59B6; color: #9B59B6; font-size: 15px;
        font-weight: bold; padding: 10px 15px; margin: 12px 12px 0 12px; }
    hr.sujet { border: 0; border-top: 1px solid #3E3E42; margin: 0 12px; }
    .email-body { background: #fff; padding: 20px; margin: 0 12px 12px 12px; }
    .email-body h2 { color: #253A5E; margin-top: 0; }
    .email-body p { margin: 8px 0; color: #333; }
    .email-body a { color: #0066cc; text-decoration: underline; }
</style>
</head>
<body>
<div class='sujet-preview'>$objet</div>
<hr class='sujet'/>
<div class='email-body'>
<table style='width:100%'><tr>
<td style='width:140px; vertical-align:top;'><img src='file:///$cheminHeader' style='width:130px;'/></td>
<td style='vertical-align:top; padding-left:25px;'>
<h2>Arrivée d'un Agent SNCF</h2>
<p>Bonjour,</p>
<p>Vous avez été identifié comme déclarant de l'arrivée de <b>$prenom $nom</b>, nouveau collaborateur dans l'entreprise.</p>
<p>Son compte lui permettant d'accéder aux applications SNCF vient d'être créé et son mot de passe sera effectif d'ici 30mn maximum.</p>
<p><b>Merci de bien vouloir lui transmettre son mot de passe indiqué dans le fichier .zip en PJ</b> ainsi que les informations ci-après.</p>
<p>Pour répondre aux règles de sécurité SNCF, ce mot de passe devra être modifié dès que possible via le site <b>Mon-ID SNCF</b>.</p>
<p>La sécurité des mots de passe a été renforcée : les mots liés à votre contexte (nom, prénom, entité, ...) ou à l'entreprise (SNCF, train, cheminot, ...) ne sont plus acceptés pour construire un mot de passe.</p>
<p>Pour en savoir plus sur la politique de mot de passe en vigueur :</p>
<p><a href='https://sncf.sharepoint.com/sites/ADAAD/SitePages/politique-de-mot-de-passe-sncf.aspx'>https://sncf.sharepoint.com/sites/ADAAD/SitePages/politique-de-mot-de-passe-sncf.aspx</a><br />
<a href='https://sncf.sharepoint.com/sites/Mon-IDSNCF-SNCFContact/SitePages/azure-password-protection.aspx'>https://sncf.sharepoint.com/sites/Mon-IDSNCF-SNCFContact/SitePages/azure-password-protection.aspx</a></p>
<p>Il est vivement recommandé de renseigner un numéro de mobile sur le site Mon-ID SNCF pour faciliter de futures réinitialisations de mots de passe.</p>
<p>Pour en savoir plus sur l'utilisation de MON-ID : guides utilisateurs sur le <a href='https://sharepoint.com'>SharePoint</a>.</p>
<p><em>Ceci est un message automatique, merci de ne pas répondre.</em></p>
<div style='margin-top:20px; font-size:13px;'>
Cordialement,<br/>
<b>Votre Support Bureautique</b><br/>
SNCF - Solutions<br/>
DIRECTION SERVICES NUMERIQUES<br/>
<img src='file:///$cheminSignature' style='width:330px; margin-top:12px;'/>
</div>
</td></tr></table>
</div>
</body>
</html>
"@
}

function Get-CorpsMessageHTML_Final {
    param($nom, $prenom, $cheminHeader, $cheminSignature)
    return @"
<html>
<head>
<meta charset='UTF-8'>
<style>
    body { font-family: Arial, sans-serif; font-size: 14px; margin: 20px; }
    h2 { color: #253A5E; margin-top:0; }
    p { margin: 8px 0; }
    a { color: #0066cc; text-decoration: underline; }
</style>
</head>
<body>
<table style='width:100%'><tr>
<td style='width:140px; vertical-align:top;'><img src='file:///$cheminHeader' style='width:130px;'/></td>
<td style='vertical-align:top; padding-left:25px;'>
<h2>Arrivée d'un Agent SNCF</h2>
<p>Bonjour,</p>
<p>Vous avez été identifié comme déclarant de l'arrivée de <b>$prenom $nom</b>, nouveau collaborateur dans l'entreprise.</p>
<p>Son compte lui permettant d'accéder aux applications SNCF vient d'être créé et son mot de passe sera effectif d'ici 30mn maximum.</p>
<p><b>Merci de bien vouloir lui transmettre son mot de passe indiqué dans le fichier .zip en PJ</b> ainsi que les informations ci-après.</p>
<p>Pour répondre aux règles de sécurité SNCF, ce mot de passe devra être modifié dès que possible via le site <b>Mon-ID SNCF</b>.</p>
<p>La sécurité des mots de passe a été renforcée : les mots liés à votre contexte (nom, prénom, entité, ...) ou à l'entreprise (SNCF, train, cheminot, ...) ne sont plus acceptés pour construire un mot de passe.</p>
<p>Pour en savoir plus sur la politique de mot de passe en vigueur :</p>
<p><a href='https://sncf.sharepoint.com/sites/ADAAD/SitePages/politique-de-mot-de-passe-sncf.aspx'>https://sncf.sharepoint.com/sites/ADAAD/SitePages/politique-de-mot-de-passe-sncf.aspx</a><br />
<a href='https://sncf.sharepoint.com/sites/Mon-IDSNCF-SNCFContact/SitePages/azure-password-protection.aspx'>https://sncf.sharepoint.com/sites/Mon-IDSNCF-SNCFContact/SitePages/azure-password-protection.aspx</a></p>
<p>Il est vivement recommandé de renseigner un numéro de mobile sur le site Mon-ID SNCF pour faciliter de futures réinitialisations de mots de passe.</p>
<p>Pour en savoir plus sur l'utilisation de MON-ID : guides utilisateurs sur le <a href='https://sharepoint.com'>SharePoint</a>.</p>
<p><em>Ceci est un message automatique, merci de ne pas répondre.</em></p>
<div style='margin-top:20px; font-size:13px;'>
Cordialement,<br/>
<b>Votre Support Bureautique</b><br/>
SNCF - Solutions<br/>
DIRECTION SERVICES NUMERIQUES<br/>
<img src='file:///$cheminSignature' style='width:330px; margin-top:12px;'/>
</div>
</td></tr></table>
</body>
</html>
"@
}

function Get-CorpsMessageHTML_DejaInit_Preview {
    param($objet, $nom, $prenom, $dateInit, $cheminHeader, $cheminSignature)
    return @"
<html>
<head>
<meta charset='UTF-8'>
<style>
    body { font-family: Segoe UI, Arial, sans-serif; font-size: 14px; margin: 0; padding: 0; background: #1E1E1E;
        scrollbar-base-color: #1E1E1E; scrollbar-face-color: #555; scrollbar-track-color: #252526;
        scrollbar-arrow-color: #808080; scrollbar-highlight-color: #555; scrollbar-shadow-color: #1E1E1E;
        scrollbar-3dlight-color: #252526; scrollbar-darkshadow-color: #1E1E1E; }
    .sujet-preview { background: #2D2D30; border-left: 3px solid #F39C12; color: #F39C12; font-size: 15px;
        font-weight: bold; padding: 10px 15px; margin: 12px 12px 0 12px; }
    hr.sujet { border: 0; border-top: 1px solid #3E3E42; margin: 0 12px; }
    .email-body { background: #fff; padding: 20px; margin: 0 12px 12px 12px; }
    .email-body h2 { color: #253A5E; margin-top: 0; }
    .email-body p { margin: 8px 0; color: #333; }
    .email-body a { color: #0066cc; text-decoration: underline; }
</style>
</head>
<body>
<div class='sujet-preview'>$objet</div>
<hr class='sujet'/>
<div class='email-body'>
<table style='width:100%'><tr>
<td style='width:140px; vertical-align:top;'><img src='file:///$cheminHeader' style='width:130px;'/></td>
<td style='vertical-align:top; padding-left:25px;'>
<h2>Mouvement d'un Agent SNCF</h2>
<p>Bonjour,</p>
<p>Vous avez été identifié comme déclarant du mouvement de <b>$prenom $nom</b> nouveau collaborateur dans l'entreprise.</p>
<p>Après vérification, un mot de passe est déjà présent sur le compte depuis le <b>$dateInit</b>, nous n'allons donc pas initialiser celui-ci.</p>
<p>Si nécessaire, <b>$prenom $nom</b> peut le modifier via le site <a href='https://mon-id.sncf.fr'>mon-id.sncf.fr</a> et, en cas de problème, en appelant l'assistance mon compte au <b>0 980 980 321</b>.</p>
<p>Merci de votre compréhension.</p>
<div style='margin-top:20px; font-size:13px;'>
Cordialement,<br/>
<b>Votre Assistance Bureautique</b><br/>
SNCF - Solutions<br/>
DIRECTION SERVICES NUMERIQUES<br/>
<img src='file:///$cheminSignature' style='width:330px; margin-top:12px;'/>
</div>
</td></tr></table>
</div>
</body>
</html>
"@
}

function Get-CorpsMessageHTML_DejaInit_Final {
    param($nom, $prenom, $dateInit, $cheminHeader, $cheminSignature)
    return @"
<html>
<head>
<meta charset='UTF-8'>
<style>
    body { font-family: Arial, sans-serif; font-size: 14px; margin: 20px; }
    h2 { color: #253A5E; margin-top:0; }
    p { margin: 8px 0; }
    a { color: #0066cc; text-decoration: underline; }
</style>
</head>
<body>
<table style='width:100%'><tr>
<td style='width:140px; vertical-align:top;'><img src='file:///$cheminHeader' style='width:130px;'/></td>
<td style='vertical-align:top; padding-left:25px;'>
<h2>Mouvement d'un Agent SNCF</h2>
<p>Bonjour,</p>
<p>Vous avez été identifié comme déclarant du mouvement de <b>$prenom $nom</b> nouveau collaborateur dans l'entreprise.</p>
<p>Après vérification, un mot de passe est déjà présent sur le compte depuis le <b>$dateInit</b>, nous n'allons donc pas initialiser celui-ci.</p>
<p>Si nécessaire, <b>$prenom $nom</b> peut le modifier via le site <a href='https://mon-id.sncf.fr'>mon-id.sncf.fr</a> et, en cas de problème, en appelant l'assistance mon compte au <b>0 980 980 321</b>.</p>
<p>Merci de votre compréhension.</p>
<div style='margin-top:20px; font-size:13px;'>
Cordialement,<br/>
<b>Votre Assistance Bureautique</b><br/>
SNCF - Solutions<br/>
DIRECTION SERVICES NUMERIQUES<br/>
<img src='file:///$cheminSignature' style='width:330px; margin-top:12px;'/>
</div>
</td></tr></table>
</body>
</html>
"@
}

# --- Interface principale (thème sombre LixiSpace) ---
$form = New-Object Windows.Forms.Form
$form.Text = "Arrivée Collaborateur"
$form.Size = New-Object Drawing.Size(1100, 920)
$form.StartPosition = "CenterScreen"
$form.BackColor = $cBgMain
$form.ForeColor = $cTextPrimary
$form.Font = [Drawing.Font]::new("Segoe UI", 10)
$form.MinimumSize = New-Object Drawing.Size(780, 650)
# Icône personnalisée
$iconPath = Join-Path $baseDir "image-arrivee-collab.ico"
if (Test-Path $iconPath) {
    try { $form.Icon = New-Object Drawing.Icon($iconPath) } catch {}
} else {
    try { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) } catch {}
}
$form.Add_Shown({
    try {
        [DarkTitleBar]::Enable($this.Handle)
        [DarkTitleBar]::ApplyDarkScrollbar($panelPreview.Handle)
        [DarkTitleBar]::ApplyDarkScrollbar($panelForm.Handle)
        [DarkTitleBar]::ApplyDarkScrollbar($panelActions.Handle)
        [DarkTitleBar]::ApplyDarkScrollbar($rtbCopy.Handle)
        [DarkTitleBar]::ApplyDarkScrollbar($dtpDateInit.Handle)
    } catch {}
})

# --- Barre d'accent violette ---
$accentBar = New-Object Windows.Forms.Panel
$accentBar.Dock = "Top"; $accentBar.Height = 3; $accentBar.BackColor = $cAccentViolet
$form.Controls.Add($accentBar)

# --- En-tête ---
$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text = "Arrivée Collaborateur"
$lblTitle.Font = [Drawing.Font]::new("Segoe UI", 16, [Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = $cWhite
$lblTitle.Location = New-Object Drawing.Point(25, 15)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblSubTitle = New-Object Windows.Forms.Label
$lblSubTitle.Text = "Notification mot de passe - Arrivée collaborateur"
$lblSubTitle.Font = [Drawing.Font]::new("Segoe UI", 9)
$lblSubTitle.ForeColor = $cTextSecondary
$lblSubTitle.Location = New-Object Drawing.Point(27, 45)
$lblSubTitle.AutoSize = $true
$form.Controls.Add($lblSubTitle)

# --- Panneau formulaire (fond secondaire) ---
$panelForm = New-Object Windows.Forms.Panel
$panelForm.Location = New-Object Drawing.Point(20, 75)
$panelForm.Size = New-Object Drawing.Size(1045, 145)
$panelForm.BackColor = $cBgSecondary
$panelForm.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($panelForm)

# Colonnes de saisie
$col1Lbl = 15; $col1In = 165; $col2Lbl = 415; $col2In = 580; $inW = 220

# Ligne 1 : RITM + Email
$lblRITM = New-Object Windows.Forms.Label
$lblRITM.Text = "RITM :"; $lblRITM.AutoSize = $true
$lblRITM.Location = New-Object Drawing.Point($col1Lbl, 18)
$lblRITM.ForeColor = $cTextSecondary
$txtRITM = New-Object Windows.Forms.TextBox
$txtRITM.Location = New-Object Drawing.Point($col1In, 15); $txtRITM.Width = $inW
$txtRITM.BackColor = $cSurface; $txtRITM.ForeColor = $cTextPrimary
$txtRITM.BorderStyle = 'FixedSingle'; $txtRITM.Font = [Drawing.Font]::new("Segoe UI", 10)

$lblEmail = New-Object Windows.Forms.Label
$lblEmail.Text = "Email du demandeur :"; $lblEmail.AutoSize = $true
$lblEmail.Location = New-Object Drawing.Point($col2Lbl, 18)
$lblEmail.ForeColor = $cTextSecondary
$txtEmail = New-Object Windows.Forms.TextBox
$txtEmail.Location = New-Object Drawing.Point($col2In, 15); $txtEmail.Width = $inW
$txtEmail.BackColor = $cSurface; $txtEmail.ForeColor = $cTextPrimary
$txtEmail.BorderStyle = 'FixedSingle'; $txtEmail.Font = [Drawing.Font]::new("Segoe UI", 10)

# Ligne 2 : Nom + Prénom
$lblNom = New-Object Windows.Forms.Label
$lblNom.Text = "Nom :"; $lblNom.AutoSize = $true
$lblNom.Location = New-Object Drawing.Point($col1Lbl, 58)
$lblNom.ForeColor = $cTextSecondary
$txtNom = New-Object Windows.Forms.TextBox
$txtNom.Location = New-Object Drawing.Point($col1In, 55); $txtNom.Width = $inW
$txtNom.BackColor = $cSurface; $txtNom.ForeColor = $cTextPrimary
$txtNom.BorderStyle = 'FixedSingle'; $txtNom.Font = [Drawing.Font]::new("Segoe UI", 10)

$lblPrenom = New-Object Windows.Forms.Label
$lblPrenom.Text = "Prénom :"; $lblPrenom.AutoSize = $true
$lblPrenom.Location = New-Object Drawing.Point($col2Lbl, 58)
$lblPrenom.ForeColor = $cTextSecondary
$txtPrenom = New-Object Windows.Forms.TextBox
$txtPrenom.Location = New-Object Drawing.Point($col2In, 55); $txtPrenom.Width = $inW
$txtPrenom.BackColor = $cSurface; $txtPrenom.ForeColor = $cTextPrimary
$txtPrenom.BorderStyle = 'FixedSingle'; $txtPrenom.Font = [Drawing.Font]::new("Segoe UI", 10)

# Images (droite du panneau)
$picHeader = New-Object Windows.Forms.PictureBox
$picHeader.SizeMode = 'Zoom'
$picHeader.Location = New-Object Drawing.Point(830, 10)
$picHeader.Size = New-Object Drawing.Size(90, 55)
$picHeader.BackColor = $cSurface
$picHeader.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
if (Test-Path $cheminHeader) { try { $picHeader.Image = [Drawing.Image]::FromFile($cheminHeader) } catch {} }

$picSignature = New-Object Windows.Forms.PictureBox
$picSignature.SizeMode = 'Zoom'
$picSignature.Location = New-Object Drawing.Point(930, 10)
$picSignature.Size = New-Object Drawing.Size(100, 55)
$picSignature.BackColor = $cSurface
$picSignature.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
if (Test-Path $cheminSignature) { try { $picSignature.Image = [Drawing.Image]::FromFile($cheminSignature) } catch {} }

$lblStatusImg = New-Object Windows.Forms.Label
$lblStatusImg.Location = New-Object Drawing.Point(830, 75); $lblStatusImg.Width = 200
$lblStatusImg.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$lblStatusImg.Font = [Drawing.Font]::new("Segoe UI", 8)
if ((Test-Path $cheminHeader) -and (Test-Path $cheminSignature)) {
    $lblStatusImg.Text = "Images détectées"; $lblStatusImg.ForeColor = $cSuccess
} else {
    $lblStatusImg.Text = "Vérifier les images !"; $lblStatusImg.ForeColor = $cDanger
}

# Ligne 3 : Checkbox mot de passe déjà initialisé + DateTimePicker
$chkMdpDejaInit = New-Object Windows.Forms.CheckBox
$chkMdpDejaInit.Text = "  Mot de passe déjà initialisé"
$chkMdpDejaInit.Appearance = 'Button'
$chkMdpDejaInit.Location = New-Object Drawing.Point($col1Lbl, 90)
$chkMdpDejaInit.Size = New-Object Drawing.Size(250, 32)
$chkMdpDejaInit.ForeColor = $cWarning
$chkMdpDejaInit.BackColor = $cSurface
$chkMdpDejaInit.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$chkMdpDejaInit.FlatStyle = 'Flat'
$chkMdpDejaInit.FlatAppearance.BorderColor = $cWarning
$chkMdpDejaInit.FlatAppearance.BorderSize = 1
$chkMdpDejaInit.FlatAppearance.CheckedBackColor = $cWarning
$chkMdpDejaInit.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(60, 60, 64)
$chkMdpDejaInit.TextAlign = [Drawing.ContentAlignment]::MiddleCenter
$chkMdpDejaInit.Cursor = [Windows.Forms.Cursors]::Hand

$lblDateInit = New-Object Windows.Forms.Label
$lblDateInit.Text = "Date d'initialisation :"
$lblDateInit.AutoSize = $true
$lblDateInit.Location = New-Object Drawing.Point($col2Lbl, 98)
$lblDateInit.ForeColor = $cTextSecondary
$lblDateInit.Visible = $false

$dtpDateInit = New-Object Windows.Forms.DateTimePicker
$dtpDateInit.Location = New-Object Drawing.Point($col2In, 95)
$dtpDateInit.Width = $inW
$dtpDateInit.Format = 'Custom'
$dtpDateInit.CustomFormat = 'dd/MM/yyyy'
$dtpDateInit.Font = [Drawing.Font]::new("Segoe UI", 10)
$dtpDateInit.BackColor = $cSurface
$dtpDateInit.ForeColor = $cTextPrimary
$dtpDateInit.CalendarMonthBackground = $cSurface
$dtpDateInit.CalendarForeColor = $cTextPrimary
$dtpDateInit.CalendarTitleBackColor = $cAccentViolet
$dtpDateInit.CalendarTitleForeColor = $cWhite
$dtpDateInit.CalendarTrailingForeColor = $cTextSecondary
$dtpDateInit.Visible = $false

$chkMdpDejaInit.Add_CheckedChanged({
    $checked = $chkMdpDejaInit.Checked
    $lblDateInit.Visible = $checked
    $dtpDateInit.Visible = $checked
    if ($checked) {
        $chkMdpDejaInit.ForeColor = $cWhite
        $btnGenPwd.Enabled = $false
        $btnGenPwd.BackColor = $cBorder
        $txtPwd.Text = ""
        $txtPwd.BackColor = [Drawing.Color]::FromArgb(50, 50, 50)
        $btnGenMsg.Enabled = $true
    } else {
        $chkMdpDejaInit.ForeColor = $cWarning
        $btnGenPwd.Enabled = $true
        $btnGenPwd.BackColor = $cAccentViolet
        $txtPwd.BackColor = $cSurface
        $btnGenMsg.Enabled = ($txtPwd.Text -ne "")
    }
    Update-Preview
})

$dtpDateInit.Add_ValueChanged({ Update-Preview })

$panelForm.Controls.AddRange(@($lblRITM,$txtRITM,$lblEmail,$txtEmail,$lblNom,$txtNom,$lblPrenom,$txtPrenom,$chkMdpDejaInit,$lblDateInit,$dtpDateInit,$picHeader,$picSignature,$lblStatusImg))

# --- Layout responsive du panneau formulaire ---
function Layout-FormPanel {
    $pw = $panelForm.ClientSize.Width
    $imgArea = 225
    $margin = 15
    $gap = 15
    $labelW = 150
    $avail = $pw - $imgArea - $margin
    $colW = [int](($avail - $gap) / 2)
    $inW = [Math]::Max(80, $colW - $labelW)

    $txtRITM.Width = $inW
    $txtNom.Width = $inW

    $c2x = $margin + $colW + $gap
    $lblEmail.Left = $c2x
    $txtEmail.Left = $c2x + $labelW
    $txtEmail.Width = $inW
    $lblPrenom.Left = $c2x
    $txtPrenom.Left = $c2x + $labelW
    $txtPrenom.Width = $inW
}
$panelForm.Add_Resize({ Layout-FormPanel })
Layout-FormPanel

# --- Barre d'actions ---
$panelActions = New-Object Windows.Forms.Panel
$panelActions.Location = New-Object Drawing.Point(20, 230)
$panelActions.Size = New-Object Drawing.Size(1045, 50)
$panelActions.BackColor = $cBgSecondary
$panelActions.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($panelActions)

$btnGenPwd = New-Object Windows.Forms.Button
$btnGenPwd.Text = "Générer mot de passe"
$btnGenPwd.Location = New-Object Drawing.Point(15, 8)
$btnGenPwd.Size = New-Object Drawing.Size(190, 34)
$btnGenPwd.FlatStyle = 'Flat'
$btnGenPwd.FlatAppearance.BorderSize = 0
$btnGenPwd.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
$btnGenPwd.BackColor = $cAccentViolet
$btnGenPwd.ForeColor = $cWhite
$btnGenPwd.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$btnGenPwd.Cursor = [Windows.Forms.Cursors]::Hand

$txtPwd = New-Object Windows.Forms.TextBox
$txtPwd.Location = New-Object Drawing.Point(215, 12)
$txtPwd.Width = 210; $txtPwd.ReadOnly = $true
$txtPwd.BackColor = $cSurface; $txtPwd.ForeColor = $cAccentViolet
$txtPwd.BorderStyle = 'FixedSingle'
$txtPwd.Font = [Drawing.Font]::new("Consolas", 11)

$btnGenMsg = New-Object Windows.Forms.Button
$btnGenMsg.Text = "Générer .msg + Maj note Snow"
$btnGenMsg.Location = New-Object Drawing.Point(445, 8)
$btnGenMsg.Size = New-Object Drawing.Size(250, 34)
$btnGenMsg.FlatStyle = 'Flat'
$btnGenMsg.FlatAppearance.BorderSize = 0
$btnGenMsg.FlatAppearance.MouseOverBackColor = $cAccentBlueHover
$btnGenMsg.BackColor = $cAccentBlue
$btnGenMsg.ForeColor = $cWhite
$btnGenMsg.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$btnGenMsg.Cursor = [Windows.Forms.Cursors]::Hand
$btnGenMsg.Enabled = $false

$btnReset = New-Object Windows.Forms.Button
$btnReset.Text = "Réinitialiser"
$btnReset.Location = New-Object Drawing.Point(715, 8)
$btnReset.Size = New-Object Drawing.Size(140, 34)
$btnReset.FlatStyle = 'Flat'
$btnReset.FlatAppearance.BorderSize = 1
$btnReset.FlatAppearance.BorderColor = $cBorder
$btnReset.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(62, 62, 66)
$btnReset.BackColor = $cBgSecondary
$btnReset.ForeColor = $cTextPrimary
$btnReset.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$btnReset.Cursor = [Windows.Forms.Cursors]::Hand
$btnReset.Add_Click({
    $txtRITM.Text = ""
    $txtEmail.Text = ""
    $txtNom.Text = ""
    $txtPrenom.Text = ""
    $txtPwd.Text = ""
    $chkMdpDejaInit.Checked = $false
    $btnGenPwd.Enabled = $true
    $btnGenPwd.BackColor = $cAccentViolet
    $txtPwd.BackColor = $cSurface
    $global:CheminFichierTxt = $null
    $global:CheminZip = $null
    $global:CopyDateInit = $null
    $global:CopyOU = "(à définir)"
    $global:CopyEmailBenef = "(à définir)"
    $rtbCopy.Text = Get-CopyBlockText
    $btnGenMsg.Enabled = $false
    Update-Preview
})

$panelActions.Controls.AddRange(@($btnGenPwd, $txtPwd, $btnGenMsg, $btnReset))

# --- Panneau d'éléments à copier ---
$panelCopy = New-Object Windows.Forms.Panel
$panelCopy.Location = New-Object Drawing.Point(20, 290)
$panelCopy.Size = New-Object Drawing.Size(1045, 137)
$panelCopy.BackColor = $cBgSecondary
$panelCopy.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($panelCopy)

$lblCopyTitle = New-Object Windows.Forms.Label
$lblCopyTitle.Text = "Note ServiceNow"
$lblCopyTitle.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$lblCopyTitle.ForeColor = $cTextSecondary
$lblCopyTitle.Location = New-Object Drawing.Point(15, 6)
$lblCopyTitle.AutoSize = $true
$panelCopy.Controls.Add($lblCopyTitle)

$global:CopyOU = "(à définir)"
$global:CopyEmailBenef = "(à définir)"

$global:CopyDateInit = $null

function Get-CopyBlockText {
    if ($global:CopyDateInit) {
        $header = "***Vérifications Mon-AD : Mot de passe déjà initialisé le $($global:CopyDateInit)***"
    } else {
        $header = "***Mot de passe initialisé***"
    }
    return @(
        $header,
        "Demande recevable",
        "Pas d'homonyme",
        "Pas de doublon de demande",
        "Compte approvisionné",
        "OU > $($global:CopyOU)",
        "Adresse de messagerie > $($global:CopyEmailBenef)"
    ) -join "`r`n"
}

$rtbCopy = New-Object Windows.Forms.RichTextBox
$rtbCopy.Location = New-Object Drawing.Point(15, 26)
$rtbCopy.Size = New-Object Drawing.Size(920, 102)
$rtbCopy.BackColor = $cSurface
$rtbCopy.ForeColor = $cTextPrimary
$rtbCopy.Font = [Drawing.Font]::new("Segoe UI", 9)
$rtbCopy.ReadOnly = $true
$rtbCopy.BorderStyle = 'None'
$rtbCopy.Text = Get-CopyBlockText
$rtbCopy.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right

$btnCopyAll = New-Object Windows.Forms.Button
$btnCopyAll.Text = "Copier tout"
$btnCopyAll.Location = New-Object Drawing.Point(945, 26)
$btnCopyAll.Size = New-Object Drawing.Size(85, 102)
$btnCopyAll.FlatStyle = 'Flat'
$btnCopyAll.FlatAppearance.BorderSize = 0
$btnCopyAll.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
$btnCopyAll.BackColor = $cAccentViolet
$btnCopyAll.ForeColor = $cWhite
$btnCopyAll.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$btnCopyAll.Cursor = [Windows.Forms.Cursors]::Hand
$btnCopyAll.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$btnCopyAll.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText($rtbCopy.Text)
    $this.Text = "Copié !"
    $this.BackColor = [Drawing.Color]::FromArgb(39, 174, 96)
    $t = New-Object Windows.Forms.Timer
    $t.Interval = 800; $t.Tag = $this
    $t.Add_Tick({
        $btn = $this.Tag
        $btn.Text = "Copier tout"
        $btn.BackColor = [Drawing.Color]::FromArgb(155, 89, 182)
        $this.Stop(); $this.Dispose()
    })
    $t.Start()
})

$panelCopy.Controls.AddRange(@($lblCopyTitle, $rtbCopy, $btnCopyAll))

# --- Aperçu du sujet ---
$lblSubjectLabel = New-Object Windows.Forms.Label
$lblSubjectLabel.Text = "Objet :"
$lblSubjectLabel.Location = New-Object Drawing.Point(20, 437)
$lblSubjectLabel.AutoSize = $true
$lblSubjectLabel.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$lblSubjectLabel.ForeColor = $cTextSecondary
$form.Controls.Add($lblSubjectLabel)

$txtSubjectPreview = New-Object Windows.Forms.Label
$txtSubjectPreview.Location = New-Object Drawing.Point(75, 433)
$txtSubjectPreview.Size = New-Object Drawing.Size(990, 28)
$txtSubjectPreview.BackColor = $cSurface
$txtSubjectPreview.ForeColor = $cAccentViolet
$txtSubjectPreview.Font = [Drawing.Font]::new("Segoe UI", 11, [Drawing.FontStyle]::Bold)
$txtSubjectPreview.TextAlign = [Drawing.ContentAlignment]::MiddleLeft
$txtSubjectPreview.Padding = New-Object Windows.Forms.Padding(10, 0, 0, 0)
$txtSubjectPreview.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($txtSubjectPreview)

# --- Aperçu du message ---
$lblPreviewLabel = New-Object Windows.Forms.Label
$lblPreviewLabel.Text = "Aperçu du message"
$lblPreviewLabel.Location = New-Object Drawing.Point(20, 474)
$lblPreviewLabel.AutoSize = $true
$lblPreviewLabel.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$lblPreviewLabel.ForeColor = $cTextSecondary
$form.Controls.Add($lblPreviewLabel)

$panelPreview = New-Object Windows.Forms.Panel
$panelPreview.Location = New-Object Drawing.Point(20, 497)
$panelPreview.Size = New-Object Drawing.Size(1045, 375)
$panelPreview.BackColor = $cBgSecondary
$panelPreview.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right -bor [Windows.Forms.AnchorStyles]::Bottom
$form.Controls.Add($panelPreview)

$webBrowser = New-Object Windows.Forms.WebBrowser
$webBrowser.Dock = 'Fill'
$webBrowser.ScriptErrorsSuppressed = $true
$panelPreview.Controls.Add($webBrowser)

# --- Logique de l'aperçu ---
function Update-Preview {
    $ritm = if($txtRITM.Text){$txtRITM.Text}else{"RITMXXXXX"}
    $nom = if($txtNom.Text){$txtNom.Text}else{"NOM"}
    $prenom = if($txtPrenom.Text){$txtPrenom.Text}else{"PRENOM"}
    if ($chkMdpDejaInit.Checked) {
        $dateInit = $dtpDateInit.Value.ToString("dd/MM/yyyy")
        $objet = "$ritm - Mot de passe déjà initialisé $nom $prenom"
        $txtSubjectPreview.Text = $objet
        $html = Get-CorpsMessageHTML_DejaInit_Preview $objet $nom $prenom $dateInit $cheminHeader $cheminSignature
    } else {
        $objet = "$ritm - Notification mot de passe $nom $prenom"
        $txtSubjectPreview.Text = $objet
        $html = Get-CorpsMessageHTML_Preview $objet $nom $prenom $cheminHeader $cheminSignature
    }
    $webBrowser.DocumentText = $html
}

# --- Événements ---
$btnGenPwd.Add_Click({
    $pw = Generate-Password
    $txtPwd.Text = $pw
    Copy-Clipboard $pw
    Show-AlertDialog -message "Le mot de passe a été généré et copié dans le presse-papiers." -title "Mot de passe généré"
    $nomPrenom = "$($txtNom.Text)$($txtPrenom.Text)"
    $global:CheminFichierTxt = Creer-FichierMotDePasse $pw $nomPrenom
    $global:CheminZip = Creer-Zip $global:CheminFichierTxt $nomPrenom
    Update-Preview
    $btnGenMsg.Enabled = $true
})

$btnGenMsg.Add_Click({
    $ritm = $txtRITM.Text.Trim(); $nom = $txtNom.Text.Trim(); $prenom = $txtPrenom.Text.Trim(); $dest = $txtEmail.Text.Trim()
    if ($ritm -eq "" -or $nom -eq "" -or $prenom -eq "" -or $dest -eq "") {
        Show-AlertDialog -message "Remplissez tous les champs !" -title "Erreur"
        return
    }

    if ($chkMdpDejaInit.Checked) {
        # --- Mode : mot de passe déjà initialisé ---
        $dateInit = $dtpDateInit.Value.ToString("dd/MM/yyyy")
        $objet = "$ritm - Mot de passe déjà initialisé $nom $prenom"
        $htmlFinal = Get-CorpsMessageHTML_DejaInit_Final $nom $prenom $dateInit $cheminHeader $cheminSignature
        $htmlPreview = Get-CorpsMessageHTML_DejaInit_Preview $objet $nom $prenom $dateInit $cheminHeader $cheminSignature
        $webBrowser.DocumentText = $htmlPreview
        $cheminMsg = Join-Path $baseDir "$ritm`_notif.msg"
        if (Creer-FichierMsg $objet $dest $htmlFinal "" $cheminMsg) {
            $rappelMsg = "Fichier .msg créé avec succès :`n$cheminMsg`n`nOuvrir le fichier maintenant ?"
            $resultatRappel = Show-AlertDialog -message $rappelMsg -title "MESSAGE CRÉÉ" -withCancel -buttonYesText "Ouvrir le fichier" -buttonNoText "Plus tard"
            if ($resultatRappel -eq [Windows.Forms.DialogResult]::Yes) {
                Invoke-Item $cheminMsg
                Attendre-FermetureOutlookEtDeplacer $cheminMsg
            }
        }
        # Demander les informations du bénéficiaire
        $global:CopyDateInit = $dateInit
        $benef = Show-BeneficiaireDialog
        if ($benef) {
            if ($benef.Email) { $global:CopyEmailBenef = $benef.Email }
            if ($benef.OU) { $global:CopyOU = ($benef.OU -replace '\s+', '/') -replace '/+', '/' }
        }
        $rtbCopy.Text = Get-CopyBlockText
    } else {
        # --- Mode : nouveau mot de passe ---
        $actionsVerif = Show-AlertDialog -message "Avez-vous bien :`n- Modifié le mot de passe dans Mon-AD`n- Déplacé le compte dans la bonne OU`n`nSi ces actions n'ont pas été réalisées, cliquez sur NON." -title "VÉRIFICATION DES ACTIONS" -withCancel -buttonYesText "Oui, tout est fait" -buttonNoText "Non, abandonner"
        if ($actionsVerif -eq [Windows.Forms.DialogResult]::No) {
            Show-AlertDialog -message "Opération annulée. Veuillez réaliser les actions nécessaires avant de générer le message." -title "Opération annulée"
            return
        }
        if (-not (Test-Path $global:CheminZip)) {
            Show-AlertDialog -message "Générez le mot de passe d'abord." -title "Erreur"
            return
        }
        $objet = "$ritm - Notification mot de passe $nom $prenom"
        $htmlFinal = Get-CorpsMessageHTML_Final $nom $prenom $cheminHeader $cheminSignature
        $htmlPreview = Get-CorpsMessageHTML_Preview $objet $nom $prenom $cheminHeader $cheminSignature
        $webBrowser.DocumentText = $htmlPreview
        $cheminMsg = Join-Path $baseDir "$ritm`_notif.msg"
        if (Creer-FichierMsg $objet $dest $htmlFinal $global:CheminZip $cheminMsg) {
            $rappelMsg = "Fichier .msg créé avec succès :`n$cheminMsg`n`nOuvrir le fichier maintenant ?"
            $resultatRappel = Show-AlertDialog -message $rappelMsg -title "MESSAGE CRÉÉ" -withCancel -buttonYesText "Ouvrir le fichier" -buttonNoText "Plus tard"
            if ($resultatRappel -eq [Windows.Forms.DialogResult]::Yes) {
                Invoke-Item $cheminMsg
                Attendre-FermetureOutlookEtDeplacer $cheminMsg
            }
            $cleanupMsg = "Voulez-vous supprimer les fichiers temporaires du dossier 'Mot de passe' ?`n`n- $($global:CheminFichierTxt)`n- $($global:CheminZip)"
            $resultatCleanup = Show-AlertDialog -message $cleanupMsg -title "NETTOYAGE" -withCancel -buttonYesText "Oui, supprimer" -buttonNoText "Non, conserver"
            if ($resultatCleanup -eq [Windows.Forms.DialogResult]::Yes) {
                if (Test-Path $global:CheminFichierTxt) { Remove-Item $global:CheminFichierTxt -Force }
                if (Test-Path $global:CheminZip) { Remove-Item $global:CheminZip -Force }
                Show-AlertDialog -message "Fichiers temporaires supprimés avec succès." -title "Nettoyage terminé"
            }
        }
        # Demander les informations du bénéficiaire
        $benef = Show-BeneficiaireDialog
        if ($benef) {
            if ($benef.Email) { $global:CopyEmailBenef = $benef.Email }
            if ($benef.OU) { $global:CopyOU = ($benef.OU -replace '\s+', '/') -replace '/+', '/' }
            $rtbCopy.Text = Get-CopyBlockText
        }
    }
})

foreach ($c in @($txtRITM, $txtNom, $txtPrenom, $txtEmail)) {
    $c.Add_TextChanged({Update-Preview})
}

Update-Preview
[void]$form.ShowDialog()