# Masquage automatique en bulle à la perte de focus — Design

- **Date** : 2026-06-30
- **Statut** : validé (brainstorming)
- **Version cible** : 1.5.0
- **Fichiers concernés** : `ArriveeCollab-PS/arrivee collab.ps1`, `ArriveeCollab-PS/lib/Tutorial.ps1`, `ArriveeCollab-PS/config.ps1`, `ArriveeCollab-PS/releases.json`

## Objectif

Quand l'application a le focus et que l'utilisateur bascule vers une **autre application**, la fenêtre se replie **automatiquement** en bulle ronde sur le bord de l'écran — exactement comme le bouton « masquer » (`»`) existant, mais sans clic. C'est un second moyen, automatique, de garder en permanence une vue sur l'outil sans le masquer à la main.

La bulle et son animation existent déjà (`Hide-App` / `Show-App`, bouton `btnHide`, bulle `$bubble`, fantôme `$ghost`). Cette fonctionnalité **n'ajoute aucune nouvelle UI ni animation** : elle se contente de déclencher `Hide-App` au bon moment.

## Comportement attendu

| Situation | Comportement |
|---|---|
| App au premier plan → l'utilisateur clique sur une autre appli | L'app se replie en bulle (animation vortex existante). |
| App **déjà en bulle** → l'utilisateur passe d'une fenêtre tierce à une autre, sans repasser par l'app | **Rien.** La bulle reste en place. |
| Clic sur la bulle | L'app revient (`Show-App` existant, inchangé). |
| Un dialogue/popup **de l'app** prend le focus (alerte, calendrier `DateTimePicker`, tutoriel, MAJ) | **Pas de masquage.** |
| Pendant le flux de génération du `.msg` (clic « Générer le .msg » jusqu'à la note ServiceNow), y compris l'ouverture du `.msg` dans Outlook | **Pas de masquage** : l'utilisateur a encore des actions sur l'app après l'ouverture du message. |
| Après le flux, l'utilisateur copie la note puis bascule vers ServiceNow (navigateur) | L'app se replie en bulle (comportement normal). |

Pas de réglage on/off : la fonctionnalité est **toujours active** (YAGNI ; non demandé).

## Architecture

Deux couches complémentaires.

### Couche 1 — Filtre par processus (mécanisme principal, permanent)

L'évènement `Form.Deactivate` se déclenche pour **toute** perte de focus, y compris vers une fenêtre enfant de la même application (dialogue modal, popup calendrier). Le bon critère n'est donc pas « ai-je perdu le focus ? » mais « **la fenêtre désormais au premier plan appartient-elle à un autre processus ?** ».

Mécanisme :

1. Un bloc P/Invoke expose `GetForegroundWindow()` et `GetWindowThreadProcessId()` (ajouté à côté des `Add-Type` existants, ou via `Add-Type -MemberDefinition`).
2. `$form.Add_Deactivate` arme un **`System.Windows.Forms.Timer` mono-coup (~200 ms)**. Le délai laisse le nouveau premier plan se stabiliser (au moment exact du `Deactivate`, la future fenêtre n'est pas toujours encore « foreground ») et absorbe les alt-tab transitoires.
3. Au tick du timer (`$timerAutoHide.Stop()` en premier — mono-coup) :
   - Si `$global:SuppressAutoHide` (voir couche 2) → ne rien faire.
   - Si `$global:AppHidden` ou animation en cours (`$slideTimer.Enabled`) → ne rien faire.
   - `$h = GetForegroundWindow()` ; si `$h` invalide (`IntPtr.Zero`) → ne rien faire.
   - `GetWindowThreadProcessId($h, [ref]$fgPid)` ; si `$fgPid == $PID` (`$PID` = variable automatique = PID du processus courant) → **ne rien faire** (c'est notre dialogue / popup calendrier / bulle / fantôme / tutoriel).
   - Sinon → `Hide-App`.

Une fois `$global:AppHidden = $true`, le formulaire est caché : son `Deactivate` ne peut plus se déclencher. La règle « bulle qui reste en place quand on switche entre fenêtres tierces » est donc **gratuite**, sans code dédié.

### Couche 2 — Drapeau de suppression du flux de génération

Variable globale `$global:SuppressAutoHide` (initialisée à `$false`). Le handler `btnGenMsg.Add_Click` est enveloppé d'un `try { $global:SuppressAutoHide = $true; … } finally { $global:SuppressAutoHide = $false }`.

Pendant tout le flux de génération — création du `.msg`, dialogues de vérification / nettoyage, ouverture du `.msg` dans Outlook (`Invoke-Item`), dialogue bénéficiaire, mise à jour de la note — l'app **ne se replie jamais**. À la sortie du handler, le comportement normal reprend.

Cette couche rend l'intention **durable** : même si l'ordre des dialogues change un jour (ex. ouverture du `.msg` déplacée en dernière action), le flux reste protégé sans dépendre du timing « le prochain `ShowDialog` reprend le focus avant le tick ».

## Points d'intégration dans `arrivee collab.ps1`

- **P/Invoke** : ajouter `GetForegroundWindow` / `GetWindowThreadProcessId` (nouveau `Add-Type` ou classe utilitaire) près des autres `Add-Type` (zone `DarkTitleBar` / `LayeredGhost`).
- **État** : déclarer `$global:SuppressAutoHide = $false` dans la zone d'init des globales de masquage (vers la ligne 1376, à côté de `$global:AppHidden`).
- **Timer + handler** : déclarer `$timerAutoHide` (mono-coup, 200 ms) et `$form.Add_Deactivate({ … })` après la définition de `Hide-App`/`Show-App` (après la ligne ~1717), pour que `Hide-App` soit déjà défini.
- **Suppression** : envelopper le corps de `btnGenMsg.Add_Click` (lignes ~1270-1340) d'un `try/finally`.

## Conventions projet (obligatoires d'après la mémoire)

- **Tutoriel** : `lib/Tutorial.ps1` — ajouter une étape expliquant le masquage automatique, juste après l'étape « Masquer l'application » (`$btnHide`). Bump `$script:TutorialVersion` de `4` → `5`.
- **Version** : `config.ps1` `Version` `1.4.3` → `1.5.0`.
- **Changelog** : nouvelle entrée dans `releases.json`.
- **Build & publication** : `build-zip.ps1` (zip versionné + `latest.json` + `dist-ready/`), puis commit + push vers `origin` (dépôt privé `Lixirian/arrivee-collab`). Si verrou Synology → relancer le build.

## Tests

Le projet utilise `tests/Test-ArriveeCollab.ps1` (fonction `Assert` maison). La logique nouvelle est essentiellement événementielle / UI (difficile à tester unitairement sans fenêtre). Couvrir ce qui est testable purement :

- La fonction de décision « doit-on masquer ? » extraite en helper pur testable, par ex. `Should-AutoHide($appHidden, $animating, $suppressed, $foregroundPid, $ownPid)` renvoyant `$true`/`$false`. Cas : même PID → `$false` ; autre PID → `$true` ; suppressed → `$false` ; appHidden → `$false` ; animating → `$false` ; PID nul/0 → `$false`.

Validation manuelle (checklist) : masquage au clic vers une autre appli ; non-masquage à l'ouverture d'un dialogue / du calendrier ; non-masquage pendant le flux `.msg` (y compris ouverture du message) ; masquage normal après le flux en basculant vers ServiceNow ; bulle inerte quand on switche entre fenêtres tierces.

## Hors périmètre

- Aucun réglage on/off, aucune persistance dans `state.json` pour cette fonctionnalité.
- Aucune modification de l'animation, de la bulle, du déplacement de la bulle, ou de `Show-App`/`Hide-App`.
- Pas de liste blanche par nom de processus (Outlook géré par le drapeau de suppression, pas par un filtrage spécifique).
