# ============================================================================
#  Lanceur "toujours la dernière version" de l'outil Arrivee Collaborateur.
#  A PLACER DANS LE DOSSIER DE DISTRIBUTION (OneDrive), a cote de latest.json et
#  des zips. A chaque lancement :
#   1. lit latest.json -> version + zip attendus ;
#   2. si la copie locale (%LOCALAPPDATA%\Arrivee-Collab\app) n'existe pas,
#      extrait le zip dedans (PREMIÈRE installation) ;
#   3. lance l'application locale (masquée via son .vbs).
#  Mémorise le chemin de distribution (dist_path.txt) pour la verif in-app (Plan B).
#  AUCUN jeton, AUCUNE API : simple lecture de fichiers (accès LECTURE SEULE OK).
# ============================================================================
param([int]$WaitPid = 0)
$ErrorActionPreference = 'Stop'
$dist    = $PSScriptRoot
$dataDir = Join-Path $env:LOCALAPPDATA 'Arrivee-Collab'
$appDir  = Join-Path $dataDir 'app'
$log     = Join-Path $dataDir 'bootstrap.log'
function L($m) { try { if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }; Add-Content -LiteralPath $log -Value ("{0} [LANCEUR] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch {} }
try {
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
    try { Set-Content -LiteralPath (Join-Path $dataDir 'dist_path.txt') -Value $dist -Encoding UTF8 -Force } catch {}

    # Relance après mise à jour in-app (Plan B) : attendre la fermeture de l'ancienne instance.
    if ($WaitPid -gt 0) { try { Wait-Process -Id $WaitPid -Timeout 90 -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Milliseconds 600 }

    # Version cible (latest.json).
    $targetVer = $null; $zipName = $null
    $mf = Join-Path $dist 'latest.json'
    if (Test-Path -LiteralPath $mf) {
        try { $j = (Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json); $targetVer = [string]$j.version; $zipName = [string]$j.zip } catch { L "latest.json illisible : $($_.Exception.Message)" }
    }
    if (-not $zipName -and $targetVer) { $zipName = "Arrivee-Collab_version$targetVer.zip" }

    # PREMIÈRE INSTALLATION uniquement. Ensuite, les MAJ se font VIA LA PASTILLE in-app
    # (Plan B) : on ne force pas la MAJ au lancement, sinon la pastille ne s'afficherait jamais.
    $localExists = Test-Path -LiteralPath (Join-Path $appDir 'Start-ArriveeCollab.vbs')
    if (-not $localExists) {
        if ($targetVer -and $zipName) {
            $zip = Join-Path $dist $zipName
            if (Test-Path -LiteralPath $zip) {
                L "Premiere installation : version $targetVer."
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
            } else { L "Zip introuvable : $zip" }
        } else { L "latest.json absent : impossible d'installer la premiere version." }
    }

    # Nettoyage du dossier de distribution : archive les zips PÉRIMÉS (best-effort ;
    # ne réussit que pour le mainteneur en accès ecriture, ignore pour les lecteurs seuls).
    if ($zipName) {
        try {
            $stale = @(Get-ChildItem -LiteralPath $dist -Filter 'Arrivee-Collab_version*.zip' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $zipName })
            if ($stale.Count -gt 0) {
                $archives = Join-Path $dist 'Archives'
                if (-not (Test-Path -LiteralPath $archives)) { New-Item -ItemType Directory -Path $archives -Force | Out-Null }
                foreach ($z in $stale) {
                    try {
                        $destZ = Join-Path $archives $z.Name
                        if (Test-Path -LiteralPath $destZ) { Remove-Item -LiteralPath $destZ -Force -ErrorAction SilentlyContinue }
                        Move-Item -LiteralPath $z.FullName -Destination $archives -Force
                        L "Zip perime archive : $($z.Name) -> Archives\"
                    } catch { L "Archivage $($z.Name) ignore (lecture seule ?) : $($_.Exception.Message)" }
                }
            }
        } catch { L "Nettoyage des zips perimes KO : $($_.Exception.Message)" }
    }

    # Lance l'application locale (masquée via son .vbs).
    $vbs = Join-Path $appDir 'Start-ArriveeCollab.vbs'
    if (Test-Path $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WorkingDirectory $appDir
        L "Application lancee depuis $appDir."
    } else {
        L "Start-ArriveeCollab.vbs introuvable dans $appDir (aucune version installee ?)."
    }
} catch { L ("ECHEC bootstrap : " + $_.Exception.Message) }
