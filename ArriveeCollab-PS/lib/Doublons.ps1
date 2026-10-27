# ============================================================================
#  Vérification des doublons de demande dans ServiceNow (table sc_task) — helpers
#  PURS (testés hors-GUI dans tests/Test-ArriveeCollab.ps1). La requête est
#  exécutée par la page ServiceNow cachée (lib/SnowPage.ps1).
#
#  Doublon = une AUTRE RITM (que celle traitée) dont une tâche « Support Site… » ou
#  « Recherche des nouveaux gestionnaires » porte le même bénéficiaire et est ENCORE
#  EN COURS : deux demandes simultanées pour le même besoin. Une tâche réalisée,
#  fermée ou annulée n'est pas un doublon (arrivée précédente, changement de statut…).
#  Utilise ConvertTo-NomNormalise / Get-NomTokens de lib/Homonymes.ps1.
# ============================================================================

# Filtre de la liste des tâches d'arrivée (identique au lien de l'équipe).
$script:FiltreTachesArrivee = 'short_descriptionSTARTSWITHSupport Site^ORshort_descriptionSTARTSWITHRecherche des nouveaux gestionnaires'

# Champs qui ne désignent PAS le bénéficiaire (demandeur, assigné, auteur…) : un nom
# qui n'y figure que là ne fait pas un doublon.
$script:ChampsNonBeneficiaire = '^(opened_by|assigned_to|closed_by|resolved_by|sys_created_by|sys_updated_by|requested_by|caller_id|watch_list|work_notes_list|approval|u_demandeur.*|u_requester.*)$'

# Filtre ServiceNow : tâches d'arrivée ACTIVES (non clôturées) contenant le nom
# (recherche texte, comme le champ « Rechercher » de la liste), les plus récentes
# d'abord. $null si moins de deux mots. Les caractères de syntaxe des requêtes (^ =)
# sont neutralisés.
function Get-RequeteDoublons {
    param([string]$NomPrenom)
    if ([string]::IsNullOrWhiteSpace($NomPrenom)) { return $null }
    $mots = @(($NomPrenom -replace '[\^=]', ' ').Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($mots.Count -lt 2) { return $null }
    return "$($script:FiltreTachesArrivee)^active=true^123TEXTQUERY321=$($mots -join ' ')^ORDERBYDESCsys_created_on"
}

# URL relative (same-origin) de la requête JSONv2 sur sc_task. Tous les champs sont
# demandés avec leur libellé (displayvalue=all) : le champ « Bénéficiaire » est ainsi
# reconnu par sa valeur, quel que soit son nom technique.
function Get-UrlJsonDoublons {
    param([string]$NomPrenom, [int]$Max = 50)
    $q = Get-RequeteDoublons $NomPrenom
    if (-not $q) { return $null }
    return "/sc_task.do?JSONv2&sysparm_action=getRecords&sysparm_query=$([uri]::EscapeDataString($q))&displayvalue=all&sysparm_record_count=$Max"
}

# Normalise un numéro de RITM saisi (« ritm0123456 » -> « RITM0123456 »).
function ConvertTo-NumeroRitm {
    param([string]$Texte)
    if ([string]::IsNullOrWhiteSpace($Texte)) { return '' }
    return ($Texte -replace '\s', '').ToUpperInvariant()
}

# Valeur affichée d'un champ (dv_<champ> si présent, sinon la valeur brute).
function Get-ValeurAffichee {
    param($Record, [string]$Champ)
    $dv = $Record.PSObject.Properties["dv_$Champ"]
    if ($dv -and -not [string]::IsNullOrWhiteSpace([string]$dv.Value)) { return [string]$dv.Value }
    $p = $Record.PSObject.Properties[$Champ]
    if ($p) { return [string]$p.Value }
    return ''
}

# Champs de la tâche dont la valeur affichée est EXACTEMENT le nom saisi (accents,
# casse et ordre ignorés), hors champs « non bénéficiaire ».
function Get-ChampsBeneficiaire {
    param($Record, [string]$NomPrenom)
    $cible = (Get-NomTokens $NomPrenom) -join ' '
    if ($cible -eq '') { return @() }
    $res = @()
    foreach ($p in $Record.PSObject.Properties) {
        $champ = if ($p.Name.StartsWith('dv_')) { $p.Name.Substring(3) } else { $p.Name }
        if ($champ -match $script:ChampsNonBeneficiaire) { continue }
        if ($res -contains $champ) { continue }
        $v = [string]$p.Value
        if ($v.Length -lt 3 -or $v.Length -gt 120) { continue }
        if (((Get-NomTokens $v) -join ' ') -eq $cible) { $res += $champ }
    }
    return $res
}

# Tâche ENCORE EN COURS ? (sc_task : 3 = Fermé réalisé, 4 = Fermé incomplet,
# 7 = Fermé ignoré ; « active » = false une fois clôturée ; libellé en repli.)
# Réalisée, fermée ou annulée => pas un doublon.
function Test-TacheEnCours {
    param($Record)
    if ([string]$Record.active -eq 'false') { return $false }
    if ([string]$Record.state -in @('3', '4', '7')) { return $false }
    return -not ((Get-ValeurAffichee $Record 'state') -match '(?i)r[ée]alis|ferm|clos|cl[oô]tur|annul|incompl|ignor|skip|cancel|complete')
}

# Motifs de la demande traitée : descriptions (normalisées) de SES tâches présentes
# dans les résultats (ex. « SUPPORT SITE ARRIVEE »). Vide si elles n'y figurent pas.
function Get-MotifsRitmCourante {
    param($Records, [string]$NomPrenom, [string]$RitmCourante)
    $ritmCourante = ConvertTo-NumeroRitm $RitmCourante
    $motifs = @()
    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        if ((ConvertTo-NumeroRitm (Get-ValeurAffichee $r 'request_item')) -ne $ritmCourante) { continue }
        $m = ConvertTo-NomNormalise (Get-ValeurAffichee $r 'short_description')
        if ($m -and $motifs -notcontains $m) { $motifs += $m }
    }
    return $motifs
}

# Tâches en doublon : même bénéficiaire, autre RITM que celle traitée, encore en
# cours, et MÊME MOTIF (même description de tâche) que la demande traitée. Si les
# tâches de la demande traitée ne figurent pas dans les résultats (motif inconnu),
# toutes les demandes en cours du bénéficiaire sont retenues (prudence).
# Renvoie des objets @{ Ritm; Tache; Statut; Description; Ouverte; Fermee; Champs }.
function Select-Doublons {
    param($Records, [string]$NomPrenom, [string]$RitmCourante)
    $ritmCourante = ConvertTo-NumeroRitm $RitmCourante
    $motifs = @(Get-MotifsRitmCourante $Records $NomPrenom $RitmCourante)
    $res = @()
    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        $ritm = ConvertTo-NumeroRitm (Get-ValeurAffichee $r 'request_item')
        if (-not $ritm -or $ritm -notmatch '^RITM') { continue }
        if ($ritm -eq $ritmCourante) { continue }
        if (-not (Test-TacheEnCours $r)) { continue }
        if ($motifs.Count -gt 0 -and $motifs -notcontains (ConvertTo-NomNormalise (Get-ValeurAffichee $r 'short_description'))) { continue }
        $champs = @(Get-ChampsBeneficiaire $r $NomPrenom)
        if ($champs.Count -eq 0) { continue }
        $res += [pscustomobject]@{
            Ritm        = $ritm
            Tache       = Get-ValeurAffichee $r 'number'
            Statut      = Get-ValeurAffichee $r 'state'
            Description = Get-ValeurAffichee $r 'short_description'
            Ouverte     = Get-ValeurAffichee $r 'opened_at'
            Fermee      = Get-ValeurAffichee $r 'closed_at'
            Champs      = ($champs -join ',')
        }
    }
    return $res   # appelants : @(Select-Doublons ...)
}

# RITM distinctes parmi les doublons, dans l'ordre (les plus récentes d'abord).
function Get-RitmsDoublons {
    param($Doublons)
    $vu = @()
    foreach ($d in @($Doublons)) { if ($d -and $vu -notcontains $d.Ritm) { $vu += $d.Ritm } }
    return $vu
}
