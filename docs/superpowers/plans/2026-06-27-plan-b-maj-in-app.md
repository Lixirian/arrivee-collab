# Plan B — Mise à jour in-app — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter la mise à jour automatique in-app : l'application détecte une version plus récente dans le dossier OneDrive, affiche une pastille, et au clic présente les notes puis se met à jour et redémarre — plus un dialogue « Quoi de neuf » après chaque montée de version.

**Architecture:** Un module `lib/Update.ps1` porte la logique (résolution du dossier de distribution, lecture de `latest.json`, comparaison de versions, changelog hors-ligne via `releases.json`), les dialogues WinForms (réutilisant le style de `Show-AlertDialog`), et l'auto-update par updater détaché (calqué sur SNOW Widget). Le script principal gagne une pastille dans l'en-tête, un Timer de vérification, et l'appel « Quoi de neuf » au démarrage.

**Tech Stack:** PowerShell 5.x, Windows Forms, `System.IO.Compression` (Expand-Archive), `[GC]`/COM (déjà présents). Aucune API réseau : lecture de fichiers OneDrive uniquement.

**Périmètre :** Ce Plan B couvre §6.5 (MAJ in-app) et §6.6 (« Quoi de neuf ») du spec, plus la dette Minor du Plan A pertinente (D1, D2, D4, D5). Le **tutoriel dynamique** (§6.6 Tutorial, §7) fera l'objet d'un **Plan C** ultérieur.

## Global Constraints

- **Langue** : tout en français, accents corrects. Encodage : `.ps1` UTF-8 **avec BOM** (le contrôleur normalise après chaque tâche `.ps1`) ; `.json` UTF-8 ; `.vbs` ASCII.
- **Nommage** : fonctions d'infrastructure en verbe anglais standard (`Get-`, `Show-`, `Invoke-`, `Update-`, `Convert-`). Pas de redéfinition de `Compare-AppVersion` (déjà dans `lib/Common.ps1`) ni de `Write-AppLog`/`New-AppState`/`Save-AppState`.
- **Distribution** : aucune API, aucun jeton — lecture de fichiers dans le dossier OneDrive résolu via `Config.UpdateDir` (relatif sous OneDrive, absolu/UNC, ou repli `dist_path.txt`). Lecture seule suffit côté utilisateur.
- **Modèle d'exécution** : l'app tourne depuis `%LOCALAPPDATA%\Arrivee-Collab\app\` (= `$Ctx.AppRoot`). L'updater remplace ce dossier et relance via `Start-ArriveeCollab.vbs`.
- **`$Ctx`** (déjà construit en Plan A) : clés `Config`, `AppRoot`, `DataDir`, `WorkDir`, `State`, `UpdateAvailable`. Ce plan ajoute la clé `UpdateBadge` (le Label pastille).
- **Pas de framework de test** : unités pures testées dans `tests/Test-ArriveeCollab.ps1` (fonction `Assert` maison). Les dialogues GUI et le self-update sont validés manuellement (checkpoint contrôleur).
- **Cadence** : `Config.UpdateCheckIntervalSec` (défaut 300 s). Premier contrôle ~8 s après ouverture.
- **Git** : commits fréquents en français, sur une branche dédiée.

---

### Task 1 : `lib/Update.ps1` — logique de détection et changelog hors-ligne

**Files:**
- Create: `ArriveeCollab-PS/lib/Update.ps1`
- Modify: `tests/Test-ArriveeCollab.ps1`

**Interfaces:**
- Consumes: `Compare-AppVersion` (de `lib/Common.ps1`), `Write-AppLog` (idem), `$Ctx` (`Config`, `DataDir`, `AppRoot`, `UpdateAvailable`).
- Produces:
  - `Get-UpdateDir($Ctx) : string|$null` — dossier de distribution résolu, ou `$null`.
  - `Get-LatestManifest($Ctx) : hashtable|$null` — `@{ Version; Zip; Notes(@()) }` lu depuis `latest.json`, ou `$null`.
  - `Convert-VersionSortKey([string]$V) : string` — clé de tri numérique paddée.
  - `Get-LocalReleaseNotes($Ctx,[string]$Version) : string[]`
  - `Get-RecentReleaseNotes($Ctx,[int]$Max) : @(@{Version;Notes})`
  - `Get-ReleaseNotesBetween($Ctx,[string]$From,[string]$To,[int]$Cap) : @(@{Version;Notes})`
  - `Invoke-UpdateCheck($Ctx)` — pose `$Ctx.UpdateAvailable` (le manifeste si version plus récente ET zip présent, sinon `$null`) puis appelle `Update-UpdateBadge $Ctx` (best-effort).

- [ ] **Step 1: Écrire les tests qui échouent**

Dans `tests/Test-ArriveeCollab.ps1`, **avant** le bloc de bilan final (`Write-Host ""` … `if ($script:fail -eq 0)`), ajouter :

```powershell
# --- Update : manifeste, tri de versions, notes hors-ligne ---
. (Join-Path $lib 'Update.ps1')
$tmpRoot = Join-Path $env:TEMP ("ac_upd_test_" + [guid]::NewGuid().ToString('N'))
$dist = Join-Path $tmpRoot 'dist'; $app = Join-Path $tmpRoot 'app'
New-Item -ItemType Directory -Path $dist, $app -Force | Out-Null
try {
    # Contexte minimal simulé
    $ctx = @{ Config = @{ UpdateDir = $dist }; DataDir = $tmpRoot; AppRoot = $app; UpdateAvailable = $null }

    # latest.json + zip dans le dossier de distribution
    '{ "version": "1.2.0", "zip": "Arrivee-Collab_version1.2.0.zip", "notes": ["Note A", "Note B"] }' |
        Out-File -LiteralPath (Join-Path $dist 'latest.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dist 'Arrivee-Collab_version1.2.0.zip') -Value 'zip'

    $m = Get-LatestManifest $ctx
    Assert ($m.Version -eq '1.2.0')                 'update : manifeste version'
    Assert ($m.Zip -eq 'Arrivee-Collab_version1.2.0.zip') 'update : manifeste zip'
    Assert (@($m.Notes).Count -eq 2)                'update : manifeste 2 notes'

    # Tri numérique de versions
    Assert ((Convert-VersionSortKey '1.10.0') -gt (Convert-VersionSortKey '1.9.0')) 'update : tri 1.10 > 1.9'

    # releases.json EMBARQUE (dans AppRoot)
    '{ "1.0.0": ["Initiale"], "1.1.0": ["Ajout X"], "1.2.0": ["Note A", "Note B"] }' |
        Out-File -LiteralPath (Join-Path $app 'releases.json') -Encoding UTF8
    $rec = Get-RecentReleaseNotes $ctx 2
    Assert (@($rec).Count -eq 2 -and $rec[0].Version -eq '1.2.0') 'update : 2 versions recentes, plus recente en tete'
    $between = Get-ReleaseNotesBetween $ctx '1.0.0' '1.2.0' 25
    Assert (@($between).Count -eq 2 -and $between.Version -contains '1.1.0' -and $between.Version -contains '1.2.0') 'update : notes entre 1.0.0(exclu) et 1.2.0'
    Assert (-not ($between.Version -contains '1.0.0')) 'update : version de depart exclue'

    # Invoke-UpdateCheck : version distante 1.2.0 > courante 1.1.0 -> UpdateAvailable pose
    $ctx.Config.Version = '1.1.0'
    Invoke-UpdateCheck $ctx
    Assert ($null -ne $ctx.UpdateAvailable -and $ctx.UpdateAvailable.Version -eq '1.2.0') 'update : UpdateAvailable pose si plus recent'

    # Pas de MAJ si courante == distante
    $ctx.Config.Version = '1.2.0'
    Invoke-UpdateCheck $ctx
    Assert ($null -eq $ctx.UpdateAvailable) 'update : pas de MAJ si deja a jour'
} finally {
    if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
```

- [ ] **Step 2: Lancer le test pour vérifier qu'il échoue**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: ÉCHEC — « Update.ps1 introuvable » ou `Get-LatestManifest` non reconnu.

- [ ] **Step 3: Écrire `lib/Update.ps1`** (logique seulement — les dialogues viennent en Task 2)

```powershell
# ============================================================================
#  Mise à jour automatique depuis un dossier de DISTRIBUTION (OneDrive/SharePoint).
#  AUCUNE API, AUCUN jeton : on lit de simples FICHIERS (latest.json + zips).
#  Ce fichier = LOGIQUE de détection + changelog hors-ligne. Les DIALOGUES WinForms
#  et le self-update sont ajoutés plus bas (Task 2).
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

# Lit latest.json -> @{ Version; Zip; Notes(@()) } ou $null.
function Get-LatestManifest {
    param($Ctx)
    $dir = Get-UpdateDir $Ctx
    if (-not $dir) { return $null }
    $mf = Join-Path $dir 'latest.json'
    if (-not (Test-Path -LiteralPath $mf)) { return $null }
    try {
        $raw = Get-Content -LiteralPath $mf -Raw -Encoding UTF8
        if (-not $raw) { return $null }
        $j = $raw | ConvertFrom-Json
        if (-not $j.version) { return $null }
        $zip = [string]$j.zip
        if (-not $zip) { $zip = "Arrivee-Collab_version$([string]$j.version).zip" }
        $notes = @()
        if ($j.notes) { $notes = @($j.notes | ForEach-Object { [string]$_ }) }
        return @{ Version = [string]$j.version; Zip = $zip; Notes = $notes }
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

# Vérifie s'il existe une version plus récente ET dont le zip est présent ; met à jour
# $Ctx.UpdateAvailable + la pastille. Ne lève jamais (dossier hors ligne = silencieux).
function Invoke-UpdateCheck {
    param($Ctx)
    try {
        $m = Get-LatestManifest $Ctx
        if ($m -and (Compare-AppVersion $m.Version $Ctx.Config.Version) -gt 0) {
            $zipPath = Join-Path (Get-UpdateDir $Ctx) $m.Zip
            if (Test-Path -LiteralPath $zipPath) {
                if (-not $Ctx.UpdateAvailable -or $Ctx.UpdateAvailable.Version -ne $m.Version) {
                    Write-AppLog ("[MAJ] Nouvelle version disponible : {0} (actuelle {1})." -f $m.Version, $Ctx.Config.Version)
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
```

- [ ] **Step 4: Lancer le test pour vérifier qu'il passe**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: toutes les assertions PASS (les 14 existantes + les ~9 nouvelles), « TOUS LES TESTS PASSENT ».
Note : `Invoke-UpdateCheck` appelle `Update-UpdateBadge` qui n'existe pas encore — le `try/catch` l'absorbe, le test passe quand même.

- [ ] **Step 5: Commit**

```bash
git add "ArriveeCollab-PS/lib/Update.ps1" tests/Test-ArriveeCollab.ps1
git commit -m "feat: lib/Update.ps1 - detection MAJ + changelog hors-ligne + tests"
```

---

### Task 2 : `lib/Update.ps1` — dialogues WinForms, « Quoi de neuf » et self-update

**Files:**
- Modify: `ArriveeCollab-PS/lib/Update.ps1` (ajout en fin de fichier)

**Interfaces:**
- Consumes: les fonctions de Task 1, plus les variables de palette `$cBgMain`, `$cBgSecondary`, `$cSurface`, `$cBorder`, `$cAccentViolet`, `$cAccentVioletHover`, `$cTextPrimary`, `$cTextSecondary`, `$cWhite`, `$cWarning`, `$baseDir` (définies dans le script principal avant le sourcing — voir Task 3) et `Compare-AppVersion`, `Save-AppState`.
- Produces:
  - `Show-NotesDialog([string]$Title,[string]$Headline,[string]$Sub,$Groups,[string]$PrimaryText,[bool]$ShowSecondary) : bool` — dialogue dark theme listant des notes groupées par version ; renvoie `$true` si le bouton primaire a été cliqué.
  - `Show-UpdateDialog($Ctx) : bool` — propose la MAJ (notes des 3 dernières versions) ; `$true` si l'utilisateur confirme.
  - `Show-WhatsNewIfUpgraded($Ctx,[string]$PreviousVersion)` — au démarrage après une vraie montée, affiche les notes de toutes les versions franchies (anti-doublon `NotesShownVersion`).
  - `Invoke-SelfUpdate($Ctx)` — copie le zip en local, écrit un updater détaché, ferme l'app.
  - `Invoke-PromptAndUpdate($Ctx)` — re-lit `latest.json`, affiche `Show-UpdateDialog`, lance `Invoke-SelfUpdate` si confirmé.

- [ ] **Step 1: Ajouter le code des dialogues et du self-update à la fin de `lib/Update.ps1`**

```powershell
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
        $dir = Get-UpdateDir $Ctx
        if (-not $dir) { Write-AppLog "[MAJ] Dossier de distribution indisponible."; return }
        $srcZip = Join-Path $dir $m.Zip
        if (-not (Test-Path -LiteralPath $srcZip)) { Write-AppLog "[MAJ] Zip source introuvable : $srcZip"; return }

        $upDir = Join-Path $Ctx.DataDir 'update'
        if (-not (Test-Path -LiteralPath $upDir)) { New-Item -ItemType Directory -Path $upDir -Force | Out-Null }
        $localZip = Join-Path $upDir ("new_$($m.Version).zip")
        Copy-Item -LiteralPath $srcZip -Destination $localZip -Force

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
```

- [ ] **Step 2: Vérifier la syntaxe**

Run: `powershell -NoProfile -Command "$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'ArriveeCollab-PS/lib/Update.ps1'),[ref]$t,[ref]$e); if($e -and $e.Count){$e|ForEach-Object{$_.Message}; exit 1} else {'SYNTAXE OK'}"`
Expected: `SYNTAXE OK`.

- [ ] **Step 3: Vérifier que la suite de tests passe toujours**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: « TOUS LES TESTS PASSENT » (les dialogues ne sont pas testés automatiquement, mais le sourcing du fichier ne doit rien casser).

- [ ] **Step 4: Commit**

```bash
git add "ArriveeCollab-PS/lib/Update.ps1"
git commit -m "feat: Update.ps1 - dialogues WinForms, Quoi de neuf, self-update"
```

---

### Task 3 : Intégration — pastille de MAJ, sourcing, « Quoi de neuf » et Timer de vérification

**Files:**
- Modify: `ArriveeCollab-PS/arrivee collab.ps1`

**Interfaces:**
- Consumes: tout `lib/Update.ps1` ; `$global:Ctx`, `$global:PrevStateVersion` (déjà posés en Plan A).
- Produces: `Update-UpdateBadge($Ctx)` (montre/cache la pastille selon `$Ctx.UpdateAvailable`) ; clé `$Ctx.UpdateBadge` ; pastille `$lblUpdateBadge` dans l'en-tête.

- [ ] **Step 1: Sourcer `lib/Update.ps1`** — après la ligne `. (Join-Path $baseDir 'lib\State.ps1')`, ajouter :

```powershell
. (Join-Path $baseDir 'lib\Update.ps1')
```

- [ ] **Step 2: Ajouter la pastille de MAJ dans l'en-tête** — juste après le bloc `$form.Controls.Add($lblSubTitle)` (vers ligne 654), insérer :

```powershell
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

# Repositionne la pastille en haut à droite quel que soit son texte (largeur auto).
function Update-UpdateBadge {
    param($Ctx)
    $b = $Ctx.UpdateBadge
    if (-not $b) { return }
    $action = {
        if ($Ctx.UpdateAvailable) {
            $b.Text = "  ⬆ Mise à jour $($Ctx.UpdateAvailable.Version)  "
            $b.Left = $form.ClientSize.Width - $b.Width - 25
            $b.Visible = $true; $b.BringToFront()
        } else { $b.Visible = $false }
    }
    if ($form.InvokeRequired) { $form.Invoke([Action]$action) } else { & $action }
}
```

- [ ] **Step 3: Brancher le démarrage** — juste AVANT la ligne finale `[void]$form.ShowDialog()`, insérer :

```powershell
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
})
```

- [ ] **Step 4: Vérifier la syntaxe**

Run: `powershell -NoProfile -Command "$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'ArriveeCollab-PS/arrivee collab.ps1'),[ref]$t,[ref]$e); if($e -and $e.Count){$e|ForEach-Object{$_.Message}; exit 1} else {'SYNTAXE OK'}"`
Expected: `SYNTAXE OK`.

- [ ] **Step 5: Vérification manuelle reportée**

La pastille et le « Quoi de neuf » seront validés au checkpoint contrôleur (Task 5), avec un vrai dossier de distribution simulé. Ne pas lancer la GUI ici.

- [ ] **Step 6: Commit**

```bash
git add "ArriveeCollab-PS/arrivee collab.ps1"
git commit -m "feat: pastille de MAJ + Quoi de neuf au demarrage + timer de verification"
```

---

### Task 4 : Dette Minor du Plan A (D1 log bootstrap, D2 build-zip, D4/D5 bootstrap)

**Files:**
- Modify: `dist-launcher/bootstrap.ps1`
- Modify: `build-zip.ps1`

**Interfaces:**
- Produces: aucun nouveau symbole — corrections de robustesse.

- [ ] **Step 1: D1 — log du bootstrap séparé** — dans `dist-launcher/bootstrap.ps1`, remplacer la ligne définissant `$log` :

```powershell
$log     = Join-Path $dataDir 'app_debug.log'
```

par :

```powershell
$log     = Join-Path $dataDir 'bootstrap.log'
```

(Le bootstrap écrit désormais dans son propre journal ; `Initialize-AppLog` de l'app ne tronquera plus les traces d'installation.)

- [ ] **Step 2: D4 — `-LiteralPath` sur `Test-Path` dans le bootstrap** — dans `dist-launcher/bootstrap.ps1`, remplacer les deux occurrences `if (Test-Path $mf)` et `if (Test-Path $zip)` par `if (Test-Path -LiteralPath $mf)` et `if (Test-Path -LiteralPath $zip)`.

- [ ] **Step 3: D5 — `finally` pour le dossier temp d'extraction** — dans `dist-launcher/bootstrap.ps1`, le bloc de première installation :

```powershell
                $tmp = Join-Path $env:TEMP ('acboot_' + [guid]::NewGuid().ToString('N'))
                Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
                $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
                $srcContent = if ($inner) { $inner.FullName } else { $tmp }
                if (-not (Test-Path $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null }
                Copy-Item -Path (Join-Path $srcContent '*') -Destination $appDir -Recurse -Force
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
                L "Version $targetVer installee dans $appDir."
```

devient :

```powershell
                $tmp = Join-Path $env:TEMP ('acboot_' + [guid]::NewGuid().ToString('N'))
                try {
                    Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
                    $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
                    $srcContent = if ($inner) { $inner.FullName } else { $tmp }
                    if (-not (Test-Path -LiteralPath $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null }
                    Copy-Item -Path (Join-Path $srcContent '*') -Destination $appDir -Recurse -Force
                    L "Version $targetVer installee dans $appDir."
                } finally {
                    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
                }
```

- [ ] **Step 4: D2 — `build-zip.ps1` ne pousse que les artefacts voulus** — dans `build-zip.ps1`, dans le bloc git, remplacer `& git add -A 2>$null | Out-Null` par un staging explicite :

```powershell
            & git add latest.json "Arrivee-Collab_version$ver.zip" .dist-launcher-history.json 2>$null | Out-Null
            & git add -u 2>$null | Out-Null
```

(`-u` stage les modifications des fichiers DÉJÀ suivis — code source, doc — sans aspirer de nouveaux fichiers non liés. Les artefacts ignorés restent exclus par `.gitignore`.)

- [ ] **Step 5: Vérifier la syntaxe des deux fichiers**

Run: `powershell -NoProfile -Command "foreach($f in 'dist-launcher/bootstrap.ps1','build-zip.ps1'){$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $f),[ref]$t,[ref]$e); if($e -and $e.Count){\"$f : ERREUR\"; $e|ForEach-Object{$_.Message}; exit 1}}; 'SYNTAXE OK'"`
Expected: `SYNTAXE OK`.

- [ ] **Step 6: Commit**

```bash
git add "dist-launcher/bootstrap.ps1" build-zip.ps1
git commit -m "fix: dette Plan A - log bootstrap separe, -LiteralPath, finally extraction, staging build explicite"
```

---

### Task 5 : Publication 1.1.0 + checkpoint MAJ bout-en-bout + CLAUDE.md

**Files:**
- Modify: `ArriveeCollab-PS/config.ps1`, `ArriveeCollab-PS/releases.json`, `CLAUDE.md`

**Interfaces:**
- Produces: version 1.1.0 publiable, doc à jour.

- [ ] **Step 1: Bump version** — dans `ArriveeCollab-PS/config.ps1`, remplacer `Version                = '1.0.0'` par `Version                = '1.1.0'`.

- [ ] **Step 2: Ajouter la note de version** — dans `ArriveeCollab-PS/releases.json`, ajouter l'entrée `1.1.0` (avant `1.0.0`) :

```json
{
    "1.1.0": [
        "Mise à jour automatique : une pastille signale les nouvelles versions ; un clic présente les nouveautés puis installe la mise à jour et redémarre l'application.",
        "Dialogue « Quoi de neuf » affiché après chaque mise à jour."
    ],
    "1.0.0": [
        "Première version distribuée : versionning, mise à jour automatique depuis OneDrive et tutoriel interactif."
    ]
}
```

- [ ] **Step 3: Mettre à jour `CLAUDE.md`** — dans la section **Lancement utilisateur final**, remplacer la mention « Les mises à jour ultérieures seront gérées via une pastille in-app (Plan B, à venir). » par : « Les mises à jour ultérieures se font via la pastille in-app : l'app vérifie périodiquement le dossier de distribution et propose d'installer la nouvelle version. » Dans la section **Modèle d'exécution**, retirer la mention « (Plan B) » de la ligne `app\`. Ajouter une ligne au tableau des modules : `lib/Update.ps1 — détection MAJ, pastille, dialogues, self-update, Quoi de neuf`.

- [ ] **Step 4: Normaliser l'encodage (contrôleur)** — *cette étape est réalisée par le contrôleur après l'implémentation* : `config.ps1` reste UTF-8 BOM, `releases.json` UTF-8 sans BOM.

- [ ] **Step 5: Commit**

```bash
git add "ArriveeCollab-PS/config.ps1" "ArriveeCollab-PS/releases.json" CLAUDE.md
git commit -m "feat: publication 1.1.0 (MAJ in-app) + notes de version + CLAUDE.md"
```

- [ ] **Step 6: Checkpoint contrôleur — MAJ bout-en-bout**

*Réalisé par le contrôleur* : installer la 1.0.0 (kit dist-ready du Plan A) dans un OneDrive simulé, lancer l'app ; builder la 1.1.0 et copier zip + latest.json dans le OneDrive simulé ; vérifier que la pastille apparaît dans l'app (≤ interval), que le clic affiche les notes, que la MAJ s'installe et relance en 1.1.0, et que « Quoi de neuf » s'affiche au redémarrage.

---

## Self-Review

**Spec coverage (Plan B scope) :**
- §6.5 `Get-UpdateDir`/`Get-LatestManifest`/`Invoke-UpdateCheck` → Task 1. ✅
- §6.5 `Show-UpdateDialog`/`Invoke-SelfUpdate`/`Invoke-PromptAndUpdate` (updater détaché, relance) → Task 2. ✅
- §6.5 pastille + Timer (8 s puis interval) → Task 3. ✅
- §6.6 `Show-WhatsNewIfUpgraded` + helpers changelog (`Get-LocalReleaseNotes`/`Get-RecentReleaseNotes`/`Get-ReleaseNotesBetween`) → Tasks 1, 2, 3. ✅
- §8 intégration (sourcing, branchement démarrage) → Task 3. ✅
- Dette Plan A D1/D2/D4/D5 → Task 4. ✅
- **Hors Plan B (→ Plan C)** : §6.6 `lib/Tutorial.ps1`, §7 étapes du tutoriel, intégration bouton « ? ». Volontairement reporté.

**Placeholder scan :** aucun TBD/TODO ; tout le code est fourni (logique + dialogues WinForms + updater). Les modifications du script principal montrent les blocs exacts et leur point d'insertion.

**Type consistency :** `Get-UpdateDir`/`Get-LatestManifest`/`Invoke-UpdateCheck` (Task 1) ↔ consommés par `Show-UpdateDialog`/`Invoke-SelfUpdate`/`Invoke-PromptAndUpdate` (Task 2) et la pastille (Task 3). `Update-UpdateBadge` appelé par `Invoke-UpdateCheck` (Task 1) ↔ défini en Task 3 (résolu à l'exécution ; `try/catch` couvre les tests de Task 1). `$Ctx.UpdateBadge`/`$Ctx.UpdateAvailable` cohérents. `Compare-AppVersion` (Common.ps1, Plan A) réutilisé, non redéfini. Noms `Arrivee-Collab_version<X>.zip` et `Start-ArriveeCollab.vbs` cohérents avec le Plan A.

---

## Plan C (à détailler après exécution du Plan B)

Tutoriel dynamique : `lib/Tutorial.ps1` (moteur data-driven versionné + rendu WinForms carte + surbrillance du contrôle ciblé), les 10 étapes du spec §7, et l'intégration (bouton « ? » dans l'en-tête + `Show-TutorialIfFirstRun` au démarrage différé). Rédigé après le Plan B, car il réutilise les patterns de dialogue et d'ancrage UI validés ici.
