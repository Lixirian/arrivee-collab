# ============================================================================
#  Utilitaires transverses : dossiers de données (hors zone synchronisée) et logs.
# ============================================================================

# Dossier racine des données d'exécution : %LOCALAPPDATA%\Arrivee-Collab.
# Les données (état, logs, sorties métier) NE vivent PAS dans le dossier de l'app :
# ce dernier est écrasé à chaque mise à jour. On les isole donc ici.
function Get-AppDataDir {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = $env:APPDATA }
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    $dir = Join-Path $base 'Arrivee-Collab'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# Sous-dossier des données métier PERSISTANTES (survit aux MAJ) : <DataDir>\data.
# Contient « Mot de passe\ », « Archive message\ » et le .msg temporaire.
function Get-AppWorkDir {
    param([string]$DataDir)
    $dir = Join-Path $DataDir 'data'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# Comparaison NUMÉRIQUE de deux versions "x.y.z" (1.0.10 > 1.0.2). Renvoie -1 / 0 / 1.
function Compare-AppVersion {
    param([string]$A, [string]$B)
    $pa = @(($A -split '\.') | ForEach-Object { [int]([regex]::Replace($_, '\D', '')) })
    $pb = @(($B -split '\.') | ForEach-Object { [int]([regex]::Replace($_, '\D', '')) })
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        $x = if ($i -lt $pa.Count) { $pa[$i] } else { 0 }
        $y = if ($i -lt $pb.Count) { $pb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

# Active l'historique du presse-papiers Windows (Win+V) s'il est désactivé, pour
# fiabiliser le bouton « Copier tout » (qui place les deux notes dans l'historique).
# Best-effort, jamais bloquant. Respecte une stratégie d'entreprise (GPO) qui
# interdirait l'historique : dans ce cas on n'écrit rien. L'écriture de la clé prend
# effet immédiatement (le service cbdhsvc la surveille), sans déconnexion.
# Renvoie $true si l'historique est (désormais) actif, $false sinon.
function Enable-ClipboardHistory {
    try {
        # Stratégie GPO : AllowClipboardHistory = 0 => interdit, on ne force pas.
        foreach ($p in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\System',
                         'HKCU:\SOFTWARE\Policies\Microsoft\Windows\System')) {
            $pol = (Get-ItemProperty -Path $p -Name AllowClipboardHistory -ErrorAction SilentlyContinue).AllowClipboardHistory
            if ($null -ne $pol -and [int]$pol -eq 0) {
                Write-AppLog "[CLIP] Historique interdit par stratégie (AllowClipboardHistory=0) : pas d'activation."
                return $false
            }
        }
        $key = 'HKCU:\Software\Microsoft\Clipboard'
        $cur = (Get-ItemProperty -Path $key -Name EnableClipboardHistory -ErrorAction SilentlyContinue).EnableClipboardHistory
        if ($null -ne $cur -and [int]$cur -eq 1) { return $true }   # déjà activé par l'utilisateur
        if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
        New-ItemProperty -Path $key -Name EnableClipboardHistory -Value 1 -PropertyType DWord -Force | Out-Null
        Write-AppLog "[CLIP] Historique du presse-papiers activé automatiquement (EnableClipboardHistory=1)."
        return $true
    } catch {
        Write-AppLog "[CLIP] Activation historique KO : $($_.Exception.Message)"
        return $false
    }
}

# ----------------------------------------------------------------------------
#  Mode « mot de passe déjà initialisé » : Mon-AD n'affiche pas une date mais le
#  nombre de jours RESTANTS avant que le mot de passe doive être changé.
#  L'opérateur saisit ce X et l'outil en déduit la date d'initialisation :
#  aujourd'hui - (durée de validité - X). C'est la seule valeur reportée dans le
#  mail et la note ServiceNow. Helpers purs => testables hors-GUI.
# ----------------------------------------------------------------------------

# Durée de validité d'un mot de passe dans l'AD (jours affichés par Mon-AD
# juste après une initialisation).
$script:DureeValiditeMdp = 365

# Normalise une saisie libre en nombre de jours.
# Renvoie $null si ce n'est pas un entier positif ou s'il dépasse $Max (~10 ans),
# sinon l'entier correspondant. La GUI s'en sert à la fois pour l'aperçu en
# temps réel et pour bloquer la génération du .msg sur une saisie invalide.
function ConvertTo-NombreDeJours {
    param([string]$Texte, [int]$Max = 3650)
    if ($null -eq $Texte) { return $null }
    $t = $Texte.Trim()
    if ($t -eq '') { return $null }
    if ($t -notmatch '^\d+$') { return $null }
    if ($t.Length -gt 9) { return $null }   # évite un dépassement de [int]
    $n = [int]$t
    if ($n -gt $Max) { return $null }
    return $n
}

# Date exacte correspondant à « il y a $Jours jours », à minuit (sans heure).
# $Reference est injectable pour rendre le calcul testable indépendamment du jour.
function Get-DateDepuisJours {
    param([int]$Jours, [datetime]$Reference = (Get-Date))
    return $Reference.Date.AddDays(-$Jours)
}

# Date d'initialisation déduite des $JoursRestants avant expiration affichés par
# Mon-AD : le mot de passe a été défini il y a ($DureeValidite - $JoursRestants) jours.
function Get-DateInitDepuisJoursRestants {
    param([int]$JoursRestants, [int]$DureeValidite = $script:DureeValiditeMdp, [datetime]$Reference = (Get-Date))
    return Get-DateDepuisJours ($DureeValidite - $JoursRestants) $Reference
}

# ----------------------------------------------------------------------------
#  Sécurité : mot de passe, validation des saisies, purge des fichiers sensibles.
#  Helpers purs => testables hors-GUI.
# ----------------------------------------------------------------------------

# Jeux de caractères du mot de passe : sans caractères ambigus à la lecture
# (0/O/o, 1/l/I) ni caractères gênants au copier-coller ou en ligne de commande
# (guillemets, &, espaces).
$script:MdpMajuscules = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
$script:MdpMinuscules = 'abcdefghijkmnpqrstuvwxyz'
$script:MdpChiffres   = '23456789'
$script:MdpSpeciaux   = '!#$%*+-=?@'

# Index aléatoire uniforme dans [0, $Max[ tiré par le générateur CRYPTOGRAPHIQUE
# (rejet des valeurs qui biaiseraient le modulo).
function Get-IndexAleatoireCrypto {
    param([System.Security.Cryptography.RandomNumberGenerator]$Rng, [int]$Max)
    $b = New-Object byte[] 4
    $limite = [uint32]::MaxValue - ([uint32]::MaxValue % [uint32]$Max)
    do { $Rng.GetBytes($b); $v = [BitConverter]::ToUInt32($b, 0) } while ($v -ge $limite)
    return [int]($v % [uint32]$Max)
}

# Mot de passe aléatoire (12 caractères par défaut) contenant au moins une
# majuscule, une minuscule, un chiffre et un caractère spécial (règle AD des
# catégories), positions mélangées par tirage cryptographique.
function New-MotDePasse {
    param([int]$Longueur = 12)
    if ($Longueur -lt 8) { $Longueur = 8 }
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $classes = @($script:MdpMajuscules, $script:MdpMinuscules, $script:MdpChiffres, $script:MdpSpeciaux)
        $tous = -join $classes
        $car = New-Object System.Collections.Generic.List[char]
        foreach ($c in $classes) { $car.Add($c[(Get-IndexAleatoireCrypto $rng $c.Length)]) }
        while ($car.Count -lt $Longueur) { $car.Add($tous[(Get-IndexAleatoireCrypto $rng $tous.Length)]) }
        for ($i = $car.Count - 1; $i -gt 0; $i--) {   # mélange de Fisher-Yates
            $j = Get-IndexAleatoireCrypto $rng ($i + 1)
            $tmp = $car[$i]; $car[$i] = $car[$j]; $car[$j] = $tmp
        }
        return -join $car
    } finally { $rng.Dispose() }
}

# Nom de fichier sûr dérivé d'une saisie libre : lettres, chiffres, « _ » et « - »
# seulement (aucun séparateur de chemin, « .. », « : » ni joker) ; repli sur un
# identifiant aléatoire si rien ne reste.
function ConvertTo-NomFichierSur {
    param([string]$Texte)
    $s = ([string]$Texte) -replace '[^\p{L}\p{N}_-]', ''
    if ($s.Length -gt 60) { $s = $s.Substring(0, 60) }
    if (-not $s) { $s = [guid]::NewGuid().ToString('N').Substring(0, 12) }
    return $s
}

# Numéro de RITM ServiceNow (« RITM » + 7 à 10 chiffres).
function Test-NumeroRitmValide {
    param([string]$Texte)
    return ([string]$Texte).Trim() -match '^RITM\d{7,10}$'
}

# Nom et prénom : lettres (accents compris), espaces, apostrophes, tirets, points.
# Refuse tout balisage (< > " & …) qui finirait dans le mail.
function Test-NomPrenomValide {
    param([string]$Texte)
    $t = ([string]$Texte).Trim()
    return ($t.Length -ge 2 -and $t.Length -le 100 -and $t -match "^[\p{L}\p{M}][\p{L}\p{M} '’.\-]*$")
}

# Une seule adresse électronique (pas de liste « ; » ni de nom affiché).
function Test-AdresseMailValide {
    param([string]$Texte)
    return ([string]$Texte).Trim() -match '^[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$'
}

# Supprime les fichiers d'un dossier plus anciens que $Jours (0 = tous). Renvoie
# le nombre de fichiers supprimés. Sans effet si le dossier n'existe pas.
function Remove-FichiersAnciens {
    param([string]$Dossier, [int]$Jours, [string]$Filtre = '*', [datetime]$Reference = (Get-Date))
    if (-not $Dossier -or -not (Test-Path -LiteralPath $Dossier)) { return 0 }
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $Dossier -File -Filter $Filtre -ErrorAction SilentlyContinue)) {
        if ($Jours -le 0 -or $f.LastWriteTime -lt $Reference.AddDays(-$Jours)) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $n++ } catch { }
        }
    }
    return $n
}

# --- Journalisation (fichier uniquement, jamais la console) ---
$script:AppLogPath = $null

function Initialize-AppLog {
    param([string]$Path)
    $script:AppLogPath = $Path
    try {
        $header = "================ DÉMARRAGE ARRIVÉE COLLAB ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) ================"
        Set-Content -LiteralPath $Path -Value $header -Encoding UTF8 -Force
    } catch { }
}

function Write-AppLog {
    param([string]$Message)
    if ($script:AppLogPath) {
        $line = "$(Get-Date -Format 'HH:mm:ss') $Message"
        try { Add-Content -LiteralPath $script:AppLogPath -Value $line -Encoding UTF8 } catch { }
    }
}

# ----------------------------------------------------------------------------
#  Décision pure : faut-il replier l'app en bulle quand elle perd le focus ?
#  Vrai uniquement si la fenêtre désormais au premier plan appartient à un
#  AUTRE processus (et qu'on n'est ni déjà masqué, ni en animation, ni dans
#  le flux de génération du .msg où le masquage est volontairement suspendu,
#  ni avec la préférence utilisateur « garder la fenêtre affichée » active).
#  Extrait en fonction testable : la logique est ainsi couverte hors-GUI.
# ----------------------------------------------------------------------------
function Should-AutoHide {
    param(
        [bool]$AppHidden,
        [bool]$Animating,
        [bool]$Suppressed,
        [int]$ForegroundPid,
        [int]$OwnPid,
        [bool]$Disabled = $false
    )
    if ($Disabled)                  { return $false }
    if ($Suppressed)                { return $false }
    if ($AppHidden)                 { return $false }
    if ($Animating)                 { return $false }
    if ($ForegroundPid -le 0)       { return $false }
    if ($ForegroundPid -eq $OwnPid) { return $false }
    return $true
}
