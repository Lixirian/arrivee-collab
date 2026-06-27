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
           Text  = "Cet outil prépare l'arrivée d'un collaborateur SNCF : il génère un mot de passe, crée l'e-mail de notification (.msg) et la note ServiceNow. Faisons un tour rapide - à chaque étape, la zone concernée est entourée en violet."
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
