# ============================================================================
#  Persistance légère de l'état entre sessions (state.json) :
#   - Version             : version de l'app ayant écrit l'état (déclenche « Quoi de neuf »)
#   - NotesShownVersion   : version dont les notes ont déjà été montrées (anti-doublon)
#   - TutorialSeen        : tutoriel déjà vu (1er lancement)
#   - TutorialSeenVersion : version du CONTENU du tutoriel déjà vue
#   - PreviewCollapsed    : préférence « aperçu replié » (restaurée au lancement)
#   - AutoHideDisabled    : préférence « ne pas replier en bulle à la perte de focus »
# ============================================================================

function New-AppState {
    param([string]$Path)
    $state = [pscustomobject]@{
        Path                = $Path
        Version             = ''
        NotesShownVersion   = ''
        TutorialSeen        = $false
        TutorialSeenVersion = 0
        PreviewCollapsed    = $false
        AutoHideDisabled    = $false
    }
    try {
        if (Test-Path -LiteralPath $Path) {
            $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
            if ($raw) {
                $data = $raw | ConvertFrom-Json
                if ($data.version)             { $state.Version           = [string]$data.version }
                if ($data.notes_shown_version) { $state.NotesShownVersion = [string]$data.notes_shown_version }
                if ($null -ne $data.tutorial_seen)         { $state.TutorialSeen        = [bool]$data.tutorial_seen }
                if ($null -ne $data.tutorial_seen_version) { $state.TutorialSeenVersion = [int]$data.tutorial_seen_version }
                if ($null -ne $data.preview_collapsed)     { $state.PreviewCollapsed    = [bool]$data.preview_collapsed }
                if ($null -ne $data.auto_hide_disabled)    { $state.AutoHideDisabled    = [bool]$data.auto_hide_disabled }
            }
        }
    } catch {
        Write-AppLog "[ETAT] Lecture impossible ($($_.Exception.Message)) : état vierge."
    }
    return $state
}

function Save-AppState {
    param($State)
    $obj = [ordered]@{
        version               = [string]$State.Version
        notes_shown_version   = [string]$State.NotesShownVersion
        tutorial_seen         = [bool]$State.TutorialSeen
        tutorial_seen_version = [int]$State.TutorialSeenVersion
        preview_collapsed     = [bool]$State.PreviewCollapsed
        auto_hide_disabled    = [bool]$State.AutoHideDisabled
    }
    $tmp = "$($State.Path).tmp"
    try {
        ($obj | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $tmp -Encoding UTF8 -Force
        # Réessais : le client de synchro ou l'antivirus peut verrouiller la cible.
        $moved = $false
        for ($i = 0; $i -lt 4 -and -not $moved; $i++) {
            try { Move-Item -LiteralPath $tmp -Destination $State.Path -Force; $moved = $true }
            catch { Start-Sleep -Milliseconds 120 }
        }
        if (-not $moved) { Write-AppLog "[ETAT] Sauvegarde : verrou persistant, abandon de ce cycle." }
    } catch {
        Write-AppLog "[ETAT] Sauvegarde impossible : $($_.Exception.Message)"
    } finally {
        if (Test-Path -LiteralPath $tmp) { try { Remove-Item -LiteralPath $tmp -Force } catch { } }
    }
}

# Migration « comme une mise à jour » : si la version persistée diffère de la version
# courante, on note simplement la nouvelle version (Arrivée Collab n'a pas d'état
# volatile à purger). Sert de déclencheur au « Quoi de neuf ». Renvoie $true si montée.
function Invoke-AppVersionMigration {
    param($State, [string]$TargetVersion)
    $prev = [string]$State.Version
    if ($prev -eq $TargetVersion) { return $false }
    Write-AppLog ("[VERSION] Mise à jour détectée : '{0}' -> '{1}'." -f $(if ($prev) { $prev } else { '(aucune)' }), $TargetVersion)
    $State.Version = $TargetVersion
    Save-AppState $State
    return $true
}
