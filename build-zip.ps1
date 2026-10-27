# ============================================================================
#  Génère le zip de distribution de l'outil Arrivée Collaborateur.
#  - Lit la version dans ArriveeCollab-PS\config.ps1 ($Config.Version).
#  - Produit  Arrivee-Collab_version<X>.zip  à la racine (dossier racine interne = même nom).
#  - Génère latest.json (version + zip + notes depuis releases.json).
#  - Archive les anciennes versions dans Archives\.
#  - Assemble dist-ready\ (lanceur + zip + latest.json) + zips d'export.
#  - En fin : COMMIT + PUSH automatique sur origin, y compris sur la branche de
#    publication lue par les apps ($Config.UpdateBranch), puis CONTRÔLE que cette
#    branche distante porte bien ce build (best-effort ; -NoGit pour s'en passer).
#  - Puis crée la RELEASE GitHub v<X> (zip + latest.json, via gh) : les postes la
#    lisent via github.com/<repo>/releases/latest/download/latest.json, en ligne dès
#    la publication (le fichier de la branche, servi par le CDN raw, garde ~5 min de cache).
#  SIGNATURE (normes cyber / DSI) : chaque zip est signé (RSA 3072, SHA-256) avec une clé
#  PRIVÉE qui ne quitte jamais ce poste : %USERPROFILE%\.arrivee-collab-signing\ (chiffrée
#  DPAPI pour l'utilisateur Windows courant ; JAMAIS dans le dépôt, GitHub ou SynologyDrive).
#  Texte signé : « Arrivee-Collab|<version>|<SHA-256 du zip> » ; empreinte + signature vont
#  dans latest.json (sha256, sig). L'app et le lanceur embarquent la clé PUBLIQUE et
#  refusent tout zip non conforme : un compte GitHub compromis ne suffit pas à diffuser.
#  Usage :  powershell -ExecutionPolicy Bypass -File build-zip.ps1 [-NoGit]
#           ... -NewSigningKey  : crée la clé (UNE fois) et inscrit la clé publique dans
#                                 config.ps1 et dist-launcher\bootstrap.ps1.
#           ... -ExportSigningKey [-KeyBackup <fichier>] : sauvegarde de la clé chiffrée par
#                                 mot de passe (AES-256, PBKDF2-SHA256 600 000 it.) -> clé USB /
#                                 gestionnaire de mots de passe. Clé perdue = plus aucune MAJ
#                                 acceptée par les postes (il faudrait redistribuer le lanceur).
#           ... -ImportSigningKey -KeyBackup <fichier> : nouveau PC -> restaure la clé.
# ============================================================================
param([switch]$NoGit, [switch]$NewSigningKey, [switch]$ExportSigningKey, [switch]$ImportSigningKey, [string]$KeyBackup = '')
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$src  = Join-Path $repo 'ArriveeCollab-PS'

# --- Clé de signature des versions ---------------------------------------------
Add-Type -AssemblyName System.Security
$keyDir   = Join-Path $env:USERPROFILE '.arrivee-collab-signing'
$keyFile  = Join-Path $keyDir 'release-key.dpapi'
$pubFiles = @(@{ File = (Join-Path $src 'config.ps1');                  Pattern = "(ReleasePublicKey\s*=\s*)'[^']*'" },
              @{ File = (Join-Path $repo 'dist-launcher\bootstrap.ps1'); Pattern = "(\`$ReleasePublicKey\s*=\s*)'[^']*'" })
function New-AcRsa { return New-Object System.Security.Cryptography.RSACryptoServiceProvider(3072, (New-Object System.Security.Cryptography.CspParameters 24)) }
function Get-AcPublishedKey($pf) { return [regex]::Match([IO.File]::ReadAllText($pf.File, [Text.Encoding]::UTF8), $pf.Pattern.Replace("'[^']*'", "'([^']*)'")).Groups[2].Value }
function Read-AcSecret([string]$Prompt) {
    $s = Read-Host $Prompt -AsSecureString
    $p = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($p) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($p) }
}
function Get-AcBackupKeys([byte[]]$Salt, [switch]$Confirm) {
    $plain = Read-AcSecret 'Mot de passe de la sauvegarde'
    if ($plain.Length -lt 12) { throw 'Mot de passe trop court (12 caractères minimum).' }
    if ($Confirm -and (Read-AcSecret 'Confirmez le mot de passe') -ne $plain) { throw 'Les deux mots de passe diffèrent.' }
    $b = (New-Object System.Security.Cryptography.Rfc2898DeriveBytes($plain, $Salt, 600000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)).GetBytes(64)
    return @{ Aes = $b[0..31]; Mac = $b[32..63] }
}
if ($NewSigningKey) {
    if (Test-Path -LiteralPath $keyFile) { throw "Une clé existe déjà ($keyFile). La remplacer couperait les mises à jour des postes : supprimez-la d'abord si c'est voulu." }
    $rsa = New-AcRsa
    New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
    [IO.File]::WriteAllBytes($keyFile, [Security.Cryptography.ProtectedData]::Protect([Text.Encoding]::UTF8.GetBytes($rsa.ToXmlString($true)), $null, 'CurrentUser'))
    $pub = $rsa.ToXmlString($false)
    foreach ($pf in $pubFiles) {
        $t = [IO.File]::ReadAllText($pf.File, [Text.Encoding]::UTF8)
        $t2 = [regex]::Replace($t, $pf.Pattern, ('${1}' + "'" + $pub + "'"))
        if ($t2 -eq $t) { throw "Emplacement de la clé publique introuvable dans $($pf.File)" }
        [IO.File]::WriteAllText($pf.File, $t2, (New-Object Text.UTF8Encoding $true))
    }
    Write-Host "Clé de signature créée : $keyFile (chiffrée DPAPI). Clé publique inscrite dans config.ps1 et bootstrap.ps1." -ForegroundColor Green
    Write-Host 'SAUVEGARDEZ-LA maintenant : .\build-zip.ps1 -ExportSigningKey' -ForegroundColor Yellow
    return
}
# Format de sauvegarde : 'ACKEY1' | sel (16) | IV (16) | AES-256-CBC(clé XML) | HMAC-SHA256 (32).
if ($ExportSigningKey) {
    if (-not (Test-Path -LiteralPath $keyFile)) { throw "Aucune clé à sauvegarder ($keyFile)." }
    if (-not $KeyBackup) { throw 'Indiquez où écrire la sauvegarde : -KeyBackup <fichier> (support hors ligne ou dossier non synchronisé, jamais le dépôt).' }
    $kbFull = [IO.Path]::GetFullPath($KeyBackup)
    if ($kbFull.StartsWith([IO.Path]::GetFullPath($repo), [StringComparison]::OrdinalIgnoreCase)) { throw 'La sauvegarde ne doit pas être écrite dans le dépôt (public).' }
    foreach ($od in @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer) | Where-Object { $_ }) {
        if ($kbFull.StartsWith([IO.Path]::GetFullPath($od), [StringComparison]::OrdinalIgnoreCase)) { throw "La sauvegarde ne doit pas être écrite dans un dossier OneDrive synchronisé ($od)." }
    }
    if (Test-Path -LiteralPath $KeyBackup) { throw "$KeyBackup existe déjà." }
    $plainKey = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($keyFile), $null, 'CurrentUser')
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider; $rng.GetBytes($salt); $rng.GetBytes($iv)
    $k = Get-AcBackupKeys $salt -Confirm
    $aes = [System.Security.Cryptography.Aes]::Create(); $aes.Key = [byte[]]$k.Aes; $aes.IV = $iv
    $ct = $aes.CreateEncryptor().TransformFinalBlock($plainKey, 0, $plainKey.Length)
    $body = [byte[]]([Text.Encoding]::ASCII.GetBytes('ACKEY1') + $salt + $iv + $ct)
    $mac = (New-Object System.Security.Cryptography.HMACSHA256 (, [byte[]]$k.Mac)).ComputeHash($body)
    [IO.File]::WriteAllBytes($KeyBackup, [byte[]]($body + $mac))
    Write-Host "Sauvegarde chiffrée écrite : $KeyBackup" -ForegroundColor Green
    Write-Host 'Rangez-la HORS du dépôt, de GitHub et de SynologyDrive (clé USB, gestionnaire de mots de passe) et notez le mot de passe.' -ForegroundColor Yellow
    return
}
if ($ImportSigningKey) {
    if (-not $KeyBackup -or -not (Test-Path -LiteralPath $KeyBackup)) { throw 'Indiquez la sauvegarde : -KeyBackup <fichier>.' }
    if (Test-Path -LiteralPath $keyFile) { throw "Une clé est déjà présente sur ce poste ($keyFile)." }
    $all = [IO.File]::ReadAllBytes($KeyBackup)
    if ($all.Length -lt 6 + 32 + 32 -or [Text.Encoding]::ASCII.GetString($all, 0, 6) -ne 'ACKEY1') { throw 'Fichier de sauvegarde invalide.' }
    $body = [byte[]]$all[0..($all.Length - 33)]; $mac = [byte[]]$all[($all.Length - 32)..($all.Length - 1)]
    $salt = [byte[]]$all[6..21]; $iv = [byte[]]$all[22..37]; $ct = [byte[]]$all[38..($all.Length - 33)]
    $k = Get-AcBackupKeys $salt
    $calc = (New-Object System.Security.Cryptography.HMACSHA256 (, [byte[]]$k.Mac)).ComputeHash($body)
    if ([Convert]::ToBase64String($calc) -ne [Convert]::ToBase64String($mac)) { throw 'Mot de passe incorrect ou sauvegarde altérée.' }
    $aes = [System.Security.Cryptography.Aes]::Create(); $aes.Key = [byte[]]$k.Aes; $aes.IV = $iv
    $plainKey = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length)
    $rsa = New-AcRsa; $rsa.FromXmlString([Text.Encoding]::UTF8.GetString($plainKey))
    foreach ($pf in $pubFiles) { if ((Get-AcPublishedKey $pf) -ne $rsa.ToXmlString($false)) { throw "Cette clé ne correspond pas à la clé publique de $($pf.File) : restauration annulée." } }
    New-Item -ItemType Directory -Path $keyDir -Force | Out-Null
    [IO.File]::WriteAllBytes($keyFile, [Security.Cryptography.ProtectedData]::Protect($plainKey, $null, 'CurrentUser'))
    Write-Host "Clé restaurée sur ce poste : $keyFile" -ForegroundColor Green
    return
}
if (-not (Test-Path -LiteralPath $keyFile)) { throw "Clé de signature introuvable ($keyFile). Première fois : -NewSigningKey ; nouveau PC : -ImportSigningKey -KeyBackup <fichier>." }
$signer = New-AcRsa
$signer.FromXmlString([Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($keyFile), $null, 'CurrentUser')))
# La clé publique livrée (app + lanceur) doit correspondre à la clé privée, sinon les postes refuseraient tout.
foreach ($pf in $pubFiles) { if ((Get-AcPublishedKey $pf) -ne $signer.ToXmlString($false)) { throw "La clé publique de $($pf.File) ne correspond pas à la clé de signature." } }

$cfg = Get-Content -LiteralPath (Join-Path $src 'config.ps1') -Raw
$m = [regex]::Match($cfg, "Version\s*=\s*'([^']+)'")
if (-not $m.Success) { throw "Version introuvable dans config.ps1 (attendu : Version = '<x>')." }
$ver = $m.Groups[1].Value
$name = "Arrivee-Collab_version$ver"

# Branche RÉELLEMENT lue par les apps installées et par le bootstrap
# (raw.githubusercontent.com/<repo>/<branche>/latest.json). Même source de vérité
# que l'app : config.ps1. Publier ailleurs = publier dans le vide.
$mb = [regex]::Match($cfg, "UpdateBranch\s*=\s*'([^']*)'")
$pubBranch = if ($mb.Success -and $mb.Groups[1].Value) { $mb.Groups[1].Value } else { 'main' }

# Staging : copie temporaire renommée pour que le dossier racine du zip = $name.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) $name
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
# Contenu = fichiers de ArriveeCollab-PS suivis par Git + nouveaux fichiers NON ignorés
# (.gitignore respecté : un .msg de test ou un dossier « Mot de passe » oublié n'est
# jamais publié). Les nouveaux fichiers sont ajoutés à Git pour être commités avec le build.
Push-Location $repo
try {
    $fichiers = @(& git -c core.quotepath=off ls-files --cached --others --exclude-standard -- 'ArriveeCollab-PS' 2>$null)
    $nouveaux = @(& git -c core.quotepath=off ls-files --others --exclude-standard -- 'ArriveeCollab-PS' 2>$null)
} finally { Pop-Location }
if ($fichiers.Count -eq 0) { throw "Aucun fichier à empaqueter (git ls-files a échoué ?)." }
if ($nouveaux.Count -gt 0) {
    Write-Host ("Nouveaux fichiers inclus et ajoutés à Git : " + ($nouveaux -join ', ')) -ForegroundColor Yellow
    Push-Location $repo; try { & git add -- $nouveaux 2>$null | Out-Null } finally { Pop-Location }
}
New-Item -ItemType Directory -Path $staging -Force | Out-Null
foreach ($rel in $fichiers) {
    $relApp = $rel.Substring('ArriveeCollab-PS/'.Length)
    $dst = Join-Path $staging $relApp
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath (Join-Path $repo $rel) -Destination $dst -Force
}

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
# Empreinte + signature : ce que l'app et le lanceur vérifient avant toute installation.
$sha = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToUpperInvariant()
$sig = [Convert]::ToBase64String($signer.SignData([Text.Encoding]::UTF8.GetBytes("Arrivee-Collab|$ver|$sha"), 'SHA256'))
# Signature du manifeste ENTIER (msig : version, empreinte, date, notes) : texte
# calculé par la MÊME fonction que celle de l'app qui le vérifie (lib/Update.ps1).
. (Join-Path $src 'lib\Update.ps1')
$date = Get-Date -Format 'yyyy-MM-dd'
$notesTxt = @($notes | ForEach-Object { [string]$_ })
$msig = [Convert]::ToBase64String($signer.SignData([Text.Encoding]::UTF8.GetBytes((Get-ManifestSignedText $ver $sha $date $notesTxt)), 'SHA256'))
$manifest = [ordered]@{ version = $ver; zip = "$name.zip"; sha256 = $sha; sig = $sig; msig = $msig; date = $date; notes = $notesTxt }
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
            & git add latest.json "Arrivee-Collab_version$ver.zip" .dist-launcher-history.json 2>$null | Out-Null
            & git add -u 2>$null | Out-Null
            & git diff --cached --quiet 2>$null
            if ($LASTEXITCODE -ne 0) {
                $msg = "Version $ver"
                if (@($notes).Count -gt 0) { $msg += "`n`n" + ((@($notes) | ForEach-Object { "- $_" }) -join "`n") }
                $tmpMsg = Join-Path ([System.IO.Path]::GetTempPath()) ("accommit_" + [guid]::NewGuid().ToString('N') + ".txt")
                [System.IO.File]::WriteAllText($tmpMsg, $msg, (New-Object System.Text.UTF8Encoding $false))
                & git commit -F $tmpMsg 2>$null | Out-Null
                $committed = ($LASTEXITCODE -eq 0)
                Remove-Item -LiteralPath $tmpMsg -Force -ErrorAction SilentlyContinue
                if ($committed) { Write-Host "Git : commit 'Version $ver' créé." }
                else { Write-Host "Git : commit KO (voir 'git status')." }
            } else { Write-Host "Git : rien à committer." }

            # --- Publication : faire avancer la branche que lisent les apps ---
            # Volontairement HORS du test « y a-t-il quelque chose à committer » :
            # un build sans changement doit quand même vérifier (et rétablir) l'état
            # publié. C'est ce contrôle qui évite les publications fantômes.
            $hasOrigin = ((& git remote 2>$null) -contains 'origin')
            if ($hasOrigin) {
                $cur = (& git rev-parse --abbrev-ref HEAD 2>$null)
                & git push origin HEAD 2>$null | Out-Null          # branche de travail
                if ($cur -ne $pubBranch) {
                    & git push origin "HEAD:$pubBranch" 2>$null | Out-Null
                    if ($LASTEXITCODE -ne 0) {
                        Write-Host "Git : push vers '$pubBranch' REFUSÉ (branche distante divergente ?)."
                        Write-Host "      Rattrapage : git fetch origin ; git merge -s ours origin/$pubBranch ; git push origin HEAD:$pubBranch"
                    }
                }
                # Contrôle final : le SHA distant de la branche de publication doit
                # être celui du build. Sinon, personne ne recevra cette version.
                $localSha = (& git rev-parse HEAD 2>$null)
                $remoteLine = (& git ls-remote origin "refs/heads/$pubBranch" 2>$null)
                $remoteSha = if ($remoteLine) { (([string]$remoteLine) -split '\s+')[0] } else { '' }
                if ($remoteSha -and $remoteSha -eq $localSha) {
                    Write-Host "PUBLICATION OK : origin/$pubBranch porte la version $ver."
                    # Release GitHub v<X> (zip + latest.json) : canal lu en PREMIER par les postes,
                    # en ligne immédiatement. Sans elle, les postes se rabattent sur la branche (~5 min).
                    $ghRepo = [regex]::Match($cfg, "UpdateRepo\s*=\s*'([^']+)'").Groups[1].Value
                    $manifestFile = Join-Path $repo 'latest.json'
                    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
                        Write-Host "RELEASE KO : gh introuvable -> pastille sous ~5 min seulement (canal branche)."
                    } else {
                        $notesFile = Join-Path ([System.IO.Path]::GetTempPath()) ("acnotes_" + [guid]::NewGuid().ToString('N') + ".md")
                        $notesMd = if (@($notes).Count) { (@($notes) | ForEach-Object { "- $_" }) -join "`n" } else { "Version $ver" }
                        [System.IO.File]::WriteAllText($notesFile, $notesMd, (New-Object System.Text.UTF8Encoding $false))
                        & gh release view "v$ver" --repo $ghRepo 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            & gh release upload "v$ver" $zip $manifestFile --clobber --repo $ghRepo 2>$null | Out-Null
                        } else {
                            & gh release create "v$ver" $zip $manifestFile --repo $ghRepo --target $localSha --title "Arrivée Collaborateur $ver" --notes-file $notesFile --latest 2>$null | Out-Null
                        }
                        $relOk = ($LASTEXITCODE -eq 0)
                        Remove-Item -LiteralPath $notesFile -Force -ErrorAction SilentlyContinue
                        if ($relOk) { Write-Host "RELEASE OK : https://github.com/$ghRepo/releases/tag/v$ver (pastille visible sous ~2 min)." }
                        else { Write-Host "RELEASE KO : création de la release v$ver impossible -> pastille sous ~5 min (canal branche). Relancer le build pour réessayer." }
                    }
                } else {
                    Write-Host "PUBLICATION KO : origin/$pubBranch ne pointe PAS sur ce build."
                    Write-Host "      local   = $localSha"
                    Write-Host ("      distant = {0}" -f $(if ($remoteSha) { $remoteSha } else { '(branche absente ou hors ligne)' }))
                    Write-Host "      -> tant que ce n'est pas corrigé, AUCUN utilisateur ne recevra la $ver."
                }
            } else { Write-Host "Git : pas de remote 'origin' -> commit local seulement." }
        } else { Write-Host "Git : pas un dépôt git -> étape ignorée." }
    } catch { Write-Host "Git : étape ignorée ($($_.Exception.Message))." }
    finally { Pop-Location; $ErrorActionPreference = $prevEAP }
} else { Write-Host "Git : -NoGit -> ni commit ni push." }
