# Plan A — Fondation & Distribution — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modulariser l'outil Arrivée Collaborateur, séparer exécution (`%LOCALAPPDATA%`) et données persistantes, et le rendre distribuable/versionnable via un dossier OneDrive (build + bootstrap), tout en restant fonctionnellement identique.

**Architecture:** On déplace le code source dans `ArriveeCollab-PS/`, on extrait la version (`config.ps1`), le changelog (`releases.json`), les utilitaires (`lib/Common.ps1`, `lib/State.ps1`). Le script principal source ces fichiers, écrit ses sorties dans `%LOCALAPPDATA%\Arrivee-Collab\data\`, et est lancé via un bootstrap posé sur OneDrive qui installe une copie locale puis lance l'app. Le `build-zip.ps1` produit le zip versionné + `latest.json` + le kit de distribution.

**Tech Stack:** PowerShell 5.x, Windows Forms, VBScript (lanceurs), `System.IO.Compression` (zip), git + gh (déjà configurés ; remote privé `origin` = `Lixirian/arrivee-collab`).

**Périmètre :** Ce Plan A couvre les volets 1 (versionning/build) et 2 (distribution/bootstrap) du spec, plus la fondation commune (chemins, état). Le Plan B (MAJ in-app + tutoriel) suivra, écrit après exécution du Plan A.

## Global Constraints

- **Langue** : tout le code, commentaires et UI en français, accents corrects (UTF-8). Les fichiers `.vbs` sont écrits en **ASCII** (comme l'existant).
- **Nommage** : fonctions métier en verbe français (`Creer-`, `Attendre-`) — existant inchangé ; nouvelles fonctions d'infrastructure en verbe anglais standard PowerShell (`Get-`, `New-`, `Save-`, `Invoke-`, `Compare-`, `Write-`, `Initialize-`) comme le projet de référence SNOW.
- **Données d'exécution** : `%LOCALAPPDATA%\Arrivee-Collab\` (jamais dans le dossier app, écrasé aux MAJ). Sorties métier sous `...\data\`.
- **Lancement** : `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden` (le `-STA` est requis pour le presse-papiers WinForms).
- **Version de départ** : `1.0.0`. `UpdateDir` = `Documents\TAM\Logiciels Dev\Arrivee collab`.
- **Git** : commits fréquents. Travailler sur la branche `master` (repo perso privé). Messages de commit en français.
- **Pas de framework de test** : tests des unités pures via un script maison `tests/Test-ArriveeCollab.ps1` avec une fonction `Assert` (pattern SNOW `Test-SnowDone.ps1`). Les éléments GUI/COM sont validés manuellement.

---

### Task 1 : Déménagement de la structure vers `ArriveeCollab-PS/`

**Files:**
- Move: `arrivee collab.ps1` → `ArriveeCollab-PS/arrivee collab.ps1`
- Move: `image-arrivee-collab.ico` → `ArriveeCollab-PS/image-arrivee-collab.ico`
- Move: `Resources/` → `ArriveeCollab-PS/Resources/`

**Interfaces:**
- Produces: dossier `ArriveeCollab-PS/` contenant le script principal + ressources. Toutes les tâches suivantes y créent leurs fichiers.

- [ ] **Step 1: Créer le dossier source et déplacer les fichiers via git**

```bash
cd "C:/Users/Lixirian/SynologyDrive/ProjetDev/Arrivee collab"
mkdir -p ArriveeCollab-PS
git mv "arrivee collab.ps1" "ArriveeCollab-PS/arrivee collab.ps1"
git mv "image-arrivee-collab.ico" "ArriveeCollab-PS/image-arrivee-collab.ico"
git mv "Resources" "ArriveeCollab-PS/Resources"
```

- [ ] **Step 2: Vérifier le déplacement**

Run: `git status --short`
Expected: lignes `R  arrivee collab.ps1 -> ArriveeCollab-PS/arrivee collab.ps1` (et idem pour l'icône + Resources). Aucune perte de fichier.

- [ ] **Step 3: Vérification manuelle — l'app se lance encore depuis le nouvel emplacement**

Run: `powershell.exe -ExecutionPolicy Bypass -NoProfile -File "ArriveeCollab-PS/arrivee collab.ps1"`
Expected: la fenêtre « Arrivée Collaborateur » s'ouvre, les 2 images s'affichent dans l'en-tête (« Images détectées » en vert). Fermer la fenêtre.
Note : à ce stade l'app crée encore `Mot de passe/` et `Archive message/` **dans `ArriveeCollab-PS/`** (corrigé en Task 5). C'est attendu.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: deplace le code source dans ArriveeCollab-PS/"
```

---

### Task 2 : `config.ps1` + `releases.json`

**Files:**
- Create: `ArriveeCollab-PS/config.ps1`
- Create: `ArriveeCollab-PS/releases.json`

**Interfaces:**
- Produces: variable globale `$Config` (hashtable) avec `.Version` (string), `.UpdateDir` (string), `.UpdateCheckIntervalSec` (int). `releases.json` : objet JSON `{ "<version>": [ "<note>", ... ] }`. Consommés par `build-zip.ps1`, `lib/Update.ps1` (Plan B), et le script principal.

- [ ] **Step 1: Créer `config.ps1`**

```powershell
# ============================================================================
#  Configuration centrale de l'outil Arrivee Collaborateur.
#  Un seul fichier a editer pour changer de version ou de dossier de MAJ.
# ============================================================================

$Config = @{
    # Version de l'application. A INCREMENTER a chaque build (build-zip.ps1).
    # Au lancement, si elle differe de la version persistee dans state.json,
    # l'app declenche le dialogue « Quoi de neuf » (cf. Plan B).
    Version                = '1.0.0'

    # Dossier de DISTRIBUTION OneDrive contenant latest.json + les zips versionnes.
    # AUCUNE API, AUCUN jeton : simple lecture de fichiers (lecture seule cote equipe).
    #  - Relatif (ex. 'Documents\...') : cherche sous chaque racine OneDrive connue.
    #  - Absolu / UNC accepte aussi.
    #  - Vide = repli sur dist_path.txt ecrit par le bootstrap.
    UpdateDir              = 'Documents\TAM\Logiciels Dev\Arrivee collab'

    # Cadence de verification d'une nouvelle version (SECONDES ; minimum 10).
    # Production : 300 (5 min). Pour tester rapidement, descendre a 10.
    UpdateCheckIntervalSec = 300
}
```

- [ ] **Step 2: Créer `releases.json`**

```json
{
    "1.0.0": [
        "Premiere version distribuee : versionning, mise a jour automatique depuis OneDrive et tutoriel interactif."
    ]
}
```

- [ ] **Step 3: Vérifier que les deux fichiers sont lisibles**

Run: `powershell -NoProfile -Command ". './ArriveeCollab-PS/config.ps1'; $Config.Version; (Get-Content './ArriveeCollab-PS/releases.json' -Raw | ConvertFrom-Json).'1.0.0'[0]"`
Expected: affiche `1.0.0` puis la note de version (pas d'erreur de parsing).

- [ ] **Step 4: Commit**

```bash
git add ArriveeCollab-PS/config.ps1 ArriveeCollab-PS/releases.json
git commit -m "feat: ajoute config.ps1 (version + UpdateDir) et releases.json"
```

---

### Task 3 : `lib/Common.ps1` (log, chemins, comparaison de versions)

**Files:**
- Create: `ArriveeCollab-PS/lib/Common.ps1`
- Test: `tests/Test-ArriveeCollab.ps1`

**Interfaces:**
- Produces:
  - `Get-AppDataDir() : string` — `%LOCALAPPDATA%\Arrivee-Collab` (créé au besoin).
  - `Get-AppWorkDir([string]$DataDir) : string` — `<DataDir>\data` (créé au besoin).
  - `Compare-AppVersion([string]$A, [string]$B) : int` — -1 / 0 / 1, comparaison numérique « x.y.z ».
  - `Initialize-AppLog([string]$Path)` — fixe le fichier log + écrit l'en-tête.
  - `Write-AppLog([string]$Message)` — ajoute une ligne horodatée au log (fichier seulement).

- [ ] **Step 1: Écrire le test qui échoue (`Compare-AppVersion`)**

Créer `tests/Test-ArriveeCollab.ps1` :

```powershell
# Tests hors-ligne des unites pures d'Arrivee Collaborateur. Aucun GUI, aucun COM.
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
Assert ((Compare-AppVersion '1.2.0' '1.2.0') -eq 0)  'compare : egalite'
Assert ((Compare-AppVersion '1.0.10' '1.0.2') -eq 1) 'compare : 1.0.10 > 1.0.2 (numerique)'
Assert ((Compare-AppVersion '2.0' '1.9.9') -eq 1)    'compare : longueurs differentes'

Write-Host ""
if ($script:fail -eq 0) { Write-Host "TOUS LES TESTS PASSENT" -ForegroundColor Green }
else { Write-Host "$($script:fail) ECHEC(S)" -ForegroundColor Red; exit 1 }
```

- [ ] **Step 2: Lancer le test pour vérifier qu'il échoue**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: ÉCHEC — erreur « Common.ps1 introuvable » ou « Compare-AppVersion n'est pas reconnu » (le fichier `lib/Common.ps1` n'existe pas encore).

- [ ] **Step 3: Écrire `lib/Common.ps1`**

```powershell
# ============================================================================
#  Utilitaires transverses : dossiers de donnees (hors zone synchronisee) et logs.
# ============================================================================

# Dossier racine des donnees d'execution : %LOCALAPPDATA%\Arrivee-Collab.
# Les donnees (etat, logs, sorties metier) NE vivent PAS dans le dossier de l'app :
# ce dernier est ecrase a chaque mise a jour. On les isole donc ici.
function Get-AppDataDir {
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = $env:APPDATA }
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    $dir = Join-Path $base 'Arrivee-Collab'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# Sous-dossier des donnees metier PERSISTANTES (survit aux MAJ) : <DataDir>\data.
# Contient « Mot de passe\ », « Archive message\ » et le .msg temporaire.
function Get-AppWorkDir {
    param([string]$DataDir)
    $dir = Join-Path $DataDir 'data'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

# Comparaison NUMERIQUE de deux versions "x.y.z" (1.0.10 > 1.0.2). Renvoie -1 / 0 / 1.
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

# --- Journalisation (fichier uniquement, jamais la console) ---
$script:AppLogPath = $null

function Initialize-AppLog {
    param([string]$Path)
    $script:AppLogPath = $Path
    try {
        $header = "================ DEMARRAGE ARRIVEE COLLAB ($(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) ================"
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
```

- [ ] **Step 4: Lancer le test pour vérifier qu'il passe**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: `PASS` sur les 5 assertions, puis `TOUS LES TESTS PASSENT`.

- [ ] **Step 5: Commit**

```bash
git add ArriveeCollab-PS/lib/Common.ps1 tests/Test-ArriveeCollab.ps1
git commit -m "feat: lib/Common.ps1 (chemins data, log, Compare-AppVersion) + tests"
```

---

### Task 4 : `lib/State.ps1` (persistance d'état + migration de version)

**Files:**
- Create: `ArriveeCollab-PS/lib/State.ps1`
- Modify: `tests/Test-ArriveeCollab.ps1` (ajouter les assertions d'état)

**Interfaces:**
- Consumes: `Write-AppLog` (de `lib/Common.ps1`).
- Produces:
  - `New-AppState([string]$Path) : pscustomobject` — propriétés `Path`, `Version` (string), `NotesShownVersion` (string), `TutorialSeen` (bool), `TutorialSeenVersion` (int).
  - `Save-AppState($State)` — écrit `state.json` (atomique `.tmp` + `Move-Item` avec retries).
  - `Invoke-AppVersionMigration($State, [string]$TargetVersion) : bool` — met `State.Version = TargetVersion` si différent, sauvegarde, renvoie `$true` si montée.

- [ ] **Step 1: Écrire les tests qui échouent (round-trip + migration)**

Ajouter à la fin de `tests/Test-ArriveeCollab.ps1`, **avant** le bloc de bilan final (`Write-Host ""` … `if ($script:fail -eq 0)`) :

```powershell
# --- State round-trip + migration ---
. (Join-Path $lib 'State.ps1')
$tmpState = Join-Path $env:TEMP ("ac_state_test_" + [guid]::NewGuid().ToString('N') + ".json")
try {
    $s = New-AppState $tmpState
    Assert ($s.Version -eq '' -and -not $s.TutorialSeen) 'state : etat vierge par defaut'

    $s.Version = '1.0.0'; $s.TutorialSeen = $true; $s.TutorialSeenVersion = 2; $s.NotesShownVersion = '1.0.0'
    Save-AppState $s
    Assert (Test-Path $tmpState) 'state : fichier ecrit'

    $s2 = New-AppState $tmpState
    Assert ($s2.Version -eq '1.0.0')        'state : Version relue'
    Assert ($s2.TutorialSeen -eq $true)     'state : TutorialSeen relu'
    Assert ($s2.TutorialSeenVersion -eq 2)  'state : TutorialSeenVersion relu'

    $migrated = Invoke-AppVersionMigration $s2 '1.1.0'
    Assert ($migrated -eq $true)            'migration : montee detectee'
    Assert ($s2.Version -eq '1.1.0')        'migration : version mise a jour'
    $noop = Invoke-AppVersionMigration $s2 '1.1.0'
    Assert ($noop -eq $false)               'migration : no-op si meme version'
} finally {
    if (Test-Path $tmpState) { Remove-Item $tmpState -Force -ErrorAction SilentlyContinue }
}
```

- [ ] **Step 2: Lancer le test pour vérifier qu'il échoue**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: ÉCHEC — « State.ps1 introuvable » ou `New-AppState` non reconnu.

- [ ] **Step 3: Écrire `lib/State.ps1`**

```powershell
# ============================================================================
#  Persistance legere de l'etat entre sessions (state.json) :
#   - Version             : version de l'app ayant ecrit l'etat (declenche « Quoi de neuf »)
#   - NotesShownVersion   : version dont les notes ont deja ete montrees (anti-doublon)
#   - TutorialSeen        : tutoriel deja vu (1er lancement)
#   - TutorialSeenVersion : version du CONTENU du tutoriel deja vue
# ============================================================================

function New-AppState {
    param([string]$Path)
    $state = [pscustomobject]@{
        Path                = $Path
        Version             = ''
        NotesShownVersion   = ''
        TutorialSeen        = $false
        TutorialSeenVersion = 0
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
            }
        }
    } catch {
        Write-AppLog "[ETAT] Lecture impossible ($($_.Exception.Message)) : etat vierge."
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
    }
    $tmp = "$($State.Path).tmp"
    try {
        ($obj | ConvertTo-Json -Depth 5) | Out-File -LiteralPath $tmp -Encoding UTF8 -Force
        # Reessais : le client de synchro ou l'antivirus peut verrouiller la cible.
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

# Migration "comme une mise a jour" : si la version persistee differe de la version
# courante, on note simplement la nouvelle version (Arrivee Collab n'a pas d'etat
# volatile a purger). Sert de declencheur au « Quoi de neuf ». Renvoie $true si montee.
function Invoke-AppVersionMigration {
    param($State, [string]$TargetVersion)
    $prev = [string]$State.Version
    if ($prev -eq $TargetVersion) { return $false }
    Write-AppLog ("[VERSION] Mise a jour detectee : '{0}' -> '{1}'." -f $(if ($prev) { $prev } else { '(aucune)' }), $TargetVersion)
    $State.Version = $TargetVersion
    Save-AppState $State
    return $true
}
```

- [ ] **Step 4: Lancer le test pour vérifier qu'il passe**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: toutes les assertions `PASS`, `TOUS LES TESTS PASSENT`.

- [ ] **Step 5: Commit**

```bash
git add ArriveeCollab-PS/lib/State.ps1 tests/Test-ArriveeCollab.ps1
git commit -m "feat: lib/State.ps1 (state.json + migration de version) + tests"
```

---

### Task 5 : Adapter le script principal (sourcing, chemins app/data, retrait du VBS inline)

**Files:**
- Modify: `ArriveeCollab-PS/arrivee collab.ps1`

**Interfaces:**
- Consumes: `$Config` (config.ps1), `Get-AppDataDir`, `Get-AppWorkDir`, `Initialize-AppLog`, `Write-AppLog` (Common.ps1), `New-AppState`, `Invoke-AppVersionMigration` (State.ps1).
- Produces: variable `$global:Ctx` (hashtable `Config`, `AppRoot`, `DataDir`, `WorkDir`, `State`, `UpdateAvailable`) consommée par le Plan B. Sorties métier écrites sous `$workDir`.

**Contexte :** `$baseDir` (résolu actuellement lignes ~136-148) reste le **dossier de l'app** (ressources, icône, `Resources/`). On ajoute `$dataDir` / `$workDir` et on redirige **uniquement les sorties** (mot de passe, archive, .msg) vers `$workDir`. Le bloc de génération du VBS inline (lignes ~75-134) est supprimé : le lancement passe désormais par le bootstrap (Task 7).

- [ ] **Step 1: Supprimer le bloc de génération du VBS inline**

Dans `ArriveeCollab-PS/arrivee collab.ps1`, supprimer entièrement le bloc commençant à `# --- Lanceur VBS portable sans élévation pour l'arrivée collab ---` (vers ligne 75) et finissant juste avant `# Détermination du bon dossier de base` (vers ligne 135). C'est tout le code qui calcule `$mainScriptName`, `$vbsContent`, écrit le `.vbs` et affiche les `Write-Host`.

- [ ] **Step 2: Sourcer config + lib et résoudre les chemins data, juste après la résolution de `$baseDir`**

Repérer le bloc existant (inchangé) :

```powershell
# Détermination du bon dossier de base, que ce soit .ps1 ou .exe ou terminal ouvert ailleurs
if ([System.AppDomain]::CurrentDomain.FriendlyName -like '*.exe') {
    $baseDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
} elseif ($PSScriptRoot) {
    $baseDir = $PSScriptRoot
} else {
    $baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
```

Juste **après** ce bloc, insérer :

```powershell
# --- Chargement de la configuration et des utilitaires (modules lib) ---
. (Join-Path $baseDir 'config.ps1')
. (Join-Path $baseDir 'lib\Common.ps1')
. (Join-Path $baseDir 'lib\State.ps1')

# Donnees d'execution hors du dossier app (qui est ecrase a chaque MAJ) :
# %LOCALAPPDATA%\Arrivee-Collab pour l'etat/log, ...\data pour les sorties metier.
$dataDir = Get-AppDataDir
$workDir = Get-AppWorkDir $dataDir
Initialize-AppLog (Join-Path $dataDir 'app_debug.log')
Write-AppLog "[INIT] App : $baseDir | Donnees : $dataDir"

# Contexte global partage (etendu par le Plan B : pastille MAJ, tutoriel).
$global:Ctx = @{
    Config          = $Config
    AppRoot         = $baseDir
    DataDir         = $dataDir
    WorkDir         = $workDir
    State           = (New-AppState (Join-Path $dataDir 'state.json'))
    UpdateAvailable = $null
}

# Migration "comme une mise a jour" (no-op si meme version) : declenchera le
# dialogue « Quoi de neuf » au Plan B. On capture la version precedente AVANT.
$global:PrevStateVersion = [string]$global:Ctx.State.Version
[void](Invoke-AppVersionMigration $global:Ctx.State $Config.Version)
```

- [ ] **Step 3: Rediriger les dossiers de sortie vers `$workDir`**

Repérer (vers ligne 146-148) :

```powershell
$resourcesFolder = Join-Path $baseDir "Resources"
$motDePasseFolder = Join-Path $baseDir "Mot de passe"
$archiveFolder = Join-Path $baseDir "Archive message"
```

Remplacer par (seules les 2 dernières lignes changent) :

```powershell
$resourcesFolder = Join-Path $baseDir "Resources"
$motDePasseFolder = Join-Path $workDir "Mot de passe"
$archiveFolder = Join-Path $workDir "Archive message"
```

- [ ] **Step 4: Rediriger le `.msg` temporaire vers `$workDir` (2 occurrences)**

Chercher les **deux** occurrences de :

```powershell
$cheminMsg = Join-Path $baseDir "$ritm`_notif.msg"
```

(une dans la branche « déjà initialisé », une dans la branche « nouveau mot de passe » de `$btnGenMsg.Add_Click`). Remplacer les deux par :

```powershell
$cheminMsg = Join-Path $workDir "$ritm`_notif.msg"
```

- [ ] **Step 5: Vérification manuelle — fonctionnel complet, sorties au bon endroit**

Run: `powershell.exe -ExecutionPolicy Bypass -NoProfile -File "ArriveeCollab-PS/arrivee collab.ps1"`
Faire : saisir RITM `RITM999`, email `test@sncf.fr`, nom `DURAND`, prénom `Jean` → « Générer mot de passe » → « Générer .msg » → confirmer les dialogues.
Expected :
- L'app fonctionne comme avant (mot de passe copié, .msg créé, note ServiceNow à jour).
- Les fichiers apparaissent sous `%LOCALAPPDATA%\Arrivee-Collab\data\` (vérifier : `dir "$env:LOCALAPPDATA\Arrivee-Collab\data"` montre `Mot de passe\`, `Archive message\`).
- `ArriveeCollab-PS/` ne contient **plus** de nouveaux `Mot de passe/` ni `Archive message/`.
- Un `app_debug.log` et un `state.json` existent dans `%LOCALAPPDATA%\Arrivee-Collab\`.

- [ ] **Step 6: Commit**

```bash
git add "ArriveeCollab-PS/arrivee collab.ps1"
git commit -m "refactor: sourcing config/lib, sorties vers %LOCALAPPDATA%, retrait du VBS inline"
```

---

### Task 6 : Lanceurs locaux de l'app (`Start-ArriveeCollab.vbs` / `.cmd`)

**Files:**
- Create: `ArriveeCollab-PS/Start-ArriveeCollab.vbs`
- Create: `ArriveeCollab-PS/Start-ArriveeCollab.cmd`

**Interfaces:**
- Produces: `Start-ArriveeCollab.vbs` lance `arrivee collab.ps1` masqué en `-STA`. C'est ce fichier que le bootstrap (Task 7) appellera dans la copie locale.

- [ ] **Step 1: Créer `Start-ArriveeCollab.vbs`** (encodage ASCII)

```vbs
' ============================================================
'  Arrivee Collaborateur - lanceur SANS fenetre console.
'  Demarre PowerShell masque en -STA (requis pour le presse-papiers
'  WinForms). Pas de .exe, pas d'elevation.
' ============================================================
Option Explicit
Dim shell, fso, scriptDir, cmd
Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & scriptDir & "\arrivee collab.ps1"""
shell.Run cmd, 0, False
```

- [ ] **Step 2: Créer `Start-ArriveeCollab.cmd`**

```bat
@echo off
REM Lanceur (passe par le .vbs pour n'avoir AUCUNE fenetre console).
cd /d "%~dp0"
start "" wscript.exe "%~dp0Start-ArriveeCollab.vbs"
```

- [ ] **Step 3: Vérification manuelle**

Double-cliquer sur `ArriveeCollab-PS/Start-ArriveeCollab.cmd` (ou : `cmd /c "ArriveeCollab-PS/Start-ArriveeCollab.cmd"`).
Expected : la fenêtre s'ouvre **sans** terminal visible ; le bouton « Générer mot de passe » copie bien dans le presse-papiers (preuve que `-STA` fonctionne). Fermer.

- [ ] **Step 4: Commit**

```bash
git add ArriveeCollab-PS/Start-ArriveeCollab.vbs ArriveeCollab-PS/Start-ArriveeCollab.cmd
git commit -m "feat: lanceurs locaux Start-ArriveeCollab (.vbs -STA masque + .cmd)"
```

---

### Task 7 : Le lanceur de distribution (`dist-launcher/` : bootstrap + .cmd/.vbs + LISEZMOI)

**Files:**
- Create: `dist-launcher/bootstrap.ps1`
- Create: `dist-launcher/Arrivee Collab.vbs`
- Create: `dist-launcher/Arrivee Collab.cmd`
- Create: `dist-launcher/LISEZMOI.txt`

**Interfaces:**
- Consumes: `latest.json` + `Arrivee-Collab_version<X>.zip` présents dans le même dossier (produits par build-zip, Task 8). Le zip contient un dossier racine `Arrivee-Collab_version<X>/` avec le contenu de `ArriveeCollab-PS/`.
- Produces: installe l'app dans `%LOCALAPPDATA%\Arrivee-Collab\app\`, écrit `%LOCALAPPDATA%\Arrivee-Collab\dist_path.txt`, lance `...\app\Start-ArriveeCollab.vbs`.

- [ ] **Step 1: Créer `dist-launcher/bootstrap.ps1`**

```powershell
# ============================================================================
#  Lanceur "toujours la derniere version" de l'outil Arrivee Collaborateur.
#  A PLACER DANS LE DOSSIER DE DISTRIBUTION (OneDrive), a cote de latest.json et
#  des zips. A chaque lancement :
#   1. lit latest.json -> version + zip attendus ;
#   2. si la copie locale (%LOCALAPPDATA%\Arrivee-Collab\app) n'existe pas,
#      extrait le zip dedans (PREMIERE installation) ;
#   3. lance l'application locale (masquee).
#  Memorise le chemin de distribution (dist_path.txt) pour la verif in-app (Plan B).
#  AUCUN jeton, AUCUNE API : simple lecture de fichiers (acces LECTURE SEULE OK).
# ============================================================================
param([int]$WaitPid = 0)
$ErrorActionPreference = 'Stop'
$dist    = $PSScriptRoot
$dataDir = Join-Path $env:LOCALAPPDATA 'Arrivee-Collab'
$appDir  = Join-Path $dataDir 'app'
$log     = Join-Path $dataDir 'app_debug.log'
function L($m) { try { if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }; Add-Content -LiteralPath $log -Value ("{0} [LANCEUR] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding UTF8 } catch {} }
try {
    if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }
    try { Set-Content -LiteralPath (Join-Path $dataDir 'dist_path.txt') -Value $dist -Encoding UTF8 -Force } catch {}

    # Relance apres mise a jour in-app (Plan B) : attendre la fermeture de l'ancienne instance.
    if ($WaitPid -gt 0) { try { Wait-Process -Id $WaitPid -Timeout 90 -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Milliseconds 600 }

    # Version cible (latest.json).
    $targetVer = $null; $zipName = $null
    $mf = Join-Path $dist 'latest.json'
    if (Test-Path $mf) {
        try { $j = (Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json); $targetVer = [string]$j.version; $zipName = [string]$j.zip } catch { L "latest.json illisible : $($_.Exception.Message)" }
    }
    if (-not $zipName -and $targetVer) { $zipName = "Arrivee-Collab_version$targetVer.zip" }

    # PREMIERE INSTALLATION uniquement. Ensuite, les MAJ se font VIA LA PASTILLE in-app
    # (Plan B) : on ne force pas la MAJ au lancement, sinon la pastille ne s'afficherait jamais.
    $localExists = Test-Path -LiteralPath (Join-Path $appDir 'Start-ArriveeCollab.vbs')
    if (-not $localExists) {
        if ($targetVer -and $zipName) {
            $zip = Join-Path $dist $zipName
            if (Test-Path $zip) {
                L "Premiere installation : version $targetVer."
                $tmp = Join-Path $env:TEMP ('acboot_' + [guid]::NewGuid().ToString('N'))
                Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force
                $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
                $srcContent = if ($inner) { $inner.FullName } else { $tmp }
                if (-not (Test-Path $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null }
                Copy-Item -Path (Join-Path $srcContent '*') -Destination $appDir -Recurse -Force
                Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
                L "Version $targetVer installee dans $appDir."
            } else { L "Zip introuvable : $zip" }
        } else { L "latest.json absent : impossible d'installer la premiere version." }
    }

    # Nettoyage du dossier de distribution : archive les zips PERIMES (best-effort ;
    # ne reussit que pour le mainteneur en acces ecriture, ignore pour les lecteurs seuls).
    if ($zipName) {
        try {
            $stale = @(Get-ChildItem -LiteralPath $dist -Filter 'Arrivee-Collab_version*.zip' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $zipName })
            if ($stale.Count -gt 0) {
                $archives = Join-Path $dist 'Archives'
                if (-not (Test-Path -LiteralPath $archives)) { New-Item -ItemType Directory -Path $archives -Force | Out-Null }
                foreach ($z in $stale) {
                    try {
                        $destZ = Join-Path $archives $z.Name
                        if (Test-Path -LiteralPath $destZ) { Remove-Item -LiteralPath $destZ -Force -ErrorAction SilentlyContinue }
                        Move-Item -LiteralPath $z.FullName -Destination $archives -Force
                        L "Zip perime archive : $($z.Name) -> Archives\"
                    } catch { L "Archivage $($z.Name) ignore (lecture seule ?) : $($_.Exception.Message)" }
                }
            }
        } catch { L "Nettoyage des zips perimes KO : $($_.Exception.Message)" }
    }

    # Lance l'application locale (masquee via son .vbs).
    $vbs = Join-Path $appDir 'Start-ArriveeCollab.vbs'
    if (Test-Path $vbs) {
        Start-Process -FilePath 'wscript.exe' -ArgumentList ('"' + $vbs + '"') -WorkingDirectory $appDir
        L "Application lancee depuis $appDir."
    } else {
        L "Start-ArriveeCollab.vbs introuvable dans $appDir (aucune version installee ?)."
    }
} catch { L ("ECHEC bootstrap : " + $_.Exception.Message) }
```

- [ ] **Step 2: Créer `dist-launcher/Arrivee Collab.vbs`** (ASCII)

```vbs
' Lanceur masque (aucune fenetre console) : execute bootstrap.ps1 du meme dossier.
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\bootstrap.ps1""", 0, False
```

- [ ] **Step 3: Créer `dist-launcher/Arrivee Collab.cmd`**

```bat
@echo off
REM Lanceur Arrivee Collaborateur (toujours la derniere version). Double-cliquer pour lancer.
start "" wscript.exe "%~dp0Arrivee Collab.vbs"
```

- [ ] **Step 4: Créer `dist-launcher/LISEZMOI.txt`** (ASCII)

```text
Arrivee Collaborateur - Dossier de distribution (OneDrive)
==========================================================

CONTENU A METTRE DANS CE DOSSIER (acces LECTURE SEULE pour l'equipe) :
  - latest.json                      (genere par build-zip.ps1 : version + zip + notes)
  - Arrivee-Collab_version<X>.zip     (le ou les zips versionnes)
  - Arrivee Collab.cmd + Arrivee Collab.vbs + bootstrap.ps1   (le lanceur)

UTILISATION (cote utilisateur)
  Lancer "Arrivee Collab.cmd" (ou un raccourci vers lui). Le lanceur :
    1. lit latest.json ;
    2. si la copie locale (%LOCALAPPDATA%\Arrivee-Collab\app) n'existe pas,
       installe la derniere version automatiquement ;
    3. demarre l'application.
  Une fois lancee, l'app surveille ce dossier : si une nouvelle version parait,
  une pastille "MAJ" s'affiche ; au clic, les notes sont presentees et la mise a
  jour se fait (fermeture + remplacement + redemarrage). [Plan B]

PUBLIER UNE NOUVELLE VERSION (cote mainteneur)
  1. Incrementer Config.Version dans ArriveeCollab-PS\config.ps1.
  2. Ajouter les notes de la version dans releases.json.
  3. Lancer build-zip.ps1  -> produit le zip + latest.json + dist-ready.
  4. Copier le contenu de dist-ready\ (ou extraire Arrivee-Collab-dist-ready.zip)
     dans CE dossier OneDrive.

ACCES : LECTURE SEULE suffit pour l'equipe (l'app ne fait que LIRE ces fichiers).
Seul le mainteneur a besoin de l'acces en ecriture pour publier.
```

- [ ] **Step 5: Vérification reportée**

La chaîne complète (cmd → vbs → bootstrap → install) sera testée en **Task 8 Step 4**, une fois le zip + latest.json produits par le build. Pas de test isolé ici.

- [ ] **Step 6: Commit**

```bash
git add "dist-launcher/"
git commit -m "feat: dist-launcher (bootstrap %LOCALAPPDATA% + lanceurs cmd/vbs + LISEZMOI)"
```

---

### Task 8 : `build-zip.ps1` (packaging + latest.json + kit + push git)

**Files:**
- Create: `build-zip.ps1`
- Create/auto: `latest.json`, `Arrivee-Collab_version1.0.0.zip`, `dist-ready/`, `Arrivee-Collab-dist-ready.zip`, `Arrivee-Collab-maj-1.0.0.zip`, `.dist-launcher-history.json`, `Archives/`

**Interfaces:**
- Consumes: `ArriveeCollab-PS/config.ps1` (`$Config.Version`), `ArriveeCollab-PS/releases.json`, `dist-launcher/*`.
- Produces: le zip versionné (dossier racine interne = `Arrivee-Collab_version<X>/`), `latest.json` (`{version, zip, notes}`), et le dossier/zip `dist-ready` à publier.

- [ ] **Step 1: Mettre à jour `.gitignore`** (ne pas versionner les artefacts lourds régénérables)

Ajouter ces lignes à `.gitignore` :

```gitignore
# Artefacts de build (regeneres par build-zip.ps1)
dist-ready/
Arrivee-Collab-dist-ready.zip
Arrivee-Collab-maj-*.zip
Archives/
```

Note : `latest.json` et `Arrivee-Collab_version<X>.zip` (version courante) **restent versionnés** (comme SNOW) — ils décrivent l'état publié.

- [ ] **Step 2: Créer `build-zip.ps1`**

```powershell
# ============================================================================
#  Genere le zip de distribution de l'outil Arrivee Collaborateur.
#  - Lit la version dans ArriveeCollab-PS\config.ps1 ($Config.Version).
#  - Produit  Arrivee-Collab_version<X>.zip  a la racine (dossier racine interne = meme nom).
#  - Genere latest.json (version + zip + notes depuis releases.json).
#  - Archive les anciennes versions dans Archives\.
#  - Assemble dist-ready\ (lanceur + zip + latest.json) + zips d'export.
#  - En fin : COMMIT + PUSH automatique sur origin (best-effort ; -NoGit pour s'en passer).
#  Usage :  powershell -ExecutionPolicy Bypass -File build-zip.ps1 [-NoGit]
# ============================================================================
param([switch]$NoGit)
$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$src  = Join-Path $repo 'ArriveeCollab-PS'

$cfg = Get-Content -LiteralPath (Join-Path $src 'config.ps1') -Raw
$m = [regex]::Match($cfg, "Version\s*=\s*'([^']+)'")
if (-not $m.Success) { throw "Version introuvable dans config.ps1 (attendu : Version = '<x>')." }
$ver = $m.Groups[1].Value
$name = "Arrivee-Collab_version$ver"

# Staging : copie temporaire renommee pour que le dossier racine du zip = $name.
$staging = Join-Path ([System.IO.Path]::GetTempPath()) $name
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
Copy-Item -LiteralPath $src -Destination $staging -Recurse

$zip = Join-Path $repo "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -Path $staging -DestinationPath $zip -CompressionLevel Optimal
Remove-Item -LiteralPath $staging -Recurse -Force

# latest.json : version + zip + notes de la version courante (depuis releases.json EMBARQUE).
$notes = @()
$relFile = Join-Path $src 'releases.json'
if (Test-Path -LiteralPath $relFile) {
    try {
        $rel = Get-Content -LiteralPath $relFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($rel.PSObject.Properties.Name -contains $ver) { $notes = @($rel.$ver) }
    } catch { Write-Host "Avertissement : releases.json illisible ($($_.Exception.Message))" }
}
$manifest = [ordered]@{ version = $ver; zip = "$name.zip"; notes = $notes }
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

# Zip d'export du kit COMPLET (1er deploiement). Contenu a la racine du zip.
$exportZip = Join-Path $repo 'Arrivee-Collab-dist-ready.zip'
if (Test-Path -LiteralPath $exportZip) { Remove-Item -LiteralPath $exportZip -Force }
Compress-Archive -Path (Join-Path $ready '*') -DestinationPath $exportZip -CompressionLevel Optimal

# Bundle de MISE A JOUR : minimal (zip + latest.json) si le lanceur n'a pas change
# depuis la version precedente, complet (lanceur + zip + latest.json) sinon.
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
    $majDesc = if ($prevKey) { "COMPLET (lanceur modifie depuis $prevKey)" } else { "COMPLET (1re reference du lanceur)" }
} else {
    Compress-Archive -Path $zip, (Join-Path $repo 'latest.json') -DestinationPath $majZip -CompressionLevel Optimal
    $majDesc = "minimal (zip + latest.json ; lanceur inchange depuis $prevKey)"
}
$hist[$ver] = $launcherSig
($hist | ConvertTo-Json) | Out-File -LiteralPath $histFile -Encoding UTF8 -Force

$sizeMo = [math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 2)
Write-Host "OK : $name.zip ($sizeMo Mo) - dossier racine interne : $name/"
if ($moved.Count -gt 0) { Write-Host ("Archivees -> Archives\ : {0}" -f ($moved -join ', ')) }
Write-Host "dist-ready\ pret a publier. Arrivee-Collab-dist-ready.zip (kit complet) regenere."
Write-Host "Arrivee-Collab-maj-$ver.zip regenere (bundle $majDesc)."

# ============================================================================
#  Publication Git : COMMIT + PUSH automatique vers origin (best-effort).
#  Un echec (hors ligne, rien a committer, pas de remote) n'echoue PAS le build.
#  Pas de '2>&1' sur git (PS 5.1 le transforme en erreur sous Stop) : 2>$null + $LASTEXITCODE.
# ============================================================================
if (-not $NoGit) {
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        Push-Location $repo
        $null = (& git rev-parse --is-inside-work-tree 2>$null)
        if ($LASTEXITCODE -eq 0) {
            & git add -A 2>$null | Out-Null
            & git diff --cached --quiet 2>$null
            if ($LASTEXITCODE -ne 0) {
                $msg = "Version $ver"
                if (@($notes).Count -gt 0) { $msg += "`n`n" + ((@($notes) | ForEach-Object { "- $_" }) -join "`n") }
                $tmpMsg = Join-Path ([System.IO.Path]::GetTempPath()) ("accommit_" + [guid]::NewGuid().ToString('N') + ".txt")
                [System.IO.File]::WriteAllText($tmpMsg, $msg, (New-Object System.Text.UTF8Encoding $false))
                & git commit -F $tmpMsg 2>$null | Out-Null
                $committed = ($LASTEXITCODE -eq 0)
                Remove-Item -LiteralPath $tmpMsg -Force -ErrorAction SilentlyContinue
                if ($committed) {
                    Write-Host "Git : commit 'Version $ver' cree."
                    $hasOrigin = ((& git remote 2>$null) -contains 'origin')
                    if ($hasOrigin) {
                        & git push origin HEAD 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) { Write-Host "Git : push vers origin OK." }
                        else { Write-Host "Git : PUSH KO (hors ligne ?). Commit local : refaire 'git push' plus tard." }
                    } else { Write-Host "Git : pas de remote 'origin' -> commit local seulement." }
                } else { Write-Host "Git : commit KO (voir 'git status')." }
            } else { Write-Host "Git : rien a committer." }
        } else { Write-Host "Git : pas un depot git -> etape ignoree." }
    } catch { Write-Host "Git : etape ignoree ($($_.Exception.Message))." }
    finally { Pop-Location; $ErrorActionPreference = $prevEAP }
} else { Write-Host "Git : -NoGit -> ni commit ni push." }
```

- [ ] **Step 3: Lancer le build (sans git pour ce 1er essai)**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File build-zip.ps1 -NoGit`
Expected: affiche `OK : Arrivee-Collab_version1.0.0.zip (...)`, crée `latest.json`, `Arrivee-Collab_version1.0.0.zip`, `dist-ready/`, `Arrivee-Collab-dist-ready.zip`, `Arrivee-Collab-maj-1.0.0.zip`.
Vérifier `latest.json` : `Get-Content latest.json` → contient `"version":"1.0.0"`, `"zip":"Arrivee-Collab_version1.0.0.zip"`, et la note.

- [ ] **Step 4: Vérification manuelle — chaîne de distribution complète (1re installation)**

Simuler un dossier OneDrive et tester l'installation locale propre :

```powershell
# Repartir d'une install locale vierge
Remove-Item "$env:LOCALAPPDATA\Arrivee-Collab\app" -Recurse -Force -ErrorAction SilentlyContinue
# Dossier "OneDrive simule"
$test = "$env:TEMP\AC-dist-test"; Remove-Item $test -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive -Path "Arrivee-Collab-dist-ready.zip" -DestinationPath $test -Force
# Lancer la chaine
cmd /c "`"$test\Arrivee Collab.cmd`""
```

Expected : après ~2-3 s, la fenêtre « Arrivée Collaborateur » s'ouvre. Vérifier que `%LOCALAPPDATA%\Arrivee-Collab\app\arrivee collab.ps1` existe (installé par le bootstrap) et que `dist_path.txt` contient le chemin `$test`. Fermer.

- [ ] **Step 5: Commit (puis test du push auto)**

```bash
git add build-zip.ps1 .gitignore latest.json Arrivee-Collab_version1.0.0.zip
git commit -m "feat: build-zip.ps1 (packaging + latest.json + kit de distribution)"
```

Puis valider le push intégré du build :
Run: `powershell -NoProfile -ExecutionPolicy Bypass -File build-zip.ps1`
Expected: `Git : rien a committer` (tout est déjà commité) OU `Git : push vers origin OK`. Aucune erreur bloquante.

---

### Task 9 : Nettoyage des obsolètes + mise à jour de CLAUDE.md

**Files:**
- Delete: `arrivée de collab.vbs`, `CreerRaccourci.ps1` (racine — remplacés par le nouveau lanceur)
- Modify: `CLAUDE.md`

**Interfaces:**
- Produces: dépôt propre, documentation à jour reflétant la nouvelle architecture.

- [ ] **Step 1: Supprimer les fichiers obsolètes**

```bash
git rm "arrivée de collab.vbs" "CreerRaccourci.ps1"
```

Justification : la génération du `.vbs` et le rôle de lanceur sont désormais assurés par `dist-launcher/` (distribution) et `ArriveeCollab-PS/Start-ArriveeCollab.vbs` (local).

- [ ] **Step 2: Mettre à jour `CLAUDE.md`**

Adapter les sections impactées :
- **Lancement** : remplacer la mention de `arrivée de collab.vbs` / `CreerRaccourci.ps1` par : développement direct via `ArriveeCollab-PS\arrivee collab.ps1` ; distribution via `build-zip.ps1` → dossier OneDrive ; lancement utilisateur via `Arrivee Collab.cmd`.
- **Architecture** : décrire la nouvelle arborescence (`ArriveeCollab-PS/` source + `lib/` + `dist-launcher/` + `build-zip.ps1`) et le modèle app/`%LOCALAPPDATA%`.
- **Dossiers** : `Mot de passe/` et `Archive message/` vivent désormais sous `%LOCALAPPDATA%\Arrivee-Collab\data\`.
- Ajouter une ligne renvoyant au spec et aux plans dans `docs/superpowers/`.

- [ ] **Step 3: Vérification — la suite de tests passe toujours**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: `TOUS LES TESTS PASSENT`.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: retire les lanceurs obsoletes, met a jour CLAUDE.md"
```

---

## Self-Review

**Spec coverage (Plan A scope) :**
- §3 Arborescence → Tasks 1, 2, 3, 4, 6, 7, 8 (tous les fichiers de la fondation/distribution créés). ✅
- §4 Modèle d'exécution (app/data) → Task 5 (chemins `$workDir`) + Task 7 (install `%LOCALAPPDATA%`). ✅
- §5 Chaîne de lancement (`-STA`, cmd→vbs→bootstrap→app) → Tasks 6, 7, 8 Step 4. ✅
- §6.1 config / §6.2 releases → Task 2. ✅
- §6.3 Common / §6.4 State (+migration) → Tasks 3, 4. ✅
- §6.7 build-zip (+push origin) → Task 8. ✅
- §6.8 bootstrap → Task 7. ✅
- §9 Risque « déménagement chemins » → Task 5 (chirurgical : seules les sorties bougent). ✅
- §9 « bloc VBS inline obsolète » + «`-STA` manquant » → Task 5 Step 1, Task 6. ✅
- **Hors Plan A (→ Plan B)** : §6.5 Update.ps1 (pastille, self-update, Quoi de neuf), §6.6 Tutorial.ps1, §7 étapes du tutoriel, §8 intégration UI (pastille + bouton « ? » + timers). Volontairement reporté.

**Placeholder scan :** aucun TBD/TODO ; tout le code des fichiers nouveaux est fourni intégralement ; les modifications du script principal montrent les blocs avant/après exacts. ✅

**Type consistency :** `Get-AppDataDir`/`Get-AppWorkDir`/`Compare-AppVersion`/`Write-AppLog`/`Initialize-AppLog` (Task 3) ↔ utilisés en Tasks 4 et 5 avec les mêmes noms/signatures. `New-AppState`/`Save-AppState`/`Invoke-AppVersionMigration` (Task 4) ↔ utilisés en Task 5. `$global:Ctx` (clés `Config/AppRoot/DataDir/WorkDir/State/UpdateAvailable`) défini en Task 5 ↔ consommé par le Plan B. Noms de zip `Arrivee-Collab_version<X>.zip` cohérents entre build-zip (Task 8) et bootstrap (Task 7). `Start-ArriveeCollab.vbs` cohérent entre Task 6 (création) et Task 7 (lancé par le bootstrap). ✅

---

## Plan B (à détailler après exécution du Plan A)

Couvrira §6.5, §6.6, §7, §8 du spec : `lib/Update.ps1` (détection MAJ, pastille, `Show-UpdateDialog`, `Invoke-SelfUpdate`, `Show-WhatsNewIfUpgraded`), `lib/Tutorial.ps1` (moteur data-driven + surbrillance + 10 étapes), et l'intégration UI (pastille MAJ + bouton « ? » + timers de vérification et de tutoriel dans le script principal). Il sera rédigé une fois le Plan A exécuté, car les points d'ancrage UI exacts (noms des contrôles d'en-tête) dépendront de l'implémentation de la fondation.
```