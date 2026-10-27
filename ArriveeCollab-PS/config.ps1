# ============================================================================
#  Configuration centrale de l'outil Arrivée Collaborateur.
#  Un seul fichier à éditer pour changer de version ou de dossier de MAJ.
# ============================================================================

$Config = @{
    # Version de l'application. À INCRÉMENTER à chaque build (build-zip.ps1).
    # Au lancement, si elle diffère de la version persistée dans state.json,
    # l'app déclenche le dialogue « Quoi de neuf » (via lib/Update.ps1).
    Version                = '1.13.1'

    # ----- Mise à jour : canal PRINCIPAL GitHub -----
    # Dépôt GitHub PUBLIC 'owner/repo'. build-zip.ps1 y crée une release v<X>
    # (zip + latest.json, lus via github.com/<repo>/releases/latest/download/ : en
    # ligne DÈS la publication) et pousse aussi les fichiers sur la branche (repli
    # raw.githubusercontent.com, ~5 min de cache CDN). SANS jeton, via le proxy
    # système. Vide = désactivé.
    UpdateRepo             = 'Lixirian/arrivee-collab'
    UpdateBranch           = 'main'

    # Clé PUBLIQUE (RSA 3072, XML) qui authentifie chaque version : l'app refuse tout
    # zip dont l'empreinte SHA-256 ou la signature ne correspond pas. Inscrite par
    # « build-zip.ps1 -NewSigningKey » ; la clé PRIVÉE reste chiffrée (DPAPI) sur le
    # poste de l'éditeur, jamais dans le dépôt.
    ReleasePublicKey       = '<RSAKeyValue><Modulus>raIRN/8SJiSaul7c49MAezHpVdn+NqrVeiWVGITIrSYg8vnPJV6OUndLedwPAq8+JnsVJdzeublKQJ4gpsW7slTiBYMgHoP36anKfQVi5HvH3NxFIG0nEYUuXTwBI69ffiM6PnmgRWM4D0JaoKDy45PugMg48YQ7av2yfjzZrBAKHEUL3kYEomblDASWhHYqHFM/o1wt7y0qzHZ60cTgNJXTwLD0u50Hv/VRjorFbkm/AmgOfkG/wDFisdt2AiQDVD9y5XeGoKemdG4LVTs/CRDxyHVwGoWSMoIeR9AHYD4FQAuK4IG9as/LmbTqsOeBDxK1kXYaPoBmwhX7vt+j91U4EHXDf90s8yzfurWrP8Uaw3BDUJeFIiyTmcIj/9fQr5T7fMgsfm8p9Hz1mBXJXouHOxBJrYF5pFoLeOF8Sye9Sj6yAnWsIRYF0XkD0R4JwT+1txdtpO3SLdZwLy/pj40r5zUxAbf1yNfkYUSANfJHRgXxHUc5YwBTkxazJQCh</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

    # ----- Repli : dossier de DISTRIBUTION OneDrive (si GitHub inaccessible) -----
    # AUCUNE API, AUCUN jeton : simple lecture de fichiers (lecture seule côté équipe).
    #  - Relatif (ex. 'Documents\...') : cherche sous chaque racine OneDrive connue.
    #  - Absolu / UNC accepté aussi.
    #  - Vide = repli sur dist_path.txt écrit par le bootstrap.
    UpdateDir              = 'Documents\TAM\Logiciels Dev\Arrivee collab'

    # Cadence de vérification d'une nouvelle version (SECONDES ; minimum 10).
    # Production : 120 (2 min, comme le widget Biblio-Tech). Pour tester, descendre à 10.
    UpdateCheckIntervalSec = 120
}
