# ============================================================================
#  Vérification d'homonymes dans ServiceNow (table sys_user).
#
#  Même principe que SNOW Widget : une page ServiceNow est chargée dans un
#  WebView2 CACHÉ (fenêtre hors écran) qui réutilise la session SSO de
#  l'entreprise (Kerberos/OpenAM). Aucun jeton, aucune API REST : la recherche
#  passe par une requête JSONv2 « same-origin » (fetch avec le cookie de session)
#  exécutée dans la page. Si une connexion est nécessaire, la fenêtre est
#  ramenée au centre de l'écran le temps de se connecter, puis re-cachée.
#
#  Partie 1 = helpers PURS (testés hors-GUI dans tests/Test-ArriveeCollab.ps1).
#  Partie 2 = moteur WebView2 (initialisé à la demande par Initialize-HomonymeEngine,
#             aucun effet de bord au simple dot-sourcing).
# ============================================================================

# ----------------------------------------------------------------------------
#  Partie 1 — helpers purs
# ----------------------------------------------------------------------------

# Normalise un nom pour la comparaison : sans accents, majuscules, tirets et
# apostrophes remplacés par des espaces, espaces multiples réduits.
# « Jérémy  Pasturel-Dupont » -> « JEREMY PASTUREL DUPONT ».
function ConvertTo-NomNormalise {
    param([string]$Texte)
    if ([string]::IsNullOrWhiteSpace($Texte)) { return '' }
    $d = $Texte.Normalize([Text.NormalizationForm]::FormD)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $d.ToCharArray()) {
        if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    $t = $sb.ToString().ToUpperInvariant() -replace "[-'’]", ' '
    return ($t -replace '\s+', ' ').Trim()
}

# Mots normalisés et TRIÉS d'un nom : l'ordre « Prénom Nom » / « NOM Prénom »
# n'a ainsi plus d'importance pour comparer deux noms.
function Get-NomTokens {
    param([string]$Texte)
    $n = ConvertTo-NomNormalise $Texte
    if ($n -eq '') { return @() }
    return @($n.Split(' ') | Sort-Object)
}

# Filtre ServiceNow (sysparm_query) : chaque mot saisi doit figurer dans le nom
# complet (champ « name »), quel que soit l'ordre. Les caractères qui ont un sens
# dans la syntaxe des requêtes (^ =) sont retirés. $null s'il y a moins de deux mots
# (un prénom seul ramènerait des centaines de comptes).
function Get-RequeteHomonymes {
    param([string]$NomPrenom)
    if ([string]::IsNullOrWhiteSpace($NomPrenom)) { return $null }
    $mots = @(($NomPrenom -replace '[\^=]', ' ').Trim() -split '\s+' | Where-Object { $_ -ne '' })
    if ($mots.Count -lt 2) { return $null }
    return (($mots | ForEach-Object { "nameLIKE$_" }) -join '^')
}

# URL relative (same-origin) de la requête JSONv2 sur sys_user.
function Get-UrlJsonHomonymes {
    param([string]$NomPrenom, [int]$Max = 50)
    $q = Get-RequeteHomonymes $NomPrenom
    if (-not $q) { return $null }
    $champs = 'user_name,name,first_name,last_name,email,active,sys_created_on'
    return "/sys_user.do?JSONv2&sysparm_action=getRecords&sysparm_query=$([uri]::EscapeDataString($q))&sysparm_fields=$champs&sysparm_record_count=$Max"
}

# Comptes dont le nom correspond EXACTEMENT (mêmes mots, accents/casse/ordre
# ignorés) au nom saisi. Le champ « name » est prioritaire ; à défaut on
# reconstitue prénom + nom. La recherche « LIKE » ramène aussi des noms plus longs
# (ex. « MARTIN Paul-Henri » pour « Paul Martin ») : ce filtre les écarte.
function Select-Homonymes {
    param($Records, [string]$NomPrenom)
    $cible = (Get-NomTokens $NomPrenom) -join ' '
    if ($cible -eq '') { return @() }
    $res = @()
    foreach ($r in @($Records)) {
        if ($null -eq $r) { continue }
        $nom = [string]$r.name
        if ([string]::IsNullOrWhiteSpace($nom)) { $nom = "$($r.first_name) $($r.last_name)" }
        if (((Get-NomTokens $nom) -join ' ') -eq $cible) { $res += $r }
    }
    return $res   # appelants : @(Select-Homonymes ...)
}

# Présence d'homonymes = au moins deux comptes portent exactement ce nom
# (un seul = le compte du bénéficiaire lui-même).
function Test-PresenceHomonymes {
    param($Comptes)
    return (@($Comptes).Count -ge 2)
}

# Libellé « CP trouvé(s) » : les CP des comptes homonymes autres que celui
# communiqué dans la RITM, séparés par des virgules.
function Get-CpTrouves {
    param($Comptes, [string]$CpDemande)
    return @(@($Comptes) | ForEach-Object { [string]$_.user_name } |
             Where-Object { $_ -and $_ -ne $CpDemande })
}

# ----------------------------------------------------------------------------
#  Partie 2 — moteur WebView2 caché
# ----------------------------------------------------------------------------

# État du moteur (global : les gestionnaires d'événements WinForms s'exécutent
# hors de la portée du script).
#   Phase : off | init | sso (SSO silencieux en cours) | auth (fenêtre affichée)
#           | ready | kick | poll | error
$global:Homo = @{
    Phase      = 'off'
    Form       = $null
    WebView    = $null
    Timer      = $null
    Task       = $null
    Deadline   = [datetime]::MinValue
    Pending    = $null       # nom en attente de vérification
    EnCours    = $null       # nom en cours de vérification
    OnResultat = $null       # { param($NomPrenom, $Records) }
    OnStatut   = $null       # { param($Etat, $Texte) } Etat = info | auth | erreur
    StartUrl   = 'https://sncf.service-now.com/now/nav/ui/classic/params/target/sys_user_list.do'
}

# Charge les assemblies WebView2 embarquées (lib\webview2) + la fenêtre hôte qui
# s'affiche SANS prendre le focus (sinon la saisie du nom serait interrompue).
function Import-HomonymeWebView2 {
    param([string]$LibDir)
    if (-not ('HomoNative' -as [type])) {
        Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public static class HomoNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string lpPathName);
}
public class HomoHostForm : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
}
"@
    }
    [void][HomoNative]::SetDllDirectory($LibDir)
    Add-Type -Path (Join-Path $LibDir 'Microsoft.Web.WebView2.Core.dll')
    Add-Type -Path (Join-Path $LibDir 'Microsoft.Web.WebView2.WinForms.dll')
    return [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::GetAvailableBrowserVersionString()
}

function Send-HomoStatut {
    param([string]$Etat, [string]$Texte)
    if ($global:Homo.OnStatut) { try { & $global:Homo.OnStatut $Etat $Texte } catch { Write-AppLog "[HOMO] OnStatut KO : $($_.Exception.Message)" } }
}

# Fenêtre de connexion : ramenée au centre de l'écran de l'app, au premier plan.
# (ShowInTaskbar n'est jamais basculé : cela recréerait le handle et casserait le WebView2.)
function Show-HomoAuth {
    $f = $global:Homo.Form
    if (-not $f) { return }
    # Une recherche interrompue par la redirection vers la connexion sera rejouée ensuite.
    if ($global:Homo.Phase -in @('kick', 'poll') -and -not $global:Homo.Pending) { $global:Homo.Pending = $global:Homo.EnCours }
    $global:Homo.Phase = 'auth'
    $scr = if ($form) { [Windows.Forms.Screen]::FromControl($form).WorkingArea } else { [Windows.Forms.Screen]::PrimaryScreen.WorkingArea }
    $f.Location = New-Object Drawing.Point(($scr.X + [int](($scr.Width - $f.Width) / 2)), ($scr.Y + [int](($scr.Height - $f.Height) / 2)))
    $f.TopMost = $true
    $f.Activate()
    Send-HomoStatut 'auth' 'Connexion ServiceNow requise'
    Write-AppLog '[HOMO] Connexion requise : fenêtre affichée.'
}

function Hide-HomoAuth {
    $f = $global:Homo.Form
    if (-not $f) { return }
    $f.TopMost = $false
    $f.Location = New-Object Drawing.Point(-5000, -5000)
}

function Test-HomoAuthVisible {
    return ($global:Homo.Form -and $global:Homo.Form.Left -gt -4000)
}

# Crée la fenêtre cachée + le WebView2 (profil persistant = session SSO conservée).
function Initialize-HomonymeEngine {
    param([string]$LibDir, [string]$DataDir, [scriptblock]$OnResultat, [scriptblock]$OnStatut)
    $global:Homo.OnResultat = $OnResultat
    $global:Homo.OnStatut = $OnStatut
    if ($global:Homo.Phase -ne 'off') { return }
    # Test hors réseau SNCF (poste de dev sans VPN) : ARRIVEE_COLLAB_HOMO_FAKE = chemin
    # d'un JSON { "records": [...] } renvoyé à la place de ServiceNow. Jamais défini en prod.
    if ($env:ARRIVEE_COLLAB_HOMO_FAKE -and (Test-Path $env:ARRIVEE_COLLAB_HOMO_FAKE)) {
        $global:Homo.Phase = 'fake'
        Write-AppLog "[HOMO] Mode test : réponses lues dans $($env:ARRIVEE_COLLAB_HOMO_FAKE)"
        return
    }
    try {
        $v = Import-HomonymeWebView2 $LibDir
        Write-AppLog "[HOMO] WebView2 runtime $v"
    } catch {
        $global:Homo.Phase = 'error'
        Write-AppLog "[HOMO] WebView2 indisponible : $($_.Exception.Message)"
        Send-HomoStatut 'erreur' 'Vérification indisponible (WebView2 absent)'
        return
    }
    $global:Homo.Phase = 'init'
    $f = New-Object HomoHostForm
    $f.Text = 'Connexion ServiceNow — Arrivée Collaborateur'
    $f.StartPosition = 'Manual'
    $f.Size = New-Object Drawing.Size(1000, 750)
    $f.Location = New-Object Drawing.Point(-5000, -5000)
    $f.ShowInTaskbar = $false
    $icon = Join-Path (Split-Path $LibDir -Parent | Split-Path -Parent) 'image-arrivee-collab.ico'
    if (Test-Path $icon) { try { $f.Icon = New-Object Drawing.Icon($icon) } catch {} }
    # La croix ne détruit pas le WebView2 : elle re-cache la fenêtre.
    $f.Add_FormClosing({
        param($s, $e)
        if ($e.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            Hide-HomoAuth
            if ($global:Homo.Phase -eq 'auth') { Send-HomoStatut 'erreur' 'Connexion ServiceNow annulée' ; $global:Homo.Phase = 'init' }
        }
    })

    $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $cp = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    $cp.UserDataFolder = Join-Path $DataDir 'webview2'
    $cp.AdditionalBrowserArguments = '--auth-server-allowlist=*.sncf.fr,*.service-now.com --auth-negotiate-delegate-allowlist=*.sncf.fr,*.service-now.com'
    $wv.CreationProperties = $cp
    $wv.Dock = 'Fill'
    $wv.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) {
            $global:Homo.Phase = 'error'
            Write-AppLog "[HOMO] Init WebView2 KO : $($e.InitializationException.Message)"
            Send-HomoStatut 'erreur' 'Vérification indisponible (WebView2)'
        }
    })
    $wv.Add_NavigationCompleted({ param($s, $e) try { Invoke-HomoNavigation $e } catch { Write-AppLog "[HOMO] Navigation KO : $($_.Exception.Message)" } })
    $f.Controls.Add($wv)
    $global:Homo.Form = $f
    $global:Homo.WebView = $wv

    # Pompe non bloquante (250 ms) : relève les Task<string> d'ExecuteScriptAsync.
    $t = New-Object Windows.Forms.Timer
    $t.Interval = 250
    $t.Add_Tick({ try { Step-HomoPump } catch { Write-AppLog "[HOMO] Pompe KO : $($_.Exception.Message)"; $global:Homo.Phase = 'ready' } })
    $global:Homo.Timer = $t
    $t.Start()

    $f.Show()   # un WebView2 jamais affiché ne charge pas (fenêtre hors écran, sans focus)
    Send-HomoStatut 'info' 'Connexion à ServiceNow…'
    $wv.Source = [uri]$global:Homo.StartUrl
    Write-AppLog '[HOMO] Moteur initialisé, navigation vers sys_user_list.'
}

# Page chargée : soit on est sur l'instance (prêt), soit sur une page de connexion.
function Invoke-HomoNavigation {
    param($e)
    $url = [string]$global:Homo.WebView.Source
    if (-not $e.IsSuccess) {
        Write-AppLog "[HOMO] Navigation en échec ($($e.WebErrorStatus)) : $url"
        if ($global:Homo.Phase -in @('init', 'auth')) {
            $global:Homo.Phase = 'error'
            Send-HomoStatut 'erreur' 'ServiceNow injoignable (réseau / VPN ?)'
        }
        return
    }
    $u = [uri]$url
    $surInstance = $u.Host -like '*service-now.com'
    # auth_redirect.do / IdP OpenAM = étapes du SSO, normalement franchies seules
    # (Kerberos). On attend sans rien afficher ; la fenêtre n'apparaît qu'en dernier
    # recours si l'on n'est pas revenu sur l'instance avant le délai (cf. Step-HomoPump).
    $pageLogin = $u.AbsolutePath -match 'login|logout|sso|saml|side_door|auth_redirect|auth\.do|welcome'
    if (-not $surInstance -or $pageLogin) {
        Write-AppLog "[HOMO] Étape SSO : $($u.Host)$($u.AbsolutePath)"
        if ($global:Homo.Phase -in @('kick', 'poll') -and -not $global:Homo.Pending) { $global:Homo.Pending = $global:Homo.EnCours }
        if ($global:Homo.Phase -notin @('sso', 'auth')) {
            $global:Homo.Phase = 'sso'
            $global:Homo.Deadline = (Get-Date).AddSeconds(12)
        }
        return
    }
    if (Test-HomoAuthVisible) { Hide-HomoAuth }
    if ($global:Homo.Phase -in @('init', 'sso', 'auth', 'error')) {
        $global:Homo.Phase = 'ready'
        Write-AppLog "[HOMO] Session ServiceNow prête : $url"
        if (-not $global:Homo.Pending) { Send-HomoStatut 'info' 'ServiceNow connecté' }
    }
}

# Demande une vérification (la dernière demande l'emporte). Démarre le moteur au besoin.
function Start-VerifHomonymes {
    param([string]$NomPrenom)
    $global:Homo.Pending = $NomPrenom
    if ($global:Homo.Phase -eq 'fake') {
        $global:Homo.Pending = $null
        $o = Get-Content -Raw -Encoding UTF8 $env:ARRIVEE_COLLAB_HOMO_FAKE | ConvertFrom-Json
        if ($global:Homo.OnResultat) { & $global:Homo.OnResultat $NomPrenom @($o.records) }
        return
    }
    if ($global:Homo.Phase -eq 'error' -and $global:Homo.WebView) {
        # Nouvelle tentative après une erreur réseau : on recharge la page de départ.
        $global:Homo.Phase = 'init'
        Send-HomoStatut 'info' 'Connexion à ServiceNow…'
        $global:Homo.WebView.Source = [uri]$global:Homo.StartUrl
    }
}

# Machine d'état appelée toutes les 250 ms.
function Step-HomoPump {
    $h = $global:Homo
    switch ($h.Phase) {
        'sso' {
            # SSO silencieux bloqué (session Windows non reconnue par l'IdP) : dernier recours.
            if ((Get-Date) -gt $h.Deadline) { Show-HomoAuth }
        }
        'ready' {
            if (-not $h.Pending) { return }
            $nom = $h.Pending; $h.Pending = $null
            $url = Get-UrlJsonHomonymes $nom
            if (-not $url) { return }
            $url = $url.Replace('\', '\\').Replace("'", "\'")   # littéral JS entre apostrophes
            $h.EnCours = $nom
            Send-HomoStatut 'info' 'Recherche d''homonymes…'
            # ExecuteScriptAsync ne résout pas les promesses : on lance le fetch, le
            # résultat est déposé dans window.__acHomo puis relevé par polling.
            $js = "(function(){window.__acHomo='PENDING';fetch('$url',{credentials:'same-origin',headers:{Accept:'application/json'}})" +
                  ".then(function(r){return r.text();}).then(function(t){try{window.__acHomo=JSON.parse(t);}catch(x){window.__acHomo={error:'parse',body:t.slice(0,200)};}})" +
                  ".catch(function(x){window.__acHomo={error:String(x)};});return 'started';})()"
            $h.Task = $h.WebView.CoreWebView2.ExecuteScriptAsync($js)
            $h.Deadline = (Get-Date).AddSeconds(25)
            $h.Phase = 'kick'
        }
        'kick' {
            if (-not $h.Task.IsCompleted) { return }
            $h.Task = $h.WebView.CoreWebView2.ExecuteScriptAsync('window.__acHomo')
            $h.Phase = 'poll'
        }
        'poll' {
            if (-not $h.Task.IsCompleted) { return }
            $res = [string]$h.Task.Result
            if ($res -eq '"PENDING"') {
                if ((Get-Date) -gt $h.Deadline) {
                    $h.Phase = 'ready'
                    Write-AppLog '[HOMO] Délai dépassé.'
                    Send-HomoStatut 'erreur' 'ServiceNow ne répond pas (cliquer pour relancer)'
                    return
                }
                $h.Task = $h.WebView.CoreWebView2.ExecuteScriptAsync('window.__acHomo')
                return
            }
            $h.Phase = 'ready'
            $o = $null
            try { $o = $res | ConvertFrom-Json } catch { }
            if ($null -eq $o -or $o.error) {
                $detail = if ($o) { "$($o.error) $($o.body)" } else { $res }
                Write-AppLog "[HOMO] Réponse inexploitable : $detail"
                # Une page HTML à la place du JSON = session expirée -> reconnexion.
                if ($o -and $o.error -eq 'parse') {
                    $h.Pending = $h.EnCours
                    $h.Phase = 'init'
                    $h.WebView.Source = [uri]$h.StartUrl
                    return
                }
                Send-HomoStatut 'erreur' 'Réponse ServiceNow inexploitable (cliquer pour relancer)'
                return
            }
            $records = @($o.records)
            Write-AppLog "[HOMO] « $($h.EnCours) » : $($records.Count) compte(s) ramené(s)."
            # Résultat périmé (le nom a changé entre-temps) : la nouvelle demande suit.
            if ($h.Pending) { return }
            if ($h.OnResultat) { & $h.OnResultat $h.EnCours $records }
        }
    }
}
