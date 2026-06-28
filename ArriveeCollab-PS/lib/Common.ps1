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
