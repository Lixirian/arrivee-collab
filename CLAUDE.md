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

**Lancement utilisateur final** : double-clic sur `Arrivee Collab.cmd` — **fichier unique** (comme `Biblio-Tech.cmd`), copié depuis `dist-launcher/` ou `dist-ready/`, posé **seul** n'importe où (dossier OneDrive partagé, bureau…), sans .vbs ni bootstrap.ps1 à côté. Il est **généré par `build-zip.ps1`** : en-tête batch (`AC_SELF=%~f0`, PowerShell masqué qui relit le .cmd et exécute ce qui suit le marqueur `##ARRIVEECOLLAB-PS##`) + `dist-launcher/bootstrap.ps1` tel quel — ne jamais éditer le .cmd à la main, modifier `bootstrap.ps1` (où `$dist` = dossier du .cmd via `$env:AC_SELF`, `$PSScriptRoot` étant vide). Le bootstrap lit `latest.json` sur le **dépôt GitHub public** (`Config.UpdateRepo`, via raw.githubusercontent.com, sans jeton ; repli : fichiers posés à côté du .cmd), installe l'app (première installation uniquement) sous `%LOCALAPPDATA%\Arrivee-Collab\` puis la lance. Les mises à jour ultérieures se font via la pastille in-app : l'app interroge périodiquement GitHub (repli dossier OneDrive) et propose d'installer la nouvelle version.

## Publier une mise à jour (démarche OBLIGATOIRE pour toute évolution)

Le canal de distribution est le dépôt GitHub public **`Lixirian/arrivee-collab`** (branche `main`) : les apps installées et le lanceur y lisent `latest.json` + le zip versionné via raw.githubusercontent.com. Toute modification livrée aux utilisateurs suit ces étapes, dans l'ordre :

1. **Incrémenter la version** dans `ArriveeCollab-PS/config.ps1` (`$Config.Version`, format `X.Y.Z` : mineur pour une fonctionnalité, patch pour un correctif).
2. **Ajouter l'entrée changelog** correspondante en tête de `ArriveeCollab-PS/releases.json` (mêmes numéros de version ; ces notes alimentent le dialogue de la pastille et le « Quoi de neuf »). Rédiger pour l'utilisateur final, en français.
3. Si le **contenu du tutoriel** a changé (`lib/Tutorial.ps1`), mettre à jour le texte des étapes ; incrémenter `$script:TutorialVersion` seulement si le tutoriel doit se ré-afficher à tous.
3 bis. **Fiches DSI / cybersécurité** (`..\Arrivee collab - Note DSI\` : « Note DSI - Arrivée Collaborateur.docx » et « Fiche cybersécurité - Arrivée Collaborateur.docx », **hors dépôt public**, diffusion restreinte pour la fiche cyber) : relire ce que la version change (sécurité, flux, données, installation, lanceur), mettre à jour le contenu et la ligne « Version de l'outil : X » / « Version analysée : X » (retouches dans Word, après sauvegarde ; empreintes SHA-256 du lanceur en annexe si `dist-launcher/` a changé). **Le build refuse de publier si ces versions ne correspondent pas** (`-SkipDocCheck` pour passer outre). Ne jamais les commiter dans le dépôt.
4. **Lancer les tests** : `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-ArriveeCollab.ps1` — tout doit passer.
5. **Builder et publier** : `.\build-zip.ps1` — génère `Arrivee-Collab_version<X>.zip` + `latest.json`, archive l'ancien zip dans `Archives\`, régénère `dist-ready\`, puis **commit + push automatiquement sur `origin`**, à la fois sur la branche de travail et sur la **branche de publication lue par les apps** (`$Config.UpdateBranch`, donc `main`). Le script termine par un contrôle `git ls-remote` et affiche **`PUBLICATION OK`** seulement si `origin/main` porte bien ce build ; en cas de `PUBLICATION KO` (branche divergente, hors ligne), **rien n'est distribué** — appliquer le rattrapage affiché (`git merge -s ours origin/main` puis `git push origin HEAD:main`). Une fois OK, les apps voient la nouvelle version sous ~5 minutes. Aucun transfert manuel.
   - Si le build échoue sur `Le processus ne peut pas accéder au fichier ... .zip` (verrou Synology Drive) : **relancer simplement `.\build-zip.ps1`**.
   - Après le push, le build crée la **release GitHub `v<X>`** (zip + `latest.json`, via `gh`) et affiche `RELEASE OK` : c'est le canal lu en premier par l'app et le lanceur (`github.com/<repo>/releases/latest/download/latest.json`, en ligne immédiatement ; la branche servie par le CDN raw garde ~5 min de cache). `RELEASE KO` = les postes se rabattent sur la branche (~5 min) ; relancer le build.
   - **Signature (normes cyber/DSI)** : chaque zip est signé RSA 3072 / SHA-256 (texte `Arrivee-Collab|<version>|<SHA-256>`, champs `sha256` + `sig` de `latest.json`). Clé PRIVÉE chiffrée DPAPI dans `%USERPROFILE%\.arrivee-collab-signing\` (jamais dans le dépôt) ; clé PUBLIQUE dans `config.ps1` (`ReleasePublicKey`) et `dist-launcher/bootstrap.ps1`. L'app (`Test-ReleasePackage`, `lib/Update.ps1`) et le lanceur refusent tout zip non conforme. Le build échoue si la clé est absente ou ne correspond pas. Sauvegarde : `.\build-zip.ps1 -ExportSigningKey` ; nouveau PC : `-ImportSigningKey -KeyBackup <fichier>` ; **ne jamais régénérer la clé** (`-NewSigningKey`) sans redistribuer le lanceur.
6. **Cas particulier — lanceur modifié** : si `dist-launcher/` a changé, le build produit un bundle `Arrivee-Collab-maj-<X>.zip` marqué « COMPLET » ; il faut alors reposer manuellement le nouveau `.cmd`/`bootstrap.ps1` aux endroits où les utilisateurs le double-cliquent (le bootstrap ne se met pas à jour tout seul). Bundle « minimal » = rien à faire.

Ne jamais committer de fichiers sensibles : `Mot de passe/`, `Archive message/` et `*.msg` sont exclus par `.gitignore` (le dépôt est PUBLIC).

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

dist-launcher/             ← lanceur
  Arrivee Collab.cmd       ← FICHIER UNIQUE distribué (GÉNÉRÉ par build-zip.ps1 = en-tête + bootstrap.ps1)
  bootstrap.ps1            ← source du lanceur (première installation sous %LOCALAPPDATA%), non distribué seul
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
1. Saisie des informations (RITM, email du demandeur, nom, prénom) — **validées** avant génération (`Test-NumeroRitmValide` `^RITM\d{7,10}$`, `Test-NomPrenomValide`, `Test-AdresseMailValide`, `lib/Common.ps1`)
2. Génération du mot de passe (`New-MotDePasse` : 12 car., RNG cryptographique, 1 majuscule + 1 minuscule + 1 chiffre + 1 spécial garantis, sans caractères ambigus ni `" & '`) → copié via `Copy-MotDePasseSecurise` (exclu de Win+V et du cloud, effacé après 2 min)
3. Création d'un fichier texte + ZIP dans `Mot de passe/` (nom assaini par `ConvertTo-NomFichierSur`)
4. Dialogue de vérification des actions pré-requises (Mon-AD, OU)
5. Création d'un fichier `.msg` Outlook avec le ZIP en PJ et un corps HTML formaté SNCF (`Get-CorpsMessageHTML_Final`, saisies encodées HTML)
6. **Suppression automatique** du .txt et du .zip (`Remove-FichiersMotDePasse`, aussi à la réinitialisation et à la fermeture ; purge complète de `Mot de passe/` au démarrage)
7. Ouverture optionnelle du .msg + archivage dans `Archive message/` (script détaché `$script:WatcherArchivage`, chemins passés en **paramètres**, auto-suppression) ; les archives de plus de **30 jours** sont purgées au démarrage (`$global:RetentionArchivesJours`)
8. Saisie des informations bénéficiaire (email, OU) → mise à jour de la note ServiceNow copiable

**Mode « Mot de passe déjà initialisé »** (case `chkMdpDejaInit` cochée) : Mon-AD n'affiche pas une date mais le **nombre de jours restants avant expiration** du mot de passe (validité 365 jours, `$script:DureeValiditeMdp` dans `lib/Common.ps1`). L'utilisateur saisit donc ce nombre de jours (0 à 365) dans `$txtJoursInit` (chiffres uniquement, flèches ↑/↓ pour ajuster) et l'app calcule la **date d'initialisation** `aujourd'hui - (365 - X)` (`Get-DateInitDepuisJoursRestants`) affichée en temps réel dans `$lblDateCalc` — c'est cette date qui part dans le mail et la note. Ce mode désactive la génération de mot de passe et envoie un mail différent (`Get-CorpsMessageHTML_DejaInit_Final`) **sans PJ ZIP** indiquant que le compte possède déjà un mot de passe. Pas d'étape de vérification Mon-AD ni de nettoyage. La génération du .msg est bloquée si le décompte est vide ou invalide. La date est reportée dans l'en-tête de la note ServiceNow via `$global:CopyDateInit`.

**Sécurité (revue complète du 27/10/2026, v1.13.0)** : journaux sans nom ni CP (RITM et compteurs seulement) ; aperçu WebBrowser verrouillé (navigation hors `about:blank` annulée, pas de menu contextuel) ; lanceurs et `Start-Process` avec chemins absolus (`%SystemRoot%\System32\...`) ; manifeste signé en entier (`msig` = `Get-ManifestSignedText` : version|sha|date|hash des notes) — un manifeste non authentifié est ignoré (`Complete-UpdateCheck`) ; le lanceur refuse toute version < `$MinVersion` (1.13.0) ; le build n'empaquette que `git ls-files --cached --others --exclude-standard` (et `git add` les nouveaux fichiers) ; la sauvegarde de clé exige `-KeyBackup` hors dépôt et hors OneDrive. Page SNOW : `Test-SnowHoteAutorise` (instance exacte + `*.sncf.fr`), `NavigationStarting`/`NewWindowRequested` bloqués (`[SECU]` dans le journal), Basic auth refusée, DevTools coupés, `--auth-server-allowlist=*.sncf.fr,sncf.service-now.com` sans délégation. Le mode test `ARRIVEE_COLLAB_*_FAKE` est ignoré par la copie installée. Risques résiduels et décisions attendues : fiches `..\Arrivee collab - Note DSI\`.

**Vérifications ServiceNow** (ligne 4 du formulaire : « Vérif. homonymes » / « Vérif. doublons ») : les deux passent par la **page cachée commune `lib/SnowPage.ps1`** (`$global:Snow`, `Initialize-SnowEngine -Type`, `Submit-SnowRequete <type> <clé> <url JSONv2>`, une requête en attente par type, rappels `OnResultat`/`OnStatut` par type). Après chargement de la page, phase `settle` de 2 s (l'UI Next Experience s'initialise encore) ; la requête (`Get-SnowKickJs`) ne part que si `document.readyState === 'complete'`, a son propre délai de 20 s, joint `X-UserToken` (`g_ck`) si présent et rapporte HTTP + content-type ; délai dépassé / page rechargée / 401-403 / HTML au lieu du JSON ⇒ `Invoke-SnowResync` = **relance de la synchro SSO** (rechargement de la page) puis nouvel essai, 2 fois max (journal `[SNOW] … -> resynchronisation SSO`). Le mode du formulaire est piloté par `Update-ModeFormulaire` (`normal` | `homonyme` | `doublon`, **le doublon l'emporte**) à partir de `$global:HomoActif` / `$global:DoublonActif` ; `$global:ModeHomonyme` / `$global:ModeDoublon` = mode effectif.

**Mode « Doublon de demande »** (`lib/Doublons.ps1`) : nécessite RITM + nom (la RITM traitée a ses propres tâches dans la liste, elle est écartée). Requête JSONv2 `sc_task` = filtre de l'équipe (`short_descriptionSTARTSWITHSupport Site^ORshort_descriptionSTARTSWITHRecherche des nouveaux gestionnaires`) + `active=true` + recherche texte `123TEXTQUERY321=<nom>`, `displayvalue=all` sans liste de champs : le champ « Bénéficiaire » est reconnu **par sa valeur** (`Get-ChampsBeneficiaire`, nom exact, hors demandeur/assigné…) quel que soit son nom technique (journalisé : `[DOUBLON] … champ(s) <nom>`). Doublon = autre RITM (`dv_request_item`), tâche **encore en cours** (`Test-TacheEnCours` : ni `active=false`, ni états 3/4/7, ni libellé réalisé/fermé/annulé — une demande réalisée n'est PAS un doublon), **même motif** que la RITM traitée (même `short_description`, déduite de ses propres tâches présentes dans les résultats par `Get-MotifsRitmCourante` ; motif inconnu ⇒ toutes les demandes en cours retenues), quel que soit le demandeur. Le champ bénéficiaire réel s'appelle `u_beneficiaire` (confirmé en prod). Journal : `[DOUBLON] RITMx : n tâche(s) active(s) examinée(s), motif de référence : …, k doublon(s).` Pastille rouge (`$cDanger`) → `Show-DoublonsDialog` (choix de la RITM citée, rappel de balise) ; mail `Get-CorpsMessageHTML_Doublon_*` (« Nous annulons votre sollicitation… <RITM>… »), objet `RITMxxx - Annulation doublon Prénom NOM`, note Snow `***Annulation - Doublon*** / Doublon de RITMyyy / Mail envoyé au demandeur`, puis rappel : passer la balise de la RITM à **« Annulation - Doublon »**. Test hors réseau : `ARRIVEE_COLLAB_DOUBLON_FAKE=<json {records:[…]}>`.

**Mode « Homonymes »** (`lib/Homonymes.ps1`) : ~1,2 s après la saisie du nom (ou clic sur `$btnVerifHomo` « Vérif. homonymes »), l'app interroge ServiceNow via un **WebView2 caché** (fenêtre `HomoHostForm` hors écran, sans activation ; DLL WebView2 1.0.2651.64 embarquées dans `lib/webview2/`, profil persistant `%LOCALAPPDATA%\Arrivee-Collab\webview2` = session SSO conservée). La recherche est une requête **JSONv2 same-origin** `sys_user.do?JSONv2&sysparm_query=nameLIKE<mot>^…` lancée par `ExecuteScriptAsync` (résultat déposé dans `window.__acHomo`, relevé par une pompe `Windows.Forms.Timer` 250 ms — `ExecuteScriptAsync` ne résout pas les promesses). Le SSO (auth_redirect → IdP OpenAM) est attendu en silence ; la fenêtre n'est montrée qu'après 12 s sans retour sur l'instance. `Select-Homonymes` garde les comptes au nom **exactement** identique (accents/casse/ordre ignorés) ; ≥ 2 comptes = homonymes → `Set-ModeHomonyme $true` : pastille rose (`$cHomonyme` #E84393) cliquable → `Show-HomonymesDialog` pour choisir le CP de la RITM ; seul `$btnGenMsg` (« Générer mail homonyme ») reste actif, mail `Get-CorpsMessageHTML_Homonyme_*` au demandeur, sans PJ, sans vérification Mon-AD/OU ni bénéficiaire. « Pas un homonyme » écarte l'alerte pour ce nom. **Test hors réseau SNCF** : `ARRIVEE_COLLAB_HOMO_FAKE=<json {records:[…]}>` remplace ServiceNow (poste de dev sans VPN = SSO impossible).

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
| `Get-CorpsMessageHTML_DejaInit_Preview` / `_Final` | Variantes pour le mode « mot de passe déjà initialisé » (mail « Mouvement d'un Agent SNCF », mentionne la date d'init **calculée**, pas de PJ) |
| `Show-AlertDialog` | Boîte de dialogue dark theme (simple OK ou Oui/Non avec textes personnalisables) |
| `Show-BeneficiaireDialog` | Dialogue pour saisir l'email et l'OU du bénéficiaire. L'OU est une **liste déroulante** (`DropDownList`) figée de 9 entités SudEst (`$ouMap` : GaresEtConnexions, HEXAFRET, OPTIMSERVICES, SARESEAU, SASNCF, SAVOYAGEURS, SudAzur, SudMobilitesTechnologies, TECHNIS), chacune mappée vers un chemin `COMMUN.AD.SNCF.FR/Ressources_Locales/Bureautique/SudEst/.../Utilisateurs`. Sélection par défaut : `SudMobilitesTechnologies` (index 7) |
| `Get-CopyBlockText` | Génère le texte de la note ServiceNow (affiché dans le panneau copiable). L'en-tête change selon `$global:CopyDateInit` |
| `Get-DateInitSaisie` | Date d'initialisation (`dd/MM/yyyy`) déduite du décompte saisi ; `$null` si la saisie est vide ou invalide |
| `Update-DateInitCalculee` | Rafraîchit l'étiquette de date calculée à droite du champ jours (violet si valide, `jj/mm/aaaa` rouge sinon) |
| `Update-Preview` | Met à jour l'aperçu HTML et l'objet en temps réel à chaque modification des champs |
| `Layout-FormPanel` | Recalcule le layout responsive du formulaire à chaque redimensionnement |

### Classe C# inline

| Classe | Rôle |
|---|---|
| `DarkTitleBar` | Active la barre de titre sombre Windows 10/11 via `DwmSetWindowAttribute` (dwmapi.dll), active le mode sombre système via `uxtheme.dll`, applique les scrollbars sombres, définit l'AppUserModelID (`SNCF.ArriveeCollaborateur`), et installe un `SetWinEventHook` (`HookCalendarPopup`) qui force le thème sombre sur les popups (`SysMonthCal32` / `DropDown`, ex. la liste déroulante des OU) dès leur ouverture |

### Scripts secondaires

- **`ArriveeCollab-PS/Start-ArriveeCollab.vbs`** / **`.cmd`** — Lanceurs locaux (développement) : exécutent le PS1 en mode fenêtre masquée, sans élévation UAC
- **`dist-launcher/bootstrap.ps1`** — Bootstrap de distribution (embarqué dans `Arrivee Collab.cmd` par le build) : télécharge le zip versionné depuis le dépôt GitHub public (repli : dossier local du .cmd), installe l'app sous `%LOCALAPPDATA%\Arrivee-Collab\app\`, puis lance `Start-ArriveeCollab.vbs`
- **`build-zip.ps1`** — Packaging : crée un zip versionné (`Arrivee-Collab_version<X>.zip`), génère `latest.json`, peuple `dist-ready/` avec les bundles complets, et tente un commit/push vers `origin`
- **`lib/Common.ps1`** — Fonctions partagées : `Get-AppDataDir`, `Get-AppWorkDir`, `Compare-AppVersion`, `Write-AppLog`, `Initialize-AppLog`, `Should-AutoHide`, `ConvertTo-NombreDeJours` / `Get-DateDepuisJours` (décompte « il y a X jours » → date exacte, helpers purs testés hors-GUI)
- **`lib/State.ps1`** — Gestion de `state.json` : `New-AppState`, `Save-AppState`, `Invoke-AppVersionMigration`
- **`lib/Update.ps1`** — détection MAJ toutes les 120 s **en arrière-plan** (`Start-UpdateCheckAsync`, runspace + timer : l'UI ne gèle jamais) ; sources : release GitHub → branche (raw) → dossier OneDrive ; pastille, dialogues, self-update avec vérification SHA-256 + signature, Quoi de neuf. `Invoke-UpdateCheck` (synchrone) reste pour les tests et le clic sur la pastille
- **`lib/Tutorial.ps1`** — tutoriel interactif data-driven (carte + surbrillance) : s'affiche automatiquement au premier lancement (~1,4 s après ouverture) et peut être rejoué à tout moment via le bouton « ? » en haut à droite. Versionné (`$script:TutorialVersion`) ; 14 étapes définies dans `Get-TutorialSteps`, état persisté dans `state.json` (`TutorialSeen` / `TutorialSeenVersion`)

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
