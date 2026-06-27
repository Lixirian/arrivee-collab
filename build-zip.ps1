# ============================================================================
#  Génère le zip de distribution de l'outil Arrivée Collaborateur.
#  - Lit la version dans ArriveeCollab-PS\config.ps1 ($Config.Version).
#  - Produit  Arrivee-Collab_version<X>.zip  à la racine (dossier racine interne = même nom).
#  - Génère latest.json (version + zip + notes depuis releases.json).
#  - Archive les anciennes versions dans Archives\.
#  - Assemble dist-ready\ (lanceur + zip + latest.json) + zips d'export.
#  - En fin : COMMIT + PUSH automatique sur origin (best-effort ; -NoGit pour s'en passer).
#  Usage :  powershell -ExecutionPolicy Bypass -File build-zip.ps1 [-NoGit]
# ============================================================================
param([switch]$NoGit)
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$src  = Join-Path $repo 'ArriveeCollab-PS'

$cfg = Get-Content -LiteralPath (Join-Path $src 'config.ps1') -Raw
$m = [regex]::Match($cfg, "Version\s*=\s*'([^']+)'")
if (-not $m.Success) { throw "Version introuvable dans config.ps1 (attendu : Version = '<x>')." }
$ver = $m.Groups[1].Value
$name = "Arrivee-Collab_version$ver"

# Staging : copie temporaire renommée pour que le dossier racine du zip = $name.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) $name
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
Copy-Item -LiteralPath $src -Destination $staging -Recurse

$zip = Join-Path $repo "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $staging -DestinationPath $zip -CompressionLevel Optimal
Remove-Item -LiteralPath $staging -Recurse -Force

# latest.json : version + zip + notes de la version courante (depuis releases.json EMBARQUÉ).
$notes = @()
$relFile = Join-Path $src 'releases.json'
if (Test-Path -LiteralPath $relFile) {
    try {
        $rel = Get-Content -LiteralPath $relFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($rel.PSObject.Properties.Name -contains $ver) { $notes = @($rel.$ver) }
    } catch { Write-Host "Avertissement : releases.json illisible ($($_.Exception.Message))" }
}
$manifest = [ordered]@{ version = $ver; zip = "$name.zip"; notes = $notes }
($manifest | ConvertTo-Json -Depth 5) | Out-File -LiteralPath (Join-Path $repo 'latest.json') -Encoding UTF8 -Force

# Archive les anciennes versions : tout Arrivee-Collab_version*.zip SAUF la courante.
$arch = Join-Path $repo 'Archives'
if (-not (Test-Path -LiteralPath $arch)) { New-Item -ItemType Directory -Path $arch -Force | Out-Null }
$moved = @()
Get-ChildItem -LiteralPath $repo -Filter 'Arrivee-Collab_version*.zip' |
    Where-Object { $_.Name -ne "$name.zip" } |
    ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination $arch -Force; $moved += $_.Name }

# Assemble dist-ready\ : lanceur + zip courant + latest.json.
$ready = Join-Path $repo 'dist-ready'
if (-not (Test-Path -LiteralPath $ready)) { New-Item -ItemType Directory -Path $ready -Force | Out-Null }
Get-ChildItem -LiteralPath $ready -Filter 'Arrivee-Collab_version*.zip' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "$name.zip" } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
Copy-Item -Path (Join-Path $repo 'dist-launcher\*') -Destination $ready -Recurse -Force
Copy-Item -LiteralPath $zip -Destination $ready -Force
Copy-Item -LiteralPath (Join-Path $repo 'latest.json') -Destination $ready -Force

# Zip d'export du kit COMPLET (1er déploiement). Contenu à la racine du zip.
$exportZip = Join-Path $repo 'Arrivee-Collab-dist-ready.zip'
if (Test-Path -LiteralPath $exportZip) { Remove-Item -LiteralPath $exportZip -Force }
Compress-Archive -Path (Join-Path $ready '*') -DestinationPath $exportZip -CompressionLevel Optimal

# Bundle de MISE À JOUR : minimal (zip + latest.json) si le lanceur n'a pas changé
# depuis la version précédente, complet (lanceur + zip + latest.json) sinon.
$launcherSig = ((Get-ChildItem -LiteralPath (Join-Path $repo 'dist-launcher') -File | Sort-Object Name |
    ForEach-Object { "$($_.Name)=$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join '|')
$histFile = Join-Path $repo '.dist-launcher-history.json'
$hist = @{}
if (Test-Path -LiteralPath $histFile) {
    try { (Get-Content -LiteralPath $histFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $hist[$_.Name] = [string]$_.Value } } catch { }
}
$prevKey = @($hist.Keys | Where-Object { [version]$_ -lt [version]$ver } | Sort-Object { [version]$_ }) | Select-Object -Last 1
$prevSig = if ($prevKey) { $hist[$prevKey] } else { $null }
$launcherChanged = ($null -eq $prevSig) -or ($launcherSig -ne $prevSig)

Get-ChildItem -LiteralPath $repo -Filter 'Arrivee-Collab-maj-*.zip' -ErrorAction SilentlyContinue | Remove-Item -Force
$majZip = Join-Path $repo "Arrivee-Collab-maj-$ver.zip"
if ($launcherChanged) {
    Compress-Archive -Path (Join-Path $ready '*') -DestinationPath $majZip -CompressionLevel Optimal
    $majDesc = if ($prevKey) { "COMPLET (lanceur modifié depuis $prevKey)" } else { "COMPLET (1re référence du lanceur)" }
} else {
    Compress-Archive -Path $zip, (Join-Path $repo 'latest.json') -DestinationPath $majZip -CompressionLevel Optimal
    $majDesc = "minimal (zip + latest.json ; lanceur inchangé depuis $prevKey)"
}
$hist[$ver] = $launcherSig
($hist | ConvertTo-Json) | Out-File -LiteralPath $histFile -Encoding UTF8 -Force

$sizeMo = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 2)
Write-Host "OK : $name.zip ($sizeMo Mo) - dossier racine interne : $name/"
if ($moved.Count -gt 0) { Write-Host ("Archivées -> Archives\ : {0}" -f ($moved -join ', ')) }
Write-Host "dist-ready\ prêt à publier. Arrivee-Collab-dist-ready.zip (kit complet) régénéré."
Write-Host "Arrivee-Collab-maj-$ver.zip régénéré (bundle $majDesc)."

# ============================================================================
#  Publication Git : COMMIT + PUSH automatique vers origin (best-effort).
#  Un échec (hors ligne, rien à committer, pas de remote) n'échoue PAS le build.
#  Pas de '2>&1' sur git (PS 5.1 le transforme en erreur sous Stop) : 2>$null + $LASTEXITCODE.
# ============================================================================
if (-not $NoGit) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location $repo
        $null = (& git rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -eq 0) {
            & git add -A 2>$null | Out-Null
            & git diff --cached --quiet 2>$null
            if ($LASTEXITCODE -ne 0) {
                $msg = "Version $ver"
                if (@($notes).Count -gt 0) { $msg += "`n`n" + ((@($notes) | ForEach-Object { "- $_" }) -join "`n") }
                $tmpMsg = Join-Path ([System.IO.Path]::GetTempPath()) ("accommit_" + [guid]::NewGuid().ToString('N') + ".txt")
                [System.IO.File]::WriteAllText($tmpMsg, $msg, (New-Object System.Text.UTF8Encoding $false))
                & git commit -F $tmpMsg 2>$null | Out-Null
                $committed = ($LASTEXITCODE -eq 0)
                Remove-Item -LiteralPath $tmpMsg -Force -ErrorAction SilentlyContinue
                if ($committed) {
                    Write-Host "Git : commit 'Version $ver' créé."
                    $hasOrigin = ((& git remote 2>$null) -contains 'origin')
                    if ($hasOrigin) {
                        & git push origin HEAD 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) { Write-Host "Git : push vers origin OK." }
                        else { Write-Host "Git : PUSH KO (hors ligne ?). Commit local : refaire 'git push' plus tard." }
                    } else { Write-Host "Git : pas de remote 'origin' -> commit local seulement." }
                } else { Write-Host "Git : commit KO (voir 'git status')." }
            } else { Write-Host "Git : rien à committer." }
        } else { Write-Host "Git : pas un dépôt git -> étape ignorée." }
    } catch { Write-Host "Git : étape ignorée ($($_.Exception.Message))." }
    finally { Pop-Location; $ErrorActionPreference = $prevEAP }
} else { Write-Host "Git : -NoGit -> ni commit ni push." }
