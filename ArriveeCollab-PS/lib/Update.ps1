# ============================================================================
#  Mise à jour automatique. CANAL PRINCIPAL : dépôt GitHub PUBLIC (lecture de
#  latest.json + du zip versionné via raw.githubusercontent.com — AUCUN jeton,
#  simple HTTPS à travers le proxy système). REPLI : dossier de DISTRIBUTION
#  (OneDrive/SharePoint) si GitHub est inaccessible ou non configuré.
#  Ce fichier = LOGIQUE de détection + changelog hors-ligne + DIALOGUES WinForms
#  + self-update.
# ============================================================================

# Résout le dossier de distribution : Config.UpdateDir (relatif sous OneDrive, ou
# absolu/UNC), repli sur dist_path.txt écrit par le bootstrap. $null si rien de valide.
function Get-UpdateDir {
    param($Ctx)
    $cands = @()
    $raw = [string]$Ctx.Config.UpdateDir
    if ($raw) {
        try { $raw = [Environment]::ExpandEnvironmentVariables($raw) } catch { }
        if ([System.IO.Path]::IsPathRooted($raw)) {
            $cands += $raw
        } else {
            foreach ($base in @($env:OneDriveCommercial, $env:OneDrive, (Join-Path $env:USERPROFILE 'OneDrive - SNCF'), (Join-Path $env:USERPROFILE 'OneDrive'))) {
                if ($base) { $cands += (Join-Path $base $raw) }
            }
        }
    }
    try {
        $dp = Join-Path $Ctx.DataDir 'dist_path.txt'
        if (Test-Path -LiteralPath $dp) {
            $v = (Get-Content -LiteralPath $dp -Raw -Encoding UTF8).Trim()
            if ($v) { $cands += $v }
        }
    } catch { }
    foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    return $null
}

# Base des URLs « raw » du dépôt GitHub de distribution (canal principal), ou $null
# si non configuré (Config.UpdateRepo = 'owner/repo', Config.UpdateBranch = 'main').
function Get-UpdateRawBase {
    param($Ctx)
    $repo = [string]$Ctx.Config.UpdateRepo
    if (-not $repo) { return $null }
    $branch = [string]$Ctx.Config.UpdateBranch
    if (-not $branch) { $branch = 'main' }
    return "https://raw.githubusercontent.com/$repo/$branch"
}

# Télécharge une URL : renvoie le TEXTE (sans -OutFile) ou écrit le fichier et renvoie
# $true. TLS 1.2 forcé + proxy système avec identifiants par défaut (postes SNCF
# derrière proxy authentifié). LÈVE en cas d'échec : l'appelant gère le repli.
function Invoke-UpdateDownload {
    param([string]$Uri, [string]$OutFile)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    try {
        $wc.Headers['User-Agent'] = 'ArriveeCollab-Update'
        $wc.Headers['Cache-Control'] = 'no-cache'
        if ($wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
        if ($OutFile) { $wc.DownloadFile($Uri, $OutFile); return $true }
        return $wc.DownloadString($Uri)
    } finally { $wc.Dispose() }
}

# Parse le CONTENU d'un latest.json -> @{ Version; Zip; Notes(@()) } ou $null.
# Fonction pure (testable hors ligne), partagée par les deux canaux.
function ConvertFrom-LatestJson {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    try {
        $j = $Raw | ConvertFrom-Json
        if (-not $j.version) { return $null }
        $zip = [string]$j.zip
        if (-not $zip) { $zip = "Arrivee-Collab_version$([string]$j.version).zip" }
        $notes = @()
        if ($j.notes) { $notes = @($j.notes | ForEach-Object { [string]$_ }) }
        return @{ Version = [string]$j.version; Zip = $zip; Notes = $notes }
    } catch { return $null }
}

# Lit latest.json -> @{ Version; Zip; Notes; Source ('github'|'dossier') } ou $null.
# Essaie GITHUB d'abord (cache-bust : le CDN raw peut servir ~5 min de cache), puis
# se replie sur le dossier de distribution.
function Get-LatestManifest {
    param($Ctx)
    $base = Get-UpdateRawBase $Ctx
    if ($base) {
        try {
            $raw = [string](Invoke-UpdateDownload -Uri ("{0}/latest.json?nocache={1}" -f $base, [DateTime]::UtcNow.Ticks))
            $m = ConvertFrom-LatestJson $raw
            if ($m) { $m.Source = 'github'; return $m }
            Write-AppLog "[MAJ] latest.json GitHub illisible : repli sur le dossier."
        } catch {
            Write-AppLog "[MAJ] GitHub inaccessible ($($_.Exception.Message)) : repli sur le dossier."
        }
    }
    $dir = Get-UpdateDir $Ctx
    if (-not $dir) { return $null }
    $mf = Join-Path $dir 'latest.json'
    if (-not (Test-Path -LiteralPath $mf)) { return $null }
    try {
        $m = ConvertFrom-LatestJson (Get-Content -LiteralPath $mf -Raw -Encoding UTF8)
        if ($m) { $m.Source = 'dossier' }
        return $m
    } catch {
        Write-AppLog "[MAJ] Lecture latest.json KO : $($_.Exception.Message)"
        return $null
    }
}

# Clé de tri numérique d'une version "a.b.c" (paddée) -> tri fiable (1.4.10 > 1.4.2).
function Convert-VersionSortKey {
    param([string]$V)
    $parts = @(([string]$V) -split '\.')
    return (($parts | ForEach-Object { '{0:D6}' -f [int]("0" + ($_ -replace '[^0-9]', '')) }) -join '.')
}

# Notes de version pour une version donnée, lisibles HORS LIGNE :
#  1) releases.json EMBARQUÉ (à la racine de AppRoot) ; 2) repli latest.json si même version.
function Get-LocalReleaseNotes {
    param($Ctx, [string]$Version)
    if (-not $Version) { return @() }
    try {
        $rf = Join-Path $Ctx.AppRoot 'releases.json'
        if (Test-Path -LiteralPath $rf) {
            $rel = Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($rel.PSObject.Properties.Name -contains $Version) {
                return @($rel.$Version | ForEach-Object { [string]$_ })
            }
        }
    } catch { Write-AppLog "[VERSION] Lecture releases.json KO : $($_.Exception.Message)" }
    try {
        $m = Get-LatestManifest $Ctx
        if ($m -and $m.Version -eq $Version -and @($m.Notes).Count -gt 0) { return @($m.Notes) }
    } catch { }
    return @()
}

# Notes des $Max versions les plus récentes du releases.json EMBARQUÉ.
function Get-RecentReleaseNotes {
    param($Ctx, [int]$Max = 3)
    $out = @()
    try {
        $rf = Join-Path $Ctx.AppRoot 'releases.json'
        if (-not (Test-Path -LiteralPath $rf)) { return @() }
        $rel = Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json
        $names = @($rel.PSObject.Properties.Name)
        $sorted = @($names | Sort-Object -Descending { Convert-VersionSortKey $_ })
        foreach ($v in @($sorted | Select-Object -First $Max)) {
            $out += @{ Version = [string]$v; Notes = @($rel.$v | ForEach-Object { [string]$_ }) }
        }
    } catch { Write-AppLog "[VERSION] Lecture recente releases.json KO : $($_.Exception.Message)" }
    return $out
}

# Notes de TOUTES les versions > $FromVersion et <= $ToVersion (releases.json EMBARQUÉ),
# de la plus récente à la plus ancienne. $Cap = garde-fou.
function Get-ReleaseNotesBetween {
    param($Ctx, [string]$FromVersion, [string]$ToVersion, [int]$Cap = 25)
    $out = @()
    try {
        $rf = Join-Path $Ctx.AppRoot 'releases.json'
        if (-not (Test-Path -LiteralPath $rf)) { return @() }
        $rel = Get-Content -LiteralPath $rf -Raw -Encoding UTF8 | ConvertFrom-Json
        $kFrom = if ($FromVersion) { Convert-VersionSortKey $FromVersion } else { '' }
        $kTo = Convert-VersionSortKey $ToVersion
        $names = @($rel.PSObject.Properties.Name | Where-Object {
            $k = Convert-VersionSortKey $_
            ($k -le $kTo) -and ((-not $kFrom) -or ($k -gt $kFrom))
        })
        $sorted = @($names | Sort-Object -Descending { Convert-VersionSortKey $_ })
        foreach ($v in @($sorted | Select-Object -First $Cap)) {
            $out += @{ Version = [string]$v; Notes = @($rel.$v | ForEach-Object { [string]$_ }) }
        }
    } catch { Write-AppLog "[VERSION] Lecture intervalle releases.json KO : $($_.Exception.Message)" }
    return $out
}

# Vérifie s'il existe une version plus récente ; met à jour $Ctx.UpdateAvailable + la
# pastille. Source GitHub : le zip est réputé présent (poussé avec latest.json par
# build-zip.ps1 ; son téléchargement est re-vérifié au moment du self-update). Source
# dossier : ne proposer que si le zip annoncé est bien là. Ne lève jamais.
function Invoke-UpdateCheck {
    param($Ctx)
    try {
        $m = Get-LatestManifest $Ctx
        if ($m -and (Compare-AppVersion $m.Version $Ctx.Config.Version) -gt 0) {
            $zipOk = $true
            if ($m.Source -ne 'github') {
                $dir = Get-UpdateDir $Ctx
                $zipPath = if ($dir) { Join-Path $dir $m.Zip } else { $null }
                $zipOk = [bool]($zipPath -and (Test-Path -LiteralPath $zipPath))
            }
            if ($zipOk) {
                if (-not $Ctx.UpdateAvailable -or $Ctx.UpdateAvailable.Version -ne $m.Version) {
                    Write-AppLog ("[MAJ] Nouvelle version disponible : {0} (actuelle {1}, source {2})." -f $m.Version, $Ctx.Config.Version, $m.Source)
                }
                $Ctx.UpdateAvailable = $m
            } else {
                Write-AppLog ("[MAJ] Version {0} annoncée mais zip introuvable : {1}" -f $m.Version, $m.Zip)
                $Ctx.UpdateAvailable = $null
            }
        } else {
            $Ctx.UpdateAvailable = $null
        }
    } catch { Write-AppLog "[MAJ] Vérification KO : $($_.Exception.Message)" }
    try { Update-UpdateBadge $Ctx } catch { }
}

# ============================================================================
#  DIALOGUES (WinForms, thème sombre — même style que Show-AlertDialog) + SELF-UPDATE.
# ============================================================================

# Dialogue générique listant des notes groupées par version. $Groups = @(@{Version;Notes}).
# Renvoie $true si le bouton primaire (violet) est cliqué, sinon $false.
function Show-NotesDialog {
    param([string]$Title, [string]$Headline, [string]$Sub, $Groups, [string]$PrimaryText, [bool]$ShowSecondary)
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = $Title
    $dlg.Size = New-Object Drawing.Size(520, 460)
    $dlg.StartPosition = "CenterScreen"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = $cBgMain; $dlg.ForeColor = $cTextPrimary
    $dlg.Font = [Drawing.Font]::new("Segoe UI", 10)
    $dlgIconPath = Join-Path $baseDir "image-arrivee-collab.ico"
    if (Test-Path $dlgIconPath) { try { $dlg.Icon = New-Object Drawing.Icon($dlgIconPath) } catch {} }
    $dlg.Add_Shown({ try { [DarkTitleBar]::Enable($this.Handle); [DarkTitleBar]::ApplyDarkScrollbar($rtbNotes.Handle) } catch {} })

    $bar = New-Object Windows.Forms.Panel
    $bar.Dock = "Top"; $bar.Height = 3; $bar.BackColor = $cAccentViolet

    $lblH = New-Object Windows.Forms.Label
    $lblH.Text = $Headline
    $lblH.Font = [Drawing.Font]::new("Segoe UI", 15, [Drawing.FontStyle]::Bold)
    $lblH.ForeColor = $cWhite
    $lblH.Location = New-Object Drawing.Point(22, 14); $lblH.AutoSize = $true

    $lblS = New-Object Windows.Forms.Label
    $lblS.Text = $Sub
    $lblS.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $lblS.ForeColor = $cAccentViolet
    $lblS.Location = New-Object Drawing.Point(24, 48); $lblS.AutoSize = $true

    # Notes : RichTextBox en lecture seule, une section "vX" + puces par groupe.
    $rtbNotes = New-Object Windows.Forms.RichTextBox
    $rtbNotes.Location = New-Object Drawing.Point(22, 80)
    $rtbNotes.Size = New-Object Drawing.Size(468, 290)
    $rtbNotes.BackColor = $cSurface; $rtbNotes.ForeColor = $cTextPrimary
    $rtbNotes.BorderStyle = 'None'; $rtbNotes.ReadOnly = $true
    $rtbNotes.Font = [Drawing.Font]::new("Segoe UI", 9)
    $sb = New-Object System.Text.StringBuilder
    foreach ($g in @($Groups)) {
        $gnotes = @($g.Notes)
        if ($gnotes.Count -eq 0) { continue }
        [void]$sb.AppendLine("v$($g.Version)")
        foreach ($n in $gnotes) { [void]$sb.AppendLine("  • $n") }
        [void]$sb.AppendLine("")
    }
    if ($sb.Length -eq 0) { [void]$sb.AppendLine("Améliorations et corrections diverses.") }
    $rtbNotes.Text = $sb.ToString().TrimEnd()

    $bp = New-Object Windows.Forms.Panel
    $bp.Dock = "Bottom"; $bp.Height = 55; $bp.BackColor = $cBgSecondary
    $result = @{ Ok = $false }

    $btnP = New-Object Windows.Forms.Button
    $btnP.Text = $PrimaryText
    $btnP.Size = New-Object Drawing.Size(230, 35)
    $btnP.Location = New-Object Drawing.Point(260, 10)
    $btnP.FlatStyle = 'Flat'; $btnP.FlatAppearance.BorderSize = 0
    $btnP.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
    $btnP.BackColor = $cAccentViolet; $btnP.ForeColor = $cWhite
    $btnP.Font = [Drawing.Font]::new("Segoe UI", 10, [Drawing.FontStyle]::Bold)
    $btnP.Cursor = [Windows.Forms.Cursors]::Hand
    $btnP.Add_Click({ $result.Ok = $true; $dlg.Close() }.GetNewClosure())
    $bp.Controls.Add($btnP); $dlg.AcceptButton = $btnP

    if ($ShowSecondary) {
        $btnL = New-Object Windows.Forms.Button
        $btnL.Text = "Plus tard"
        $btnL.Size = New-Object Drawing.Size(110, 35)
        $btnL.Location = New-Object Drawing.Point(140, 10)
        $btnL.FlatStyle = 'Flat'; $btnL.FlatAppearance.BorderSize = 0
        $btnL.FlatAppearance.MouseOverBackColor = [Drawing.Color]::FromArgb(78, 78, 82)
        $btnL.BackColor = $cBorder; $btnL.ForeColor = $cTextPrimary
        $btnL.Font = [Drawing.Font]::new("Segoe UI", 10)
        $btnL.Cursor = [Windows.Forms.Cursors]::Hand
        $btnL.Add_Click({ $dlg.Close() }.GetNewClosure())
        $bp.Controls.Add($btnL); $dlg.CancelButton = $btnL
    }

    $dlg.Controls.AddRange(@($rtbNotes, $lblS, $lblH, $bar, $bp))
    [void]$dlg.ShowDialog()
    return $result.Ok
}

# Dialogue de proposition de mise à jour : notes des 3 dernières versions + bouton confirmer.
function Show-UpdateDialog {
    param($Ctx)
    $m = $Ctx.UpdateAvailable
    if (-not $m) { return $false }
    $groups = @(@{ Version = $m.Version; Notes = @($m.Notes) })
    foreach ($g in @(Get-RecentReleaseNotes $Ctx 3)) {
        if ([string]$g.Version -ne [string]$m.Version) { $groups += $g }
    }
    $groups = @($groups | Select-Object -First 3)
    $sub = "Version $($Ctx.Config.Version)  →  $($m.Version)"
    return (Show-NotesDialog "Mise à jour Arrivée Collab" "⬆ Mise à jour disponible" $sub $groups "⬆ Mettre à jour et redémarrer" $true)
}

# À APPELER AU LANCEMENT (avec la version PRÉCÉDENTE capturée AVANT migration). Si l'app
# a fait une vraie montée, affiche les notes de toutes les versions franchies. Anti-doublon.
function Show-WhatsNewIfUpgraded {
    param($Ctx, [string]$PreviousVersion)
    try {
        $cur = [string]$Ctx.Config.Version
        if (-not $PreviousVersion) { return }
        if ((Compare-AppVersion $cur $PreviousVersion) -le 0) { return }
        if ([string]$Ctx.State.NotesShownVersion -eq $cur) {
            Write-AppLog ("[VERSION] Notes {0} déjà vues : pas de ré-affichage." -f $cur); return
        }
        Write-AppLog ("[VERSION] Montée {0} -> {1} : affichage des notes franchies." -f $PreviousVersion, $cur)
        $groups = @(Get-ReleaseNotesBetween $Ctx $PreviousVersion $cur)
        if (@($groups).Count -eq 0) { $groups = @(@{ Version = $cur; Notes = (Get-LocalReleaseNotes $Ctx $cur) }) }
        $sub = "Version $PreviousVersion  →  $cur"
        [void](Show-NotesDialog "Nouveautés Arrivée Collab" "✨ Mise à jour installée" $sub $groups "OK" $false)
        $Ctx.State.NotesShownVersion = $cur
        try { Save-AppState $Ctx.State } catch { }
    } catch { Write-AppLog "[VERSION] Affichage des notes au lancement KO : $($_.Exception.Message)" }
}

# Lance la mise à jour : copie le zip en local, écrit un updater DÉTACHÉ (attend la
# fermeture de l'app, remplace AppRoot, relance via Start-ArriveeCollab.vbs), puis ferme.
function Invoke-SelfUpdate {
    param($Ctx)
    try {
        $m = $Ctx.UpdateAvailable
        if (-not $m) { return }
        $upDir = Join-Path $Ctx.DataDir 'update'
        if (-not (Test-Path -LiteralPath $upDir)) { New-Item -ItemType Directory -Path $upDir -Force | Out-Null }
        $localZip = Join-Path $upDir ("new_$($m.Version).zip")

        if ($m.Source -eq 'github') {
            # Canal GitHub : téléchargement du zip versionné depuis le dépôt.
            $base = Get-UpdateRawBase $Ctx
            if (-not $base) { Write-AppLog "[MAJ] Dépôt GitHub non configuré."; return }
            try {
                [void](Invoke-UpdateDownload -Uri ("$base/$($m.Zip)") -OutFile $localZip)
                Write-AppLog ("[MAJ] Zip {0} téléchargé depuis GitHub." -f $m.Zip)
            } catch { Write-AppLog "[MAJ] Téléchargement GitHub KO : $($_.Exception.Message)"; return }
        } else {
            # Repli : copie depuis le dossier de distribution.
            $dir = Get-UpdateDir $Ctx
            if (-not $dir) { Write-AppLog "[MAJ] Dossier de distribution indisponible."; return }
            $srcZip = Join-Path $dir $m.Zip
            if (-not (Test-Path -LiteralPath $srcZip)) { Write-AppLog "[MAJ] Zip source introuvable : $srcZip"; return }
            Copy-Item -LiteralPath $srcZip -Destination $localZip -Force
        }

        $appRoot   = $Ctx.AppRoot
        $launcher  = Join-Path $appRoot 'Start-ArriveeCollab.vbs'
        $updaterPs = Join-Path $upDir 'updater.ps1'
        $logPath   = Join-Path $Ctx.DataDir 'app_debug.log'

        $updaterBody = @'
param([int]$AppPid, [string]$Zip, [string]$AppRoot, [string]$Launcher, [string]$LogPath)
function L($m) { try { Add-Content -LiteralPath $LogPath -Value ("{0} [MAJ] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch {} }
try {
    try { Wait-Process -Id $AppPid -Timeout 90 -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 800
    $tmp = Join-Path $env:TEMP ('acupd_' + [guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $Zip -DestinationPath $tmp -Force
        $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
        $srcContent = if ($inner) { $inner.FullName } else { $tmp }
        Copy-Item -Path (Join-Path $srcContent '*') -Destination $AppRoot -Recurse -Force
        L ("Fichiers remplaces dans " + $AppRoot)
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $Zip -Force -ErrorAction SilentlyContinue
    }
    Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $Launcher + '"') -WorkingDirectory $AppRoot
    L "Application relancee apres mise a jour."
} catch { L ("ECHEC updater : " + $_.Exception.Message) }
'@
        [System.IO.File]::WriteAllText($updaterPs, $updaterBody, (New-Object System.Text.UTF8Encoding $false))

        $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -AppPid {1} -Zip "{2}" -AppRoot "{3}" -Launcher "{4}" -LogPath "{5}"' -f `
            $updaterPs, $PID, $localZip, $appRoot, $launcher, $logPath
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -WindowStyle Hidden | Out-Null
        Write-AppLog ("[MAJ] Updater lancé (vers {0}). Fermeture de l'application." -f $m.Version)
        try { $form.Close() } catch { }
        [System.Windows.Forms.Application]::Exit()
    } catch { Write-AppLog "[MAJ] Lancement de la mise à jour KO : $($_.Exception.Message)" }
}

# Re-lit latest.json à l'instant du clic (saute à la toute dernière version), affiche le
# dialogue, et lance le self-update si confirmé.
function Invoke-PromptAndUpdate {
    param($Ctx)
    try { Invoke-UpdateCheck $Ctx } catch { }
    if (-not $Ctx.UpdateAvailable) { return }
    if (Show-UpdateDialog $Ctx) { Invoke-SelfUpdate $Ctx }
}
