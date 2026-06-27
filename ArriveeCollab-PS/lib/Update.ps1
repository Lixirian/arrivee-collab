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
            $dir = Get-UpdateDir $Ctx
            $zipPath = if ($dir) { Join-Path $dir $m.Zip } else { $null }
            if ($zipPath -and (Test-Path -LiteralPath $zipPath)) {
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
