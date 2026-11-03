@echo off
REM ============================================================
REM  Arrivee Collaborateur - UN SEUL FICHIER : double-cliquer.
REM  Installe la derniere version signee si besoin, cree les
REM  raccourcis puis lance l'application. Aucun .exe, aucun droit
REM  administrateur, aucun identifiant stocke.
REM  Options : /repair (reinstaller) ; /nostart (installer sans lancer)
REM  Fichier GENERE par build-zip.ps1 (dist-launcher\bootstrap.ps1).
REM ============================================================
setlocal
set "AC_SELF=%~f0"
set "ACARGS="
if /i "%~1"=="/repair" set "ACARGS=-Repair"
if /i "%~1"=="/nostart" set "ACARGS=-NoStart"
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$s=[IO.File]::ReadAllText($env:AC_SELF,[Text.Encoding]::UTF8); $i=$s.IndexOf('#'+'#ARRIVEECOLLAB-PS#'+'#'); & ([ScriptBlock]::Create($s.Substring($i))) %ACARGS%"
exit /b
##ARRIVEECOLLAB-PS##
# ============================================================================
#  Lanceur de l'outil Arrivée Collaborateur. Embarqué TEL QUEL dans
#  « Arrivee Collab.cmd » (FICHIER UNIQUE généré par build-zip.ps1, comme
#  SNOW Widget.cmd et Biblio-Tech.cmd) : seul le .cmd est à distribuer (SharePoint,
#  partage, bureau...). Une copie locale sert aussi de cible aux raccourcis.
#  A chaque lancement :
#   1. si la copie locale (%LOCALAPPDATA%\Arrivee-Collab\app) est absente, incomplète,
#      antérieure à la version minimale ou si -Repair est demandé : lit latest.json,
#      télécharge le paquet, contrôle son empreinte SHA-256 et la signature de
#      l'éditeur, puis l'installe. Canal principal : dépôt GitHub PUBLIC (aucun jeton) ;
#      repli : fichiers latest.json + zip posés à côté du .cmd (dossier synchronisé) ;
#   2. copie le lanceur en local et, si le .cmd a été lancé directement, crée les
#      raccourcis Bureau + Menu Démarrer ;
#   3. lance l'application (sans fenêtre console).
#  Il ne force JAMAIS la mise à jour d'une installation saine et à jour du minimum :
#  celles-ci passent par la pastille de l'application, sur confirmation de l'utilisateur.
#  Aucun droit administrateur, aucun identifiant, aucune donnée envoyée.
#  Options : -Repair (réinstallation) ; -NoStart (installe sans lancer l'application
#  ni créer de raccourci : déploiement par script).
# ============================================================================
param([switch]$Repair, [switch]$NoStart)
$ErrorActionPreference = 'Stop'
$Repo    = 'Lixirian/arrivee-collab'   # dépôt GitHub public de distribution
$Branch  = 'main'
# Version minimale installable : première version livrant le lanceur local (cible des
# raccourcis). Une installation antérieure est mise à niveau au double-clic sur le .cmd.
$MinVersion = '1.14.0'
# Clé PUBLIQUE de l'éditeur (inscrite par build-zip.ps1 -NewSigningKey, identique à
# config.ps1) : aucun zip n'est installé sans empreinte SHA-256 + signature valides.
$ReleasePublicKey = '<RSAKeyValue><Modulus>raIRN/8SJiSaul7c49MAezHpVdn+NqrVeiWVGITIrSYg8vnPJV6OUndLedwPAq8+JnsVJdzeublKQJ4gpsW7slTiBYMgHoP36anKfQVi5HvH3NxFIG0nEYUuXTwBI69ffiM6PnmgRWM4D0JaoKDy45PugMg48YQ7av2yfjzZrBAKHEUL3kYEomblDASWhHYqHFM/o1wt7y0qzHZ60cTgNJXTwLD0u50Hv/VRjorFbkm/AmgOfkG/wDFisdt2AiQDVD9y5XeGoKemdG4LVTs/CRDxyHVwGoWSMoIeR9AHYD4FQAuK4IG9as/LmbTqsOeBDxK1kXYaPoBmwhX7vt+j91U4EHXDf90s8yzfurWrP8Uaw3BDUJeFIiyTmcIj/9fQr5T7fMgsfm8p9Hz1mBXJXouHOxBJrYF5pFoLeOF8Sye9Sj6yAnWsIRYF0XkD0R4JwT+1txdtpO3SLdZwLy/pj40r5zUxAbf1yNfkYUSANfJHRgXxHUc5YwBTkxazJQCh</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

$dataDir = Join-Path $env:LOCALAPPDATA 'Arrivee-Collab'
$appDir  = Join-Path $dataDir 'app'
$lchDir  = Join-Path $dataDir 'launcher'
$log     = Join-Path $dataDir 'bootstrap.log'
$entry   = Join-Path $appDir 'Start-ArriveeCollab.vbs'
$lchVbs  = Join-Path $lchDir 'Arrivee Collab.vbs'
$wscript = Join-Path $env:SystemRoot 'System32\wscript.exe'

function L($m) { try { if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }; Add-Content -LiteralPath $log -Value ("{0} [LANCEUR] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch {} }

# Client web : TLS 1.2 + proxy système avec identifiants par défaut (postes SNCF).
function New-BootWebClient {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $wc = New-Object System.Net.WebClient
    $wc.Headers['User-Agent'] = 'ArriveeCollab-Bootstrap'
    $wc.Headers['Cache-Control'] = 'no-cache'
    if ($wc.Proxy) { $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials }
    return $wc
}

# Dossier du .cmd s'il a été lancé directement ; sinon (raccourci -> lanceur local)
# le dernier dossier mémorisé, pour garder le repli hors GitHub.
function Get-BootDistDir {
    if ($env:AC_SELF) { return (Split-Path -Parent $env:AC_SELF) }
    try {
        $dp = Join-Path $dataDir 'dist_path.txt'
        if (Test-Path -LiteralPath $dp) { return (Get-Content -LiteralPath $dp -Raw -Encoding UTF8).Trim() }
    } catch { }
    return $null
}

# Version installée ('' si illisible) ; installation antérieure au minimum = mise à niveau.
function Get-BootInstalledVersion {
    try { return [regex]::Match([IO.File]::ReadAllText((Join-Path $appDir 'config.ps1'), [Text.Encoding]::UTF8), "Version\s*=\s*'([^']+)'").Groups[1].Value } catch { return '' }
}
function Test-BootTooOld {
    $v = Get-BootInstalledVersion
    if ($v -notmatch '^\d{1,4}(\.\d{1,4}){1,3}$') { return $false }
    return ([version]$v -lt [version]$MinVersion)
}
function Test-BootHealthy {
    foreach ($f in @('arrivee collab.ps1', 'config.ps1', 'Start-ArriveeCollab.vbs', 'lib\Common.ps1', 'lib\Update.ps1', 'Resources\Signature.png', 'lib\webview2\Microsoft.Web.WebView2.Core.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $appDir $f))) { return $false }
    }
    return $true
}

# Manifeste : release GitHub (immédiat), fichier du dépôt (~5 min de cache), dossier local.
# Une réponse illisible, mal formée ou sous le minimum accepté passe à la source suivante.
function Test-BootManifestVersion($J) {
    if (-not $J) { return $false }
    $v = [string]$J.version
    if ($v -notmatch '^\d{1,4}(\.\d{1,4}){1,3}$') { L "latest.json : version invalide « $v »."; return $false }
    if ([version]$v -lt [version]$MinVersion) { L "latest.json : version $v inférieure au minimum accepté ($MinVersion) : ignorée."; return $false }
    return $true
}
function Get-BootManifest([string]$DistDir) {
    foreach ($u in @("https://github.com/$Repo/releases/latest/download/latest.json?t=$([DateTime]::UtcNow.Ticks)",
                     "https://raw.githubusercontent.com/$Repo/$Branch/latest.json?nocache=$([DateTime]::UtcNow.Ticks)")) {
        try {
            $wc = New-BootWebClient
            try { $raw = $wc.DownloadString($u) } finally { $wc.Dispose() }
            $j = $raw.TrimStart([char]0xFEFF) | ConvertFrom-Json
            L "latest.json GitHub ($u) : version $($j.version)."
            if (Test-BootManifestVersion $j) { return @{ J = $j; Mode = 'github' } }
        } catch { L "latest.json GitHub KO ($u) : $($_.Exception.Message)" }
    }
    if ($DistDir) {
        $mf = Join-Path $DistDir 'latest.json'
        if (Test-Path -LiteralPath $mf) {
            try {
                $j = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
                L "latest.json du dossier : version $($j.version)."
                if (Test-BootManifestVersion $j) { return @{ J = $j; Mode = 'dossier' } }
            } catch { L "latest.json du dossier illisible : $($_.Exception.Message)" }
        }
    }
    return $null
}

# Signature RSA de l'éditeur sur « Arrivee-Collab|<version>|<SHA> ».
function Test-BootSignature([string]$Version, [string]$Sha, [string]$Sig) {
    if (-not $ReleasePublicKey -or -not $Sig) { return $false }
    try {
        $rsa = New-Object System.Security.Cryptography.RSACryptoServiceProvider((New-Object System.Security.Cryptography.CspParameters 24))
        $rsa.FromXmlString($ReleasePublicKey)
        return $rsa.VerifyData([Text.Encoding]::UTF8.GetBytes("Arrivee-Collab|$Version|$Sha"), 'SHA256', [Convert]::FromBase64String($Sig))
    } catch { return $false }
}

# Une instance en cours verrouille ses DLL WebView2 : elle est fermée avant le remplacement
# (uniquement quand une installation est nécessaire, jamais à un lancement normal).
function Stop-BootRunningApp {
    $target = Join-Path $appDir 'arrivee collab.ps1'
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine.IndexOf($target, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    foreach ($p in $procs) {
        L "Arrêt de l'instance en cours (PID $($p.ProcessId))."
        try { Stop-Process -Id $p.ProcessId -Force } catch { }
    }
    if ($procs.Count) { Start-Sleep -Seconds 2 }
}

function Install-BootApp($Man, [string]$DistDir) {
    $j = $Man.J
    $ver = [string]$j.version
    # Nom et adresses RECONSTRUITS : ceux du manifeste, s'ils existent, sont ignorés.
    $zipName = "Arrivee-Collab_version$ver.zip"
    $tmpZip = Join-Path $env:TEMP ('acboot_' + [guid]::NewGuid().ToString('N') + '.zip')
    $tmp = $null
    try {
        $got = $false
        if ($Man.Mode -eq 'github') {
            foreach ($u in @("https://github.com/$Repo/releases/download/v$ver/$zipName", "https://raw.githubusercontent.com/$Repo/$Branch/$zipName")) {
                try {
                    $wc = New-BootWebClient
                    try { $wc.DownloadFile($u, $tmpZip) } finally { $wc.Dispose() }
                    $got = $true
                    L "Zip $zipName téléchargé : $u"
                    break
                } catch { L "Téléchargement KO ($u) : $($_.Exception.Message)" }
            }
        }
        if (-not $got -and $DistDir) {
            $local = Join-Path $DistDir $zipName
            if (Test-Path -LiteralPath $local) { Copy-Item -LiteralPath $local -Destination $tmpZip -Force; $got = $true; L "Zip $zipName copié depuis le dossier." }
        }
        if (-not $got) { throw "paquet $zipName introuvable (GitHub et dossier)" }

        # Zip verrouillé en écriture de la vérification jusqu'à la fin de l'extraction :
        # le fichier vérifié est exactement celui qui est installé.
        $lock = [System.IO.File]::Open($tmpZip, 'Open', 'Read', 'Read')
        try {
            $hasher = [System.Security.Cryptography.SHA256]::Create()
            try { $sha = ([BitConverter]::ToString($hasher.ComputeHash($lock)) -replace '-', '').ToUpperInvariant() } finally { $hasher.Dispose() }
            if (-not $j.sha256 -or $sha -ne ([string]$j.sha256).ToUpperInvariant()) { L "Installation REFUSEE ($zipName) : empreinte SHA-256 invalide (obtenu $sha)."; throw 'empreinte SHA-256 absente ou invalide (fichier corrompu ou altéré)' }
            if (-not (Test-BootSignature $ver $sha ([string]$j.sig))) { L "Installation REFUSEE ($zipName) : signature invalide."; throw "signature de la version $ver absente ou invalide" }
            L "Paquet $ver vérifié (SHA-256 + signature)."
            $tmp = Join-Path $env:TEMP ('acboot_' + [guid]::NewGuid().ToString('N'))
            Expand-Archive -LiteralPath $tmpZip -DestinationPath $tmp -Force
        } finally { $lock.Dispose() }

        $inner = Get-ChildItem -LiteralPath $tmp -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'arrivee collab.ps1') } | Select-Object -First 1
        if (-not $inner) { throw 'archive invalide' }
        Stop-BootRunningApp
        if (-not (Test-Path -LiteralPath $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null }
        # Quelques essais : un processus WebView2 peut libérer ses fichiers avec retard.
        for ($i = 1; $i -le 5; $i++) {
            try { Copy-Item -Path (Join-Path $inner.FullName '*') -Destination $appDir -Recurse -Force; break }
            catch { if ($i -eq 5) { throw }; Start-Sleep -Seconds 2 }
        }
        L "Version $ver installée dans $appDir."
    } finally {
        if ($tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $tmpZip -Force -ErrorAction SilentlyContinue
    }
}

# Copie le lanceur hors du dossier app (il survit à une copie abîmée et la répare).
function Install-BootLauncher {
    $src = Join-Path $appDir 'launcher'
    if (-not (Test-Path -LiteralPath (Join-Path $src 'bootstrap.ps1'))) { return }
    if (-not (Test-Path -LiteralPath $lchDir)) { New-Item -ItemType Directory -Path $lchDir -Force | Out-Null }
    foreach ($f in @('bootstrap.ps1', 'Arrivee Collab.vbs')) {
        $s = Join-Path $src $f
        if (Test-Path -LiteralPath $s) { Copy-Item -LiteralPath $s -Destination (Join-Path $lchDir $f) -Force }
    }
}

# Raccourcis Menu Démarrer + Bureau vers le lanceur LOCAL (jamais vers le dossier partagé).
# Créés quand le .cmd est lancé directement (ou à une installation) ; jamais depuis un
# raccourci : un raccourci supprimé par l'utilisateur ne revient pas tout seul.
function Install-BootShortcuts {
    if (-not (Test-Path -LiteralPath $lchVbs)) { L 'Lanceur local absent : raccourcis non créés.'; return }
    $wsh = New-Object -ComObject WScript.Shell
    $ico = Join-Path $appDir 'image-arrivee-collab.ico'
    foreach ($lnk in @((Join-Path ([Environment]::GetFolderPath('Programs')) 'Arrivée Collab.lnk'), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Arrivée Collab.lnk'))) {
        try {
            $sc = $wsh.CreateShortcut($lnk)
            $sc.TargetPath = $wscript
            $sc.Arguments = '"' + $lchVbs + '"'
            $sc.WorkingDirectory = $lchDir
            if (Test-Path -LiteralPath $ico) { $sc.IconLocation = "$ico,0" }
            $sc.Description = 'Arrivée Collaborateur - notification des nouveaux collaborateurs'
            $sc.Save()
            L "Raccourci créé : $lnk"
        } catch { L "Raccourci non créé ($lnk) : $($_.Exception.Message)" }
    }
}

try {
    if (-not (Test-Path -LiteralPath $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
    $dist = Get-BootDistDir
    if ($env:AC_SELF) { try { Set-Content -LiteralPath (Join-Path $dataDir 'dist_path.txt') -Value $dist -Encoding UTF8 -Force } catch { } }

    $healthy = Test-BootHealthy
    $reason = if ($Repair) { 'réparation demandée' } elseif (-not $healthy) { 'première installation ou installation incomplète' } elseif (Test-BootTooOld) { "version installée $(Get-BootInstalledVersion) antérieure au minimum $MinVersion" } else { '' }
    if ($reason) {
        L "Installation : $reason."
        $man = Get-BootManifest $dist
        if ($man) {
            try { Install-BootApp $man $dist }
            catch {
                L "Installation non appliquée : $($_.Exception.Message)"
                # Une réparation ratée n'empêche pas de lancer une installation saine.
                if (-not $healthy) { throw }
            }
        } elseif (-not $healthy) { throw 'version à installer introuvable (GitHub injoignable et aucun fichier à côté du lanceur)' }
        else { L 'Réparation impossible hors ligne : lancement de la version en place.' }
    }
    try {
        Install-BootLauncher
        if (($reason -or $env:AC_SELF) -and -not $NoStart) { Install-BootShortcuts }
    } catch { L "Lanceur local non mis à jour : $($_.Exception.Message)" }

    if ($NoStart) { L 'Option -NoStart : application non lancée.' }
    elseif (Test-Path -LiteralPath $entry) {
        Remove-Item Env:\AC_SELF -ErrorAction SilentlyContinue
        Start-Process -FilePath $wscript -ArgumentList ('"' + $entry + '"') -WorkingDirectory $appDir
        L "Application lancée depuis $appDir."
    } else { throw "aucune version installée dans $appDir" }
} catch {
    L ("ÉCHEC : " + $_.Exception.Message)
    if (-not $NoStart) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            [void][System.Windows.Forms.MessageBox]::Show(
                "Installation impossible : $($_.Exception.Message)`n`nVérifiez l'accès à github.com (réseau, proxy), puis relancez.`nJournal : $log",
                'Arrivée Collaborateur', 'OK', 'Error')
        } catch { }
    }
    exit 1
}
