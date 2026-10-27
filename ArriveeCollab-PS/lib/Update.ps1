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

# Parse le CONTENU d'un latest.json -> @{ Version; Zip; Sha256; Sig; Notes(@()) } ou $null.
# Fonction pure (testable hors ligne), partagée par tous les canaux.
# Le manifeste n'est pas signé lui-même : on n'accepte qu'une version au format strict et
# le nom du zip est RECONSTRUIT (jamais repris du manifeste : un manifeste forgé ne peut
# pas viser un autre fichier, ex. « ..\..\x.zip »). L'authenticité du zip est garantie
# par Sha256 + Sig, vérifiés avant installation (Test-ReleasePackage).
function ConvertFrom-LatestJson {
    param([string]$Raw)
    if (-not $Raw) { return $null }
    try {
        $j = $Raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
        $ver = [string]$j.version
        if ($ver -notmatch '^\d{1,4}(\.\d{1,4}){1,3}$') { return $null }
        $notes = @()
        if ($j.notes) { $notes = @($j.notes | ForEach-Object { [string]$_ }) }
        return @{
            Version = $ver; Zip = "Arrivee-Collab_version$ver.zip"; Notes = $notes
            Sha256 = ([string]$j.sha256).ToUpperInvariant(); Sig = [string]$j.sig
            Date = [string]$j.date; MSig = [string]$j.msig
        }
    } catch { return $null }
}

# Texte signé pour le MANIFESTE entier (champ msig) : version, empreinte, date et
# empreinte SHA-256 des notes (une par ligne). Un manifeste forgé ne peut donc ni
# afficher de fausses notes ni annoncer une version qui n'existe pas.
function Get-ManifestSignedText {
    param([string]$Version, [string]$Sha256, [string]$Date, $Notes)
    $h = [System.Security.Cryptography.SHA256]::Create()
    try {
        $nh = -join ($h.ComputeHash([Text.Encoding]::UTF8.GetBytes(((@($Notes) | ForEach-Object { [string]$_ }) -join "`n"))) | ForEach-Object { $_.ToString('X2') })
    } finally { $h.Dispose() }
    return "Arrivee-Collab-manifest|$Version|$($Sha256.ToUpperInvariant())|$Date|$nh"
}

# Manifeste authentique ? (signature msig vérifiée avec la clé publique embarquée).
function Test-ManifestSignature {
    param($Manifest, [string]$PublicKeyXml)
    if (-not $Manifest -or -not $PublicKeyXml -or -not $Manifest.MSig -or -not $Manifest.Sha256) { return $false }
    try {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider((New-Object System.Security.Cryptography.CspParameters 24))
        try {
            $rsa.FromXmlString($PublicKeyXml)
            $txt = Get-ManifestSignedText $Manifest.Version $Manifest.Sha256 $Manifest.Date $Manifest.Notes
            return $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes($txt), 'SHA256', [Convert]::FromBase64String($Manifest.MSig))
        } finally { $rsa.Dispose() }
    } catch { return $false }
}

# Texte signé par l'éditeur pour une version : lie la version ET le contenu exact du zip
# (on ne peut ni rejouer l'ancienne signature d'une autre version, ni changer le zip).
function Get-ReleaseSignedText {
    param([string]$Version, [string]$Sha256)
    return "Arrivee-Collab|$Version|$($Sha256.ToUpperInvariant())"
}

# Signature RSA 3072 / SHA-256 (base64) vérifiée avec la clé PUBLIQUE embarquée
# (Config.ReleasePublicKey, XML). La clé privée ne quitte jamais le poste de l'éditeur
# (build-zip.ps1, chiffrée DPAPI). Fonction pure : $false au moindre doute.
function Test-ReleaseSignature {
    param([string]$PublicKeyXml, [string]$Version, [string]$Sha256, [string]$Sig)
    if (-not $PublicKeyXml -or -not $Version -or -not $Sha256 -or -not $Sig) { return $false }
    try {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider((New-Object System.Security.Cryptography.CspParameters 24))
        try {
            $rsa.FromXmlString($PublicKeyXml)
            return $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes((Get-ReleaseSignedText $Version $Sha256)), 'SHA256', [Convert]::FromBase64String($Sig))
        } finally { $rsa.Dispose() }
    } catch { return $false }
}

# Contrôle d'un zip téléchargé AVANT installation : empreinte SHA-256 identique à celle
# du manifeste ET signature de l'éditeur valide. Renvoie $null si OK, sinon le motif.
function Test-ReleasePackage {
    param([string]$ZipPath, $Manifest, [string]$PublicKeyXml)
    if (-not (Test-Path -LiteralPath $ZipPath)) { return 'zip introuvable' }
    if (-not $PublicKeyXml) { return 'clé publique de vérification absente de la configuration' }
    $sha = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if (-not $Manifest.Sha256 -or $sha -ne $Manifest.Sha256) { return "empreinte SHA-256 invalide (attendu '$($Manifest.Sha256)', obtenu $sha)" }
    if (-not (Test-ReleaseSignature $PublicKeyXml $Manifest.Version $sha $Manifest.Sig)) { return 'signature de l''éditeur absente ou invalide' }
    return $null
}

# URL du latest.json joint à la DERNIÈRE release GitHub (créée par build-zip.ps1) :
# disponible DÈS la publication, contrairement au fichier du dépôt servi par le CDN
# raw (~5 min de cache, le paramètre anti-cache n'y change rien). Même canal que
# le widget Biblio-Tech. $null si aucun dépôt configuré.
function Get-UpdateReleaseManifestUrl {
    param($Ctx)
    $repo = [string]$Ctx.Config.UpdateRepo
    if (-not $repo) { return $null }
    return ('https://github.com/{0}/releases/latest/download/latest.json?t={1}' -f $repo, [DateTime]::UtcNow.Ticks)
}

# Lit latest.json -> @{ Version; Zip; Notes; Source ('release'|'github'|'dossier') } ou $null.
# Ordre : release GitHub (immédiat) -> fichier du dépôt (raw, ~5 min de cache) ->
# dossier de distribution.
function Get-LatestManifest {
    param($Ctx)
    $relUrl = Get-UpdateReleaseManifestUrl $Ctx
    if ($relUrl) {
        try {
            $m = ConvertFrom-LatestJson ([string](Invoke-UpdateDownload -Uri $relUrl))
            if ($m) { $m.Source = 'release'; return $m }
        } catch {
            if (-not $script:UpdateReleaseFailLogged) {
                $script:UpdateReleaseFailLogged = $true
                Write-AppLog "[MAJ] latest.json de la release illisible ($($_.Exception.Message)) : repli sur le dépôt."
            }
        }
    }
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
    try { $m = Get-LatestManifest $Ctx } catch { $m = $null; Write-AppLog "[MAJ] Vérification KO : $($_.Exception.Message)" }
    Complete-UpdateCheck $Ctx $m
}

# Applique le résultat d'un contrôle (manifeste ou $null) : UpdateAvailable + pastille.
function Complete-UpdateCheck {
    param($Ctx, $m)
    try {
        # Manifeste non authentifié (clé publique présente) : ignoré, aucune pastille,
        # aucune note affichée. Évite les fausses annonces / notes et le blocage par
        # une version « 999 » inexistante.
        $pub = [string]$Ctx.Config.ReleasePublicKey
        if ($m -and $pub -and -not (Test-ManifestSignature $m $pub)) {
            if ($script:ManifesteRefuseVersion -ne $m.Version) {
                $script:ManifesteRefuseVersion = $m.Version
                Write-AppLog "[MAJ] Manifeste $($m.Version) (source $($m.Source)) NON AUTHENTIFIÉ : ignoré."
            }
            $m = $null
        }
        if ($m -and (Compare-AppVersion $m.Version $Ctx.Config.Version) -gt 0) {
            $zipOk = $true
            if ($m.Source -notin @('release', 'github')) {
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

# Contrôle périodique NON BLOQUANT : les requêtes réseau (jusqu'à 3 sources, proxy
# lent…) tournent dans un runspace, l'interface ne gèle jamais. Le résultat est relevé
# par un timer WinForms (thread UI) puis appliqué par Complete-UpdateCheck.
function Start-UpdateCheckAsync {
    param($Ctx)
    if ($global:UpdateCheckJob) { return }   # contrôle déjà en cours
    $lib = Join-Path $Ctx.AppRoot 'lib'
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
        param($LibDir, $Config, $DataDir, $AppRoot)
        . (Join-Path $LibDir 'Common.ps1')
        . (Join-Path $LibDir 'Update.ps1')
        $c = @{ Config = $Config; DataDir = $DataDir; AppRoot = $AppRoot }
        try { return @{ Ok = $true; Manifest = (Get-LatestManifest $c) } }
        catch { return @{ Ok = $false; Error = $_.Exception.Message } }
    }.ToString()).AddArgument($lib).AddArgument($Ctx.Config).AddArgument($Ctx.DataDir).AddArgument($Ctx.AppRoot)
    $global:UpdateCheckJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = Get-Date }
    $t = New-Object Windows.Forms.Timer
    $t.Interval = 500
    $t.Add_Tick({
        $j = $global:UpdateCheckJob
        if (-not $j) { $this.Stop(); $this.Dispose(); return }
        if (-not $j.Handle.IsCompleted) {
            if (((Get-Date) - $j.Started).TotalSeconds -lt 120) { return }
            try { $j.PS.Stop() } catch { }
            Write-AppLog '[MAJ] Vérification abandonnée (délai dépassé).'
            $r = $null
        } else {
            $r = $null
            try { foreach ($o in $j.PS.EndInvoke($j.Handle)) { if ($o -is [hashtable]) { $r = $o } } } catch { Write-AppLog "[MAJ] Vérification KO : $($_.Exception.Message)" }
        }
        try { $j.PS.Dispose() } catch { }
        $global:UpdateCheckJob = $null
        $this.Stop(); $this.Dispose()
        if ($r -and -not $r.Ok) { Write-AppLog "[MAJ] Vérification KO : $($r.Error)" }
        $m = if ($r -and $r.Ok) { $r.Manifest } else { $null }
        # Échec réseau : on garde l'état connu (pas de pastille qui clignote).
        if ($null -eq $m -and -not ($r -and $r.Ok)) { return }
        Complete-UpdateCheck $global:Ctx $m
    })
    $t.Start()
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

        if ($m.Source -in @('release', 'github')) {
            # Canal GitHub : zip joint à la release v<X> (en ligne dès la publication),
            # repli sur le zip versionné du dépôt (raw).
            $base = Get-UpdateRawBase $Ctx
            if (-not $base) { Write-AppLog "[MAJ] Dépôt GitHub non configuré."; return }
            $urls = @(
                ('https://github.com/{0}/releases/download/v{1}/{2}' -f $Ctx.Config.UpdateRepo, $m.Version, $m.Zip),
                "$base/$($m.Zip)"
            )
            $ok = $false
            foreach ($u in $urls) {
                try {
                    [void](Invoke-UpdateDownload -Uri $u -OutFile $localZip)
                    Write-AppLog ("[MAJ] Zip {0} téléchargé : {1}" -f $m.Zip, $u)
                    $ok = $true; break
                } catch { Write-AppLog "[MAJ] Téléchargement KO ($u) : $($_.Exception.Message)" }
            }
            if (-not $ok) { return }
        } else {
            # Repli : copie depuis le dossier de distribution.
            $dir = Get-UpdateDir $Ctx
            if (-not $dir) { Write-AppLog "[MAJ] Dossier de distribution indisponible."; return }
            $srcZip = Join-Path $dir $m.Zip
            if (-not (Test-Path -LiteralPath $srcZip)) { Write-AppLog "[MAJ] Zip source introuvable : $srcZip"; return }
            Copy-Item -LiteralPath $srcZip -Destination $localZip -Force
        }

        # Intégrité + authenticité (normes cyber / DSI) : rien n'est installé si le zip
        # n'est pas exactement celui signé par l'éditeur.
        $refus = Test-ReleasePackage $localZip $m ([string]$Ctx.Config.ReleasePublicKey)
        if ($refus) {
            Write-AppLog "[MAJ] Mise à jour $($m.Version) REFUSÉE : $refus."
            Remove-Item -LiteralPath $localZip -Force -ErrorAction SilentlyContinue
            try { Show-AlertDialog -message "La mise à jour $($m.Version) a été refusée car le paquet téléchargé n'a pas pu être authentifié ($refus).`n`nAucune modification n'a été faite. Réessayez plus tard ou prévenez le responsable de l'outil." -title "Mise à jour refusée" } catch { }
            return
        }
        Write-AppLog "[MAJ] Paquet $($m.Version) vérifié (SHA-256 + signature)."

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
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $Launcher + '"') -WorkingDirectory $AppRoot
    L "Application relancee apres mise a jour."
} catch { L ("ECHEC updater : " + $_.Exception.Message) }
'@
        [System.IO.File]::WriteAllText($updaterPs, $updaterBody, (New-Object System.Text.UTF8Encoding $false))

        $argLine = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -AppPid {1} -Zip "{2}" -AppRoot "{3}" -Launcher "{4}" -LogPath "{5}"' -f `
            $updaterPs, $PID, $localZip, $appRoot, $launcher, $logPath
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $argLine -WindowStyle Hidden | Out-Null
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
