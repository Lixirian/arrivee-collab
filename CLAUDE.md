# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Projet

Outil d'automatisation SNCF pour l'onboarding de nouveaux collaborateurs. Application GUI Windows Forms écrite en PowerShell qui génère des mots de passe sécurisés et crée des e-mails Outlook (.msg) de notification.

## Lancement

```powershell
# Méthode recommandée (sans élévation UAC)
# Double-cliquer sur "arrivée de collab.vbs"

# Ou directement en PowerShell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "arrivee collab.ps1"

# Créer un raccourci bureau (génère/régénère le fichier .vbs)
.\CreerRaccourci.ps1
```

Pas de build, pas de tests, pas de linting — c'est un utilitaire autonome.

## Architecture

**Tout le code applicatif est dans `arrivee collab.ps1`** (~886 lignes). Il n'y a pas de modules externes.

Le script suit une structure linéaire :
1. Chargement assemblies .NET + déclaration de la classe C# inline `DarkTitleBar` (`Add-Type`)
2. Génération du lanceur VBS (code de `CreerRaccourci.ps1` dupliqué inline)
3. Résolution des chemins
4. Définition de la palette de couleurs (`$c*`) + fonction `Show-AlertDialog`
5. Vérification des ressources (via `Show-AlertDialog` thème sombre)
6. Déclaration des fonctions métier et UI
7. Construction de l'interface Windows Forms (contrôles, layout responsive, événements)
8. Boucle principale via `$form.ShowDialog()`

### Flux de travail utilisateur

1. Saisie des informations (RITM, email du demandeur, nom, prénom)
2. Génération d'un mot de passe aléatoire 12 caractères → copié dans le presse-papiers
3. Création d'un fichier texte + ZIP dans `Mot de passe/`
4. Dialogue de vérification des actions pré-requises (Mon-AD, OU)
5. Création d'un fichier `.msg` Outlook avec le ZIP en PJ et un corps HTML formaté SNCF
6. Ouverture optionnelle du .msg + archivage automatique dans `Archive message/` (via script PowerShell en arrière-plan qui poll le fichier jusqu'à sa libération)
7. Nettoyage optionnel des fichiers temporaires
8. Saisie des informations bénéficiaire (email, OU) → mise à jour de la note ServiceNow copiable

### Fonctions clés

| Fonction | Rôle |
|---|---|
| `Generate-Password` | Mot de passe 12 chars (ASCII 33-38, 48-57, 65-90, 97-122) |
| `Copy-Clipboard` | Wrapper `[System.Windows.Forms.Clipboard]::SetText` |
| `Creer-FichierMotDePasse` | Écrit le mot de passe dans un .txt |
| `Creer-Zip` | Compresse le .txt dans un ZIP (via dossier temp `$env:TEMP\tempZipSNCF`) |
| `Creer-FichierMsg` | Crée un .msg via COM Outlook |
| `Attendre-FermetureOutlookEtDeplacer` | Lance un script PS en arrière-plan (max 30 tentatives, 2s d'intervalle) qui attend la libération du fichier .msg puis le déplace dans Archive |
| `Get-CorpsMessageHTML_Preview` / `_Final` | Génère le HTML du mail (Preview inclut l'objet + cadre sombre, Final = mail brut envoyé) |
| `Show-AlertDialog` | Boîte de dialogue dark theme (simple OK ou Oui/Non avec textes personnalisables) |
| `Show-BeneficiaireDialog` | Dialogue pour saisir l'email et l'OU du bénéficiaire (OU par défaut : `COMMUN.AD.SNCF.FR/.../Utilisateurs`) |
| `Get-CopyBlockText` | Génère le texte de la note ServiceNow (affiché dans le panneau copiable) |
| `Update-Preview` | Met à jour l'aperçu HTML et l'objet en temps réel à chaque modification des champs |
| `Layout-FormPanel` | Recalcule le layout responsive du formulaire à chaque redimensionnement |

### Classe C# inline

| Classe | Rôle |
|---|---|
| `DarkTitleBar` | Active la barre de titre sombre Windows 10/11 via `DwmSetWindowAttribute` (dwmapi.dll), active le mode sombre système via `uxtheme.dll`, applique les scrollbars sombres, et définit l'AppUserModelID (`SNCF.ArriveeCollaborateur`) |

### Scripts secondaires

- **`arrivée de collab.vbs`** — Lanceur VBScript qui exécute le PS1 en mode fenêtre masquée sans élévation
- **`CreerRaccourci.ps1`** — Génère (ou régénère) le fichier VBS lanceur. Note : ce code est aussi dupliqué inline dans le PS1 principal (lignes ~169-228)

### Dossiers

- `image-arrivee-collab.ico` — Icône de l'application (fenêtre principale + dialogues). Note : `CreerRaccourci.ps1` référence un nom différent (`arrivee-collab.ico`) pour le raccourci VBS.
- `Resources/` — Images embarquées dans le mail (`image arrivee collab.jpg` + `Signature.png`). **Obligatoire** au lancement.
- `Mot de passe/` — Fichiers temporaires (mot de passe .txt et .zip). Créé automatiquement.
- `Archive message/` — Stockage des .msg envoyés. Créé automatiquement.

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
- Les variables globales utilisent le préfixe `$global:` (`$global:CheminZip`, `$global:CheminFichierTxt`, `$global:CopyOU`, `$global:CopyEmailBenef`)
- Le fichier .msg est nommé `{RITM}_notif.msg` à la racine du projet avant archivage
