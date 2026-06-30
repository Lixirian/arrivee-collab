# Masquage automatique en bulle à la perte de focus — Plan d'implémentation

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replier automatiquement l'app en bulle dès qu'elle perd le focus vers une autre application, sans masquer pendant ses propres dialogues ni pendant le flux de génération du `.msg`.

**Architecture:** Un helper pur `Should-AutoHide` (dans `lib/Common.ps1`, testable hors-GUI) encapsule la décision. Dans `arrivee collab.ps1`, `Form.Deactivate` arme un timer mono-coup 200 ms ; au tick, on lit la fenêtre au premier plan via P/Invoke (`GetForegroundWindow`/`GetWindowThreadProcessId`) et on appelle `Should-AutoHide` ; si vrai → `Hide-App` (existant). Un drapeau `$global:SuppressAutoHide` enveloppe `btnGenMsg.Add_Click` pour neutraliser le masquage pendant toute la génération.

**Tech Stack:** PowerShell 5.1, Windows Forms, P/Invoke (`user32.dll`), `Add-Type`.

## Global Constraints

- Encodage de TOUS les `.ps1` : **UTF-8 avec BOM** (sinon mojibake des accents en PowerShell 5.1). Vérifier après chaque écriture.
- Code, commentaires et UI **en français**, accents corrects.
- Convention de nommage PowerShell `Verbe-Nom` (verbes français quand métier).
- Toute feature ajoutée ⇒ +1 étape de tutoriel + bump `$script:TutorialVersion`.
- Toute feature ⇒ bump `config.ps1` `Version`, entrée `releases.json`, build via `build-zip.ps1`, commit + push `origin`.
- Version courante `1.4.3` ⇒ cible **`1.5.0`**. `$script:TutorialVersion` `4` ⇒ **`5`**.
- Ne PAS modifier l'animation, la bulle, le déplacement de la bulle, `Show-App` ni `Hide-App`.

---

### Task 1 : Helper de décision pur `Should-AutoHide` (testable)

**Files:**
- Modify: `ArriveeCollab-PS/lib/Common.ps1` (ajout d'une fonction en fin de fichier)
- Test: `tests/Test-ArriveeCollab.ps1` (ajout d'un bloc d'assertions)

**Interfaces:**
- Consumes: rien.
- Produces: `Should-AutoHide([bool]$AppHidden, [bool]$Animating, [bool]$Suppressed, [int]$ForegroundPid, [int]$OwnPid) -> [bool]`. Renvoie `$true` uniquement si : non supprimé, app non masquée, pas d'animation, `$ForegroundPid > 0`, et `$ForegroundPid -ne $OwnPid`.

- [ ] **Step 1 : Écrire les tests qui échouent**

Ajouter à la fin de `tests/Test-ArriveeCollab.ps1` (avant le bloc final qui affiche le bilan / `exit`) :

```powershell
# --- Should-AutoHide (décision de masquage auto) ---
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234) -eq $true)  'autohide : autre processus => masquer'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 1234 -OwnPid 1234) -eq $false) 'autohide : meme processus (dialogue/calendrier) => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $true  -ForegroundPid 4321 -OwnPid 1234) -eq $false) 'autohide : flux .msg supprime => non'
Assert ((Should-AutoHide -AppHidden $true  -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234) -eq $false) 'autohide : deja masquee => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $true  -Suppressed $false -ForegroundPid 4321 -OwnPid 1234) -eq $false) 'autohide : animation en cours => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 0    -OwnPid 1234) -eq $false) 'autohide : pas de fenetre premier plan => non'
```

- [ ] **Step 2 : Lancer les tests pour vérifier l'échec**

Run : `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ArriveeCollab.ps1`
Expected : erreur « The term 'Should-AutoHide' is not recognized » (la fonction n'existe pas encore).

- [ ] **Step 3 : Implémenter le helper**

Ajouter à la fin de `ArriveeCollab-PS/lib/Common.ps1` :

```powershell
# ----------------------------------------------------------------------------
#  Décision pure : faut-il replier l'app en bulle quand elle perd le focus ?
#  Vrai uniquement si la fenêtre désormais au premier plan appartient à un
#  AUTRE processus (et qu'on n'est ni déjà masqué, ni en animation, ni dans
#  le flux de génération du .msg où le masquage est volontairement suspendu).
# ----------------------------------------------------------------------------
function Should-AutoHide {
    param(
        [bool]$AppHidden,
        [bool]$Animating,
        [bool]$Suppressed,
        [int]$ForegroundPid,
        [int]$OwnPid
    )
    if ($Suppressed)             { return $false }
    if ($AppHidden)              { return $false }
    if ($Animating)              { return $false }
    if ($ForegroundPid -le 0)    { return $false }
    if ($ForegroundPid -eq $OwnPid) { return $false }
    return $true
}
```

- [ ] **Step 4 : Lancer les tests pour vérifier le succès**

Run : `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ArriveeCollab.ps1`
Expected : toutes les lignes `PASS`, dont les 6 `autohide : …`. Aucune `FAIL`.

- [ ] **Step 5 : Vérifier l'encodage BOM puis commit**

Vérifier que `lib/Common.ps1` est toujours UTF-8 BOM (les 3 premiers octets `EF BB BF`).

```bash
git add "ArriveeCollab-PS/lib/Common.ps1" "tests/Test-ArriveeCollab.ps1"
git commit -m "feat: helper pur Should-AutoHide + tests"
```

---

### Task 2 : Câblage du masquage auto dans `arrivee collab.ps1`

**Files:**
- Modify: `ArriveeCollab-PS/arrivee collab.ps1` — bloc P/Invoke (près des `Add-Type`), init globale (~ligne 1376), timer + `Add_Deactivate` (après `$btnHide.Add_Click`, ~ligne 1717).

**Interfaces:**
- Consumes: `Should-AutoHide` (Task 1), `Hide-App` (existant, ligne 1663), `$slideTimer` (existant, ligne 1609), `$global:AppHidden` (existant, ligne 1376).
- Produces: `$global:SuppressAutoHide` (init `$false`) consommé par Task 3 ; classe `[Win32.Fg]` avec `GetForegroundWindow()` et `GetWindowThreadProcessId(IntPtr, out uint)`.

- [ ] **Step 1 : Ajouter le P/Invoke**

Juste après le bloc `Add-Type … LayeredGhost … "@` (après la ligne ~1541), ajouter :

```powershell
# P/Invoke : fenêtre au premier plan + son PID (pour le masquage automatique).
Add-Type -Namespace Win32 -Name Fg -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
'@
```

- [ ] **Step 2 : Déclarer la globale de suppression**

Juste après `$global:AppHidden = $false` (ligne ~1376), ajouter :

```powershell
# Drapeau : suspend le masquage automatique pendant le flux de génération du .msg.
$global:SuppressAutoHide = $false
```

- [ ] **Step 3 : Ajouter le timer mono-coup + le handler Deactivate**

Juste après `$btnHide.Add_Click({ Hide-App })` (ligne ~1717), ajouter :

```powershell
# ============================================================================
#  Masquage AUTOMATIQUE : quand l'app perd le focus vers une AUTRE application,
#  elle se replie en bulle (même animation que le bouton « masquer »). Un timer
#  mono-coup de 200 ms laisse le nouveau premier plan se stabiliser ; on ne
#  masque que si sa fenêtre appartient à un autre processus (cf. Should-AutoHide).
# ============================================================================
$timerAutoHide = New-Object Windows.Forms.Timer
$timerAutoHide.Interval = 200
$timerAutoHide.Add_Tick({
    $this.Stop()
    $h = [Win32.Fg]::GetForegroundWindow()
    $fgPid = [uint32]0
    if ($h -ne [IntPtr]::Zero) { [void][Win32.Fg]::GetWindowThreadProcessId($h, [ref]$fgPid) }
    if (Should-AutoHide -AppHidden $global:AppHidden -Animating $slideTimer.Enabled -Suppressed $global:SuppressAutoHide -ForegroundPid ([int]$fgPid) -OwnPid $PID) {
        Hide-App
    }
}.GetNewClosure())
$form.Add_Deactivate({
    if ($global:AppHidden -or $slideTimer.Enabled -or $global:SuppressAutoHide) { return }
    $timerAutoHide.Stop(); $timerAutoHide.Start()
}.GetNewClosure())
```

- [ ] **Step 4 : Vérifier que le script parse sans erreur**

Run :
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$e=$null;[System.Management.Automation.Language.Parser]::ParseFile('ArriveeCollab-PS\arrivee collab.ps1',[ref]$null,[ref]$e); if($e){$e|ForEach-Object{$_.Message}; exit 1} else {'PARSE OK'}"
```
Expected : `PARSE OK`, exit 0.

- [ ] **Step 5 : Vérification manuelle GUI**

Lancer : `powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File "ArriveeCollab-PS\arrivee collab.ps1"`
Vérifier : (a) cliquer une autre appli (ex. navigateur) → l'app se replie en bulle ; (b) cliquer la bulle → l'app revient ; (c) ouvrir le sélecteur de date `DateTimePicker` (cocher « mot de passe déjà initialisé ») et cliquer le calendrier → **pas** de masquage ; (d) une `Show-AlertDialog` (ex. clic « Générer le .msg » champs vides) → **pas** de masquage ; (e) app déjà en bulle, switcher entre deux fenêtres tierces → la bulle ne bouge pas.

- [ ] **Step 6 : Vérifier l'encodage BOM puis commit**

```bash
git add "ArriveeCollab-PS/arrivee collab.ps1"
git commit -m "feat: masquage auto en bulle a la perte de focus"
```

---

### Task 3 : Suspendre le masquage pendant le flux de génération du `.msg`

**Files:**
- Modify: `ArriveeCollab-PS/arrivee collab.ps1` — handler `btnGenMsg.Add_Click` (lignes ~1270-1340).

**Interfaces:**
- Consumes: `$global:SuppressAutoHide` (Task 2).
- Produces: rien.

- [ ] **Step 1 : Envelopper le corps du handler dans try/finally**

Remplacer la ligne d'ouverture `$btnGenMsg.Add_Click({` par :

```powershell
$btnGenMsg.Add_Click({
    $global:SuppressAutoHide = $true
    try {
```

et remplacer la ligne de fermeture `})` correspondante (ligne ~1340, juste avant `foreach ($c in @($txtRITM, …`) par :

```powershell
    } finally {
        $global:SuppressAutoHide = $false
    }
})
```

Indenter le corps existant d'un niveau n'est pas obligatoire (PowerShell est insensible à l'indentation) ; ne pas réindenter pour garder le diff minimal. Les `return` existants dans le corps déclenchent quand même le `finally`.

- [ ] **Step 2 : Vérifier que le script parse sans erreur**

Run :
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$e=$null;[System.Management.Automation.Language.Parser]::ParseFile('ArriveeCollab-PS\arrivee collab.ps1',[ref]$null,[ref]$e); if($e){$e|ForEach-Object{$_.Message}; exit 1} else {'PARSE OK'}"
```
Expected : `PARSE OK`.

- [ ] **Step 3 : Vérification manuelle GUI**

Lancer l'app, remplir RITM / e-mail / nom, cocher « mot de passe déjà initialisé », cliquer « Générer le .msg », répondre « Ouvrir le fichier » : Outlook s'ouvre, l'app **ne se replie pas** ; le dialogue bénéficiaire s'affiche normalement ; après fermeture et copie de la note, basculer vers une autre appli → l'app se replie (normal).

- [ ] **Step 4 : Commit**

```bash
git add "ArriveeCollab-PS/arrivee collab.ps1"
git commit -m "feat: pas de masquage auto pendant la generation du .msg"
```

---

### Task 4 : Étape de tutoriel + bump version du tutoriel

**Files:**
- Modify: `ArriveeCollab-PS/lib/Tutorial.ps1` — commentaire d'en-tête (ligne 3), `$script:TutorialVersion` (ligne 10), `Get-TutorialSteps` (après l'étape `$btnHide`, ligne ~52).

**Interfaces:**
- Consumes: `$btnHide` (cible existante).
- Produces: rien.

- [ ] **Step 1 : Bumper la version du tutoriel**

Remplacer `$script:TutorialVersion = 4` par `$script:TutorialVersion = 5`.
Remplacer dans le commentaire d'en-tête `présente l'outil en 13 étapes.` par `présente l'outil en 14 étapes.`

- [ ] **Step 2 : Ajouter l'étape**

Juste après l'étape « Masquer l'application » (le bloc `@{ … Target = { $btnHide } }`, ligne ~52) et avant l'étape « C'est parti ! », insérer :

```powershell
        @{ Icon = ([char]::ConvertFromUtf32(0x1F9F2)); Title = 'Masquage automatique'
           Text  = "Plus besoin de cliquer : dès que vous basculez vers une autre application, l'outil se replie tout seul dans cette bulle pour rester visible sans vous gêner. Cliquez la bulle pour le ramener. Pendant la création du .msg (et son ouverture dans Outlook), l'app reste affichée pour vous laisser terminer."
           Target = { $btnHide } }
```

- [ ] **Step 3 : Vérifier que le module parse sans erreur**

Run :
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "$e=$null;[System.Management.Automation.Language.Parser]::ParseFile('ArriveeCollab-PS\lib\Tutorial.ps1',[ref]$null,[ref]$e); if($e){$e|ForEach-Object{$_.Message}; exit 1} else {'PARSE OK'}"
```
Expected : `PARSE OK`.

- [ ] **Step 4 : Vérifier l'encodage BOM puis commit**

```bash
git add "ArriveeCollab-PS/lib/Tutorial.ps1"
git commit -m "feat: etape de tutoriel pour le masquage automatique"
```

---

### Task 5 : Bump de version + changelog

**Files:**
- Modify: `ArriveeCollab-PS/config.ps1` (ligne 10), `ArriveeCollab-PS/releases.json` (entête).

**Interfaces:**
- Consumes: rien.
- Produces: `Version = '1.5.0'` lue par `build-zip.ps1` / `lib/Update.ps1`.

- [ ] **Step 1 : Bumper la version**

Dans `config.ps1`, remplacer `Version                = '1.4.3'` par `Version                = '1.5.0'`.

- [ ] **Step 2 : Ajouter l'entrée de changelog**

Dans `releases.json`, ajouter en tête de l'objet (juste après `{`), avant `"1.4.3"` :

```json
    "1.5.0": [
        "Masquage automatique : dès que vous basculez vers une autre application, l'outil se replie tout seul dans la bulle pour rester visible. Cliquez la bulle pour le ramener.",
        "L'app reste affichée pendant toute la génération du .msg (y compris son ouverture dans Outlook), le temps de finir vos actions.",
        "Tutoriel enrichi (14 étapes) présentant le masquage automatique."
    ],
```

- [ ] **Step 3 : Vérifier que le JSON est valide**

Run :
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-Content 'ArriveeCollab-PS\releases.json' -Raw | ConvertFrom-Json | Out-Null; 'JSON OK'"
```
Expected : `JSON OK`.

- [ ] **Step 4 : Commit**

```bash
git add "ArriveeCollab-PS/config.ps1" "ArriveeCollab-PS/releases.json"
git commit -m "chore: version 1.5.0 + changelog"
```

---

### Task 6 : Build de distribution + publication

**Files:**
- Run: `build-zip.ps1` (génère le zip versionné, `latest.json`, `dist-ready/`, puis tente commit + push `origin`).

**Interfaces:**
- Consumes: `config.ps1` `Version = '1.5.0'`.
- Produces: `Arrivee-Collab_version1.5.0.zip`, `latest.json` mis à jour.

- [ ] **Step 1 : Lancer la suite de tests complète (garde-fou)**

Run : `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ArriveeCollab.ps1`
Expected : aucune ligne `FAIL`.

- [ ] **Step 2 : Construire le zip de distribution**

Run : `.\build-zip.ps1`
Expected : `Arrivee-Collab_version1.5.0.zip` créé, `latest.json` indiquant `1.5.0`. En cas d'erreur de verrou Synology, relancer `.\build-zip.ps1`.

- [ ] **Step 3 : Vérifier latest.json**

Run :
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-Content latest.json -Raw | ConvertFrom-Json).version"
```
Expected : `1.5.0`.

- [ ] **Step 4 : Commit + push (si build-zip.ps1 ne l'a pas déjà fait)**

```bash
git add -A
git commit -m "build: distribution 1.5.0" || echo "rien a committer"
git push origin master
```

---

## Self-Review

**Couverture spec :**
- « Filtre par processus / Deactivate / timer 200 ms » → Task 2 (P/Invoke + timer + handler) + Task 1 (`Should-AutoHide`). ✓
- « Drapeau de suppression autour de btnGenMsg » → Task 3. ✓
- « Bulle inerte quand on switche entre fenêtres tierces » → gratuit (Deactivate ne se déclenche plus quand le form est caché) ; vérifié Task 2 Step 5(e). ✓
- « Étape tutoriel + TutorialVersion 4→5 » → Task 4. ✓
- « Version 1.4.3→1.5.0 + releases.json » → Task 5. ✓
- « Build + commit/push » → Task 6. ✓
- « Test pur Should-AutoHide » → Task 1. ✓

**Scan placeholders :** aucun TBD/TODO ; tout le code est fourni intégralement.

**Cohérence des types :** `Should-AutoHide` même signature en Task 1 (définition + tests) et Task 2 (appel). `$global:SuppressAutoHide` défini Task 2, consommé Task 3. `[Win32.Fg]` défini et utilisé Task 2.
