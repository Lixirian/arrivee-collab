# ============================================================================
#  Vérification d'homonymes dans ServiceNow (table sys_user) — helpers PURS
#  (testés hors-GUI dans tests/Test-ArriveeCollab.ps1). La requête est exécutée
#  par la page ServiceNow cachée (lib/SnowPage.ps1).
# ============================================================================

# Normalise un nom pour la comparaison : sans accents, majuscules, tirets et
# apostrophes remplacés par des espaces, espaces multiples réduits.
# « Jérémy  Pasturel-Dupont » -> « JEREMY PASTUREL DUPONT ».
function ConvertTo-NomNormalise {
    param([string]$Texte)
    if ([string]::IsNullOrWhiteSpace($Texte)) { return '' }
    $d = $Texte.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $t = $sb.ToString().ToUpperInvariant() -replace "[-'’]", ' '
    return ($t -replace '\s+', ' ').Trim()
}

# Mots normalisés et TRIÉS d'un nom : l'ordre « Prénom Nom » / « NOM Prénom »
# n'a ainsi plus d'importance pour comparer deux noms.
function Get-NomTokens {
    param([string]$Texte)
    $n = ConvertTo-NomNormalise $Texte
    if ($n -eq '') { return @() }
    return @($n.Split(' ') | Sort-Object)
}

# Filtre ServiceNow (sysparm_query) : chaque mot saisi doit figurer dans le nom
# complet (champ « name »), quel que soit l'ordre. Les caractères qui ont un sens
# dans la syntaxe des requêtes (^ =) sont retirés. $null s'il y a moins de deux mots
# (un prénom seul ramènerait des centaines de comptes).
function Get-RequeteHomonymes {
    param([string]$NomPrenom)
    if ([string]::IsNullOrWhiteSpace($NomPrenom)) { return $null }
    $mots = @(($NomPrenom -replace '[\^=]', ' ').Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($mots.Count -lt 2) { return $null }
    return (($mots | ForEach-Object { "nameLIKE$_" }) -join '^')
}

# URL relative (same-origin) de la requête JSONv2 sur sys_user.
function Get-UrlJsonHomonymes {
    param([string]$NomPrenom, [int]$Max = 50)
    $q = Get-RequeteHomonymes $NomPrenom
    if (-not $q) { return $null }
    $champs = 'user_name,name,first_name,last_name,email,active,sys_created_on'
    return "/sys_user.do?JSONv2&sysparm_action=getRecords&sysparm_query=$([uri]::EscapeDataString($q))&sysparm_fields=$champs&sysparm_record_count=$Max"
}

# Comptes dont le nom correspond EXACTEMENT (mêmes mots, accents/casse/ordre
# ignorés) au nom saisi. Le champ « name » est prioritaire ; à défaut on
# reconstitue prénom + nom. La recherche « LIKE » ramène aussi des noms plus longs
# (ex. « MARTIN Paul-Henri » pour « Paul Martin ») : ce filtre les écarte.
function Select-Homonymes {
    param($Records, [string]$NomPrenom)
    $cible = (Get-NomTokens $NomPrenom) -join ' '
    if ($cible -eq '') { return @() }
    $res = @()
    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        $nom = [string]$r.name
        if ([string]::IsNullOrWhiteSpace($nom)) { $nom = "$($r.first_name) $($r.last_name)" }
        if (((Get-NomTokens $nom) -join ' ') -eq $cible) { $res += $r }
    }
    return $res   # appelants : @(Select-Homonymes ...)
}

# Présence d'homonymes = au moins deux comptes portent exactement ce nom
# (un seul = le compte du bénéficiaire lui-même).
function Test-PresenceHomonymes {
    param($Comptes)
    return (@($Comptes).Count -ge 2)
}

# Libellé « CP trouvé(s) » : les CP des comptes homonymes autres que celui
# communiqué dans la RITM, séparés par des virgules.
function Get-CpTrouves {
    param($Comptes, [string]$CpDemande)
    return @(@($Comptes) | ForEach-Object { [string]$_.user_name } |
             Where-Object { $_ -and $_ -ne $CpDemande })
}

