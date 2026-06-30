Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem

# --- Instance unique : empêche d'ouvrir plusieurs fenêtres/bulles simultanées ---
# (En mode masqué l'app n'a ni croix ni entrée dans la barre des tâches : sans ce
#  verrou, relancer le lanceur empilerait des instances et donc des bulles.)
$global:AppCreatedNew = $false
$global:AppMutex = New-Object System.Threading.Mutex($true, 'ArriveeCollaborateur_SingleInstance', [ref]$global:AppCreatedNew)
if (-not $global:AppCreatedNew) {
    [System.Windows.Forms.MessageBox]::Show(
        "L'outil « Arrivée Collaborateur » est déjà en cours d'exécution.`r`n`r`nSi la fenêtre n'est pas visible, cliquez sur la bulle située sur le bord droit de votre écran principal pour la ramener.",
        "Arrivée Collaborateur",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    exit
}

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

# Détermination du bon dossier de base, que ce soit .ps1 ou .exe ou terminal ouvert ailleurs
if ([System.AppDomain]::CurrentDomain.FriendlyName -like '*.exe') {
    $baseDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
} elseif ($PSScriptRoot) {
    $baseDir = $PSScriptRoot
} else {
    $baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# --- Chargement de la configuration et des utilitaires (modules lib) ---
. (Join-Path $baseDir 'config.ps1')
. (Join-Path $baseDir 'lib\Common.ps1')
. (Join-Path $baseDir 'lib\State.ps1')
. (Join-Path $baseDir 'lib\Update.ps1')
. (Join-Path $baseDir 'lib\Tutorial.ps1')

# Données d'exécution hors du dossier app (qui est écrasé à chaque MAJ) :
# %LOCALAPPDATA%\Arrivee-Collab pour l'état/log, ...\data pour les sorties métier.
$dataDir = Get-AppDataDir
$workDir = Get-AppWorkDir $dataDir
Initialize-AppLog (Join-Path $dataDir 'app_debug.log')
Write-AppLog "[INIT] App : $baseDir | Données : $dataDir"

# Active l'historique du presse-papiers (Win+V) s'il est désactivé : indispensable
# pour que le bouton « Copier tout » y place les deux notes. Best-effort, non bloquant.
[void](Enable-ClipboardHistory)

# Contexte global partagé (étendu par le Plan B : pastille MAJ, tutoriel).
$global:Ctx = @{
    Config          = $Config
    AppRoot         = $baseDir
    DataDir         = $dataDir
    WorkDir         = $workDir
    State           = (New-AppState (Join-Path $dataDir 'state.json'))
    UpdateAvailable = $null
}

# Migration « comme une mise à jour » (no-op si même version) : déclenchera le
# dialogue « Quoi de neuf » au Plan B. On capture la version précédente AVANT.
$global:PrevStateVersion = [string]$global:Ctx.State.Version
[void](Invoke-AppVersionMigration $global:Ctx.State $Config.Version)

# Chemins dossiers et fichiers importants
$resourcesFolder = Join-Path $baseDir "Resources"
$motDePasseFolder = Join-Path $workDir "Mot de passe"
$archiveFolder = Join-Path $workDir "Archive message"

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
    param($objet, $nomPrenom, $cheminHeader, $cheminSignature)
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
<p>Vous avez été identifié comme déclarant de l'arrivée de <b>$nomPrenom</b>, nouveau collaborateur dans l'entreprise.</p>
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
    param($nomPrenom, $cheminHeader, $cheminSignature)
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
<p>Vous avez été identifié comme déclarant de l'arrivée de <b>$nomPrenom</b>, nouveau collaborateur dans l'entreprise.</p>
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
    param($objet, $nomPrenom, $dateInit, $cheminHeader, $cheminSignature)
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
<p>Vous avez été identifié comme déclarant du mouvement de <b>$nomPrenom</b> nouveau collaborateur dans l'entreprise.</p>
<p>Après vérification, un mot de passe est déjà présent sur le compte depuis le <b>$dateInit</b>, nous n'allons donc pas initialiser celui-ci.</p>
<p>Si nécessaire, <b>$nomPrenom</b> peut le modifier via le site <a href='https://mon-id.sncf.fr'>mon-id.sncf.fr</a> et, en cas de problème, en appelant l'assistance mon compte au <b>0 980 980 321</b>.</p>
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
    param($nomPrenom, $dateInit, $cheminHeader, $cheminSignature)
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
<p>Vous avez été identifié comme déclarant du mouvement de <b>$nomPrenom</b> nouveau collaborateur dans l'entreprise.</p>
<p>Après vérification, un mot de passe est déjà présent sur le compte depuis le <b>$dateInit</b>, nous n'allons donc pas initialiser celui-ci.</p>
<p>Si nécessaire, <b>$nomPrenom</b> peut le modifier via le site <a href='https://mon-id.sncf.fr'>mon-id.sncf.fr</a> et, en cas de problème, en appelant l'assistance mon compte au <b>0 980 980 321</b>.</p>
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
$form.MinimumSize = New-Object Drawing.Size(1095, 650)
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
        [DarkTitleBar]::ApplyDarkScrollbar($rtbMsg.Handle)
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

# --- Pastille de mise à jour (cachée par défaut, ancrée en haut à droite) ---
$lblUpdateBadge = New-Object Windows.Forms.Label
$lblUpdateBadge.Text = "  ⬆ Mise à jour disponible  "
$lblUpdateBadge.AutoSize = $true
$lblUpdateBadge.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$lblUpdateBadge.ForeColor = $cWhite
$lblUpdateBadge.BackColor = $cWarning
$lblUpdateBadge.Padding = New-Object Windows.Forms.Padding(6, 4, 6, 4)
$lblUpdateBadge.Location = New-Object Drawing.Point(900, 22)
$lblUpdateBadge.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$lblUpdateBadge.Cursor = [Windows.Forms.Cursors]::Hand
$lblUpdateBadge.Visible = $false
$lblUpdateBadge.Add_Click({ Invoke-PromptAndUpdate $global:Ctx })
$form.Controls.Add($lblUpdateBadge)
$lblUpdateBadge.BringToFront()
$global:Ctx.UpdateBadge = $lblUpdateBadge

# --- Bouton « ? » : rejouer le tutoriel (en-tête, ancré en haut à droite) ---
$btnHelp = New-Object Windows.Forms.Button
$btnHelp.Text = "?"
$btnHelp.Size = New-Object Drawing.Size(34, 34)
$btnHelp.Location = New-Object Drawing.Point(1042, 18)
$btnHelp.FlatStyle = 'Flat'; $btnHelp.FlatAppearance.BorderSize = 0
$btnHelp.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
$btnHelp.BackColor = $cBorder; $btnHelp.ForeColor = $cWhite
$btnHelp.Font = [Drawing.Font]::new("Segoe UI", 12, [Drawing.FontStyle]::Bold)
$btnHelp.Cursor = [Windows.Forms.Cursors]::Hand
$btnHelp.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$btnHelp.Add_Click({ try { Show-Tutorial $global:Ctx } catch { Write-AppLog "[TUTO] Relecture KO : $($_.Exception.Message)" } })
$form.Controls.Add($btnHelp)
$btnHelp.BringToFront()

# Repositionne la pastille en haut à droite quel que soit son texte (largeur auto).
function Update-UpdateBadge {
    param($Ctx)
    $b = $Ctx.UpdateBadge
    if (-not $b) { return }
    $action = {
        if ($Ctx.UpdateAvailable) {
            $b.Text = "  ⬆ Mise à jour $($Ctx.UpdateAvailable.Version)  "
            $b.Left = $btnHide.Left - $b.Width - 10
            $b.Visible = $true; $b.BringToFront()
        } else { $b.Visible = $false }
    }
    if ($form.InvokeRequired) { $form.Invoke([Action]$action) } else { & $action }
}

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

# Ligne 2 : Nom et prénom (champ unique, saisie « Prénom Nom »)
$lblNomPrenom = New-Object Windows.Forms.Label
$lblNomPrenom.Text = "Nom et prénom :"; $lblNomPrenom.AutoSize = $true
$lblNomPrenom.Location = New-Object Drawing.Point($col1Lbl, 58)
$lblNomPrenom.ForeColor = $cTextSecondary
$txtNomPrenom = New-Object Windows.Forms.TextBox
$txtNomPrenom.Location = New-Object Drawing.Point($col1In, 55); $txtNomPrenom.Width = $inW
$txtNomPrenom.BackColor = $cSurface; $txtNomPrenom.ForeColor = $cTextPrimary
$txtNomPrenom.BorderStyle = 'FixedSingle'; $txtNomPrenom.Font = [Drawing.Font]::new("Segoe UI", 10)

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

$panelForm.Controls.AddRange(@($lblRITM,$txtRITM,$lblEmail,$txtEmail,$lblNomPrenom,$txtNomPrenom,$chkMdpDejaInit,$lblDateInit,$dtpDateInit,$picHeader,$picSignature,$lblStatusImg))

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
    $txtNomPrenom.Width = $inW

    $c2x = $margin + $colW + $gap
    $lblEmail.Left = $c2x
    $txtEmail.Left = $c2x + $labelW
    $txtEmail.Width = $inW
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
    $txtNomPrenom.Text = ""
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

# --- Panneau d'éléments à copier (Note ServiceNow, à gauche) ---
$panelCopy = New-Object Windows.Forms.Panel
$panelCopy.Location = New-Object Drawing.Point(20, 290)
$panelCopy.Size = New-Object Drawing.Size(615, 137)
$panelCopy.BackColor = $cBgSecondary
$panelCopy.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
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

# Message de clôture à destination du demandeur (« Note Utilisateur »).
# Le texte change selon le mode (case « Mot de passe déjà initialisé »).
function Get-MessageDemandeurText {
    if ($chkMdpDejaInit.Checked) {
        $corps = "Le compte est bien activé. Le mot de passe n'a pas été modifié, car il avait déjà été initialisé."
    } else {
        $corps = "Le compte a bien été activé. Le mot de passe a été envoyé par mail au demandeur."
    }
    return @(
        "Bonjour,",
        "",
        $corps,
        "",
        "Cordialement,",
        "L'assistance bureautique."
    ) -join "`r`n"
}

$rtbCopy = New-Object Windows.Forms.RichTextBox
$rtbCopy.Location = New-Object Drawing.Point(15, 26)
$rtbCopy.Size = New-Object Drawing.Size(490, 102)
$rtbCopy.BackColor = $cSurface
$rtbCopy.ForeColor = $cTextPrimary
$rtbCopy.Font = [Drawing.Font]::new("Segoe UI", 9)
$rtbCopy.ReadOnly = $true
$rtbCopy.BorderStyle = 'None'
$rtbCopy.Text = Get-CopyBlockText
$rtbCopy.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right

$btnCopyAll = New-Object Windows.Forms.Button
$btnCopyAll.Text = "Copier"
$btnCopyAll.Location = New-Object Drawing.Point(515, 26)
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

# --- Panneau « Note Utilisateur » (message au demandeur, à droite) ---
$panelMsg = New-Object Windows.Forms.Panel
$panelMsg.Location = New-Object Drawing.Point(650, 290)
$panelMsg.Size = New-Object Drawing.Size(415, 137)
$panelMsg.BackColor = $cBgSecondary
$panelMsg.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left
$form.Controls.Add($panelMsg)

$lblMsgTitle = New-Object Windows.Forms.Label
$lblMsgTitle.Text = "Note Utilisateur"
$lblMsgTitle.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$lblMsgTitle.ForeColor = $cTextSecondary
$lblMsgTitle.Location = New-Object Drawing.Point(15, 6)
$lblMsgTitle.AutoSize = $true

$rtbMsg = New-Object Windows.Forms.RichTextBox
$rtbMsg.Location = New-Object Drawing.Point(15, 26)
$rtbMsg.Size = New-Object Drawing.Size(290, 102)
$rtbMsg.BackColor = $cSurface
$rtbMsg.ForeColor = $cTextPrimary
$rtbMsg.Font = [Drawing.Font]::new("Segoe UI", 9)
$rtbMsg.ReadOnly = $true
$rtbMsg.BorderStyle = 'None'
$rtbMsg.Text = Get-MessageDemandeurText
$rtbMsg.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right

$btnCopyMsg = New-Object Windows.Forms.Button
$btnCopyMsg.Text = "Copier"
$btnCopyMsg.Location = New-Object Drawing.Point(315, 26)
$btnCopyMsg.Size = New-Object Drawing.Size(85, 102)
$btnCopyMsg.FlatStyle = 'Flat'
$btnCopyMsg.FlatAppearance.BorderSize = 0
$btnCopyMsg.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
$btnCopyMsg.BackColor = $cAccentViolet
$btnCopyMsg.ForeColor = $cWhite
$btnCopyMsg.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)
$btnCopyMsg.Cursor = [Windows.Forms.Cursors]::Hand
$btnCopyMsg.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$btnCopyMsg.Add_Click({
    [System.Windows.Forms.Clipboard]::SetText($rtbMsg.Text)
    $this.Text = "Copié !"
    $this.BackColor = [Drawing.Color]::FromArgb(39, 174, 96)
    $t = New-Object Windows.Forms.Timer
    $t.Interval = 800; $t.Tag = $this
    $t.Add_Tick({
        $btn = $this.Tag
        $btn.Text = "Copier"
        $btn.BackColor = [Drawing.Color]::FromArgb(155, 89, 182)
        $this.Stop(); $this.Dispose()
    })
    $t.Start()
})

$panelMsg.Controls.AddRange(@($lblMsgTitle, $rtbMsg, $btnCopyMsg))

# Répartit la largeur disponible entre les deux notes (responsive côte à côte).
# La Note ServiceNow (gauche) est un peu plus large que la Note Utilisateur (droite).
function Layout-CopyPanels {
    $totalW = $form.ClientSize.Width - 40
    if ($totalW -lt 200) { return }
    $gap = 15
    $leftW = [int](($totalW - $gap) * 0.595)
    $panelCopy.Left = 20
    $panelCopy.Width = $leftW
    $panelMsg.Left = 20 + $leftW + $gap
    $panelMsg.Width = $totalW - $gap - $leftW
}
$form.Add_Resize({ Layout-CopyPanels })
Layout-CopyPanels

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

# --- Bouton « Copier tout » visible uniquement quand l'aperçu est masqué ---
# Les deux notes étant cachées en mode replié, ce bouton permet de copier
# d'un clic la Note ServiceNow + la Note Utilisateur.
$btnCopyCollapsed = New-Object Windows.Forms.Button
$btnCopyCollapsed.Text = "📋  Copier tout (Note ServiceNow + Note Utilisateur)"
$btnCopyCollapsed.Location = New-Object Drawing.Point(20, 288)
$btnCopyCollapsed.Size = New-Object Drawing.Size(1045, 36)
$btnCopyCollapsed.FlatStyle = 'Flat'
$btnCopyCollapsed.FlatAppearance.BorderSize = 0
$btnCopyCollapsed.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
$btnCopyCollapsed.BackColor = $cAccentViolet
$btnCopyCollapsed.ForeColor = $cWhite
$btnCopyCollapsed.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$btnCopyCollapsed.Cursor = [Windows.Forms.Cursors]::Hand
$btnCopyCollapsed.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Left -bor [Windows.Forms.AnchorStyles]::Right
$btnCopyCollapsed.Visible = $false
$btnCopyCollapsed.Add_Click({
    # « Copier tout » = DEUX copies -> deux entrées distinctes dans l'historique du
    # presse-papiers (Win+V), messages bruts (sans en-tête).
    #   1) note Utilisateur copiée tout de suite ;
    #   2) note ServiceNow copiée en DIFFÉRÉ via un Timer.
    # Le différé est INDISPENSABLE : il laisse la boucle de messages tourner pour que
    # le service d'historique Windows (cbdhsvc) « photographie » la 1re copie AVANT
    # qu'elle soit remplacée par la 2e. Un Start-Sleep bloquant échoue (seule la
    # dernière note survit). Résultat : Ctrl+V colle la note ServiceNow (dernière
    # copiée), et Win+V propose aussi la note Utilisateur.
    [System.Windows.Forms.Clipboard]::SetText((Get-MessageDemandeurText))
    $this.Text = "Copié ×2 !"
    $this.BackColor = [Drawing.Color]::FromArgb(39, 174, 96)
    $t = New-Object Windows.Forms.Timer
    $t.Interval = 350; $t.Tag = $this
    $t.Add_Tick({
        $this.Stop()
        $btn = $this.Tag
        try { [System.Windows.Forms.Clipboard]::SetText((Get-CopyBlockText)) } catch {}
        $btn.Text = "📋  Copier tout (Note ServiceNow + Note Utilisateur)"
        $btn.BackColor = [Drawing.Color]::FromArgb(155, 89, 182)
        $this.Dispose()
    })
    $t.Start()
})
$form.Controls.Add($btnCopyCollapsed)

# --- Bouton repli/dépli du bas (objet + aperçu + notes) ---
# Gagne de la place sur les petits écrans : un clic masque tout le bas et réduit
# la hauteur de la fenêtre ; re-clic restaure.
$global:PreviewCollapsed = $false
$btnTogglePreview = New-Object Windows.Forms.Button
$btnTogglePreview.Text = "▼ Aperçu"
$btnTogglePreview.Location = New-Object Drawing.Point(870, 8)
$btnTogglePreview.Size = New-Object Drawing.Size(160, 34)
$btnTogglePreview.FlatStyle = 'Flat'
$btnTogglePreview.FlatAppearance.BorderSize = 1
$btnTogglePreview.FlatAppearance.BorderColor = $cBorder
$btnTogglePreview.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(62, 62, 66)
$btnTogglePreview.BackColor = $cBgSecondary
$btnTogglePreview.ForeColor = $cTextPrimary
$btnTogglePreview.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
$btnTogglePreview.Cursor = [Windows.Forms.Cursors]::Hand
$btnTogglePreview.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$btnTogglePreview.Add_Click({
    $global:PreviewCollapsed = -not $global:PreviewCollapsed
    $vis = -not $global:PreviewCollapsed
    $panelCopy.Visible = $vis
    $panelMsg.Visible = $vis
    $lblSubjectLabel.Visible = $vis
    $txtSubjectPreview.Visible = $vis
    $lblPreviewLabel.Visible = $vis
    $panelPreview.Visible = $vis
    $btnCopyCollapsed.Visible = $global:PreviewCollapsed
    if ($global:PreviewCollapsed) {
        $btnTogglePreview.Text = "▶ Aperçu"
        $form.MinimumSize = New-Object Drawing.Size(1095, 348)
        $form.Height = 380
    } else {
        $btnTogglePreview.Text = "▼ Aperçu"
        $form.Height = 920
        $form.MinimumSize = New-Object Drawing.Size(1095, 650)
    }
})
$panelActions.Controls.Add($btnTogglePreview)

# --- Logique de l'aperçu ---
function Update-Preview {
    $ritm = if($txtRITM.Text){$txtRITM.Text}else{"RITMXXXXX"}
    $nomPrenom = if($txtNomPrenom.Text){$txtNomPrenom.Text}else{"Prénom NOM"}
    if ($chkMdpDejaInit.Checked) {
        $dateInit = $dtpDateInit.Value.ToString("dd/MM/yyyy")
        $objet = "$ritm - Mot de passe déjà initialisé $nomPrenom"
        $txtSubjectPreview.Text = $objet
        $html = Get-CorpsMessageHTML_DejaInit_Preview $objet $nomPrenom $dateInit $cheminHeader $cheminSignature
    } else {
        $objet = "$ritm - Notification mot de passe $nomPrenom"
        $txtSubjectPreview.Text = $objet
        $html = Get-CorpsMessageHTML_Preview $objet $nomPrenom $cheminHeader $cheminSignature
    }
    $rtbMsg.Text = Get-MessageDemandeurText
    $webBrowser.DocumentText = $html
}

# --- Événements ---
$btnGenPwd.Add_Click({
    $pw = Generate-Password
    $txtPwd.Text = $pw
    Copy-Clipboard $pw
    Show-AlertDialog -message "Le mot de passe a été généré et copié dans le presse-papiers." -title "Mot de passe généré"
    $nomFichier = ($txtNomPrenom.Text -replace '\s', '')
    $global:CheminFichierTxt = Creer-FichierMotDePasse $pw $nomFichier
    $global:CheminZip = Creer-Zip $global:CheminFichierTxt $nomFichier
    Update-Preview
    $btnGenMsg.Enabled = $true
})

$btnGenMsg.Add_Click({
    # Pendant toute la génération (création du .msg, ouverture dans Outlook,
    # dialogues, saisie bénéficiaire), on suspend le masquage automatique :
    # l'utilisateur a encore des actions sur l'app après l'ouverture du message.
    $global:SuppressAutoHide = $true
    try {
    $ritm = $txtRITM.Text.Trim(); $nomPrenom = $txtNomPrenom.Text.Trim(); $dest = $txtEmail.Text.Trim()
    if ($ritm -eq "" -or $nomPrenom -eq "" -or $dest -eq "") {
        Show-AlertDialog -message "Remplissez tous les champs !" -title "Erreur"
        return
    }

    if ($chkMdpDejaInit.Checked) {
        # --- Mode : mot de passe déjà initialisé ---
        $dateInit = $dtpDateInit.Value.ToString("dd/MM/yyyy")
        $objet = "$ritm - Mot de passe déjà initialisé $nomPrenom"
        $htmlFinal = Get-CorpsMessageHTML_DejaInit_Final $nomPrenom $dateInit $cheminHeader $cheminSignature
        $htmlPreview = Get-CorpsMessageHTML_DejaInit_Preview $objet $nomPrenom $dateInit $cheminHeader $cheminSignature
        $webBrowser.DocumentText = $htmlPreview
        $cheminMsg = Join-Path $workDir "$ritm`_notif.msg"
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
        $objet = "$ritm - Notification mot de passe $nomPrenom"
        $htmlFinal = Get-CorpsMessageHTML_Final $nomPrenom $cheminHeader $cheminSignature
        $htmlPreview = Get-CorpsMessageHTML_Preview $objet $nomPrenom $cheminHeader $cheminSignature
        $webBrowser.DocumentText = $htmlPreview
        $cheminMsg = Join-Path $workDir "$ritm`_notif.msg"
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
    } finally {
        $global:SuppressAutoHide = $false
    }
})

foreach ($c in @($txtRITM, $txtNomPrenom, $txtEmail)) {
    $c.Add_TextChanged({Update-Preview})
}

Update-Preview

# --- Mise à jour : « Quoi de neuf » après une montée, puis vérification périodique ---
$global:Ctx.UpdateAvailable = $null
$form.Add_Shown({
    try { Show-WhatsNewIfUpgraded $global:Ctx $global:PrevStateVersion } catch { Write-AppLog "[VERSION] Quoi de neuf KO : $($_.Exception.Message)" }
    # 1er contrôle ~8 s après ouverture, puis selon Config.UpdateCheckIntervalSec.
    $timerUpd = New-Object Windows.Forms.Timer
    $timerUpd.Interval = 8000
    $timerUpd.Add_Tick({
        $this.Interval = [Math]::Max(10, [int]$global:Ctx.Config.UpdateCheckIntervalSec) * 1000
        try { Invoke-UpdateCheck $global:Ctx } catch { Write-AppLog "[MAJ] Tick KO : $($_.Exception.Message)" }
    })
    $timerUpd.Start()
    # Tutoriel au tout premier lancement (différé ~1,4 s pour laisser l'UI se peindre).
    $timerTuto = New-Object Windows.Forms.Timer
    $timerTuto.Interval = 1400
    $timerTuto.Add_Tick({
        $this.Stop()
        try { Show-TutorialIfFirstRun $global:Ctx } catch { Write-AppLog "[TUTO] 1er lancement KO : $($_.Exception.Message)" }
    })
    $timerTuto.Start()
})

# ============================================================================
#  Masquage de l'app : un bouton « masquer » (en-tête) fait coulisser la fenêtre
#  hors écran vers la droite, puis affiche une petite LANGUETTE au bord droit de
#  l'écran de l'app. Clic sur la languette : l'app revient en glissant. La languette
#  n'apparaît QUE pendant le masquage. Tout est recalculé au clic (correct multi-écran).
# ============================================================================
$global:AppHidden = $false
# Drapeau : suspend le masquage automatique pendant le flux de génération du .msg.
$global:SuppressAutoHide = $false
# Dernière position de la bulle ($null = jamais déplacée => position par défaut).
$global:BubbleLastPos = $null
# Position d'apparition résolue au masquage + bounds pleins de l'app (pour l'animation).
$global:BubbleNextPos = $null
$global:BubbleSide = 'Right'
$global:AppFullBounds = $null
# Capture de la fenêtre (image source du fantôme animé).
$global:GhostSrc = $null

# Bouton « masquer » dans l'en-tête (à gauche du bouton « ? »).
$btnHide = New-Object Windows.Forms.Button
$btnHide.Text = "»"
$btnHide.Size = New-Object Drawing.Size(34, 34)
$btnHide.Location = New-Object Drawing.Point(1002, 18)
$btnHide.FlatStyle = 'Flat'; $btnHide.FlatAppearance.BorderSize = 0
$btnHide.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
$btnHide.BackColor = $cBorder; $btnHide.ForeColor = $cWhite
$btnHide.Font = [Drawing.Font]::new("Segoe UI", 12, [Drawing.FontStyle]::Bold)
$btnHide.Cursor = [Windows.Forms.Cursors]::Hand
$btnHide.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$form.Controls.Add($btnHide)
$btnHide.BringToFront()

# Bulle RONDE flottante (style « bulle de discussion ») avec l'icône de l'app. Cachée
# par défaut ; n'apparaît qu'une fois l'app masquée.
$bubble = New-Object Windows.Forms.Form
$bubble.FormBorderStyle = 'None'; $bubble.ShowInTaskbar = $false
$bubble.StartPosition = 'Manual'; $bubble.TopMost = $true
# Windows impose une largeur mini de fenêtre (~136 px) : sans lever cette contrainte,
# la bulle resterait large de 136 px (cercle clippé à gauche => bulle « décalée »).
$bubble.MinimumSize = New-Object Drawing.Size(1, 1)
$bubble.AutoScaleMode = 'None'
$bubble.Size = New-Object Drawing.Size(54, 54)
$bubble.BackColor = [Drawing.Color]::White
$bpath = New-Object Drawing.Drawing2D.GraphicsPath
$bpath.AddEllipse(0, 0, 54, 54)
$bubble.Region = New-Object Drawing.Region($bpath)
$bubble.Cursor = [Windows.Forms.Cursors]::Hand

$picBubble = New-Object Windows.Forms.PictureBox
$picBubble.Dock = 'Fill'; $picBubble.SizeMode = 'StretchImage'
$picBubble.BackColor = [Drawing.Color]::White
$picBubble.Cursor = [Windows.Forms.Cursors]::Hand
# Avatar = SEULEMENT la TÊTE de la conseillère, recadrée depuis l'en-tête paysage
# (qui contient aussi un robot et le buste). Rect calé sur le visage détecté (35,14,80,80).
try {
    if (Test-Path $cheminHeader) {
        $srcAvatar = New-Object Drawing.Bitmap($cheminHeader)
        $crop = New-Object Drawing.Rectangle(35, 14, 80, 80)
        $picBubble.Image = $srcAvatar.Clone($crop, $srcAvatar.PixelFormat)
        $srcAvatar.Dispose()
    } elseif ($picHeader.Image) { $picBubble.Image = $picHeader.Image }
} catch { if ($picHeader.Image) { $picBubble.Image = $picHeader.Image } }
$bubble.Controls.Add($picBubble)

# --- Déplacement de la bulle à la souris (comme les bulles de discussion Messenger) ---
# On distingue un simple clic (=> afficher l'app) d'un glisser (=> repositionner la bulle).
# Un glisser au-delà de 5 px verrouille le mode déplacement ; au relâchement la bulle
# s'aimante au bord gauche/droit le plus proche de l'écran où elle se trouve.
$dragState = @{ Dragging = $false; Moved = $false; OffX = 0; OffY = 0; DownX = 0; DownY = 0 }
$picBubble.Add_MouseDown({
    param($s, $e)
    if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    $dragState.Dragging = $true
    $dragState.Moved = $false
    $dragState.OffX = $e.X
    $dragState.OffY = $e.Y
    $p = [Windows.Forms.Cursor]::Position
    $dragState.DownX = $p.X; $dragState.DownY = $p.Y
})
$picBubble.Add_MouseMove({
    param($s, $e)
    if (-not $dragState.Dragging) { return }
    $p = [Windows.Forms.Cursor]::Position
    if (-not $dragState.Moved -and ([Math]::Abs($p.X - $dragState.DownX) -gt 5 -or [Math]::Abs($p.Y - $dragState.DownY) -gt 5)) {
        $dragState.Moved = $true
    }
    $bubble.Location = New-Object Drawing.Point(($p.X - $dragState.OffX), ($p.Y - $dragState.OffY))
})
$picBubble.Add_MouseUp({
    param($s, $e)
    if ($e.Button -ne [Windows.Forms.MouseButtons]::Left) { return }
    if (-not $dragState.Dragging) { return }
    $dragState.Dragging = $false
    if ($dragState.Moved) {
        # Aimantation au bord gauche/droit le plus proche de l'écran courant.
        $cx = $bubble.Left + [int]($bubble.Width / 2)
        $cy = $bubble.Top + [int]($bubble.Height / 2)
        $wa = [Windows.Forms.Screen]::FromPoint((New-Object Drawing.Point($cx, $cy))).WorkingArea
        $y = [Math]::Max($wa.Top, [Math]::Min($bubble.Top, $wa.Bottom - $bubble.Height))
        if ($cx -lt ($wa.Left + $wa.Width / 2)) { $x = $wa.Left + 8; $global:BubbleSide = 'Left' } else { $x = $wa.Right - $bubble.Width - 8; $global:BubbleSide = 'Right' }
        $bubble.Location = New-Object Drawing.Point([int]$x, [int]$y)
        # Mémorise la position + le côté pour la prochaine animation et le prochain masquage.
        $global:BubbleLastPos = $bubble.Location
    } else {
        Show-App
    }
})

# ============================================================================
#  Animation « vortex / trou noir » (façon Kamui) : au masquage, une IMAGE FANTÔME
#  de l'app TOURNE sur elle-même, SPIRALE et s'aspire vers la bulle en accélérant ;
#  à l'affichage, elle ré-émerge de la bulle (tourne à l'envers + grandit). Point
#  focal = la bulle (pas le bord d'écran) => robuste multi-écran ; le vrai formulaire
#  n'est jamais redimensionné. On anime un fantôme (capture d'écran) qui tourne,
#  SPIRALE, devient progressivement FLOU + ARRONDI + transparent (doux pour les yeux),
#  via une fenêtre à transparence PAR PIXEL (UpdateLayeredWindow).
# ============================================================================
# Fenêtre à transparence PAR PIXEL (alpha doux, pas de bord net) via UpdateLayeredWindow.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
public static class LayeredGhost {
    [DllImport("user32.dll", SetLastError=true)] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll", SetLastError=true)] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern IntPtr SelectObject(IntPtr dc, IntPtr o);
    [DllImport("gdi32.dll")] static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    [DllImport("user32.dll", SetLastError=true)]
    static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr dst, ref POINT pDst, ref SIZE size, IntPtr src, ref POINT pSrc, int key, ref BLENDFUNCTION bf, int flags);
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int x, y; public POINT(int a, int b){x=a;y=b;} }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; public SIZE(int a, int b){cx=a;cy=b;} }
    [StructLayout(LayoutKind.Sequential, Pack=1)] struct BLENDFUNCTION { public byte Op, Flags, Alpha, Format; }
    const int GWL_EXSTYLE=-20, WS_EX_LAYERED=0x80000, ULW_ALPHA=2;
    public static void Enable(IntPtr hwnd) {
        int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
    }
    static void Premultiply(Bitmap bmp) {
        Rectangle r = new Rectangle(0,0,bmp.Width,bmp.Height);
        BitmapData d = bmp.LockBits(r, ImageLockMode.ReadWrite, PixelFormat.Format32bppArgb);
        byte[] buf = new byte[d.Stride*d.Height];
        Marshal.Copy(d.Scan0, buf, 0, buf.Length);
        for (int i=0;i<buf.Length;i+=4){
            int a=buf[i+3];
            buf[i]=(byte)(buf[i]*a/255); buf[i+1]=(byte)(buf[i+1]*a/255); buf[i+2]=(byte)(buf[i+2]*a/255);
        }
        Marshal.Copy(buf,0,d.Scan0,buf.Length);
        bmp.UnlockBits(d);
    }
    public static void Update(IntPtr hwnd, Bitmap bmp, int x, int y, byte alpha) {
        Premultiply(bmp);
        IntPtr screen = GetDC(IntPtr.Zero);
        IntPtr mem = CreateCompatibleDC(screen);
        IntPtr hb = IntPtr.Zero, old = IntPtr.Zero;
        try {
            hb = bmp.GetHbitmap(Color.FromArgb(0));
            old = SelectObject(mem, hb);
            SIZE sz = new SIZE(bmp.Width, bmp.Height);
            POINT ps = new POINT(0,0); POINT pd = new POINT(x,y);
            BLENDFUNCTION bf = new BLENDFUNCTION(); bf.Op=0; bf.Flags=0; bf.Alpha=alpha; bf.Format=1;
            UpdateLayeredWindow(hwnd, screen, ref pd, ref sz, mem, ref ps, 0, ref bf, ULW_ALPHA);
        } finally {
            if (old != IntPtr.Zero) SelectObject(mem, old);
            if (hb != IntPtr.Zero) DeleteObject(hb);
            DeleteDC(mem); ReleaseDC(IntPtr.Zero, screen);
        }
    }
}
"@

# P/Invoke : fenêtre au premier plan + son PID (pour le masquage automatique).
Add-Type -Namespace Win32 -Name Fg -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
'@

$ghost = New-Object Windows.Forms.Form
$ghost.FormBorderStyle = 'None'; $ghost.ShowInTaskbar = $false
$ghost.StartPosition = 'Manual'; $ghost.TopMost = $true
$ghost.MinimumSize = New-Object Drawing.Size(1, 1)
$ghost.AutoScaleMode = 'None'
$null = $ghost.Handle                       # force la création du handle
[LayeredGhost]::Enable($ghost.Handle)       # active la transparence par pixel

# Capture pixel-fidèle de la fenêtre (inclut le WebBrowser d'aperçu) -> $global:GhostSrc.
function Capture-FormToGhost {
    try {
        $b = $form.Bounds
        $bmp = New-Object Drawing.Bitmap($b.Width, $b.Height)
        $g = [Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.X, $b.Y, 0, 0, $b.Size)
        $g.Dispose()
        $old = $global:GhostSrc; $global:GhostSrc = $bmp; if ($old) { $old.Dispose() }
    } catch { $global:GhostSrc = $null }
}

# Rend une frame « Kamui » (ARGB) : image pivotée de $Ang°, masquée en rectangle ARRONDI
# (rayon ramené par $RoundFrac : 0=rect, 1=ellipse) puis FLOUTÉE (facteur $BlurF >= 1).
# Renvoie @{ Bmp; W; H }. Le FONDU global est appliqué à part (alpha de la fenêtre).
function Render-Kamui($Src, $Dw, $Dh, $Ang, $BlurF, $RoundFrac) {
    $rad = $Ang * [Math]::PI / 180.0
    $c = [Math]::Abs([Math]::Cos($rad)); $s = [Math]::Abs([Math]::Sin($rad))
    $pad = 26
    $bw = [int][Math]::Ceiling($Dw * $c + $Dh * $s) + 2 * $pad; if ($bw -lt 1) { $bw = 1 }
    $bh = [int][Math]::Ceiling($Dw * $s + $Dh * $c) + 2 * $pad; if ($bh -lt 1) { $bh = 1 }
    $canvas = New-Object Drawing.Bitmap($bw, $bh, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($canvas)
    $g.SmoothingMode = 'AntiAlias'; $g.InterpolationMode = 'HighQualityBilinear'
    $g.TranslateTransform($bw / 2.0, $bh / 2.0); $g.RotateTransform([single]$Ang)
    $rr = [Math]::Min($Dw, $Dh) / 2.0 * $RoundFrac
    if ($rr -lt 0.5) {
        $g.SetClip((New-Object Drawing.RectangleF([single](-$Dw / 2.0), [single](-$Dh / 2.0), [single]$Dw, [single]$Dh)))
    } else {
        $d = 2.0 * $rr; $pp = New-Object Drawing.Drawing2D.GraphicsPath
        $pp.AddArc([single](-$Dw / 2.0), [single](-$Dh / 2.0), [single]$d, [single]$d, 180, 90)
        $pp.AddArc([single]($Dw / 2.0 - $d), [single](-$Dh / 2.0), [single]$d, [single]$d, 270, 90)
        $pp.AddArc([single]($Dw / 2.0 - $d), [single]($Dh / 2.0 - $d), [single]$d, [single]$d, 0, 90)
        $pp.AddArc([single](-$Dw / 2.0), [single]($Dh / 2.0 - $d), [single]$d, [single]$d, 90, 90)
        $pp.CloseFigure(); $g.SetClip($pp); $pp.Dispose()
    }
    $g.DrawImage($Src, (New-Object Drawing.Rectangle([int](-$Dw / 2), [int](-$Dh / 2), [int]$Dw, [int]$Dh)))
    $g.ResetClip(); $g.Dispose()
    if ($BlurF -gt 1.05) {
        $hw = [Math]::Max(1, [int]($bw / $BlurF)); $hh = [Math]::Max(1, [int]($bh / $BlurF))
        $tmp = New-Object Drawing.Bitmap($hw, $hh, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $ga = [Drawing.Graphics]::FromImage($tmp); $ga.InterpolationMode = 'HighQualityBilinear'; $ga.DrawImage($canvas, 0, 0, $hw, $hh); $ga.Dispose()
        $out = New-Object Drawing.Bitmap($bw, $bh, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gb = [Drawing.Graphics]::FromImage($out); $gb.InterpolationMode = 'HighQualityBilinear'; $gb.DrawImage($tmp, 0, 0, $bw, $bh); $gb.Dispose()
        $canvas.Dispose(); $tmp.Dispose(); $canvas = $out
    }
    return @{ Bmp = $canvas; W = $bw; H = $bh }
}

# Compose + affiche une frame centrée sur ($Cx,$Cy), avec fondu $Alpha (0-255).
function Set-GhostFrame($Cx, $Cy, $Dw, $Dh, $Ang, $BlurF, $RoundFrac, $Alpha) {
    $r = Render-Kamui $global:GhostSrc $Dw $Dh $Ang $BlurF $RoundFrac
    $x = [int]($Cx - $r.W / 2.0); $y = [int]($Cy - $r.H / 2.0)
    $a = [int]$Alpha; if ($a -lt 0) { $a = 0 } elseif ($a -gt 255) { $a = 255 }
    [LayeredGhost]::Update($ghost.Handle, $r.Bmp, $x, $y, [byte]$a)
    $r.Bmp.Dispose()
}

$slideTimer = New-Object Windows.Forms.Timer
$slideTimer.Interval = 10
$slideState = @{ Frame = 0; Total = 16; Hiding = $false
    AppCx = 0.0; AppCy = 0.0; BubCx = 0.0; BubCy = 0.0; W0 = 1; H0 = 1; Spins = 1.5; R0 = 120.0 }
$slideTimer.Add_Tick({
    $slideState.Frame++
    $t = $slideState.Frame / $slideState.Total
    if ($t -gt 1) { $t = 1 }
    if ($slideState.Hiding) {
        $p = [Math]::Pow($t, 1.9)                       # aspiration : retient puis happe
    } else {
        $p = 1.0 - [Math]::Pow(1 - $t, 1.9)             # émergence : jaillit puis se pose
    }
    # 'a' = progression « avancée dans le trou » (0 = pleine app nette, 1 = happée/floue).
    $a = if ($slideState.Hiding) { $p } else { 1.0 - $p }
    # Angle de la SPIRALE (trajectoire uniquement) : l'app NE TOURNE PAS sur elle-même.
    $pathAng = $slideState.Spins * 360.0 * $a
    $scale = 1.0 - 0.96 * $a
    $blurF = 1.0 + 9.0 * [Math]::Pow($a, 1.3)
    $round = [Math]::Min(1.0, $a * 1.4)
    $alpha = 255.0 * (1.0 - 0.88 * $a)
    if ($slideState.Hiding) {
        $cx0 = $slideState.AppCx + ($slideState.BubCx - $slideState.AppCx) * $p
        $cy0 = $slideState.AppCy + ($slideState.BubCy - $slideState.AppCy) * $p
    } else {
        $cx0 = $slideState.BubCx + ($slideState.AppCx - $slideState.BubCx) * $p
        $cy0 = $slideState.BubCy + ($slideState.AppCy - $slideState.BubCy) * $p
    }
    # Décalage en SPIRALE : rayon nul aux extrémités, maximal au milieu (trajectoire courbe).
    $sr = $slideState.R0 * [Math]::Sin([Math]::PI * $p)
    $rad = $pathAng * [Math]::PI / 180.0
    $cx = $cx0 + $sr * [Math]::Cos($rad)
    $cy = $cy0 + $sr * [Math]::Sin($rad)
    # Angle de rotation de l'image = 0 : l'app reste droite (pas de spin).
    Set-GhostFrame $cx $cy ([Math]::Max(1, $slideState.W0 * $scale)) ([Math]::Max(1, $slideState.H0 * $scale)) 0 $blurF $round $alpha
    if ($slideState.Frame -ge $slideState.Total) {
        $slideTimer.Stop()
        if ($slideState.Hiding) {
            $global:AppHidden = $true
            $bubble.Location = $global:BubbleNextPos
            $global:BubbleLastPos = $global:BubbleNextPos
            $bubble.TopMost = $true
            $bubble.Show(); $bubble.BringToFront()
            $ghost.Hide()
            $bubble.Activate()
        } else {
            $form.Bounds = $global:AppFullBounds
            $form.Show(); $form.Activate()
            $global:AppHidden = $false
            $ghost.Hide()
        }
    }
}.GetNewClosure())

function Hide-App {
    if ($slideTimer.Enabled -or $global:AppHidden) { return }
    # Résout la position d'apparition de la bulle (mémorisée, sinon défaut bord droit).
    $bw = $bubble.Width; $bh = $bubble.Height
    $pos = $global:BubbleLastPos; $valid = $false
    if ($null -ne $pos) {
        $vc = New-Object Drawing.Point(($pos.X + [int]($bw / 2)), ($pos.Y + [int]($bh / 2)))
        if ([Windows.Forms.SystemInformation]::VirtualScreen.Contains($vc)) { $valid = $true }
    }
    if (-not $valid) {
        $wa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $pos = New-Object Drawing.Point(($wa.Right - $bw - 8), [int]($wa.Top + ($wa.Height - $bh) / 2))
    }
    $global:BubbleNextPos = $pos
    $global:AppFullBounds = $form.Bounds
    Capture-FormToGhost
    $fb = $global:AppFullBounds
    if ($null -eq $global:GhostSrc) {
        # Repli si la capture a échoué : masquage direct sans animation.
        $global:AppHidden = $true; $form.Hide()
        $bubble.Location = $pos; $global:BubbleLastPos = $pos
        $bubble.TopMost = $true; $bubble.Show(); $bubble.BringToFront(); return
    }
    $slideState.W0 = $fb.Width; $slideState.H0 = $fb.Height
    $slideState.AppCx = $fb.X + $fb.Width / 2.0; $slideState.AppCy = $fb.Y + $fb.Height / 2.0
    $slideState.BubCx = $pos.X + $bw / 2.0; $slideState.BubCy = $pos.Y + $bh / 2.0
    $slideState.Frame = 0; $slideState.Hiding = $true
    # Frame 0 = image pleine, nette, non pivotée => relais sans rupture avec la fenêtre.
    [LayeredGhost]::Enable($ghost.Handle)
    Set-GhostFrame $slideState.AppCx $slideState.AppCy $fb.Width $fb.Height 0 1.0 0.0 255
    $ghost.Visible = $true; $ghost.BringToFront()
    $form.Hide()
    $slideTimer.Start()
}
function Show-App {
    if (-not $global:AppHidden -or $slideTimer.Enabled) { return }
    if ($null -eq $global:GhostSrc -or $null -eq $global:AppFullBounds) {
        # Repli : affichage direct.
        $bubble.Hide(); if ($global:AppFullBounds) { $form.Bounds = $global:AppFullBounds }
        $form.Show(); $form.Activate(); $global:AppHidden = $false; return
    }
    $fb = $global:AppFullBounds
    $slideState.W0 = $fb.Width; $slideState.H0 = $fb.Height
    $slideState.AppCx = $fb.X + $fb.Width / 2.0; $slideState.AppCy = $fb.Y + $fb.Height / 2.0
    $slideState.BubCx = $bubble.Left + $bubble.Width / 2.0; $slideState.BubCy = $bubble.Top + $bubble.Height / 2.0
    $slideState.Frame = 0; $slideState.Hiding = $false
    # Frame 0 = tout petit, flou, transparent (sans rotation), au centre de la bulle.
    [LayeredGhost]::Enable($ghost.Handle)
    Set-GhostFrame $slideState.BubCx $slideState.BubCy ([Math]::Max(1, $fb.Width * 0.04)) ([Math]::Max(1, $fb.Height * 0.04)) 0 10.0 1.0 30
    $bubble.Hide()
    $ghost.Visible = $true; $ghost.BringToFront()
    $slideTimer.Start()
}

$btnHide.Add_Click({ Hide-App })

# ============================================================================
#  Masquage AUTOMATIQUE : quand l'app perd le focus vers une AUTRE application,
#  elle se replie en bulle (même animation que le bouton « masquer »). Un timer
#  mono-coup de 200 ms laisse le nouveau premier plan se stabiliser ; on ne
#  masque que si sa fenêtre appartient à un autre processus (cf. Should-AutoHide,
#  lib/Common.ps1). Couvre ainsi dialogues, popup calendrier, tutoriel, bulle.
# ============================================================================
$timerAutoHide = New-Object Windows.Forms.Timer
$timerAutoHide.Interval = 200
$timerAutoHide.Add_Tick({
    $timerAutoHide.Stop()
    $h = [Win32.Fg]::GetForegroundWindow()
    $fgPid = [uint32]0
    if ($h -ne [IntPtr]::Zero) { [void][Win32.Fg]::GetWindowThreadProcessId($h, [ref]$fgPid) }
    if (Should-AutoHide -AppHidden $global:AppHidden -Animating $slideTimer.Enabled -Suppressed $global:SuppressAutoHide -ForegroundPid ([int]$fgPid) -OwnPid $PID) {
        Hide-App
    }
}.GetNewClosure())
$form.Add_Deactivate({
    if ($global:AppHidden -or $slideTimer.Enabled -or $global:SuppressAutoHide) { return }
    $timerAutoHide.Stop(); $timerAutoHide.Start()
}.GetNewClosure())
# (le clic simple sur la bulle est géré par MouseUp ci-dessus : tap = afficher, glisser = déplacer)

# Clic-DROIT sur la bulle : menu pour afficher ou fermer l'app même en mode masqué
# (sans ce menu, une app masquée n'a aucun moyen d'être fermée -> instances empilées).
$bubbleMenu = New-Object Windows.Forms.ContextMenuStrip
$bubbleMenu.BackColor = $cBgSecondary
$bubbleMenu.ForeColor = $cTextPrimary
$bubbleMenu.ShowImageMargin = $false
$miShow = $bubbleMenu.Items.Add("Afficher l'application")
$miShow.add_Click({ Show-App })
$miClose = $bubbleMenu.Items.Add("Fermer l'application")
$miClose.add_Click({ $global:AppHidden = $false; $bubble.Hide(); $form.Close() })
$bubble.ContextMenuStrip = $bubbleMenu
$picBubble.ContextMenuStrip = $bubbleMenu

$form.Add_FormClosed({ try { $bubble.Close() } catch { }; try { $ghost.Close() } catch { } })

# Démarrage TOUJOURS centré sur l'écran principal — UNE SEULE fois (sinon le re-Show
# de la languette recentrerait l'app au lieu de la laisser glisser).
$global:AppFirstShown = $false
$form.Add_Shown({
    if ($global:AppFirstShown) { return }
    $global:AppFirstShown = $true
    try {
        $pa = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = [int]($pa.X + ($pa.Width - $form.Width) / 2)
        $y = [Math]::Max($pa.Y, [int]($pa.Y + ($pa.Height - $form.Height) / 2))
        $form.Location = New-Object Drawing.Point($x, $y)
    } catch { }
})

# Boucle principale : Application::Run (et non ShowDialog) pour que la languette
# reste active à côté de la fenêtre principale.
[Windows.Forms.Application]::Run($form)