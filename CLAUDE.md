# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Projet

Outil d'automatisation SNCF pour l'onboarding de nouveaux collaborateurs. Application GUI Windows Forms écrite en PowerShell qui génère des mots de passe sécurisés et crée des e-mails Outlook (.msg) de notification.

## Lancement

```powershell
# Développement — lancer directement le script source
powershell.exe -ExecutionPolicy Bypass -NoProfile -STA -File "ArriveeCollab-PS\arrivee collab.ps1"

# Ou via le lanceur local (fenêtre masquée, sans élévation UAC)
# Double-cliquer sur ArriveeCollab-PS\Start-ArriveeCollab.vbs

# Exécuter les tests unitaires
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ArriveeCollab.ps1

# Construire un zip de distribution versionné
.\build-zip.ps1
```

**Lancement utilisateur final** : double-clic sur `Arrivee Collab.cmd` (copié depuis `dist-launcher/`, posé n'importe où — dossier OneDrive partagé, bureau…). Le bootstrap lit `latest.json` sur le **dépôt GitHub public** (`Config.UpdateRepo`, via raw.githubusercontent.com, sans jeton ; repli : fichiers posés à côté du .cmd), installe l'app (première installation uniquement) sous `%LOCALAPPDATA%\Arrivee-Collab\` puis la lance. Les mises à jour ultérieures se font via la pastille in-app : l'app interroge périodiquement GitHub (repli dossier OneDrive) et propose d'installer la nouvelle version. La publication d'une version = `.\build-zip.ps1` qui commit + push automatiquement `latest.json` + le zip versionné sur `origin` (GitHub).

## Architecture

### Arborescence

```
ArriveeCollab-PS/          ← code source
  arrivee collab.ps1       ← script principal (~1156 lignes)
  config.ps1               ← version de l'app + UpdateRepo (dépôt GitHub) + UpdateDir (repli OneDrive)
  releases.json            ← changelog versionné
  image-arrivee-collab.ico
  Resources/               ← images embarquées dans le mail (obligatoire)
  Start-ArriveeCollab.vbs  ← lanceur local (fenêtre masquée, développement)
  Start-ArriveeCollab.cmd
  lib/
    Common.ps1             ← chemins data, log, Compare-AppVersion, Write-AppLog
    State.ps1              ← state.json, migration de version

dist-launcher/             ← fichiers à poser sur le OneDrive de distribution
  Arrivee Collab.cmd       ← point d'entrée utilisateur final
  Arrivee Collab.vbs
  bootstrap.ps1            ← première installation de l'app sous %LOCALAPPDATA%
  LISEZMOI.txt

build-zip.ps1              ← packaging : zip versionné + latest.json + dist-ready/
latest.json                ← métadonnées de la dernière release
tests/
  Test-ArriveeCollab.ps1   ← tests unitaires (fonction Assert maison)
docs/superpowers/          ← specs et plans de conception
  specs/2026-06-27-versionning-maj-tutoriel-design.md
  plans/2026-06-27-plan-a-fondation-distribution.md
```

### Modèle d'exécution

L'app écrit toutes ses sorties sous `%LOCALAPPDATA%\Arrivee-Collab\` :
- `app\` — copie de `ArriveeCollab-PS/` (écrasée lors des mises à jour par `lib/Update.ps1`)
- `data\Mot de passe\` — .txt et .zip temporaires du mot de passe
- `data\Archive message\` — .msg archivés après envoi
- `state.json` — état persistant (version installée…)
- `app_debug.log` — journal de débogage

### Structure du script principal

`arrivee collab.ps1` suit une structure linéaire :
1. Chargement assemblies .NET + déclaration de la classe C# inline `DarkTitleBar` (`Add-Type`)
2. Import des modules `lib/Common.ps1` et `lib/State.ps1`, initialisation du contexte `$global:Ctx`
3. Résolution des chemins (via `Get-AppDataDir` / `Get-AppWorkDir`)
4. Définition de la palette de couleurs (`$c*`) + fonction `Show-AlertDialog`
5. Vérification des ressources (via `Show-AlertDialog` thème sombre)
6. Déclaration des fonctions métier et UI
7. Construction de l'interface Windows Forms (contrôles, layout responsive, événements)
8. Boucle principale via `$form.ShowDialog()`

### Flux de travail utilisateur

L'événement `btnGenMsg.Add_Click` (vers la fin du PS1) se scinde en **deux modes** selon la case à cocher `chkMdpDejaInit` :

**Mode standard (nouveau mot de passe)** :
1. Saisie des informations (RITM, email du demandeur, nom, prénom)
2. Génération d'un mot de passe aléatoire 12 caractères → copié dans le presse-papiers
3. Création d'un fichier texte + ZIP dans `Mot de passe/`
4. Dialogue de vérification des actions pré-requises (Mon-AD, OU)
5. Création d'un fichier `.msg` Outlook avec le ZIP en PJ et un corps HTML formaté SNCF (`Get-CorpsMessageHTML_Final`)
6. Ouverture optionnelle du .msg + archivage automatique dans `Archive message/` (via script PowerShell en arrière-plan qui poll le fichier jusqu'à sa libération)
7. Nettoyage optionnel des fichiers temporaires
8. Saisie des informations bénéficiaire (email, OU) → mise à jour de la note ServiceNow copiable

**Mode « Mot de passe déjà initialisé »** (case `chkMdpDejaInit` cochée) : affiche un `DateTimePicker` (date d'initialisation), désactive la génération de mot de passe, et envoie un mail différent (`Get-CorpsMessageHTML_DejaInit_Final`) **sans PJ ZIP** indiquant que le compte possède déjà un mot de passe. Pas d'étape de vérification Mon-AD ni de nettoyage. La date est reportée dans l'en-tête de la note ServiceNow via `$global:CopyDateInit`.

### Fonctions clés

| Fonction | Rôle |
|---|---|
| `Generate-Password` | Mot de passe 12 chars (ASCII 33-38, 48-57, 65-90, 97-122) |
| `Copy-Clipboard` | Wrapper `[System.Windows.Forms.Clipboard]::SetText` |
| `Creer-FichierMotDePasse` | Écrit le mot de passe dans un .txt |
| `Creer-Zip` | Compresse le .txt dans un ZIP (via dossier temp `$env:TEMP\tempZipSNCF`) |
| `Creer-FichierMsg` | Crée un .msg via COM Outlook |
| `Attendre-FermetureOutlookEtDeplacer` | Lance un script PS en arrière-plan (max 30 tentatives, 2s d'intervalle) qui attend la libération du fichier .msg puis le déplace dans Archive |
| `Get-CorpsMessageHTML_Preview` / `_Final` | Génère le HTML du mail standard (Preview inclut l'objet + cadre sombre, Final = mail brut envoyé) |
| `Get-CorpsMessageHTML_DejaInit_Preview` / `_Final` | Variantes pour le mode « mot de passe déjà initialisé » (mail « Mouvement d'un Agent SNCF », mentionne la date d'init, pas de PJ) |
| `Show-AlertDialog` | Boîte de dialogue dark theme (simple OK ou Oui/Non avec textes personnalisables) |
| `Show-BeneficiaireDialog` | Dialogue pour saisir l'email et l'OU du bénéficiaire. L'OU est une **liste déroulante** (`DropDownList`) figée de 9 entités SudEst (`$ouMap` : GaresEtConnexions, HEXAFRET, OPTIMSERVICES, SARESEAU, SASNCF, SAVOYAGEURS, SudAzur, SudMobilitesTechnologies, TECHNIS), chacune mappée vers un chemin `COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/.../Utilisateurs`. Sélection par défaut : `SudMobilitesTechnologies` (index 7) |
| `Get-CopyBlockText` | Génère le texte de la note ServiceNow (affiché dans le panneau copiable). L'en-tête change selon `$global:CopyDateInit` |
| `Update-Preview` | Met à jour l'aperçu HTML et l'objet en temps réel à chaque modification des champs |
| `Layout-FormPanel` | Recalcule le layout responsive du formulaire à chaque redimensionnement |

### Classe C# inline

| Classe | Rôle |
|---|---|
| `DarkTitleBar` | Active la barre de titre sombre Windows 10/11 via `DwmSetWindowAttribute` (dwmapi.dll), active le mode sombre système via `uxtheme.dll`, applique les scrollbars sombres, définit l'AppUserModelID (`SNCF.ArriveeCollaborateur`), et installe un `SetWinEventHook` (`HookCalendarPopup`) qui force le thème sombre sur les popups de calendrier (`SysMonthCal32` / `DropDown`) du `DateTimePicker` dès leur ouverture |

### Scripts secondaires

- **`ArriveeCollab-PS/Start-ArriveeCollab.vbs`** / **`.cmd`** — Lanceurs locaux (développement) : exécutent le PS1 en mode fenêtre masquée, sans élévation UAC
- **`dist-launcher/bootstrap.ps1`** — Bootstrap de distribution : télécharge le zip versionné depuis le dépôt GitHub public (repli : dossier local du .cmd), installe l'app sous `%LOCALAPPDATA%\Arrivee-Collab\app\`, puis lance `Start-ArriveeCollab.vbs`
- **`build-zip.ps1`** — Packaging : crée un zip versionné (`Arrivee-Collab_version<X>.zip`), génère `latest.json`, peuple `dist-ready/` avec les bundles complets, et tente un commit/push vers `origin`
- **`lib/Common.ps1`** — Fonctions partagées : `Get-AppDataDir`, `Get-AppWorkDir`, `Compare-AppVersion`, `Write-AppLog`, `Initialize-AppLog`
- **`lib/State.ps1`** — Gestion de `state.json` : `New-AppState`, `Save-AppState`, `Invoke-AppVersionMigration`
- **`lib/Update.ps1`** — détection MAJ (GitHub raw en canal principal, dossier OneDrive en repli), pastille, dialogues, self-update, Quoi de neuf
- **`lib/Tutorial.ps1`** — tutoriel interactif data-driven (carte + surbrillance) : s'affiche automatiquement au premier lancement (~1,4 s après ouverture) et peut être rejoué à tout moment via le bouton « ? » en haut à droite. Versionné (`$script:TutorialVersion`) ; 10 étapes définies dans `Get-TutorialSteps`, état persisté dans `state.json` (`TutorialSeen` / `TutorialSeenVersion`)

### Dossiers

- `ArriveeCollab-PS/image-arrivee-collab.ico` — Icône de l'application (fenêtre principale + dialogues)
- `ArriveeCollab-PS/Resources/` — Images embarquées dans le mail (`image arrivee collab.jpg` + `Signature.png`). **Obligatoire** au lancement.
- `%LOCALAPPDATA%\Arrivee-Collab\data\Mot de passe\` — Fichiers temporaires (mot de passe .txt et .zip). Créé automatiquement.
- `%LOCALAPPDATA%\Arrivee-Collab\data\Archive message\` — Stockage des .msg envoyés. Créé automatiquement.
- `docs/superpowers/` — Spécifications et plans de conception (voir `specs/` et `plans/`).

## Dépendances système

- Windows PowerShell 5.0+
- Assemblies .NET : `System.Windows.Forms`, `System.Drawing`, `System.IO.Compression.FileSystem`
- Microsoft Outlook installé localement (objet COM `Outlook.Application` pour la création des .msg)

## Thème graphique (style LixiSpace)

L'interface utilise un thème sombre inspiré de LixiSpace. Les couleurs sont définies dans des variables `$c*` :

| Token | Hex | Usage |
|---|---|---|
| `$cBgMain` | #1E1E1E | Fond principal |
| `$cBgSecondary` | #252526 | Panneaux secondaires |
| `$cSurface` | #2D2D30 | Surfaces (inputs, images) |
| `$cBorder` | #3E3E42 | Bordures, boutons secondaires |
| `$cAccentViolet` | #9B59B6 | Accent principal (boutons, titres) |
| `$cAccentVioletHover` | #8E44AD | Hover boutons violet |
| `$cAccentBlue` | #007ACC | Accent secondaire (bouton .msg) |
| `$cAccentBlueHover` | #005A9E | Hover bouton bleu |
| `$cDanger` | #E74C3C | Erreurs, alertes critiques |
| `$cSuccess` | #27AE60 | Confirmation, succès |
| `$cWarning` | #F39C12 | Avertissements |
| `$cTextPrimary` | #CCCCCC | Texte principal |
| `$cTextSecondary` | #808080 | Labels, sous-titres |
| `$cWhite` | #FFFFFF | Texte boutons |

Boutons : `FlatStyle = 'Flat'`, `BorderSize = 0`, police Segoe UI SemiBold. Barre de titre sombre via `DwmSetWindowAttribute`. Preview HTML : cadre sombre (#1E1E1E) avec contenu email sur fond blanc. Le formulaire est responsive grâce à `Layout-FormPanel` et aux `Anchor` sur les contrôles.

## Conventions

- Le code et l'interface sont entièrement en français
- Les noms de fonctions utilisent la convention `Verbe-Nom` PowerShell mais avec des verbes français (`Creer-`, `Attendre-`)
- L'adresse expéditeur configurée est `noreply.dsnu.asut.asuidf@sncf.fr`
- Les liens dans le template HTML pointent vers le SharePoint interne SNCF
- Les variables globales utilisent le préfixe `$global:` (`$global:CheminZip`, `$global:CheminFichierTxt`, `$global:CopyOU`, `$global:CopyEmailBenef`, `$global:CopyDateInit`)
- Le fichier .msg est nommé `{RITM}_notif.msg` dans `%LOCALAPPDATA%\Arrivee-Collab\` avant archivage
