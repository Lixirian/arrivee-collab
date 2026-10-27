# Tests hors-ligne des unités pures d'Arrivée Collaborateur. Aucun GUI, aucun COM.
$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot '..\ArriveeCollab-PS\lib'
. (Join-Path $lib 'Common.ps1')
$script:fail = 0
function Assert($cond, $label) {
    if ($cond) { Write-Host "PASS $label" }
    else { Write-Host "FAIL $label" -ForegroundColor Red; $script:fail++ }
}

# --- Compare-AppVersion ---
Assert ((Compare-AppVersion '1.0.1' '1.0.0') -eq 1)  'compare : 1.0.1 > 1.0.0'
Assert ((Compare-AppVersion '1.0.0' '1.0.1') -eq -1) 'compare : 1.0.0 < 1.0.1'
Assert ((Compare-AppVersion '1.2.0' '1.2.0') -eq 0)  'compare : égalité'
Assert ((Compare-AppVersion '1.0.10' '1.0.2') -eq 1) 'compare : 1.0.10 > 1.0.2 (numérique)'
Assert ((Compare-AppVersion '2.0' '1.9.9') -eq 1)    'compare : longueurs différentes'

# --- Décompte « il y a X jours » -> date d'initialisation ---
Assert ((ConvertTo-NombreDeJours '0') -eq 0)      'jours : 0 accepte'
Assert ((ConvertTo-NombreDeJours '45') -eq 45)    'jours : entier accepte'
Assert ((ConvertTo-NombreDeJours ' 7 ') -eq 7)    'jours : espaces ignores'
Assert ($null -eq (ConvertTo-NombreDeJours ''))   'jours : vide -> null'
Assert ($null -eq (ConvertTo-NombreDeJours $null)) 'jours : null -> null'
Assert ($null -eq (ConvertTo-NombreDeJours 'abc')) 'jours : texte -> null'
Assert ($null -eq (ConvertTo-NombreDeJours '-3'))  'jours : negatif -> null'
Assert ($null -eq (ConvertTo-NombreDeJours '1,5')) 'jours : decimal -> null'
Assert ($null -eq (ConvertTo-NombreDeJours '99999')) 'jours : au-dela du max -> null'
Assert ($null -eq (ConvertTo-NombreDeJours '99999999999')) 'jours : trop grand pour un int -> null'
Assert ((ConvertTo-NombreDeJours '3650') -eq 3650) 'jours : max inclus'

$ref = [datetime]'2026-07-28'
Assert ((Get-DateDepuisJours 0 $ref)  -eq [datetime]'2026-07-28') 'date : 0 jour -> aujourd hui'
Assert ((Get-DateDepuisJours 1 $ref)  -eq [datetime]'2026-07-27') 'date : 1 jour -> veille'
Assert ((Get-DateDepuisJours 30 $ref) -eq [datetime]'2026-06-28') 'date : 30 jours -> mois precedent'
Assert ((Get-DateDepuisJours 209 $ref) -eq [datetime]'2025-12-31') 'date : bascule d annee'
Assert (((Get-DateDepuisJours 5 ([datetime]'2026-07-28 16:42:11')).TimeOfDay) -eq [timespan]::Zero) 'date : heure remise a minuit'
Assert ((Get-DateDepuisJours 1 ([datetime]'2024-03-01')) -eq [datetime]'2024-02-29') 'date : annee bissextile'

# --- Jours restants avant expiration (Mon-AD) -> date d'initialisation ---
Assert ($script:DureeValiditeMdp -eq 365) 'restants : validite par defaut 365 jours'
Assert ((Get-DateInitDepuisJoursRestants 365 -Reference $ref) -eq [datetime]'2026-07-28') 'restants : 365 -> initialise aujourd hui'
Assert ((Get-DateInitDepuisJoursRestants 364 -Reference $ref) -eq [datetime]'2026-07-27') 'restants : 364 -> veille'
Assert ((Get-DateInitDepuisJoursRestants 335 -Reference $ref) -eq [datetime]'2026-06-28') 'restants : 335 -> il y a 30 jours'
Assert ((Get-DateInitDepuisJoursRestants 0 -Reference $ref) -eq [datetime]'2025-07-28') 'restants : 0 -> il y a 365 jours'
Assert ((Get-DateInitDepuisJoursRestants 80 -DureeValidite 90 -Reference $ref) -eq [datetime]'2026-07-18') 'restants : duree de validite parametrable'
Assert ($null -eq (ConvertTo-NombreDeJours '366' -Max $script:DureeValiditeMdp)) 'restants : au-dela de la validite -> null'

# --- Homonymes (helpers purs de lib/Homonymes.ps1) ---
. (Join-Path $lib 'Homonymes.ps1')
Assert ((ConvertTo-NomNormalise '  Jérémy   Pasturel ') -eq 'JEREMY PASTUREL') 'homo : normalisation accents/casse/espaces'
Assert ((ConvertTo-NomNormalise "Jean-Christian D'Ors") -eq 'JEAN CHRISTIAN D ORS') 'homo : tirets et apostrophes'
Assert ((ConvertTo-NomNormalise '') -eq '') 'homo : vide'
Assert (((Get-NomTokens 'PASTUREL Jeremy') -join ' ') -eq ((Get-NomTokens 'Jérémy pasturel') -join ' ')) 'homo : ordre et accents ignores'
Assert ($null -eq (Get-RequeteHomonymes 'Jeremy')) 'homo : un seul mot -> pas de requete'
Assert ($null -eq (Get-RequeteHomonymes '   ')) 'homo : blanc -> pas de requete'
Assert ((Get-RequeteHomonymes 'Jeremy  PASTUREL') -eq 'nameLIKEJeremy^nameLIKEPASTUREL') 'homo : requete LIKE par mot'
Assert ((Get-RequeteHomonymes 'Jeremy^x=1 PASTUREL') -eq 'nameLIKEJeremy^nameLIKEx^nameLIKE1^nameLIKEPASTUREL') 'homo : caracteres de requete neutralises'
$u = Get-UrlJsonHomonymes 'Jeremy PASTUREL'
Assert ($u.StartsWith('/sys_user.do?JSONv2&sysparm_action=getRecords&sysparm_query=nameLIKEJeremy%5EnameLIKEPASTUREL&')) 'homo : URL JSONv2 encodee'
Assert ($u -match 'sysparm_fields=user_name,name,first_name,last_name,email,active,sys_created_on') 'homo : champs demandes'
$recs = @(
    [pscustomobject]@{ user_name = '7903222J'; name = 'PASTUREL Jeremy' }
    [pscustomobject]@{ user_name = 'PMGN1';    name = 'PASTUREL Jérémy' }
    [pscustomobject]@{ user_name = '1111111A'; name = 'PASTUREL Jeremy-Paul' }
    [pscustomobject]@{ user_name = '2222222B'; name = ''; first_name = 'jeremy'; last_name = 'pasturel' }
)
$m = @(Select-Homonymes $recs 'Jeremy PASTUREL')
Assert ($m.Count -eq 3) 'homo : correspondances exactes (accents, ordre, prenom+nom de repli)'
Assert (-not (@($m.user_name) -contains '1111111A')) 'homo : nom compose different ecarte'
Assert (Test-PresenceHomonymes $m) 'homo : 3 comptes -> homonymes'
Assert (-not (Test-PresenceHomonymes @($recs[0]))) 'homo : 1 compte -> pas d homonyme'
Assert (-not (Test-PresenceHomonymes @())) 'homo : 0 compte -> pas d homonyme'
Assert ((@(Select-Homonymes $recs 'Paul Martin')).Count -eq 0) 'homo : aucun compte'
Assert (((Get-CpTrouves $m '7903222J') -join ', ') -eq 'PMGN1, 2222222B') 'homo : CP trouves = autres que le demande'

# --- State round-trip + migration ---
. (Join-Path $lib 'State.ps1')
$tmpState = Join-Path $env:TEMP ("ac_state_test_" + [guid]::NewGuid().ToString('N') + ".json")
try {
    $s = New-AppState $tmpState
    Assert ($s.Version -eq '' -and -not $s.TutorialSeen) 'state : état vierge par défaut'
    Assert ($s.PreviewCollapsed -eq $false) 'state : PreviewCollapsed faux par défaut'

    $s.Version = '1.0.0'; $s.TutorialSeen = $true; $s.TutorialSeenVersion = 2; $s.NotesShownVersion = '1.0.0'; $s.PreviewCollapsed = $true
    Save-AppState $s
    Assert (Test-Path $tmpState) 'state : fichier écrit'

    $s2 = New-AppState $tmpState
    Assert ($s2.Version -eq '1.0.0')        'state : Version relue'
    Assert ($s2.TutorialSeen -eq $true)     'state : TutorialSeen relu'
    Assert ($s2.TutorialSeenVersion -eq 2)  'state : TutorialSeenVersion relu'
    Assert ($s2.NotesShownVersion -eq '1.0.0') 'state : NotesShownVersion relue'
    Assert ($s2.PreviewCollapsed -eq $true) 'state : PreviewCollapsed relu'

    $migrated = Invoke-AppVersionMigration $s2 '1.1.0'
    Assert ($migrated -eq $true)            'migration : montée détectée'
    Assert ($s2.Version -eq '1.1.0')        'migration : version mise à jour'
    $noop = Invoke-AppVersionMigration $s2 '1.1.0'
    Assert ($noop -eq $false)               'migration : no-op si même version'
} finally {
    if (Test-Path $tmpState) { Remove-Item $tmpState -Force -ErrorAction SilentlyContinue }
}

# --- Update : manifeste, tri de versions, notes hors-ligne ---
. (Join-Path $lib 'Update.ps1')
$tmpRoot = Join-Path $env:TEMP ("ac_upd_test_" + [guid]::NewGuid().ToString('N'))
$dist = Join-Path $tmpRoot 'dist'; $app = Join-Path $tmpRoot 'app'
New-Item -ItemType Directory -Path $dist, $app -Force | Out-Null
try {
    # Contexte minimal simulé
    $ctx = @{ Config = @{ UpdateDir = $dist }; DataDir = $tmpRoot; AppRoot = $app; UpdateAvailable = $null }

    # latest.json + zip dans le dossier de distribution
    '{ "version": "1.2.0", "zip": "Arrivee-Collab_version1.2.0.zip", "notes": ["Note A", "Note B"] }' |
        Out-File -LiteralPath (Join-Path $dist 'latest.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dist 'Arrivee-Collab_version1.2.0.zip') -Value 'zip'

    $m = Get-LatestManifest $ctx
    Assert ($m.Version -eq '1.2.0')                 'update : manifeste version'
    Assert ($m.Zip -eq 'Arrivee-Collab_version1.2.0.zip') 'update : manifeste zip'
    Assert (@($m.Notes).Count -eq 2)                'update : manifeste 2 notes'
    Assert ($m.Source -eq 'dossier')                'update : source dossier (repli)'

    # ConvertFrom-LatestJson (parse pur, partage GitHub/dossier)
    $p = ConvertFrom-LatestJson '{ "version": "2.0.0", "notes": ["N"] }'
    Assert ($p.Version -eq '2.0.0' -and $p.Zip -eq 'Arrivee-Collab_version2.0.0.zip') 'update : parse -> zip par defaut'
    Assert ($null -eq (ConvertFrom-LatestJson '{ "zip": "x.zip" }')) 'update : parse sans version -> null'
    Assert ($null -eq (ConvertFrom-LatestJson 'pas du json'))        'update : parse json invalide -> null'

    # Get-UpdateRawBase : absent -> null ; configure -> URL raw
    Assert ($null -eq (Get-UpdateRawBase $ctx)) 'update : pas de repo github -> base null'
    $ctxGh = @{ Config = @{ UpdateRepo = 'user/repo'; UpdateBranch = '' } }
    Assert ((Get-UpdateRawBase $ctxGh) -eq 'https://raw.githubusercontent.com/user/repo/main') 'update : base raw (branche main par defaut)'

    # Tri numérique de versions
    Assert ((Convert-VersionSortKey '1.10.0') -gt (Convert-VersionSortKey '1.9.0')) 'update : tri 1.10 > 1.9'

    # releases.json EMBARQUÉ (dans AppRoot)
    '{ "1.0.0": ["Initiale"], "1.1.0": ["Ajout X"], "1.2.0": ["Note A", "Note B"] }' |
        Out-File -LiteralPath (Join-Path $app 'releases.json') -Encoding UTF8
    $rec = Get-RecentReleaseNotes $ctx 2
    Assert (@($rec).Count -eq 2 -and $rec[0].Version -eq '1.2.0') 'update : 2 versions recentes, plus recente en tete'
    $between = Get-ReleaseNotesBetween $ctx '1.0.0' '1.2.0' 25
    Assert (@($between).Count -eq 2 -and $between.Version -contains '1.1.0' -and $between.Version -contains '1.2.0') 'update : notes entre 1.0.0(exclu) et 1.2.0'
    Assert (-not ($between.Version -contains '1.0.0')) 'update : version de depart exclue'

    # Invoke-UpdateCheck : version distante 1.2.0 > courante 1.1.0 -> UpdateAvailable pose
    $ctx.Config.Version = '1.1.0'
    Invoke-UpdateCheck $ctx
    Assert ($null -ne $ctx.UpdateAvailable -and $ctx.UpdateAvailable.Version -eq '1.2.0') 'update : UpdateAvailable pose si plus recent'

    # Pas de MAJ si courante == distante
    $ctx.Config.Version = '1.2.0'
    Invoke-UpdateCheck $ctx
    Assert ($null -eq $ctx.UpdateAvailable) 'update : pas de MAJ si deja a jour'

    # Zip annonce mais absent -> pas de MAJ
    $ctx.Config.Version = '1.1.0'
    Remove-Item -LiteralPath (Join-Path $dist 'Arrivee-Collab_version1.2.0.zip') -Force
    Invoke-UpdateCheck $ctx
    Assert ($null -eq $ctx.UpdateAvailable) 'update : pas de MAJ si zip absent'
} finally {
    if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Tutoriel : étapes + décision d'affichage ---
. (Join-Path $lib 'Tutorial.ps1')
$steps = @(Get-TutorialSteps @{ })
Assert (@($steps).Count -eq 15) 'tuto : 15 etapes'
Assert (@($steps | Where-Object { -not $_.Title }).Count -eq 0) 'tuto : chaque etape a un titre'
Assert (@($steps | Where-Object { -not $_.Text }).Count -eq 0)  'tuto : chaque etape a un texte'
Assert (@($steps | Where-Object { -not $_.Icon }).Count -eq 0)  'tuto : chaque etape a une icone'
Assert ($null -ne $steps[1].Target) 'tuto : etape 2 a une cible (scriptblock)'

# Test-TutorialDue : pas vu -> du ; vu version courante -> pas du ; contenu plus recent -> du
Assert (Test-TutorialDue @{ TutorialSeenVersion = 0 } 1) 'tuto : jamais vu -> affiche'
Assert (-not (Test-TutorialDue @{ TutorialSeenVersion = 1 } 1)) 'tuto : deja vu version courante -> pas affiche'
Assert (Test-TutorialDue @{ TutorialSeenVersion = 1 } 2) 'tuto : contenu plus recent -> reaffiche'

# --- Should-AutoHide (décision de masquage auto) ---
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234) -eq $true)  'autohide : autre processus => masquer'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 1234 -OwnPid 1234) -eq $false) 'autohide : meme processus (dialogue/calendrier) => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $true  -ForegroundPid 4321 -OwnPid 1234) -eq $false) 'autohide : flux .msg supprime => non'
Assert ((Should-AutoHide -AppHidden $true  -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234) -eq $false) 'autohide : deja masquee => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $true  -Suppressed $false -ForegroundPid 4321 -OwnPid 1234) -eq $false) 'autohide : animation en cours => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 0    -OwnPid 1234) -eq $false) 'autohide : pas de fenetre premier plan => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234 -Disabled $true)  -eq $false) 'autohide : option desactivee => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234 -Disabled $false) -eq $true)  'autohide : option active => masquer'

Write-Host ""
if ($script:fail -eq 0) { Write-Host "TOUS LES TESTS PASSENT" -ForegroundColor Green }
else { Write-Host "$($script:fail) ÉCHEC(S)" -ForegroundColor Red; exit 1 }
