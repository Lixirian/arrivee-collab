# ============================================================================
#  Configuration centrale de l'outil Arrivée Collaborateur.
#  Un seul fichier à éditer pour changer de version ou de dossier de MAJ.
# ============================================================================

$Config = @{
    # Version de l'application. À INCRÉMENTER à chaque build (build-zip.ps1).
    # Au lancement, si elle diffère de la version persistée dans state.json,
    # l'app déclenche le dialogue « Quoi de neuf » (via lib/Update.ps1).
    Version                = '1.4.0'

    # Dossier de DISTRIBUTION OneDrive contenant latest.json + les zips versionnés.
    # AUCUNE API, AUCUN jeton : simple lecture de fichiers (lecture seule côté équipe).
    #  - Relatif (ex. 'Documents\...') : cherche sous chaque racine OneDrive connue.
    #  - Absolu / UNC accepté aussi.
    #  - Vide = repli sur dist_path.txt écrit par le bootstrap.
    UpdateDir              = 'Documents\TAM\Logiciels Dev\Arrivee collab'

    # Cadence de vérification d'une nouvelle version (SECONDES ; minimum 10).
    # Production : 300 (5 min). Pour tester rapidement, descendre à 10.
    UpdateCheckIntervalSec = 300
}
