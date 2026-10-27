# ============================================================================
#  Lanceur "toujours la dernière version" de l'outil Arrivee Collaborateur.
#  Embarqué TEL QUEL dans « Arrivee Collab.cmd » (FICHIER UNIQUE généré par
#  build-zip.ps1, comme Biblio-Tech.cmd) : seul le .cmd est à distribuer.
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
# Clé PUBLIQUE de l'éditeur (inscrite par build-zip.ps1 -NewSigningKey, identique à
# config.ps1) : aucun zip n'est installé sans empreinte SHA-256 + signature valides.
# Version minimale installable (première version avec l'ensemble des protections).
$MinVersion = '1.13.0'
$ReleasePublicKey = '<RSAKeyValue><Modulus>raIRN/8SJiSaul7c49MAezHpVdn+NqrVeiWVGITIrSYg8vnPJV6OUndLedwPAq8+JnsVJdzeublKQJ4gpsW7slTiBYMgHoP36anKfQVi5HvH3NxFIG0nEYUuXTwBI69ffiM6PnmgRWM4D0JaoKDy45PugMg48YQ7av2yfjzZrBAKHEUL3kYEomblDASWhHYqHFM/o1wt7y0qzHZ60cTgNJXTwLD0u50Hv/VRjorFbkm/AmgOfkG/wDFisdt2AiQDVD9y5XeGoKemdG4LVTs/CRDxyHVwGoWSMoIeR9AHYD4FQAuK4IG9as/LmbTqsOeBDxK1kXYaPoBmwhX7vt+j91U4EHXDf90s8yzfurWrP8Uaw3BDUJeFIiyTmcIj/9fQr5T7fMgsfm8p9Hz1mBXJXouHOxBJrYF5pFoLeOF8Sye9Sj6yAnWsIRYF0XkD0R4JwT+1txdtpO3SLdZwLy/pj40r5zUxAbf1yNfkYUSANfJHRgXxHUc5YwBTkxazJQCh</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
# Dossier du lanceur : embarqué dans « Arrivee Collab.cmd » (fichier unique), $PSScriptRoot
# est vide -> dossier du .cmd (AC_SELF, posé par son en-tête).
$dist    = if ($PSScriptRoot) { $PSScriptRoot } elseif ($env:AC_SELF) { Split-Path -Parent $env:AC_SELF } else { $env:TEMP }
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

    # Version cible (latest.json) : release GitHub (immédiate), puis fichier du dépôt
    # (raw, ~5 min de cache CDN), puis fichier posé à côté de ce script.
    $targetVer = $null; $zipName = $null; $srcMode = $null; $j = $null   # 'github' | 'dossier'
    foreach ($u in @("https://github.com/$Repo/releases/latest/download/latest.json?t=$([DateTime]::UtcNow.Ticks)",
                     "$rawBase/latest.json?nocache=$([DateTime]::UtcNow.Ticks)")) {
        try {
            $wc = New-BootWebClient
            try { $raw = $wc.DownloadString($u) } finally { $wc.Dispose() }
            $j = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
            $srcMode = 'github'
            L "latest.json GitHub ($u) : version $($j.version)."
            break
        } catch { L "latest.json GitHub KO ($u) : $($_.Exception.Message)" }
    }
    if (-not $j) {
        $mf = Join-Path $dist 'latest.json'
        if (Test-Path -LiteralPath $mf) {
            try { $j = (Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json); $srcMode = 'dossier' } catch { L "latest.json illisible : $($_.Exception.Message)" }
        }
    }
    # Version au format strict et au moins égale au minimum accepté (pas de première
    # installation d'une ancienne version signée) ; nom du zip RECONSTRUIT (jamais repris
    # du manifeste).
    if ($j -and ([string]$j.version) -match '^\d{1,4}(\.\d{1,4}){1,3}$') {
        if ([version]([string]$j.version) -ge [version]$MinVersion) {
            $targetVer = [string]$j.version
            $zipName = "Arrivee-Collab_version$targetVer.zip"
        } else { L "latest.json : version $($j.version) inférieure au minimum accepté ($MinVersion) : ignorée." }
    } elseif ($j) { L "latest.json : version invalide « $($j.version) »." }

    # Empreinte SHA-256 + signature RSA de l'éditeur sur « Arrivee-Collab|<version>|<SHA> ».
    function Test-BootPackage([string]$ZipPath) {
        if (-not $ReleasePublicKey) { return 'clé publique absente du lanceur' }
        $sha = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToUpperInvariant()
        if (-not $j.sha256 -or $sha -ne ([string]$j.sha256).ToUpperInvariant()) { return "empreinte SHA-256 invalide (obtenu $sha)" }
        try {
            $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider((New-Object System.Security.Cryptography.CspParameters 24))
            $rsa.FromXmlString($ReleasePublicKey)
            if ($rsa.VerifyData([Text.Encoding]::UTF8.GetBytes("Arrivee-Collab|$targetVer|$sha"), 'SHA256', [Convert]::FromBase64String([string]$j.sig))) { return $null }
        } catch { }
        return 'signature de l''éditeur absente ou invalide'
    }

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
                foreach ($u in @("https://github.com/$Repo/releases/download/v$targetVer/$zipName", "$rawBase/$zipName")) {
                    try {
                        $wc = New-BootWebClient
                        try { $wc.DownloadFile($u, $dlZip) } finally { $wc.Dispose() }
                        $zip = $dlZip
                        L "Zip $zipName telecharge : $u"
                        break
                    } catch { L "Telechargement KO ($u) : $($_.Exception.Message)" }
                }
            }
            if (-not $zip) {
                $localSrc = Join-Path $dist $zipName
                if (Test-Path -LiteralPath $localSrc) { $zip = $localSrc } else { L "Zip introuvable : $localSrc" }
            }
            if ($zip) {
                $refus = Test-BootPackage $zip
                if ($refus) {
                    L "Installation REFUSEE ($zipName) : $refus."
                    if ($zip -ne (Join-Path $dist $zipName)) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
                    $zip = $null
                } else { L "Paquet $targetVer verifie (SHA-256 + signature)." }
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
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\wscript.exe') -ArgumentList ('"' + $vbs + '"') -WorkingDirectory $appDir
        L "Application lancee depuis $appDir."
    } else {
        L "Start-ArriveeCollab.vbs introuvable dans $appDir (aucune version installee ?)."
    }
} catch { L ("ECHEC bootstrap : " + $_.Exception.Message) }
