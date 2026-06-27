# Conception — Versionning, mise à jour automatique (OneDrive) et tutoriel dynamique

**Date :** 2026-06-27
**Projet :** Arrivée Collaborateur (outil SNCF d'onboarding, GUI WinForms PowerShell)
**Modèle de référence :** SNOW Widget (`../Service now vue bureau/`)

---

## 1. Objectif

Doter l'outil Arrivée Collaborateur des mêmes mécanismes de distribution que SNOW Widget :

1. **Versionning** de l'application (version unique + changelog).
2. **Mise à jour automatique** depuis un dossier de distribution OneDrive/SharePoint (sans API ni jeton : simple lecture de fichiers).
3. **Tutoriel dynamique** affiché au premier lancement, re-jouable, et re-montré quand son contenu évolue.

Le tout calqué sur l'architecture éprouvée de SNOW Widget, adapté de WPF vers WinForms et d'une base monolithique vers une base modularisée.

## 2. Décisions de cadrage (validées)

| Sujet | Décision |
|---|---|
| Public visé | **Équipe** (techniciens TAM) → modèle SNOW complet (OneDrive partagé en lecture seule + copie locale par poste) |
| Périmètre | **Les 3 volets d'un coup** (versionning + MAJ auto + tutoriel) |
| Transfert vers OneDrive pro | **Manuel** : le build produit un zip « kit complet » à transférer/extraire à la main |
| Structure du code | **Modulariser** comme SNOW (`config.ps1`, `releases.json`, `lib/*.ps1`) |
| Étapes du tutoriel | **Conçues ici** (l'utilisateur ajustera les textes) |
| Dossier de distribution (UpdateDir) | `Documents\TAM\Logiciels Dev\Arrivee collab` (même base que SNOW Widget, dernier dossier renommé) ; repli automatique via `dist_path.txt` écrit par le bootstrap |
| Exécution | **%LOCALAPPDATA%** : app remplaçable + données persistantes séparées |
| Arborescence | **Sous-dossier dédié** `ArriveeCollab-PS/` |
| Style tutoriel | **Cartes dark theme + surbrillance** du contrôle concerné |
| Git | Dépôt **sans remote** → le build fait un commit **local** seulement (pas de push) |

## 3. Arborescence cible

```
Arrivee collab/                         ← racine du dépôt = KIT DE DISTRIBUTION
├── build-zip.ps1                       ← NOUVEAU (adapté de SNOW)
├── dist-launcher/                      ← NOUVEAU (le lanceur posé sur OneDrive)
│   ├── bootstrap.ps1                   ← installe en local %LOCALAPPDATA% + lance
│   ├── Arrivee Collab.cmd              ← double-clic utilisateur
│   ├── Arrivee Collab.vbs              ← lance bootstrap masqué
│   └── LISEZMOI.txt
├── latest.json                         ← NOUVEAU (généré : version + zip + notes)
├── Arrivee-Collab_version<X>.zip       ← généré (version courante à la racine)
├── Arrivee-Collab-dist-ready.zip       ← généré : kit complet (1er déploiement)
├── Arrivee-Collab-maj-<X>.zip          ← généré : bundle MAJ (minimal ou complet)
├── Archives/                           ← anciens zips de version
├── .dist-launcher-history.json         ← signatures du lanceur par version (bundle MAJ)
├── CLAUDE.md
├── docs/superpowers/specs/             ← ce document
└── ArriveeCollab-PS/                   ← NOUVEAU dossier source = CONTENU du zip
    ├── arrivee collab.ps1              ← script principal (déplacé + adapté)
    ├── config.ps1                      ← NOUVEAU : Version, UpdateDir, cadences
    ├── releases.json                   ← NOUVEAU : changelog { "1.0.0":[...] }
    ├── Start-ArriveeCollab.vbs         ← lance le PS1 masqué (-STA)
    ├── Start-ArriveeCollab.cmd         ← équivalent .cmd
    ├── image-arrivee-collab.ico
    ├── Resources/                      ← images embarquées (suivent dans le zip)
    │   ├── image arrivee collab.jpg
    │   └── Signature.png
    └── lib/                            ← NOUVEAU
        ├── Common.ps1                  ← log + résolution de chemins + helpers
        ├── State.ps1                   ← state.json (lecture/écriture atomique)
        ├── Update.ps1                  ← détection MAJ + pastille + self-update
        └── Tutorial.ps1                ← moteur de tutoriel data-driven
```

**Migration des fichiers existants** : `git mv` de `arrivee collab.ps1`, `image-arrivee-collab.ico`, `Resources/` vers `ArriveeCollab-PS/`. Les anciens `arrivée de collab.vbs` et `CreerRaccourci.ps1` à la racine deviennent obsolètes (le rôle « lanceur » est repris par `dist-launcher/` et `Start-ArriveeCollab.vbs`) ; ils seront supprimés ou archivés.

## 4. Modèle d'exécution (point structurant)

Aujourd'hui l'app tourne **depuis son dossier** et y écrit ses sorties. Comme le dossier app sera **écrasé à chaque mise à jour**, on sépare strictement **app (remplaçable)** et **données (persistantes)** :

| Élément | Emplacement cible | Justification |
|---|---|---|
| Code, `lib/`, `config.ps1`, `releases.json`, `Resources/`, `.ico` | `%LOCALAPPDATA%\Arrivee-Collab\app\` | écrasé proprement à chaque MAJ |
| `Mot de passe/` (txt + zip temporaires) | `%LOCALAPPDATA%\Arrivee-Collab\data\Mot de passe\` | **survit** aux MAJ |
| `Archive message/` (.msg archivés) | `%LOCALAPPDATA%\Arrivee-Collab\data\Archive message\` | **survit** aux MAJ |
| `{RITM}_notif.msg` (temp avant archivage) | `%LOCALAPPDATA%\Arrivee-Collab\data\` | hors dossier app |
| `state.json`, `app_debug.log`, `dist_path.txt` | `%LOCALAPPDATA%\Arrivee-Collab\` | méta locales |

**Impact sur le code existant** : la variable `$baseDir` (résolue lignes 136-148 du script actuel) se scinde en deux :
- `$appDir` = dossier du script en cours d'exécution → sert à `Resources/`, `.ico`, `config.ps1`, `releases.json`.
- `$dataDir` = `%LOCALAPPDATA%\Arrivee-Collab\data` (créé au besoin) → sert à `$motDePasseFolder`, `$archiveFolder`, et au chemin du `.msg` temporaire (`$cheminMsg`).

Tous les `Join-Path $baseDir ...` de sortie passent à `$dataDir` ; les `Join-Path $baseDir ...` de ressources passent à `$appDir`.

## 5. Chaîne de lancement

Reproduit fidèlement SNOW (toutes les étapes en fenêtre masquée) :

```
[OneDrive] Arrivee Collab.cmd
   └─> Arrivee Collab.vbs (masqué)
        └─> bootstrap.ps1
             ├─ lit latest.json (version cible)
             ├─ écrit %LOCALAPPDATA%\Arrivee-Collab\dist_path.txt
             ├─ 1re install : extrait le zip dans ...\app\
             ├─ archive les zips périmés du OneDrive (best-effort, écriture)
             └─> ...\app\Start-ArriveeCollab.vbs (masqué)
                  └─> powershell -STA -WindowStyle Hidden -File "arrivee collab.ps1"
```

`-STA` est requis : l'app utilise `[System.Windows.Forms.Clipboard]::SetText` et les dialogues WinForms (le VBS actuel ne le passe pas → à corriger dans le nouveau lanceur).

**Important — pas de MAJ forcée au lancement** : le bootstrap n'installe que la *première* fois. Ensuite, les montées de version passent par la **pastille in-app** (sinon la pastille ne s'afficherait jamais, l'app étant déjà à jour avant de s'ouvrir).

## 6. Composants détaillés

### 6.1 `config.ps1`
Hashtable `$Config` éditable, source de vérité :
```powershell
$Config = @{
    Version                = '1.0.0'   # à incrémenter à chaque build
    UpdateDir              = 'Documents\TAM\Logiciels Dev\Arrivee collab'  # relatif sous OneDrive (même base que SNOW Widget)
    UpdateCheckIntervalSec = 300        # cadence de vérification d'une nouvelle version (min 10)
}
```
La résolution de `UpdateDir` reprend `Get-SnowUpdateDir` : si relatif, cherche sous `%OneDriveCommercial%`, `%OneDrive%`, `USERPROFILE\OneDrive - SNCF`, `USERPROFILE\OneDrive` ; repli sur `dist_path.txt`.

### 6.2 `releases.json`
Changelog embarqué (lisible hors-ligne) :
```json
{ "1.0.0": ["Première version distribuée : versionning, mise à jour automatique et tutoriel."] }
```

### 6.3 `lib/Common.ps1`
- `Write-Log` (équivalent `Write-SnowLog`) → `%LOCALAPPDATA%\Arrivee-Collab\app_debug.log`.
- Résolution `$appDir` / `$dataDir`, création des sous-dossiers data.
- `Compare-AppVersion` (adapté de `Compare-SnowVersion`) : comparaison numérique « x.y.z ».

### 6.4 `lib/State.ps1`
`state.json` allégé (l'app n'a ni tickets ni badges). Champs :
```
Version              : version de l'app ayant écrit l'état (déclenche « Quoi de neuf »)
NotesShownVersion    : version dont les notes ont déjà été montrées (anti-doublon)
TutorialSeen         : tutoriel déjà vu (bool)
TutorialSeenVersion  : version du CONTENU du tutoriel déjà vue (int)
```
Fonctions `New-AppState` / `Save-AppState` reprises de SNOW (écriture `.tmp` puis `Move-Item` avec retries pour les verrous OneDrive/antivirus). `Invoke-AppVersionMigration` : ici quasi no-op (pas d'état volatile à purger, pas de cache WebView2) → met simplement `Version = TargetVersion` et sauvegarde ; sert de déclencheur au « Quoi de neuf ».

### 6.5 `lib/Update.ps1`
Adapté de `SnowUpdate.ps1`, dialogues refaits en **WinForms** (réutilisent le style de `Show-AlertDialog` existant) :
- `Get-UpdateDir`, `Get-LatestManifest`, `Invoke-UpdateCheck` (pose `$Ctx.UpdateAvailable` + rafraîchit la pastille).
- `Show-UpdateDialog` (WinForms dark) : notes des 3 dernières versions + boutons « Plus tard » / « Mettre à jour et redémarrer ».
- `Invoke-PromptAndUpdate` : re-lit `latest.json` au clic puis affiche le dialogue.
- `Invoke-SelfUpdate` : copie le zip en local, écrit un `updater.ps1` **détaché** (attend la fermeture via `Wait-Process -Id $PID`, remplace le contenu de `...\app\`, relance via `Start-ArriveeCollab.vbs`), archive l'ancienne version sur OneDrive (best-effort), puis ferme l'app.
- `Show-WhatsNewIfUpgraded` : au démarrage, après une vraie montée, dialogue récap de toutes les versions franchies (anti-doublon `NotesShownVersion`).
- Helpers changelog : `Get-LocalReleaseNotes`, `Get-RecentReleaseNotes`, `Get-ReleaseNotesBetween`.

### 6.6 `lib/Tutorial.ps1`
Moteur **data-driven** + rendu **WinForms** :
- `$script:TutorialVersion` (int) : à incrémenter quand le contenu change → re-montre le tuto une fois.
- `Get-TutorialSteps` → tableau d'étapes `@{ Icon; Title; Body; TargetControl }` (voir §7).
- `Show-Tutorial $Ctx` : superpose un **voile semi-transparent** (form borderless plein écran, `Opacity`), une **carte** dark theme (Précédent / Suivant / Passer), et **dessine un cadre violet** (`$cAccentViolet`) autour du `TargetControl` de l'étape (rectangle calculé via `PointToScreen`/`Bounds`). Re-jouable via le bouton « ? ».
- `Show-TutorialIfFirstRun $Ctx` : affiche si `TutorialSeen = $false` OU `TutorialSeenVersion < TutorialVersion` ; différé ~1,4 s (Timer) pour laisser l'UI se peindre.

### 6.7 `build-zip.ps1` (racine)
Adapté de SNOW à l'identique, avec les noms Arrivée Collab :
- Lit `ArriveeCollab-PS\config.ps1` → `$Config.Version`.
- Produit `Arrivee-Collab_version<X>.zip` (dossier racine interne = même nom), `latest.json`, archive les anciens zips → `Archives/`.
- Assemble `dist-ready/` (lanceur `dist-launcher/*` + zip + latest.json), génère `Arrivee-Collab-dist-ready.zip` (kit complet) et `Arrivee-Collab-maj-<X>.zip` (minimal si le lanceur n'a pas changé, complet sinon — via `.dist-launcher-history.json`).
- **Git** : commit + **push automatique** vers `origin` (le dépôt privé `Lixirian/arrivee-collab` créé le 2026-06-27). Best-effort : un échec (hors ligne) n'échoue pas le build. `-NoGit` saute l'étape.

### 6.8 `dist-launcher/bootstrap.ps1`
Adapté de SNOW : `dataDir = %LOCALAPPDATA%\Arrivee-Collab`, `appDir = ...\app`, sonde la présence de `...\app\Start-ArriveeCollab.vbs` pour décider de la première installation, mémorise `dist_path.txt`, nettoie les zips périmés (best-effort), lance l'app.

## 7. Étapes du tutoriel (proposées)

| # | Icône | Titre | Contrôle ciblé |
|---|---|---|---|
| 1 | 👋 | Bienvenue dans l'outil Arrivée Collaborateur | — |
| 2 | 📝 | Les informations à saisir (RITM, email demandeur, nom, prénom) | `$panelForm` |
| 3 | 🔑 | Générer le mot de passe (copié auto + ZIP) | `$btnGenPwd` |
| 4 | ⚠️ | Mode « Mot de passe déjà initialisé » + date | `$chkMdpDejaInit` |
| 5 | ✅ | Vérifications Mon-AD / OU avant l'envoi | — |
| 6 | 📧 | Générer le .msg + archivage automatique | `$btnGenMsg` |
| 7 | 👤 | Saisie des informations bénéficiaire (email + OU) | — |
| 8 | 📋 | La note ServiceNow copiable | `$panelCopy` |
| 9 | 🔄 | Le bouton Réinitialiser | `$btnReset` |
| 10 | 🎉 | C'est parti ! | — |

## 8. Intégration dans le script principal

Au début du script (après chargement des assemblies et résolution des chemins) :
```powershell
. (Join-Path $appDir 'config.ps1')
. (Join-Path $appDir 'lib\Common.ps1')
. (Join-Path $appDir 'lib\State.ps1')
. (Join-Path $appDir 'lib\Update.ps1')
. (Join-Path $appDir 'lib\Tutorial.ps1')
```
Un objet léger `$Ctx` (hashtable) porte `Config`, `State`, `AppRoot`, `DataDir`, `UpdateAvailable`, et les références aux contrôles de la pastille/tutoriel. Au lancement, dans l'ordre :
1. `$prevVer = $State.Version` puis `Invoke-AppVersionMigration`.
2. Construction de l'UI (existant) + ajout **pastille MAJ** et **bouton « ? »** dans l'en-tête.
3. `Show-WhatsNewIfUpgraded $Ctx $prevVer`.
4. Timer : 1er `Invoke-UpdateCheck` ~8 s après ouverture, puis toutes les `UpdateCheckIntervalSec`.
5. Timer ~1,4 s : `Show-TutorialIfFirstRun $Ctx`.

**Pastille MAJ** : petit `Label`/`Button` (caché par défaut) dans l'en-tête, à droite du titre, couleur `$cWarning`/`$cAccentViolet` ; visible quand `$Ctx.UpdateAvailable` ; clic → `Invoke-PromptAndUpdate`. **Bouton « ? »** : à côté, clic → `Show-Tutorial`.

## 9. Risques et points d'attention

- **Déménagement des chemins** : risque principal. Tout `Join-Path $baseDir` doit être trié en `$appDir` (ressources) ou `$dataDir` (sorties). Revue systématique nécessaire (RITM .msg, txt, zip, archive).
- **Verrous OneDrive / antivirus** : couverts par l'écriture atomique `.tmp` + retries (repris de SNOW).
- **`-STA` manquant** dans le lanceur actuel : à corriger (presse-papiers WinForms).
- **Bloc VBS inline obsolète** (lignes 75-134) : à retirer du script principal.
- **Première bascule** : les utilisateurs qui lançaient l'app « en place » devront passer par le nouveau lanceur OneDrive ; prévoir une note de migration dans `LISEZMOI.txt`.
- **Icône / AppUserModelID** : conserver `DarkTitleBar::SetAppId` ; vérifier le chemin `.ico` sous `$appDir`.

## 10. Hors périmètre (YAGNI)

- Pas de gestion d'historique distant complexe : le build pousse simplement `master` vers `origin` (best-effort).
- Pas de notifications toast Windows.
- Pas de cache WebView2 à purger (l'app n'en a pas).
- Pas de canal de MAJ par API/HTTP : uniquement lecture de fichiers OneDrive.
- Pas de signature de code ni d'installeur MSI.

## 11. Plan de validation manuelle

1. **Build** : `build-zip.ps1` produit le zip versionné, `latest.json`, `dist-ready/`, et fait un commit local.
2. **1re install** : extraire `Arrivee-Collab-dist-ready.zip` dans un dossier « OneDrive simulé », lancer `Arrivee Collab.cmd` → l'app s'installe dans `%LOCALAPPDATA%\Arrivee-Collab\app` et s'ouvre ; **tutoriel** affiché.
3. **Fonctionnel inchangé** : générer un mot de passe, un .msg, vérifier que `Mot de passe/` et `Archive message/` se créent sous `...\data\`.
4. **MAJ** : incrémenter `Version`, ajouter une note, rebuild, copier zip+latest.json dans le dossier OneDrive → **pastille** dans l'app ouverte → clic → notes → redémarrage sur la nouvelle version → **« Quoi de neuf »**.
5. **Tutoriel** : re-jouable via « ? » ; bump `TutorialVersion` → re-montré une fois.
6. **Persistance** : `state.json` conserve `TutorialSeen` / `NotesShownVersion` entre deux lancements.
