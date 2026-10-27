# Tests hors-ligne des unités pures d'Arrivée Collaborateur. Aucun GUI, aucun COM.
$ErrorActionPreference = 'Stop'
$lib = Join-Path $PSScriptRoot '..\ArriveeCollab-PS\lib'
. (Join-Path $lib 'Common.ps1')
$script:fail = 0
function Assert($cond, $label) {
    if ($cond) { Write-Host "PASS $label" }
    else { Write-Host "FAIL $label" -ForegroundColor Red; $script:fail++ }
}

# --- Compare-AppVersion ---
Assert ((Compare-AppVersion '1.0.1' '1.0.0') -eq 1)  'compare : 1.0.1 > 1.0.0'
Assert ((Compare-AppVersion '1.0.0' '1.0.1') -eq -1) 'compare : 1.0.0 < 1.0.1'
Assert ((Compare-AppVersion '1.2.0' '1.2.0') -eq 0)  'compare : égalité'
Assert ((Compare-AppVersion '1.0.10' '1.0.2') -eq 1) 'compare : 1.0.10 > 1.0.2 (numérique)'
Assert ((Compare-AppVersion '2.0' '1.9.9') -eq 1)    'compare : longueurs différentes'

# --- Décompte « il y a X jours » -> date d'initialisation ---
Assert ((ConvertTo-NombreDeJours '0') -eq 0)      'jours : 0 accepte'
Assert ((ConvertTo-NombreDeJours '45') -eq 45)    'jours : entier accepte'
Assert ((ConvertTo-NombreDeJours ' 7 ') -eq 7)    'jours : espaces ignores'
Assert ($null -eq (ConvertTo-NombreDeJours ''))   'jours : vide -> null'
Assert ($null -eq (ConvertTo-NombreDeJours $null)) 'jours : null -> null'
Assert ($null -eq (ConvertTo-NombreDeJours 'abc')) 'jours : texte -> null'
Assert ($null -eq (ConvertTo-NombreDeJours '-3'))  'jours : negatif -> null'
Assert ($null -eq (ConvertTo-NombreDeJours '1,5')) 'jours : decimal -> null'
Assert ($null -eq (ConvertTo-NombreDeJours '99999')) 'jours : au-dela du max -> null'
Assert ($null -eq (ConvertTo-NombreDeJours '99999999999')) 'jours : trop grand pour un int -> null'
Assert ((ConvertTo-NombreDeJours '3650') -eq 3650) 'jours : max inclus'

$ref = [datetime]'2026-07-28'
Assert ((Get-DateDepuisJours 0 $ref)  -eq [datetime]'2026-07-28') 'date : 0 jour -> aujourd hui'
Assert ((Get-DateDepuisJours 1 $ref)  -eq [datetime]'2026-07-27') 'date : 1 jour -> veille'
Assert ((Get-DateDepuisJours 30 $ref) -eq [datetime]'2026-06-28') 'date : 30 jours -> mois precedent'
Assert ((Get-DateDepuisJours 209 $ref) -eq [datetime]'2025-12-31') 'date : bascule d annee'
Assert (((Get-DateDepuisJours 5 ([datetime]'2026-07-28 16:42:11')).TimeOfDay) -eq [timespan]::Zero) 'date : heure remise a minuit'
Assert ((Get-DateDepuisJours 1 ([datetime]'2024-03-01')) -eq [datetime]'2024-02-29') 'date : annee bissextile'

# --- Jours restants avant expiration (Mon-AD) -> date d'initialisation ---
Assert ($script:DureeValiditeMdp -eq 365) 'restants : validite par defaut 365 jours'
Assert ((Get-DateInitDepuisJoursRestants 365 -Reference $ref) -eq [datetime]'2026-07-28') 'restants : 365 -> initialise aujourd hui'
Assert ((Get-DateInitDepuisJoursRestants 364 -Reference $ref) -eq [datetime]'2026-07-27') 'restants : 364 -> veille'
Assert ((Get-DateInitDepuisJoursRestants 335 -Reference $ref) -eq [datetime]'2026-06-28') 'restants : 335 -> il y a 30 jours'
Assert ((Get-DateInitDepuisJoursRestants 0 -Reference $ref) -eq [datetime]'2025-07-28') 'restants : 0 -> il y a 365 jours'
Assert ((Get-DateInitDepuisJoursRestants 80 -DureeValidite 90 -Reference $ref) -eq [datetime]'2026-07-18') 'restants : duree de validite parametrable'
Assert ($null -eq (ConvertTo-NombreDeJours '366' -Max $script:DureeValiditeMdp)) 'restants : au-dela de la validite -> null'

# --- Sécurité : mot de passe, saisies, purge (lib/Common.ps1) ---
$amb = '[0Oo1lI"&'' ]'
$okClasses = $true; $okAmb = $true; $okLong = $true
foreach ($i in 1..300) {
    $pw = New-MotDePasse
    if ($pw.Length -ne 12) { $okLong = $false }
    if ($pw -cnotmatch '[A-Z]' -or $pw -cnotmatch '[a-z]' -or $pw -notmatch '\d' -or $pw -notmatch '[!#$%*+\-=?@]') { $okClasses = $false }
    if ($pw -cmatch $amb) { $okAmb = $false }
}
Assert $okLong    'mdp : 12 caracteres'
Assert $okClasses 'mdp : majuscule + minuscule + chiffre + special a chaque tirage (300 essais)'
Assert $okAmb     'mdp : aucun caractere ambigu ni guillemet / & / espace'
Assert ((New-MotDePasse 16).Length -eq 16) 'mdp : longueur parametrable'
Assert ((@(1..50 | ForEach-Object { New-MotDePasse }) | Sort-Object -Unique).Count -eq 50) 'mdp : tirages distincts'
Assert ((ConvertTo-NomFichierSur 'Jean DUPONT') -eq 'JeanDUPONT') 'fichier : nom assaini'
Assert ((ConvertTo-NomFichierSur '..\..\Startup\x:y[1]') -eq 'Startupxy1') 'fichier : separateurs, .., : et jokers retires'
Assert ((ConvertTo-NomFichierSur '<>"|').Length -eq 12) 'fichier : repli aleatoire si vide'
Assert (Test-NumeroRitmValide 'RITM2178872') 'ritm : valide'
Assert (-not (Test-NumeroRitmValide "RITM1';Start-Process calc;'")) 'ritm : injection refusee'
Assert (-not (Test-NumeroRitmValide 'RITM12')) 'ritm : trop court refuse'
Assert (Test-NomPrenomValide "KHADRAOUI Mohamed-Nedal") 'nom : compose accepte'
Assert (Test-NomPrenomValide "Jérôme D'Arc") 'nom : accents et apostrophe acceptes'
Assert (-not (Test-NomPrenomValide 'Jean<img src=x onerror=alert(1)>')) 'nom : balisage refuse'
Assert (-not (Test-NomPrenomValide 'Jean & Co')) 'nom : & refuse'
Assert (Test-AdresseMailValide 'jean-philippe.mineo@sncf.fr') 'mail : adresse valide'
Assert (-not (Test-AdresseMailValide 'a@sncf.fr; b@evil.com')) 'mail : liste refusee'
Assert (-not (Test-AdresseMailValide 'Jean <a@sncf.fr>')) 'mail : nom affiche refuse'
$tmpPurge = Join-Path $env:TEMP ("ac_purge_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpPurge | Out-Null
try {
    $vieux = Join-Path $tmpPurge 'vieux.msg'; $recent = Join-Path $tmpPurge 'recent.msg'; $autre = Join-Path $tmpPurge 'vieux.txt'
    foreach ($f in $vieux, $recent, $autre) { Set-Content -LiteralPath $f -Value 'x' }
    (Get-Item -LiteralPath $vieux).LastWriteTime = (Get-Date).AddDays(-31)
    (Get-Item -LiteralPath $autre).LastWriteTime = (Get-Date).AddDays(-31)
    $n = Remove-FichiersAnciens $tmpPurge 30 '*.msg'
    Assert ($n -eq 1 -and -not (Test-Path -LiteralPath $vieux) -and (Test-Path -LiteralPath $recent) -and (Test-Path -LiteralPath $autre)) 'purge : seuls les .msg de plus de 30 jours'
    Assert ((Remove-FichiersAnciens $tmpPurge 0) -eq 2 -and @(Get-ChildItem -LiteralPath $tmpPurge).Count -eq 0) 'purge : 0 jour = tout supprimer'
    Assert ((Remove-FichiersAnciens (Join-Path $tmpPurge 'absent') 0) -eq 0) 'purge : dossier absent sans erreur'
} finally { Remove-Item -LiteralPath $tmpPurge -Recurse -Force -ErrorAction SilentlyContinue }

# --- Page ServiceNow cachée : hôtes autorisés (lib/SnowPage.ps1) ---
. (Join-Path $lib 'SnowPage.ps1')
Assert (Test-SnowHoteAutorise 'https://sncf.service-now.com/now/nav/ui/classic/params/target/sys_user_list.do') 'snow : instance autorisee'
Assert (Test-SnowHoteAutorise 'https://idp.sncf.fr/openam/XUI/') 'snow : IdP SNCF autorise'
Assert (-not (Test-SnowHoteAutorise 'https://evil.service-now.com/')) 'snow : autre instance ServiceNow refusee'
Assert (-not (Test-SnowHoteAutorise 'https://evilservice-now.com/')) 'snow : faux domaine refuse'
Assert (-not (Test-SnowHoteAutorise 'https://sncf.fr.evil.com/')) 'snow : suffixe trompeur refuse'
Assert (-not (Test-SnowHoteAutorise 'http://sncf.service-now.com/')) 'snow : http refuse'
Assert (-not (Test-SnowHoteAutorise 'file://C:/Windows/win.ini')) 'snow : file refuse'
$js = Get-SnowKickJs "/x.do?a=1&b='2'</script>"
Assert ($js -match [regex]::Escape('fetch("/x.do?a=1\u0026b=\u00272\u0027\u003c/script\u003e"') -or $js -match 'fetch\("/x\.do\?a=1') 'snow : URL inseree comme litteral JS echappe'

# --- Homonymes (helpers purs de lib/Homonymes.ps1) ---
. (Join-Path $lib 'Homonymes.ps1')
Assert ((ConvertTo-NomNormalise '  Jérémy   Pasturel ') -eq 'JEREMY PASTUREL') 'homo : normalisation accents/casse/espaces'
Assert ((ConvertTo-NomNormalise "Jean-Christian D'Ors") -eq 'JEAN CHRISTIAN D ORS') 'homo : tirets et apostrophes'
Assert ((ConvertTo-NomNormalise '') -eq '') 'homo : vide'
Assert (((Get-NomTokens 'PASTUREL Jeremy') -join ' ') -eq ((Get-NomTokens 'Jérémy pasturel') -join ' ')) 'homo : ordre et accents ignores'
Assert ($null -eq (Get-RequeteHomonymes 'Jeremy')) 'homo : un seul mot -> pas de requete'
Assert ($null -eq (Get-RequeteHomonymes '   ')) 'homo : blanc -> pas de requete'
Assert ((Get-RequeteHomonymes 'Jeremy  PASTUREL') -eq 'nameLIKEJeremy^nameLIKEPASTUREL') 'homo : requete LIKE par mot'
Assert ((Get-RequeteHomonymes 'Jeremy^x=1 PASTUREL') -eq 'nameLIKEJeremy^nameLIKEx^nameLIKE1^nameLIKEPASTUREL') 'homo : caracteres de requete neutralises'
$u = Get-UrlJsonHomonymes 'Jeremy PASTUREL'
Assert ($u.StartsWith('/sys_user.do?JSONv2&sysparm_action=getRecords&sysparm_query=nameLIKEJeremy%5EnameLIKEPASTUREL&')) 'homo : URL JSONv2 encodee'
Assert ($u -match 'sysparm_fields=user_name,name,first_name,last_name,email,active,sys_created_on') 'homo : champs demandes'
$recs = @(
    [pscustomobject]@{ user_name = '7903222J'; name = 'PASTUREL Jeremy' }
    [pscustomobject]@{ user_name = 'PMGN1';    name = 'PASTUREL Jérémy' }
    [pscustomobject]@{ user_name = '1111111A'; name = 'PASTUREL Jeremy-Paul' }
    [pscustomobject]@{ user_name = '2222222B'; name = ''; first_name = 'jeremy'; last_name = 'pasturel' }
)
$m = @(Select-Homonymes $recs 'Jeremy PASTUREL')
Assert ($m.Count -eq 3) 'homo : correspondances exactes (accents, ordre, prenom+nom de repli)'
Assert (-not (@($m.user_name) -contains '1111111A')) 'homo : nom compose different ecarte'
Assert (Test-PresenceHomonymes $m) 'homo : 3 comptes -> homonymes'
Assert (-not (Test-PresenceHomonymes @($recs[0]))) 'homo : 1 compte -> pas d homonyme'
Assert (-not (Test-PresenceHomonymes @())) 'homo : 0 compte -> pas d homonyme'
Assert ((@(Select-Homonymes $recs 'Paul Martin')).Count -eq 0) 'homo : aucun compte'
Assert (((Get-CpTrouves $m '7903222J') -join ', ') -eq 'PMGN1, 2222222B') 'homo : CP trouves = autres que le demande'

# --- Doublons de demande (helpers purs de lib/Doublons.ps1) ---
. (Join-Path $lib 'Doublons.ps1')
Assert ($null -eq (Get-RequeteDoublons 'Melissa')) 'doublon : un seul mot -> pas de requete'
$qd = Get-RequeteDoublons 'Melissa  GUFFLET'
Assert ($qd -eq 'short_descriptionSTARTSWITHSupport Site^ORshort_descriptionSTARTSWITHRecherche des nouveaux gestionnaires^123TEXTQUERY321=Melissa GUFFLET^ORDERBYDESCsys_created_on') 'doublon : filtre de la liste + recherche texte + tri'
Assert ((Get-RequeteDoublons 'A^x=1 B') -notmatch '\^x|=1') 'doublon : caracteres de requete neutralises'
$ud = Get-UrlJsonDoublons 'Melissa GUFFLET'
Assert ($ud.StartsWith('/sc_task.do?JSONv2&sysparm_action=getRecords&sysparm_query=') -and $ud -match '&displayvalue=all&') 'doublon : URL JSONv2 sc_task avec libelles'
Assert ((ConvertTo-NumeroRitm ' ritm0123 456 ') -eq 'RITM0123456') 'doublon : normalisation du numero de RITM'
$taches = @(
    [pscustomobject]@{ number = 'SCTASK3233533'; dv_number = 'SCTASK3233533'; request_item = 'aaa'; dv_request_item = 'RITM0000002'; state = '3'; dv_state = 'Réalisé'; short_description = 'Support Site Arrivée'; u_beneficiaire = 'bbb'; dv_u_beneficiaire = 'GUFFLET Melissa'; opened_by = 'x'; dv_opened_by = 'PETOT Caroline'; dv_opened_at = '20/10/2026 10:00:00' }
    [pscustomobject]@{ number = 'SCTASK3233424'; request_item = 'ccc'; dv_request_item = 'RITM0000001'; state = '2'; dv_state = 'En cours'; short_description = 'Support Site Arrivée'; dv_u_beneficiaire = 'GUFFLET Mélissa' }
    [pscustomobject]@{ number = 'SCTASK1'; dv_request_item = 'RITM0000003'; state = '4'; dv_state = 'Fermé incomplet'; dv_u_beneficiaire = 'GUFFLET Melissa' }
    [pscustomobject]@{ number = 'SCTASK2'; dv_request_item = 'RITM0000004'; state = '3'; dv_state = 'Réalisé'; dv_u_beneficiaire = 'GUFFLET Melissa-Anne' }
    [pscustomobject]@{ number = 'SCTASK3'; dv_request_item = 'RITM0000005'; state = '3'; dv_state = 'Réalisé'; dv_u_beneficiaire = 'DUPONT Jean'; dv_opened_by = 'GUFFLET Melissa' }
    [pscustomobject]@{ number = 'SCTASK4'; dv_request_item = 'RITM0000006'; state = '3'; dv_state = 'Annulé'; dv_u_beneficiaire = 'GUFFLET Melissa' }
)
$dbl = @(Select-Doublons $taches 'Melissa GUFFLET' 'ritm0000001')
Assert ($dbl.Count -eq 1 -and $dbl[0].Ritm -eq 'RITM0000002') 'doublon : seule l autre RITM non annulee du meme beneficiaire'
Assert ($dbl[0].Tache -eq 'SCTASK3233533' -and $dbl[0].Statut -eq 'Réalisé' -and $dbl[0].Champs -eq 'u_beneficiaire') 'doublon : tache, statut et champ beneficiaire reconnus'
Assert ((@(Select-Doublons $taches 'Melissa GUFFLET' 'RITM0000009')).Count -eq 2) 'doublon : sans la RITM courante, les deux RITM actives comptent'
Assert ((@(Select-Doublons $taches 'Jean DUPONT' 'RITM0000009')).Count -eq 1) 'doublon : autre beneficiaire'
Assert (Test-TacheAnnulee $taches[2]) 'doublon : etat 4 = annulee'
Assert (Test-TacheAnnulee $taches[5]) 'doublon : libelle Annule = annulee'
Assert (-not (Test-TacheAnnulee $taches[0])) 'doublon : realisee = non annulee'
Assert ((@(Get-ChampsBeneficiaire $taches[4] 'Melissa GUFFLET')).Count -eq 0) 'doublon : nom present seulement comme demandeur -> ignore'
Assert (((Get-RitmsDoublons @(Select-Doublons $taches 'Melissa GUFFLET' 'RITM0000009')) -join ',') -eq 'RITM0000002,RITM0000001') 'doublon : RITM distinctes dans l ordre'

# --- State round-trip + migration ---
. (Join-Path $lib 'State.ps1')
$tmpState = Join-Path $env:TEMP ("ac_state_test_" + [guid]::NewGuid().ToString('N') + ".json")
try {
    $s = New-AppState $tmpState
    Assert ($s.Version -eq '' -and -not $s.TutorialSeen) 'state : état vierge par défaut'
    Assert ($s.PreviewCollapsed -eq $false) 'state : PreviewCollapsed faux par défaut'

    $s.Version = '1.0.0'; $s.TutorialSeen = $true; $s.TutorialSeenVersion = 2; $s.NotesShownVersion = '1.0.0'; $s.PreviewCollapsed = $true
    Save-AppState $s
    Assert (Test-Path $tmpState) 'state : fichier écrit'

    $s2 = New-AppState $tmpState
    Assert ($s2.Version -eq '1.0.0')        'state : Version relue'
    Assert ($s2.TutorialSeen -eq $true)     'state : TutorialSeen relu'
    Assert ($s2.TutorialSeenVersion -eq 2)  'state : TutorialSeenVersion relu'
    Assert ($s2.NotesShownVersion -eq '1.0.0') 'state : NotesShownVersion relue'
    Assert ($s2.PreviewCollapsed -eq $true) 'state : PreviewCollapsed relu'

    $migrated = Invoke-AppVersionMigration $s2 '1.1.0'
    Assert ($migrated -eq $true)            'migration : montée détectée'
    Assert ($s2.Version -eq '1.1.0')        'migration : version mise à jour'
    $noop = Invoke-AppVersionMigration $s2 '1.1.0'
    Assert ($noop -eq $false)               'migration : no-op si même version'
} finally {
    if (Test-Path $tmpState) { Remove-Item $tmpState -Force -ErrorAction SilentlyContinue }
}

# --- Update : manifeste, tri de versions, notes hors-ligne ---
. (Join-Path $lib 'Update.ps1')
$tmpRoot = Join-Path $env:TEMP ("ac_upd_test_" + [guid]::NewGuid().ToString('N'))
$dist = Join-Path $tmpRoot 'dist'; $app = Join-Path $tmpRoot 'app'
New-Item -ItemType Directory -Path $dist, $app -Force | Out-Null
try {
    # Contexte minimal simulé
    $ctx = @{ Config = @{ UpdateDir = $dist }; DataDir = $tmpRoot; AppRoot = $app; UpdateAvailable = $null }

    # latest.json + zip dans le dossier de distribution
    '{ "version": "1.2.0", "zip": "Arrivee-Collab_version1.2.0.zip", "notes": ["Note A", "Note B"] }' |
        Out-File -LiteralPath (Join-Path $dist 'latest.json') -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dist 'Arrivee-Collab_version1.2.0.zip') -Value 'zip'

    $m = Get-LatestManifest $ctx
    Assert ($m.Version -eq '1.2.0')                 'update : manifeste version'
    Assert ($m.Zip -eq 'Arrivee-Collab_version1.2.0.zip') 'update : manifeste zip'
    Assert (@($m.Notes).Count -eq 2)                'update : manifeste 2 notes'
    Assert ($m.Source -eq 'dossier')                'update : source dossier (repli)'

    # ConvertFrom-LatestJson (parse pur, partage GitHub/dossier)
    $p = ConvertFrom-LatestJson '{ "version": "2.0.0", "notes": ["N"] }'
    Assert ($p.Version -eq '2.0.0' -and $p.Zip -eq 'Arrivee-Collab_version2.0.0.zip') 'update : parse -> zip par defaut'
    Assert ($null -eq (ConvertFrom-LatestJson '{ "zip": "x.zip" }')) 'update : parse sans version -> null'
    Assert ($null -eq (ConvertFrom-LatestJson 'pas du json'))        'update : parse json invalide -> null'
    Assert ($null -eq (ConvertFrom-LatestJson '{ "version": "1.2; rm -rf" }')) 'update : version hors format -> null'
    $pz = ConvertFrom-LatestJson ('{ "version": "1.2.0", "zip": "..\\..\\evil.zip", "sha256": "abcd", "sig": "S" }')
    Assert ($pz.Zip -eq 'Arrivee-Collab_version1.2.0.zip') 'update : nom du zip reconstruit (pas celui du manifeste)'
    Assert ($pz.Sha256 -eq 'ABCD' -and $pz.Sig -eq 'S') 'update : sha256 (majuscules) + sig lus'
    Assert ($null -ne (ConvertFrom-LatestJson ([string][char]0xFEFF + '{ "version": "1.0.0" }'))) 'update : BOM tolere'

    # Signature RSA / SHA-256 des versions
    $rsaT = New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)
    $pubT = $rsaT.ToXmlString($false)
    $shaT = 'AB' * 32
    $sigT = [Convert]::ToBase64String($rsaT.SignData([Text.Encoding]::UTF8.GetBytes((Get-ReleaseSignedText '1.2.0' $shaT)), 'SHA256'))
    Assert ((Get-ReleaseSignedText '1.2.0' 'ab') -eq 'Arrivee-Collab|1.2.0|AB') 'sig : texte signe'
    Assert (Test-ReleaseSignature $pubT '1.2.0' $shaT $sigT) 'sig : signature valide acceptee'
    Assert (-not (Test-ReleaseSignature $pubT '1.2.1' $shaT $sigT)) 'sig : autre version refusee (pas de rejeu)'
    Assert (-not (Test-ReleaseSignature $pubT '1.2.0' ('CD' * 32) $sigT)) 'sig : autre empreinte refusee'
    $autre = (New-Object System.Security.Cryptography.RSACryptoServiceProvider(2048)).ToXmlString($false)
    Assert (-not (Test-ReleaseSignature $autre '1.2.0' $shaT $sigT)) 'sig : autre cle refusee'
    Assert (-not (Test-ReleaseSignature $pubT '1.2.0' $shaT '')) 'sig : signature vide refusee'
    Assert (-not (Test-ReleaseSignature $pubT '1.2.0' $shaT 'pas-du-base64!')) 'sig : signature illisible refusee'
    Assert (-not (Test-ReleaseSignature '' '1.2.0' $shaT $sigT)) 'sig : sans cle publique refusee'

    # Contrôle d'un paquet : empreinte du fichier + signature
    $zf = Join-Path $tmpRoot 'paquet.zip'
    Set-Content -LiteralPath $zf -Value 'contenu du paquet'
    $shaF = (Get-FileHash -LiteralPath $zf -Algorithm SHA256).Hash
    $sigF = [Convert]::ToBase64String($rsaT.SignData([Text.Encoding]::UTF8.GetBytes((Get-ReleaseSignedText '1.2.0' $shaF)), 'SHA256'))
    $mf = @{ Version = '1.2.0'; Sha256 = $shaF; Sig = $sigF }
    Assert ($null -eq (Test-ReleasePackage $zf $mf $pubT)) 'paquet : conforme -> accepte'
    Assert ($null -ne (Test-ReleasePackage $zf $mf ''))    'paquet : sans cle publique -> refuse'
    Assert ($null -ne (Test-ReleasePackage $zf @{ Version = '1.2.0'; Sha256 = ''; Sig = $sigF } $pubT)) 'paquet : sans empreinte -> refuse'
    Add-Content -LiteralPath $zf -Value 'altere'
    Assert ((Test-ReleasePackage $zf $mf $pubT) -match 'SHA-256') 'paquet : fichier altere -> refuse'
    Assert ($null -ne (Test-ReleasePackage (Join-Path $tmpRoot 'absent.zip') $mf $pubT)) 'paquet : absent -> refuse'

    # Signature du manifeste entier (msig : version, empreinte, date, notes)
    $notesT = @('Note A', 'Note B')
    $msigT = [Convert]::ToBase64String($rsaT.SignData([Text.Encoding]::UTF8.GetBytes((Get-ManifestSignedText '1.2.0' $shaT '2026-10-27' $notesT)), 'SHA256'))
    $manT = @{ Version = '1.2.0'; Sha256 = $shaT; Date = '2026-10-27'; Notes = $notesT; MSig = $msigT }
    Assert (Test-ManifestSignature $manT $pubT) 'manifeste : signature valide acceptee'
    Assert (-not (Test-ManifestSignature (@{} + $manT + @{}) '')) 'manifeste : sans cle refuse'
    $forge = $manT.Clone(); $forge.Notes = @('Appelez le 06 00 00 00 00 pour activer la mise a jour')
    Assert (-not (Test-ManifestSignature $forge $pubT)) 'manifeste : notes modifiees refusees'
    $forge = $manT.Clone(); $forge.Version = '999.0'
    Assert (-not (Test-ManifestSignature $forge $pubT)) 'manifeste : version 999 forgee refusee'
    $forge = $manT.Clone(); $forge.MSig = ''
    Assert (-not (Test-ManifestSignature $forge $pubT)) 'manifeste : sans msig refuse'
    # Complete-UpdateCheck : un manifeste non authentifie ne pose aucune pastille
    function Update-UpdateBadge { param($c) }
    $ctxSig = @{ Config = @{ Version = '1.0.0'; ReleasePublicKey = $pubT }; UpdateAvailable = $null }
    $forge = $manT.Clone(); $forge.Version = '999.0'; $forge.Source = 'release'
    Complete-UpdateCheck $ctxSig $forge
    Assert ($null -eq $ctxSig.UpdateAvailable) 'manifeste : version forgee -> aucune mise a jour proposee'
    $ok = $manT.Clone(); $ok.Source = 'release'
    Complete-UpdateCheck $ctxSig $ok
    Assert ($ctxSig.UpdateAvailable.Version -eq '1.2.0') 'manifeste : authentique -> mise a jour proposee'

    # Get-UpdateRawBase : absent -> null ; configure -> URL raw
    Assert ($null -eq (Get-UpdateRawBase $ctx)) 'update : pas de repo github -> base null'
    $ctxGh = @{ Config = @{ UpdateRepo = 'user/repo'; UpdateBranch = '' } }
    Assert ((Get-UpdateRawBase $ctxGh) -eq 'https://raw.githubusercontent.com/user/repo/main') 'update : base raw (branche main par defaut)'

    # Tri numérique de versions
    Assert ((Convert-VersionSortKey '1.10.0') -gt (Convert-VersionSortKey '1.9.0')) 'update : tri 1.10 > 1.9'

    # releases.json EMBARQUÉ (dans AppRoot)
    '{ "1.0.0": ["Initiale"], "1.1.0": ["Ajout X"], "1.2.0": ["Note A", "Note B"] }' |
        Out-File -LiteralPath (Join-Path $app 'releases.json') -Encoding UTF8
    $rec = Get-RecentReleaseNotes $ctx 2
    Assert (@($rec).Count -eq 2 -and $rec[0].Version -eq '1.2.0') 'update : 2 versions recentes, plus recente en tete'
    $between = Get-ReleaseNotesBetween $ctx '1.0.0' '1.2.0' 25
    Assert (@($between).Count -eq 2 -and $between.Version -contains '1.1.0' -and $between.Version -contains '1.2.0') 'update : notes entre 1.0.0(exclu) et 1.2.0'
    Assert (-not ($between.Version -contains '1.0.0')) 'update : version de depart exclue'

    # Invoke-UpdateCheck : version distante 1.2.0 > courante 1.1.0 -> UpdateAvailable pose
    $ctx.Config.Version = '1.1.0'
    Invoke-UpdateCheck $ctx
    Assert ($null -ne $ctx.UpdateAvailable -and $ctx.UpdateAvailable.Version -eq '1.2.0') 'update : UpdateAvailable pose si plus recent'

    # Pas de MAJ si courante == distante
    $ctx.Config.Version = '1.2.0'
    Invoke-UpdateCheck $ctx
    Assert ($null -eq $ctx.UpdateAvailable) 'update : pas de MAJ si deja a jour'

    # Zip annonce mais absent -> pas de MAJ
    $ctx.Config.Version = '1.1.0'
    Remove-Item -LiteralPath (Join-Path $dist 'Arrivee-Collab_version1.2.0.zip') -Force
    Invoke-UpdateCheck $ctx
    Assert ($null -eq $ctx.UpdateAvailable) 'update : pas de MAJ si zip absent'
} finally {
    if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Tutoriel : étapes + décision d'affichage ---
. (Join-Path $lib 'Tutorial.ps1')
$steps = @(Get-TutorialSteps @{ })
Assert (@($steps).Count -eq 16) 'tuto : 16 etapes'
Assert (@($steps | Where-Object { -not $_.Title }).Count -eq 0) 'tuto : chaque etape a un titre'
Assert (@($steps | Where-Object { -not $_.Text }).Count -eq 0)  'tuto : chaque etape a un texte'
Assert (@($steps | Where-Object { -not $_.Icon }).Count -eq 0)  'tuto : chaque etape a une icone'
Assert ($null -ne $steps[1].Target) 'tuto : etape 2 a une cible (scriptblock)'

# Test-TutorialDue : pas vu -> du ; vu version courante -> pas du ; contenu plus recent -> du
Assert (Test-TutorialDue @{ TutorialSeenVersion = 0 } 1) 'tuto : jamais vu -> affiche'
Assert (-not (Test-TutorialDue @{ TutorialSeenVersion = 1 } 1)) 'tuto : deja vu version courante -> pas affiche'
Assert (Test-TutorialDue @{ TutorialSeenVersion = 1 } 2) 'tuto : contenu plus recent -> reaffiche'

# --- Should-AutoHide (décision de masquage auto) ---
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234) -eq $true)  'autohide : autre processus => masquer'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 1234 -OwnPid 1234) -eq $false) 'autohide : meme processus (dialogue/calendrier) => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $true  -ForegroundPid 4321 -OwnPid 1234) -eq $false) 'autohide : flux .msg supprime => non'
Assert ((Should-AutoHide -AppHidden $true  -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234) -eq $false) 'autohide : deja masquee => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $true  -Suppressed $false -ForegroundPid 4321 -OwnPid 1234) -eq $false) 'autohide : animation en cours => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 0    -OwnPid 1234) -eq $false) 'autohide : pas de fenetre premier plan => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234 -Disabled $true)  -eq $false) 'autohide : option desactivee => non'
Assert ((Should-AutoHide -AppHidden $false -Animating $false -Suppressed $false -ForegroundPid 4321 -OwnPid 1234 -Disabled $false) -eq $true)  'autohide : option active => masquer'

Write-Host ""
if ($script:fail -eq 0) { Write-Host "TOUS LES TESTS PASSENT" -ForegroundColor Green }
else { Write-Host "$($script:fail) ÉCHEC(S)" -ForegroundColor Red; exit 1 }
