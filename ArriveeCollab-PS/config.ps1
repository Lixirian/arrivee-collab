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
