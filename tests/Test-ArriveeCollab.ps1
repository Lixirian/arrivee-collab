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

Write-Host ""
if ($script:fail -eq 0) { Write-Host "TOUS LES TESTS PASSENT" -ForegroundColor Green }
else { Write-Host "$($script:fail) ÉCHEC(S)" -ForegroundColor Red; exit 1 }
