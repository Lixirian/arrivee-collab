# ============================================================================
#  Lanceur "toujours la dernière version" de l'outil Arrivee Collaborateur.
#  A chaque lancement :
#   1. lit latest.json -> version + zip attendus. CANAL PRINCIPAL : dépôt GitHub
#      PUBLIC (raw.githubusercontent.com, AUCUN jeton, via le proxy système).
#      REPLI : le fichier latest.json posé à côté de ce script (dossier OneDrive) ;
#   2. si la copie locale (%LOCALAPPDATA%\Arrivee-Collab\app) n'existe pas,
#      télécharge/copie le zip et l'extrait dedans (PREMIÈRE installation) ;
#   3. lance l'application locale (masquée via son .vbs).
#  Les MAJ suivantes passent par la PASTILLE in-app (qui interroge aussi GitHub).
#  Mémorise le chemin de distribution (dist_path.txt) pour la verif in-app (repli).
# ============================================================================
param([int]$WaitPid = 0)
$ErrorActionPreference = 'Stop'
$Repo    = 'Lixirian/arrivee-collab'   # dépôt GitHub public de distribution
$Branch  = 'main'
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

    # Client web : TLS 1.2 + proxy système avec identifiants par défaut (postes SNCF).
    $rawBase = "https://raw.githubusercontent.com/$Repo/$Branch"
    function New-BootWebClient {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'ArriveeCollab-Bootstrap'
        $wc.Headers['Cache-Control'] = 'no-cache'
        if ($wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
        return $wc
    }

    # Version cible (latest.json) : GITHUB d'abord, repli sur le fichier local.
    $targetVer = $null; $zipName = $null; $srcMode = $null   # 'github' | 'dossier'
    try {
        $wc = New-BootWebClient
        try { $raw = $wc.DownloadString("$rawBase/latest.json?nocache=$([DateTime]::UtcNow.Ticks)") } finally { $wc.Dispose() }
        $j = $raw | ConvertFrom-Json
        $targetVer = [string]$j.version; $zipName = [string]$j.zip; $srcMode = 'github'
        L "latest.json GitHub : version $targetVer."
    } catch { L "GitHub inaccessible ($($_.Exception.Message)) : repli sur le dossier local." }
    if (-not $targetVer) {
        $mf = Join-Path $dist 'latest.json'
        if (Test-Path -LiteralPath $mf) {
            try { $j = (Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json); $targetVer = [string]$j.version; $zipName = [string]$j.zip; $srcMode = 'dossier' } catch { L "latest.json illisible : $($_.Exception.Message)" }
        }
    }
    if (-not $zipName -and $targetVer) { $zipName = "Arrivee-Collab_version$targetVer.zip" }

    # PREMIÈRE INSTALLATION uniquement. Ensuite, les MAJ se font VIA LA PASTILLE in-app
    # (qui interroge aussi GitHub) : on ne force pas la MAJ au lancement, sinon la
    # pastille ne s'afficherait jamais.
    $localExists = Test-Path -LiteralPath (Join-Path $appDir 'Start-ArriveeCollab.vbs')
    if (-not $localExists) {
        if ($targetVer -and $zipName) {
            # Récupère le zip : téléchargement GitHub, ou copie depuis le dossier.
            $zip = $null
            if ($srcMode -eq 'github') {
                $dlZip = Join-Path $env:TEMP ('acboot_' + [guid]::NewGuid().ToString('N') + '.zip')
                try {
                    $wc = New-BootWebClient
                    try { $wc.DownloadFile("$rawBase/$zipName", $dlZip) } finally { $wc.Dispose() }
                    $zip = $dlZip
                    L "Zip $zipName telecharge depuis GitHub."
                } catch { L "Telechargement GitHub KO ($($_.Exception.Message)) : repli sur le dossier local." }
            }
            if (-not $zip) {
                $localSrc = Join-Path $dist $zipName
                if (Test-Path -LiteralPath $localSrc) { $zip = $localSrc } else { L "Zip introuvable : $localSrc" }
            }
            if ($zip) {
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
                    if ($zip -ne (Join-Path $dist $zipName)) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
                }
            }
        } else { L "latest.json introuvable (GitHub et dossier) : impossible d'installer la premiere version." }
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
