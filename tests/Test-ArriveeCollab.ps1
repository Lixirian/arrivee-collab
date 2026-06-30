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

# --- State round-trip + migration ---
. (Join-Path $lib 'State.ps1')
$tmpState = Join-Path $env:TEMP ("ac_state_test_" + [guid]::NewGuid().ToString('N') + ".json")
try {
    $s = New-AppState $tmpState
    Assert ($s.Version -eq '' -and -not $s.TutorialSeen) 'state : état vierge par défaut'

    $s.Version = '1.0.0'; $s.TutorialSeen = $true; $s.TutorialSeenVersion = 2; $s.NotesShownVersion = '1.0.0'
    Save-AppState $s
    Assert (Test-Path $tmpState) 'state : fichier écrit'

    $s2 = New-AppState $tmpState
    Assert ($s2.Version -eq '1.0.0')        'state : Version relue'
    Assert ($s2.TutorialSeen -eq $true)     'state : TutorialSeen relu'
    Assert ($s2.TutorialSeenVersion -eq 2)  'state : TutorialSeenVersion relu'
    Assert ($s2.NotesShownVersion -eq '1.0.0') 'state : NotesShownVersion relue'

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
Assert (@($steps).Count -eq 13) 'tuto : 13 etapes'
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

Write-Host ""
if ($script:fail -eq 0) { Write-Host "TOUS LES TESTS PASSENT" -ForegroundColor Green }
else { Write-Host "$($script:fail) ÉCHEC(S)" -ForegroundColor Red; exit 1 }
