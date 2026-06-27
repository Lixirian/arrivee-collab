# Plan C — Tutoriel dynamique — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ajouter un tutoriel interactif qui, au premier lancement (et re-jouable via un bouton « ? »), présente l'outil en 10 étapes, chacune mettant en évidence le vrai contrôle concerné par un cadre violet et une carte d'explication.

**Architecture:** Un module `lib/Tutorial.ps1` porte les étapes data-driven (versionnées via `$script:TutorialVersion`), un helper de géométrie (`Get-ControlScreenRect`), la décision d'affichage (`Test-TutorialDue`), et le rendu WinForms : deux Forms `TopMost` non modaux — un « cadre » (anneau violet via `Region`) autour du contrôle ciblé et une « carte » dark theme (icône/titre/texte/progression/navigation). Le script principal gagne un bouton « ? » dans l'en-tête et un Timer différé au démarrage. L'état (`TutorialSeen`/`TutorialSeenVersion`) existe déjà dans `state.json` (Plan A).

**Tech Stack:** PowerShell 5.x, Windows Forms, `System.Drawing.Region` (cadre en anneau). Aucune dépendance nouvelle.

**Périmètre :** Ce Plan C couvre §6.6 (Tutorial.ps1) et §7 (les 10 étapes) du spec, plus l'intégration UI (§8). C'est le dernier sous-système du spec.

## Global Constraints

- **Langue** : tout en français, accents corrects. Encodage : `.ps1` UTF-8 **avec BOM** (le contrôleur normalise après chaque tâche `.ps1`) ; `.json` UTF-8.
- **Caractères spéciaux** : les icônes/flèches sont produites via `[char]::ConvertFromUtf32(0x....)` (jamais d'emoji littéral dans le source — robustesse d'encodage, comme le projet de référence SNOW).
- **Nommage** : fonctions d'infrastructure en verbe anglais standard (`Get-`, `Show-`, `Test-`). Réutilise `Write-AppLog` (Common.ps1) et `Save-AppState` (State.ps1) — ne les redéfinit PAS.
- **État** : `$Ctx.State.TutorialSeen` (bool) et `$Ctx.State.TutorialSeenVersion` (int) existent déjà (Plan A). Le tutoriel les met à jour via `Save-AppState`.
- **Contrôles cibles** (déjà présents dans `arrivee collab.ps1`, au scope script, résolus à l'exécution dans les scriptblocks `Target`) : `$panelForm`, `$btnGenPwd`, `$chkMdpDejaInit`, `$btnGenMsg`, `$panelCopy`, `$btnReset`. Palette `$c*`, `$form` également au scope script.
- **Rendu** : pas de Form modal imbriqué. Le tutoriel utilise deux Forms `TopMost` `.Show()` (non modaux) et désactive `$form` (`$form.Enabled = $false`) pendant l'affichage, réactivé à la fermeture.
- **Pas de framework de test** : unités pures dans `tests/Test-ArriveeCollab.ps1` (Assert maison). Le rendu GUI est validé manuellement (checkpoint contrôleur + utilisateur).
- **Git** : commits fréquents en français, branche dédiée.

---

### Task 1 : `lib/Tutorial.ps1` — étapes, géométrie, décision d'affichage

**Files:**
- Create: `ArriveeCollab-PS/lib/Tutorial.ps1`
- Modify: `tests/Test-ArriveeCollab.ps1`

**Interfaces:**
- Consumes: `Write-AppLog` (Common.ps1) ; `$Ctx.State` (`TutorialSeen`, `TutorialSeenVersion`).
- Produces:
  - `$script:TutorialVersion` (int) — version du contenu du tutoriel.
  - `Get-TutorialSteps($Ctx) : @(@{Icon;Title;Text;Target})` — 10 étapes ; `Target` est un scriptblock renvoyant un contrôle WinForms ou `$null`.
  - `Get-ControlScreenRect($Control) : [Drawing.Rectangle]|$null` — rectangle écran du contrôle visible, ou `$null`.
  - `Test-TutorialDue($State,[int]$Version) : bool` — `$true` si `$State.TutorialSeenVersion < $Version`.
  - `Show-TutorialIfFirstRun($Ctx)` — appelle `Show-Tutorial` (Task 2) si `Test-TutorialDue`.

- [ ] **Step 1: Écrire les tests qui échouent**

Dans `tests/Test-ArriveeCollab.ps1`, **avant** le bloc de bilan final (`Write-Host ""` … `if ($script:fail -eq 0)`), ajouter :

```powershell
# --- Tutoriel : étapes + décision d'affichage ---
. (Join-Path $lib 'Tutorial.ps1')
$steps = @(Get-TutorialSteps @{ })
Assert (@($steps).Count -eq 10) 'tuto : 10 etapes'
Assert (@($steps | Where-Object { -not $_.Title }).Count -eq 0) 'tuto : chaque etape a un titre'
Assert (@($steps | Where-Object { -not $_.Text }).Count -eq 0)  'tuto : chaque etape a un texte'
Assert ($null -ne $steps[1].Target) 'tuto : etape 2 a une cible (scriptblock)'

# Test-TutorialDue : pas vu -> du ; vu version courante -> pas du ; contenu plus recent -> du
Assert (Test-TutorialDue @{ TutorialSeenVersion = 0 } 1) 'tuto : jamais vu -> affiche'
Assert (-not (Test-TutorialDue @{ TutorialSeenVersion = 1 } 1)) 'tuto : deja vu version courante -> pas affiche'
Assert (Test-TutorialDue @{ TutorialSeenVersion = 1 } 2) 'tuto : contenu plus recent -> reaffiche'
```

- [ ] **Step 2: Lancer le test pour vérifier qu'il échoue**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: ÉCHEC — « Tutorial.ps1 introuvable » ou `Get-TutorialSteps` non reconnu.

- [ ] **Step 3: Écrire `lib/Tutorial.ps1`** (logique seulement — le rendu `Show-Tutorial` vient en Task 2)

```powershell
# ============================================================================
#  Tutoriel interactif : au PREMIER lancement (et re-jouable via le bouton « ? »),
#  présente l'outil en 10 étapes. Chaque étape met en évidence le vrai contrôle
#  (cadre violet) avec une carte d'explication à côté. Rendu WinForms (Task 2).
# ============================================================================

# Version du CONTENU du tutoriel. À INCRÉMENTER à chaque modification de
# Get-TutorialSteps : un utilisateur ayant vu une version plus ancienne le revoit
# une fois au lancement (bouton « Passer » disponible).
$script:TutorialVersion = 1

# Étapes data-driven. Icon = caractère (ConvertFromUtf32, robuste à l'encodage).
# Target = scriptblock renvoyant le contrôle à encadrer (ou $null pour une carte centrée).
function Get-TutorialSteps {
    param($Ctx)
    return @(
        @{ Icon = ([char]::ConvertFromUtf32(0x1F44B)); Title = 'Bienvenue'
           Text  = "Cet outil prépare l'arrivée d'un collaborateur SNCF : il génère un mot de passe, crée l'e-mail de notification (.msg) et la note ServiceNow. Faisons un tour rapide — à chaque étape, la zone concernée est entourée en violet."
           Target = { $null } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F4DD)); Title = 'Les informations à saisir'
           Text  = "Renseignez ici le RITM, l'adresse e-mail du demandeur, le nom et le prénom du nouveau collaborateur. L'aperçu du message se met à jour en temps réel."
           Target = { $panelForm } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F511)); Title = 'Générer le mot de passe'
           Text  = "Ce bouton crée un mot de passe aléatoire de 12 caractères, le copie dans le presse-papiers et prépare un fichier .zip protégé à joindre au mail."
           Target = { $btnGenPwd } }
        @{ Icon = ([char]::ConvertFromUtf32(0x26A0)); Title = 'Mot de passe déjà initialisé'
           Text  = "Si le compte possède déjà un mot de passe, cochez cette case : indiquez la date d'initialisation, et l'outil enverra un mail différent (sans pièce jointe) au lieu d'en générer un nouveau."
           Target = { $chkMdpDejaInit } }
        @{ Icon = ([char]::ConvertFromUtf32(0x2705)); Title = 'Vérifications avant envoi'
           Text  = "Avant de générer le .msg, l'outil vous demande de confirmer que vous avez bien modifié le mot de passe dans Mon-AD et déplacé le compte dans la bonne OU."
           Target = { $null } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F4E7)); Title = 'Générer le .msg'
           Text  = "Ce bouton crée l'e-mail Outlook de notification (avec le .zip en pièce jointe) et met à jour la note ServiceNow. Le .msg est archivé automatiquement après envoi."
           Target = { $btnGenMsg } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F464)); Title = 'Informations bénéficiaire'
           Text  = "Après la création du .msg, une fenêtre vous demande l'adresse de messagerie et l'OU du bénéficiaire (liste déroulante des entités SudEst) pour compléter la note ServiceNow."
           Target = { $null } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F4CB)); Title = 'La note ServiceNow'
           Text  = "Ce panneau affiche la note prête à coller dans ServiceNow. Le bouton « Copier tout » la place dans le presse-papiers en un clic."
           Target = { $panelCopy } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F504)); Title = 'Réinitialiser'
           Text  = "Ce bouton vide tous les champs pour traiter une nouvelle arrivée sans relancer l'application."
           Target = { $btnReset } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F389)); Title = "C'est parti !"
           Text  = "Vous êtes prêt. Les mises à jour de l'outil vous présenteront automatiquement les nouveautés. Vous pouvez rejouer ce tutoriel à tout moment via le bouton « ? » en haut à droite."
           Target = { $null } }
    )
}

# Rectangle ÉCRAN d'un contrôle visible (coin haut-gauche via PointToScreen + taille).
# $null si le contrôle est absent, masqué, ou pas encore mesuré.
function Get-ControlScreenRect {
    param($Control)
    if (-not $Control) { return $null }
    try {
        if (-not $Control.Visible) { return $null }
        $s = $Control.Size
        if ($s.Width -le 0 -or $s.Height -le 0) { return $null }
        $p = $Control.PointToScreen([System.Drawing.Point]::Empty)
        return New-Object System.Drawing.Rectangle($p.X, $p.Y, $s.Width, $s.Height)
    } catch { return $null }
}

# Décide s'il faut afficher le tutoriel : vrai tant que la version vue est antérieure
# à la version du contenu courant (jamais vu = 0).
function Test-TutorialDue {
    param($State, [int]$Version)
    if ([int]$State.TutorialSeenVersion -ge $Version) { return $false }
    return $true
}

# À APPELER AU LANCEMENT (différé) : affiche le tutoriel si jamais vu (1er lancement)
# OU si son contenu a changé depuis la dernière fois. Sinon ne fait rien.
function Show-TutorialIfFirstRun {
    param($Ctx)
    try {
        if (-not (Test-TutorialDue $Ctx.State $script:TutorialVersion)) { return }
        $reason = if ($Ctx.State.TutorialSeen) { "contenu mis à jour (vu v$($Ctx.State.TutorialSeenVersion))" } else { 'premier lancement' }
        Write-AppLog "[TUTO] Affichage du tutoriel : $reason."
        Show-Tutorial $Ctx
    } catch { Write-AppLog "[TUTO] Lancement KO : $($_.Exception.Message)" }
}
```

- [ ] **Step 4: Lancer le test pour vérifier qu'il passe**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: toutes les assertions PASS (les existantes + les 7 nouvelles), « TOUS LES TESTS PASSENT ».
Note : `Get-TutorialSteps` construit des scriptblocks `Target` mais ne les exécute pas — le test ne référence donc pas `$panelForm` etc.

- [ ] **Step 5: Commit**

```bash
git add "ArriveeCollab-PS/lib/Tutorial.ps1" tests/Test-ArriveeCollab.ps1
git commit -m "feat: lib/Tutorial.ps1 - etapes data-driven + decision d'affichage + tests"
```

---

### Task 2 : `lib/Tutorial.ps1` — rendu WinForms (carte + cadre de surbrillance)

**Files:**
- Modify: `ArriveeCollab-PS/lib/Tutorial.ps1` (ajout en fin de fichier)

**Interfaces:**
- Consumes: `Get-TutorialSteps`, `Get-ControlScreenRect`, `$script:TutorialVersion` (Task 1) ; palette `$c*`, `$form` (script principal) ; `Save-AppState`, `Write-AppLog`.
- Produces: `Show-Tutorial($Ctx)` — affiche le tutoriel (deux Forms non modaux), gère la navigation, et marque `TutorialSeen`/`TutorialSeenVersion` à la fin.

- [ ] **Step 1: Ajouter le rendu à la fin de `lib/Tutorial.ps1`**

```powershell
# ============================================================================
#  RENDU WinForms : carte d'explication (dark) + cadre de surbrillance (anneau
#  violet via Region) autour du contrôle ciblé. Deux Forms TopMost NON modaux ;
#  $form est désactivé pendant le tutoriel et réactivé à la fermeture.
# ============================================================================
function Show-Tutorial {
    param($Ctx)
    $steps = @(Get-TutorialSteps $Ctx)
    $n = $steps.Count
    if ($n -eq 0) { return }

    # --- Cadre de surbrillance : Form anneau violet, repositionné par étape ---
    $frame = New-Object Windows.Forms.Form
    $frame.FormBorderStyle = 'None'; $frame.ShowInTaskbar = $false
    $frame.StartPosition = 'Manual'; $frame.TopMost = $true
    $frame.BackColor = $cAccentViolet
    $frame.Enabled = $false   # purement décoratif (pas d'interaction)

    # --- Carte d'explication : Form dark avec liseré violet ---
    $card = New-Object Windows.Forms.Form
    $card.FormBorderStyle = 'None'; $card.ShowInTaskbar = $false
    $card.StartPosition = 'Manual'; $card.TopMost = $true
    $card.Size = New-Object Drawing.Size(450, 250)
    $card.BackColor = $cBgMain
    $card.Add_Paint({ param($s, $e)
        $pen = New-Object Drawing.Pen($cAccentViolet, 2)
        $e.Graphics.DrawRectangle($pen, 1, 1, $s.ClientSize.Width - 3, $s.ClientSize.Height - 3)
        $pen.Dispose()
    })

    $lblStep = New-Object Windows.Forms.Label
    $lblStep.Location = New-Object Drawing.Point(20, 16); $lblStep.AutoSize = $true
    $lblStep.ForeColor = $cTextSecondary; $lblStep.Font = [Drawing.Font]::new("Segoe UI", 8, [Drawing.FontStyle]::Bold)

    $lblIcon = New-Object Windows.Forms.Label
    $lblIcon.Location = New-Object Drawing.Point(18, 32); $lblIcon.AutoSize = $true
    $lblIcon.Font = [Drawing.Font]::new("Segoe UI Emoji", 20)

    $lblTitle = New-Object Windows.Forms.Label
    $lblTitle.Location = New-Object Drawing.Point(62, 38); $lblTitle.Size = New-Object Drawing.Size(372, 28)
    $lblTitle.ForeColor = $cWhite; $lblTitle.Font = [Drawing.Font]::new("Segoe UI", 13, [Drawing.FontStyle]::Bold)

    $lblText = New-Object Windows.Forms.Label
    $lblText.Location = New-Object Drawing.Point(20, 74); $lblText.Size = New-Object Drawing.Size(410, 96)
    $lblText.ForeColor = $cTextPrimary; $lblText.Font = [Drawing.Font]::new("Segoe UI", 10)

    $dotsPanel = New-Object Windows.Forms.Panel
    $dotsPanel.Location = New-Object Drawing.Point(20, 176); $dotsPanel.Size = New-Object Drawing.Size(410, 12)
    $dotsPanel.BackColor = $cBgMain
    $dots = @()
    for ($d = 0; $d -lt $n; $d++) {
        $dot = New-Object Windows.Forms.Panel
        $dot.Size = New-Object Drawing.Size(8, 8); $dot.Location = New-Object Drawing.Point(($d * 15), 2)
        $dot.BackColor = $cBorder
        $dotsPanel.Controls.Add($dot); $dots += $dot
    }

    $btnSkip = New-Object Windows.Forms.Button
    $btnSkip.Text = "Passer"; $btnSkip.Location = New-Object Drawing.Point(20, 202); $btnSkip.Size = New-Object Drawing.Size(80, 32)
    $btnSkip.FlatStyle = 'Flat'; $btnSkip.FlatAppearance.BorderSize = 0; $btnSkip.BackColor = $cBgSecondary
    $btnSkip.ForeColor = $cTextSecondary; $btnSkip.Cursor = [Windows.Forms.Cursors]::Hand

    $btnPrev = New-Object Windows.Forms.Button
    $btnPrev.Text = ("$([char]::ConvertFromUtf32(0x25C0)) Précédent"); $btnPrev.Location = New-Object Drawing.Point(232, 202); $btnPrev.Size = New-Object Drawing.Size(102, 32)
    $btnPrev.FlatStyle = 'Flat'; $btnPrev.FlatAppearance.BorderSize = 0; $btnPrev.BackColor = $cBorder
    $btnPrev.ForeColor = $cTextPrimary; $btnPrev.Cursor = [Windows.Forms.Cursors]::Hand

    $btnNext = New-Object Windows.Forms.Button
    $btnNext.Location = New-Object Drawing.Point(342, 202); $btnNext.Size = New-Object Drawing.Size(88, 32)
    $btnNext.FlatStyle = 'Flat'; $btnNext.FlatAppearance.BorderSize = 0; $btnNext.BackColor = $cAccentViolet
    $btnNext.ForeColor = $cWhite; $btnNext.Cursor = [Windows.Forms.Cursors]::Hand
    $btnNext.Font = [Drawing.Font]::new("Segoe UI", 9, [Drawing.FontStyle]::Bold)

    $card.Controls.AddRange(@($lblStep, $lblIcon, $lblTitle, $lblText, $dotsPanel, $btnSkip, $btnPrev, $btnNext))

    $st = @{ I = 0 }

    $render = {
        $i = $st.I; $step = $steps[$i]
        $lblStep.Text = ("ÉTAPE {0} / {1}" -f ($i + 1), $n)
        $lblIcon.Text = [string]$step.Icon
        $lblTitle.Text = [string]$step.Title
        $lblText.Text = [string]$step.Text
        for ($d = 0; $d -lt $n; $d++) { $dots[$d].BackColor = if ($d -eq $i) { $cAccentViolet } else { $cBorder } }
        $btnPrev.Visible = ($i -gt 0)
        $btnNext.Text = if ($i -ge ($n - 1)) { "Terminer $([char]::ConvertFromUtf32(0x2713))" } else { "Suivant $([char]::ConvertFromUtf32(0x25B6))" }

        $target = $null; try { if ($step.Target) { $target = & $step.Target } } catch { }
        $rect = Get-ControlScreenRect $target
        $area = [Windows.Forms.Screen]::FromControl($card).WorkingArea
        if ($rect) {
            $pad = 5; $bw = 3
            $fx = $rect.X - $pad - $bw; $fy = $rect.Y - $pad - $bw
            $fw = $rect.Width + 2 * ($pad + $bw); $fh = $rect.Height + 2 * ($pad + $bw)
            $frame.Bounds = New-Object Drawing.Rectangle($fx, $fy, $fw, $fh)
            $reg = New-Object Drawing.Region(New-Object Drawing.Rectangle(0, 0, $fw, $fh))
            $reg.Exclude((New-Object Drawing.Rectangle($bw, $bw, $fw - 2 * $bw, $fh - 2 * $bw)))
            $frame.Region = $reg
            $frame.Visible = $true; $frame.BringToFront()
            $cx = [Math]::Max($area.Left + 10, [Math]::Min($rect.X, $area.Right - $card.Width - 10))
            if (($fy + $fh + 12 + $card.Height) -le $area.Bottom) { $cy = $fy + $fh + 12 }
            elseif (($fy - 12 - $card.Height) -ge $area.Top) { $cy = $fy - 12 - $card.Height }
            else { $cy = [int](($area.Top + $area.Bottom - $card.Height) / 2) }
            $card.Location = New-Object Drawing.Point([int]$cx, [int]$cy)
        } else {
            $frame.Visible = $false
            $card.Location = New-Object Drawing.Point([int](($area.Left + $area.Right - $card.Width) / 2), [int](($area.Top + $area.Bottom - $card.Height) / 2))
        }
        $card.BringToFront(); $card.Activate()
    }.GetNewClosure()

    $finish = {
        try { $Ctx.State.TutorialSeen = $true; $Ctx.State.TutorialSeenVersion = $script:TutorialVersion; Save-AppState $Ctx.State } catch { }
        try { $form.Enabled = $true } catch { }
        try { $frame.Close() } catch { }
        try { $card.Close() } catch { }
    }.GetNewClosure()

    $btnSkip.Add_Click($finish)
    $btnPrev.Add_Click({ if ($st.I -gt 0) { $st.I--; & $render } }.GetNewClosure())
    $btnNext.Add_Click({ if ($st.I -lt ($n - 1)) { $st.I++; & $render } else { & $finish } }.GetNewClosure())
    # Sécurité : si la carte est fermée autrement (Alt+F4), réactiver le principal + fermer le cadre.
    $card.Add_FormClosed({ try { $frame.Close() } catch { }; try { $form.Enabled = $true } catch { } }.GetNewClosure())

    try { $form.Enabled = $false } catch { }
    $frame.Show(); $card.Show()
    & $render
    $card.Activate()
}
```

- [ ] **Step 2: Vérifier la syntaxe**

Run: `powershell -NoProfile -Command "$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'ArriveeCollab-PS/lib/Tutorial.ps1'),[ref]$t,[ref]$e); if($e -and $e.Count){$e|ForEach-Object{$_.Message}; exit 1} else {'SYNTAXE OK'}"`
Expected: `SYNTAXE OK`.

- [ ] **Step 3: Vérifier que la suite de tests passe toujours**

Run: `powershell -NoProfile -ExecutionPolicy Bypass -File tests/Test-ArriveeCollab.ps1`
Expected: « TOUS LES TESTS PASSENT » (le rendu n'est pas testé automatiquement, mais le sourcing du fichier enrichi ne doit rien casser).

- [ ] **Step 4: Commit**

```bash
git add "ArriveeCollab-PS/lib/Tutorial.ps1"
git commit -m "feat: Tutorial.ps1 - rendu WinForms (carte + cadre de surbrillance)"
```

---

### Task 3 : Intégration — bouton « ? », sourcing et affichage au démarrage

**Files:**
- Modify: `ArriveeCollab-PS/arrivee collab.ps1`

**Interfaces:**
- Consumes: `lib/Tutorial.ps1` (`Show-Tutorial`, `Show-TutorialIfFirstRun`) ; `$global:Ctx`, `$form`, palette `$c*`, `$lblUpdateBadge` (pastille, Plan B).
- Produces: bouton `$btnHelp` (« ? ») dans l'en-tête.

- [ ] **Step 1: Sourcer `lib/Tutorial.ps1`** — après la ligne `. (Join-Path $baseDir 'lib\Update.ps1')`, ajouter :

```powershell
. (Join-Path $baseDir 'lib\Tutorial.ps1')
```

- [ ] **Step 2: Ajouter le bouton « ? » dans l'en-tête** — juste après le bloc qui ajoute la pastille (`$global:Ctx.UpdateBadge = $lblUpdateBadge`), insérer :

```powershell
# --- Bouton « ? » : rejouer le tutoriel (en-tête, ancré en haut à droite) ---
$btnHelp = New-Object Windows.Forms.Button
$btnHelp.Text = "?"
$btnHelp.Size = New-Object Drawing.Size(34, 34)
$btnHelp.Location = New-Object Drawing.Point(1055, 18)
$btnHelp.FlatStyle = 'Flat'; $btnHelp.FlatAppearance.BorderSize = 0
$btnHelp.FlatAppearance.MouseOverBackColor = $cAccentVioletHover
$btnHelp.BackColor = $cBorder; $btnHelp.ForeColor = $cWhite
$btnHelp.Font = [Drawing.Font]::new("Segoe UI", 12, [Drawing.FontStyle]::Bold)
$btnHelp.Cursor = [Windows.Forms.Cursors]::Hand
$btnHelp.Anchor = [Windows.Forms.AnchorStyles]::Top -bor [Windows.Forms.AnchorStyles]::Right
$btnHelp.Add_Click({ try { Show-Tutorial $global:Ctx } catch { Write-AppLog "[TUTO] Relecture KO : $($_.Exception.Message)" } })
$form.Controls.Add($btnHelp)
$btnHelp.BringToFront()
```

- [ ] **Step 3: Afficher le tutoriel au 1er lancement** — dans le bloc `$form.Add_Shown({...})` ajouté au Plan B (celui qui contient `Show-WhatsNewIfUpgraded` et le Timer de MAJ), ajouter À LA FIN du scriptblock (juste avant sa `})` fermante), un Timer différé :

```powershell
    # Tutoriel au tout premier lancement (différé ~1,4 s pour laisser l'UI se peindre).
    $timerTuto = New-Object Windows.Forms.Timer
    $timerTuto.Interval = 1400
    $timerTuto.Add_Tick({
        $this.Stop()
        try { Show-TutorialIfFirstRun $global:Ctx } catch { Write-AppLog "[TUTO] 1er lancement KO : $($_.Exception.Message)" }
    })
    $timerTuto.Start()
```

- [ ] **Step 4: Vérifier la syntaxe**

Run: `powershell -NoProfile -Command "$e=$null;$t=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path 'ArriveeCollab-PS/arrivee collab.ps1'),[ref]$t,[ref]$e); if($e -and $e.Count){$e|ForEach-Object{$_.Message}; exit 1} else {'SYNTAXE OK'}"`
Expected: `SYNTAXE OK`. Vérifier aussi (Grep) la présence du sourcing `lib\Tutorial.ps1`, du `$btnHelp`, et de `Show-TutorialIfFirstRun`.

- [ ] **Step 5: Vérification manuelle reportée**

La validation visuelle (carte, cadre, navigation, 1er lancement) sera faite au checkpoint contrôleur (Task 4). Ne pas lancer la GUI ici.

- [ ] **Step 6: Commit**

```bash
git add "ArriveeCollab-PS/arrivee collab.ps1"
git commit -m "feat: bouton ? (rejouer tutoriel) + affichage au 1er lancement"
```

---

### Task 4 : Publication 1.2.0 + checkpoint tutoriel + CLAUDE.md

**Files:**
- Modify: `ArriveeCollab-PS/config.ps1`, `ArriveeCollab-PS/releases.json`, `CLAUDE.md`

**Interfaces:**
- Produces: version 1.2.0 publiable, doc à jour.

- [ ] **Step 1: Bump version** — dans `ArriveeCollab-PS/config.ps1`, remplacer `Version                = '1.1.0'` par `Version                = '1.2.0'`.

- [ ] **Step 2: Ajouter la note de version** — dans `ArriveeCollab-PS/releases.json`, ajouter l'entrée `1.2.0` (avant `1.1.0`) :

```json
{
    "1.2.0": [
        "Tutoriel interactif : au premier lancement, un guide en 10 étapes présente l'outil ; chaque étape met en évidence la zone concernée.",
        "Bouton « ? » en haut à droite pour rejouer le tutoriel à tout moment."
    ],
    "1.1.0": [
        "Mise à jour automatique : une pastille signale les nouvelles versions ; un clic présente les nouveautés puis installe la mise à jour et redémarre l'application.",
        "Dialogue « Quoi de neuf » affiché après chaque mise à jour."
    ],
    "1.0.0": [
        "Première version distribuée : versionning, mise à jour automatique depuis OneDrive et tutoriel interactif."
    ]
}
```

- [ ] **Step 3: Mettre à jour `CLAUDE.md`** — dans le tableau des modules, ajouter `lib/Tutorial.ps1 — tutoriel interactif data-driven (carte + surbrillance), versionné`. Retirer toute mention « tutoriel à venir / Plan C ». Dans la section « Fonctions clés » ou « Architecture », mentionner que le tutoriel s'affiche au 1er lancement et est re-jouable via le bouton « ? ».

- [ ] **Step 4: Normaliser l'encodage (contrôleur)** — *réalisé par le contrôleur* : `config.ps1` reste UTF-8 BOM ; `releases.json` UTF-8.

- [ ] **Step 5: Commit**

```bash
git add "ArriveeCollab-PS/config.ps1" "ArriveeCollab-PS/releases.json" CLAUDE.md
git commit -m "feat: publication 1.2.0 (tutoriel) + notes de version + CLAUDE.md"
```

- [ ] **Step 6: Checkpoint contrôleur — tutoriel réel**

*Réalisé par le contrôleur* : lancer l'app sur un état vierge (`%LOCALAPPDATA%\Arrivee-Collab` supprimé) et vérifier que le tutoriel s'affiche après ~1,4 s (carte + cadre de surbrillance), que la navigation Suivant/Précédent/Passer fonctionne, que le cadre se positionne sur les bons contrôles, et qu'après « Terminer » l'état `state.json` porte `tutorial_seen=true` / `tutorial_seen_version=1`. Relancer : le tutoriel ne doit plus s'afficher. Le bouton « ? » doit le rejouer.

---

## Self-Review

**Spec coverage (Plan C scope) :**
- §6.6 `lib/Tutorial.ps1` (moteur data-driven versionné + rendu WinForms carte + surbrillance) → Tasks 1, 2. ✅
- §7 les 10 étapes (Bienvenue → C'est parti, ciblant panelForm/btnGenPwd/chkMdpDejaInit/btnGenMsg/panelCopy/btnReset) → Task 1 (`Get-TutorialSteps`). ✅
- §8 intégration (bouton « ? » + `Show-TutorialIfFirstRun` au démarrage différé) → Task 3. ✅
- Persistance `TutorialSeen`/`TutorialSeenVersion` (déjà dans state.json, Plan A) → consommée par `Show-Tutorial`/`Test-TutorialDue`. ✅
- Publication + doc → Task 4.

**Placeholder scan :** aucun TBD/TODO ; tout le code est fourni (étapes, helper géométrie, rendu WinForms, intégration). Les textes des 10 étapes sont concrets.

**Type consistency :** `Get-TutorialSteps`/`Get-ControlScreenRect`/`Test-TutorialDue`/`$script:TutorialVersion` (Task 1) ↔ consommés par `Show-Tutorial` (Task 2) et `Show-TutorialIfFirstRun` (Task 1). `Show-Tutorial`/`Show-TutorialIfFirstRun` (Tutorial.ps1) ↔ appelés par le bouton « ? » et le Timer (Task 3). `Save-AppState`/`Write-AppLog` réutilisés, non redéfinis. Contrôles cibles (`$panelForm`, `$btnGenPwd`, `$chkMdpDejaInit`, `$btnGenMsg`, `$panelCopy`, `$btnReset`) cohérents avec le script principal. État `TutorialSeen`/`TutorialSeenVersion` cohérent avec `New-AppState` (Plan A).

---

Ce plan termine le spec `2026-06-27-versionning-maj-tutoriel-design.md` : après le Plan C, les trois volets (versionning/distribution, MAJ in-app, tutoriel) sont livrés.
