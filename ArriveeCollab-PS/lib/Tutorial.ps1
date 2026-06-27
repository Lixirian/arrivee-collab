# ============================================================================
#  Tutoriel interactif : au PREMIER lancement (et re-jouable via le bouton « ? »),
#  présente l'outil en 12 étapes. Chaque étape met en évidence le vrai contrôle
#  (cadre violet) avec une carte d'explication à côté. Rendu WinForms (Task 2).
# ============================================================================

# Version du CONTENU du tutoriel. À INCRÉMENTER à chaque modification de
# Get-TutorialSteps : un utilisateur ayant vu une version plus ancienne le revoit
# une fois au lancement (bouton « Passer » disponible).
$script:TutorialVersion = 3

# Étapes data-driven. Icon = caractère (ConvertFromUtf32, robuste à l'encodage).
# Target = scriptblock renvoyant le contrôle à encadrer (ou $null pour une carte centrée).
function Get-TutorialSteps {
    param($Ctx)
    return @(
        @{ Icon = ([char]::ConvertFromUtf32(0x1F44B)); Title = 'Bienvenue'
           Text  = "Cet outil prépare l'arrivée d'un collaborateur SNCF : il génère un mot de passe, crée l'e-mail de notification (.msg) et la note ServiceNow. Faisons un tour rapide — à chaque étape, la zone concernée est entourée en violet."
           Target = { $null } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F4DD)); Title = 'Les informations à saisir'
           Text  = "Renseignez ici le RITM, l'adresse e-mail du demandeur et le nom et prénom du nouveau collaborateur (un seul champ). L'aperçu du message se met à jour en temps réel."
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
        @{ Icon = ([char]::ConvertFromUtf32(0x1F441)); Title = "Replier l'aperçu"
           Text  = "Ce bouton replie l'objet, l'aperçu du message et la note ServiceNow pour réduire la fenêtre — pratique sur un petit écran de portable. Recliquez pour les réafficher."
           Target = { $btnTogglePreview } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F504)); Title = 'Réinitialiser'
           Text  = "Ce bouton vide tous les champs pour traiter une nouvelle arrivée sans relancer l'application."
           Target = { $btnReset } }
        @{ Icon = ([char]::ConvertFromUtf32(0x1F4AC)); Title = "Masquer l'application"
           Text  = "Ce bouton aspire la fenêtre dans une petite bulle ronde posée sur le bord de l'écran. Cliquez la bulle pour faire réapparaître l'app, glissez-la pour la déplacer (elle s'aimante au bord gauche ou droit), ou clic droit pour fermer l'outil."
           Target = { $btnHide } }
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

# ============================================================================
#  RENDU WinForms (style SNOW) : un VOILE sombre plein écran (Opacity) troué sur
#  la zone concernée (la zone reste nette, le reste de l'app est assombri), un
#  CADRE ROUGE animé (pulsation) autour de la zone, et une CARTE d'explication
#  MODALE (ShowDialog) : impossible de cliquer ailleurs ni de cacher l'app pendant
#  le tutoriel. Tout est en coordonnées ÉCRAN.
# ============================================================================
function Show-Tutorial {
    param($Ctx)
    $steps = @(Get-TutorialSteps $Ctx)
    $n = $steps.Count
    if ($n -eq 0) { return }
    # Capture LOCALE : dans une closure (.GetNewClosure), `$script:` désignerait le
    # module de la closure (où $TutorialVersion est absent = $null) et non ce script.
    $ver = $script:TutorialVersion
    $screen = [Windows.Forms.Screen]::FromControl($form).Bounds

    # --- Voile sombre plein écran, troué sur la cible ---
    $veil = New-Object Windows.Forms.Form
    $veil.FormBorderStyle = 'None'; $veil.ShowInTaskbar = $false
    $veil.StartPosition = 'Manual'; $veil.Bounds = $screen
    $veil.BackColor = [Drawing.Color]::Black
    $veil.Opacity = 0.6; $veil.TopMost = $true

    # --- Cadre rouge animé (anneau via Region) autour de la cible ---
    $frame = New-Object Windows.Forms.Form
    $frame.FormBorderStyle = 'None'; $frame.ShowInTaskbar = $false
    $frame.StartPosition = 'Manual'; $frame.TopMost = $true
    $frame.BackColor = $cDanger
    $frame.Region = New-Object Drawing.Region(New-Object Drawing.Rectangle(0, 0, 1, 1))   # invisible au départ (anti-flash)
    $frame.Add_FormClosed({ try { if ($this.Region) { $this.Region.Dispose() } } catch { } })
    # Pulsation : l'opacité du cadre oscille pour attirer l'œil.
    $pulse = New-Object Windows.Forms.Timer
    $pulse.Interval = 55
    $pulseState = @{ V = 1.0; Dir = -0.07 }
    $pulse.Add_Tick({
        $pulseState.V += $pulseState.Dir
        if ($pulseState.V -le 0.35) { $pulseState.V = 0.35; $pulseState.Dir = 0.07 }
        elseif ($pulseState.V -ge 1.0) { $pulseState.V = 1.0; $pulseState.Dir = -0.07 }
        try { if ($frame.Visible) { $frame.Opacity = $pulseState.V } } catch { }
    }.GetNewClosure())

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
    }.GetNewClosure())

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
        # Écran de l'APP (et non de la carte, pas encore positionnée -> écran principal).
        $area = [Windows.Forms.Screen]::FromControl($form).WorkingArea
        if ($rect) {
            # Trou du voile sur la cible (coordonnées du voile = écran - origine écran).
            $vreg = New-Object Drawing.Region(New-Object Drawing.Rectangle(0, 0, $screen.Width, $screen.Height))
            $vreg.Exclude((New-Object Drawing.Rectangle(($rect.X - $screen.X), ($rect.Y - $screen.Y), $rect.Width, $rect.Height)))
            $oldV = $veil.Region; $veil.Region = $vreg; if ($oldV) { $oldV.Dispose() }
            # Cadre rouge en anneau autour de la cible (parenthèses obligatoires dans
            # les arguments de Rectangle : la virgule a une précédence > '-'/'*').
            $pad = 4; $bw = 3
            $fx = $rect.X - $pad - $bw; $fy = $rect.Y - $pad - $bw
            $fw = $rect.Width + 2 * ($pad + $bw); $fh = $rect.Height + 2 * ($pad + $bw)
            $frame.Visible = $false   # reshaper invisible pour éviter le flash carré rouge
            $frame.Bounds = New-Object Drawing.Rectangle($fx, $fy, $fw, $fh)
            $freg = New-Object Drawing.Region(New-Object Drawing.Rectangle(0, 0, $fw, $fh))
            $freg.Exclude((New-Object Drawing.Rectangle($bw, $bw, ($fw - 2 * $bw), ($fh - 2 * $bw))))
            $oldF = $frame.Region; $frame.Region = $freg; if ($oldF) { $oldF.Dispose() }
            $frame.Visible = $true; $pulse.Start()
            $cx = [Math]::Max($area.Left + 10, [Math]::Min($rect.X, $area.Right - $card.Width - 10))
            if (($fy + $fh + 12 + $card.Height) -le $area.Bottom) { $cy = $fy + $fh + 12 }
            elseif (($fy - 12 - $card.Height) -ge $area.Top) { $cy = $fy - 12 - $card.Height }
            else { $cy = [int](($area.Top + $area.Bottom - $card.Height) / 2) }
            $card.Location = New-Object Drawing.Point([int]$cx, [int]$cy)
        } else {
            # Pas de cible : voile plein (aucun trou), cadre caché, carte centrée.
            $vreg = New-Object Drawing.Region(New-Object Drawing.Rectangle(0, 0, $screen.Width, $screen.Height))
            $oldV = $veil.Region; $veil.Region = $vreg; if ($oldV) { $oldV.Dispose() }
            $pulse.Stop(); $frame.Visible = $false
            $card.Location = New-Object Drawing.Point([int](($area.Left + $area.Right - $card.Width) / 2), [int](($area.Top + $area.Bottom - $card.Height) / 2))
        }
        # Garder la carte au-dessus du voile et du cadre.
        $card.BringToFront(); $card.Activate()
    }.GetNewClosure()

    $finish = {
        try { $Ctx.State.TutorialSeen = $true; $Ctx.State.TutorialSeenVersion = $ver; Save-AppState $Ctx.State } catch { }
        try { $pulse.Stop() } catch { }
        try { $card.Close() } catch { }   # ferme la carte modale -> ShowDialog retourne
    }.GetNewClosure()

    $btnSkip.Add_Click($finish)
    $btnPrev.Add_Click({ if ($st.I -gt 0) { $st.I--; & $render } }.GetNewClosure())
    $btnNext.Add_Click({ if ($st.I -lt ($n - 1)) { $st.I++; & $render } else { & $finish } }.GetNewClosure())

    # Affichage : voile + cadre (non modaux), puis carte MODALE qui bloque l'app.
    # Le 1er rendu se fait dans Add_Shown (la carte a alors un handle valide).
    $card.Add_Shown({ & $render }.GetNewClosure())
    $veil.Show($form); $frame.Show($form)
    [void]$card.ShowDialog($form)

    # Nettoyage après fermeture de la carte (bouton ou Alt+F4).
    try { if (-not $Ctx.State.TutorialSeen) { $Ctx.State.TutorialSeen = $true; $Ctx.State.TutorialSeenVersion = $ver; Save-AppState $Ctx.State } } catch { }
    try { $pulse.Stop(); $pulse.Dispose() } catch { }
    try { $frame.Close() } catch { }
    try { $veil.Close() } catch { }
}
