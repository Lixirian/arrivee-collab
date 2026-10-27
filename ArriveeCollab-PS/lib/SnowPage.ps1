# ============================================================================
#  Page ServiceNow CACHÉE, partagée par les vérifications (homonymes, doublons).
#
#  Même principe que SNOW Widget : une page ServiceNow est chargée dans un
#  WebView2 CACHÉ (fenêtre hors écran, sans prendre le focus) qui réutilise la
#  session SSO de l'entreprise (Kerberos/OpenAM). Aucun jeton stocké, aucune API
#  REST : chaque recherche est une requête JSONv2 « same-origin » (fetch avec le
#  cookie de session) exécutée dans la page. Le SSO est attendu en silence ; si une
#  connexion interactive est vraiment nécessaire, la fenêtre est ramenée au centre
#  de l'écran le temps de se connecter, puis re-cachée.
#
#  Robustesse : la requête ne part qu'une fois la page stabilisée (l'interface
#  « Next Experience » continue de s'initialiser après le chargement) ; délai dépassé,
#  page rechargée, 401/403 ou page HTML au lieu du JSON (session expirée) =>
#  RESYNCHRONISATION SSO (rechargement de la page) puis nouvel essai automatique.
#
#  Sécurité : navigation limitée à l'instance et à l'IdP SNCF, aucune nouvelle
#  fenêtre, authentification Windows intégrée limitée à *.sncf.fr + l'instance,
#  sans délégation Kerberos ; toute demande d'identifiants « Basic » est refusée.
#
#  Une requête en attente PAR TYPE (la dernière demande d'un type remplace la
#  précédente) ; les types sont traités l'un après l'autre. Rien n'est lancé au
#  simple dot-sourcing : Initialize-SnowEngine crée la page à la première demande.
# ============================================================================

$script:SnowInstanceHost = 'sncf.service-now.com'

# État du moteur (global : les gestionnaires d'événements WinForms s'exécutent
# hors de la portée du script).
#   Phase : off | init | sso (SSO silencieux en cours) | auth (fenêtre affichée)
#           | settle (page chargée, stabilisation) | ready | kick | poll | error
#           | fake (test hors réseau)
$global:Snow = @{
    Phase      = 'off'
    Form       = $null
    WebView    = $null
    Timer      = $null
    Task       = $null
    Deadline   = [datetime]::MinValue
    Pending    = [ordered]@{}   # Type -> @{ Type; Cle; Url; Essais }
    EnCours    = $null          # requête en cours d'exécution
    OnResultat = @{}            # Type -> { param($Cle, $Records) }
    OnStatut   = @{}            # Type -> { param($Etat, $Texte) } Etat = info | auth | erreur
    StartUrl   = "https://$($script:SnowInstanceHost)/now/nav/ui/classic/params/target/sys_user_list.do"
}

# Hôtes autorisés dans la page cachée : l'instance ServiceNow (exacte) et les
# serveurs SNCF (IdP OpenAM du SSO). Fonction pure (testée hors-GUI).
function Test-SnowHoteAutorise {
    param([string]$Url)
    try { $u = [uri]$Url } catch { return $false }
    if ($u.Scheme -notin @('https', 'about', 'data')) { return $false }
    if ($u.Scheme -ne 'https') { return $true }
    $h = $u.Host.ToLowerInvariant()
    return ($h -eq $script:SnowInstanceHost -or $h -eq 'sncf.fr' -or $h.EndsWith('.sncf.fr'))
}

# Charge les assemblies WebView2 embarquées (lib\webview2) + la fenêtre hôte qui
# s'affiche SANS prendre le focus (sinon la saisie en cours serait interrompue).
function Import-SnowWebView2 {
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

# Statut diffusé à un type (ou à tous les types enregistrés si $Type est vide).
function Send-SnowStatut {
    param([string]$Etat, [string]$Texte, [string]$Type = '')
    $cibles = if ($Type) { @($Type) } else { @($global:Snow.OnStatut.Keys) }
    foreach ($t in $cibles) {
        $cb = $global:Snow.OnStatut[$t]
        if ($cb) { try { & $cb $Etat $Texte } catch { Write-AppLog "[SNOW] OnStatut($t) KO : $($_.Exception.Message)" } }
    }
}

# Remet en file une requête interrompue (redirection SSO, page rechargée…).
function Restore-SnowEnCours {
    $r = $global:Snow.EnCours
    if ($r -and -not $global:Snow.Pending.Contains($r.Type)) { $global:Snow.Pending[$r.Type] = $r }
    $global:Snow.EnCours = $null
}

# Échec d'une requête : resynchronisation SSO (rechargement de la page) et nouvel
# essai automatique, au plus 2 fois ; au-delà, l'erreur est affichée.
function Invoke-SnowResync {
    param([string]$Motif)
    $h = $global:Snow
    $req = $h.EnCours
    $h.EnCours = $null
    if (-not $req) { $h.Phase = 'ready'; return }
    if ([int]$req.Essais -lt 2) {
        $req.Essais = [int]$req.Essais + 1
        if (-not $h.Pending.Contains($req.Type)) { $h.Pending[$req.Type] = $req }
        Write-AppLog "[SNOW] $($req.Type) : $Motif -> resynchronisation SSO (essai $($req.Essais + 1))."
        Send-SnowStatut 'info' 'Resynchronisation SSO avec ServiceNow…' $req.Type
        $h.Phase = 'init'
        $h.WebView.Source = [uri]$h.StartUrl
        return
    }
    $h.Phase = 'ready'
    Write-AppLog "[SNOW] $($req.Type) : $Motif -> abandon après resynchronisation."
    Send-SnowStatut 'erreur' 'ServiceNow ne répond pas (cliquer pour relancer)' $req.Type
}

# Fenêtre de connexion : ramenée au centre de l'écran de l'app, au premier plan.
# (ShowInTaskbar n'est jamais basculé : cela recréerait le handle et casserait le WebView2.)
function Show-SnowAuth {
    $f = $global:Snow.Form
    if (-not $f) { return }
    if ($global:Snow.Phase -in @('kick', 'poll')) { Restore-SnowEnCours }
    $global:Snow.Phase = 'auth'
    $scr = if ($form) { [Windows.Forms.Screen]::FromControl($form).WorkingArea } else { [Windows.Forms.Screen]::PrimaryScreen.WorkingArea }
    $f.Location = New-Object Drawing.Point(($scr.X + [int](($scr.Width - $f.Width) / 2)), ($scr.Y + [int](($scr.Height - $f.Height) / 2)))
    $f.TopMost = $true
    $f.Activate()
    Send-SnowStatut 'auth' 'Connexion ServiceNow requise'
    Write-AppLog '[SNOW] Connexion requise : fenêtre affichée.'
}

function Hide-SnowAuth {
    $f = $global:Snow.Form
    if (-not $f) { return }
    $f.TopMost = $false
    $f.Location = New-Object Drawing.Point(-5000, -5000)
}

function Test-SnowAuthVisible {
    return ($global:Snow.Form -and $global:Snow.Form.Left -gt -4000)
}

# Mode test hors réseau SNCF autorisé ? Uniquement pour une copie de DÉVELOPPEMENT
# (jamais pour la copie installée sous %LOCALAPPDATA%\Arrivee-Collab\app).
function Test-SnowModeTest {
    param([string]$LibDir)
    if (-not ($env:ARRIVEE_COLLAB_HOMO_FAKE -or $env:ARRIVEE_COLLAB_DOUBLON_FAKE)) { return $false }
    $installe = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Arrivee-Collab\app')).TrimEnd('\')
    $app = [IO.Path]::GetFullPath((Split-Path (Split-Path $LibDir -Parent) -Parent)).TrimEnd('\')
    return ($app -ine $installe)
}

# Enregistre les rappels d'un type et crée la page cachée au premier appel
# (profil WebView2 persistant = session SSO conservée d'un lancement à l'autre).
function Initialize-SnowEngine {
    param([string]$LibDir, [string]$DataDir, [string]$Type, [scriptblock]$OnResultat, [scriptblock]$OnStatut)
    $global:Snow.OnResultat[$Type] = $OnResultat
    $global:Snow.OnStatut[$Type] = $OnStatut
    if ($global:Snow.Phase -ne 'off') { return }
    # Test hors réseau SNCF (poste de dev sans VPN) : ARRIVEE_COLLAB_HOMO_FAKE et/ou
    # ARRIVEE_COLLAB_DOUBLON_FAKE = chemin d'un JSON { "records": [...] } renvoyé à la
    # place de ServiceNow pour ce type. Ignoré par la copie installée.
    if (Test-SnowModeTest $LibDir) {
        $global:Snow.Phase = 'fake'
        Write-AppLog '[SNOW] Mode test : réponses lues dans des fichiers locaux.'
        return
    }
    try {
        $v = Import-SnowWebView2 $LibDir
        Write-AppLog "[SNOW] WebView2 runtime $v"
    } catch {
        $global:Snow.Phase = 'error'
        Write-AppLog "[SNOW] WebView2 indisponible : $($_.Exception.Message)"
        Send-SnowStatut 'erreur' 'Vérification indisponible (WebView2 absent)'
        return
    }
    $global:Snow.Phase = 'init'
    $f = New-Object HomoHostForm
    $f.Text = 'Connexion ServiceNow — Arrivée Collaborateur'
    $f.StartPosition = 'Manual'
    $f.Size = New-Object Drawing.Size(1000, 750)
    $f.Location = New-Object Drawing.Point(-5000, -5000)
    $f.ShowInTaskbar = $false
    $icon = Join-Path (Split-Path $LibDir -Parent | Split-Path -Parent) 'image-arrivee-collab.ico'
    if (Test-Path -LiteralPath $icon) { try { $f.Icon = New-Object Drawing.Icon($icon) } catch {} }
    # La croix ne détruit pas le WebView2 : elle re-cache la fenêtre.
    $f.Add_FormClosing({
        param($s, $e)
        if ($e.CloseReason -eq [Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            Hide-SnowAuth
            if ($global:Snow.Phase -eq 'auth') { Send-SnowStatut 'erreur' 'Connexion ServiceNow annulée'; $global:Snow.Phase = 'error' }
        }
    })

    $wv = New-Object Microsoft.Web.WebView2.WinForms.WebView2
    $cp = New-Object Microsoft.Web.WebView2.WinForms.CoreWebView2CreationProperties
    $cp.UserDataFolder = Join-Path $DataDir 'webview2'
    # Authentification Windows intégrée (Kerberos) limitée aux serveurs SNCF et à
    # l'instance, SANS délégation du ticket (inutile pour le SSO).
    $cp.AdditionalBrowserArguments = "--auth-server-allowlist=*.sncf.fr,$($script:SnowInstanceHost)"
    $wv.CreationProperties = $cp
    $wv.Dock = 'Fill'
    $wv.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) {
            $global:Snow.Phase = 'error'
            Write-AppLog "[SNOW] Init WebView2 KO : $($e.InitializationException.Message)"
            Send-SnowStatut 'erreur' 'Vérification indisponible (WebView2)'
            return
        }
        try {
            $c = $s.CoreWebView2
            $c.Settings.AreDevToolsEnabled = $false
            $c.Settings.AreDefaultContextMenusEnabled = $false
            $c.Settings.IsStatusBarEnabled = $false
            # Navigation limitée à l'instance et à l'IdP SNCF.
            $c.add_NavigationStarting({
                param($cs, $ne)
                if (-not (Test-SnowHoteAutorise $ne.Uri)) {
                    $ne.Cancel = $true
                    Write-AppLog "[SECU] Navigation bloquée : $(([uri]$ne.Uri).Host)"
                }
            })
            # Aucune nouvelle fenêtre (pop-up, lien « nouvel onglet »).
            $c.add_NewWindowRequested({ param($cs, $ne) $ne.Handled = $true; Write-AppLog '[SECU] Ouverture de fenêtre bloquée.' })
            # Une demande d'identifiants « Basic » resterait bloquée dans une fenêtre
            # cachée (requête sans fin) : refusée, la requête échoue proprement.
            $c.add_BasicAuthenticationRequested({ param($cs, $ne) $ne.Cancel = $true; Write-AppLog '[SNOW] Authentification Basic demandée par le serveur : refusée.' })
        } catch { Write-AppLog "[SNOW] Réglages WebView2 KO : $($_.Exception.Message)" }
    })
    $wv.Add_NavigationCompleted({ param($s, $e) try { Invoke-SnowNavigation $e } catch { Write-AppLog "[SNOW] Navigation KO : $($_.Exception.Message)" } })
    $f.Controls.Add($wv)
    $global:Snow.Form = $f
    $global:Snow.WebView = $wv

    # Pompe non bloquante (250 ms) : relève les Task<string> d'ExecuteScriptAsync.
    $t = New-Object Windows.Forms.Timer
    $t.Interval = 250
    $t.Add_Tick({ try { Step-SnowPump } catch { Write-AppLog "[SNOW] Pompe KO : $($_.Exception.Message)"; Invoke-SnowResync 'erreur interne' } })
    $global:Snow.Timer = $t
    $t.Start()

    $f.Show()   # un WebView2 jamais affiché ne charge pas (fenêtre hors écran, sans focus)
    Send-SnowStatut 'info' 'Connexion à ServiceNow…'
    $wv.Source = [uri]$global:Snow.StartUrl
    Write-AppLog '[SNOW] Page cachée initialisée.'
}

# Page chargée : soit on est sur l'instance (stabilisation puis prêt), soit sur une
# étape du SSO.
function Invoke-SnowNavigation {
    param($e)
    $url = [string]$global:Snow.WebView.Source
    if (-not $e.IsSuccess) {
        Write-AppLog "[SNOW] Navigation en échec ($($e.WebErrorStatus)) : $(([uri]$url).Host)"
        if ($global:Snow.Phase -in @('init', 'sso', 'auth', 'settle')) {
            $global:Snow.Phase = 'error'
            Send-SnowStatut 'erreur' 'ServiceNow injoignable (réseau / VPN ?)'
        }
        return
    }
    $u = [uri]$url
    $surInstance = ($u.Host -eq $script:SnowInstanceHost)
    # auth_redirect.do / IdP OpenAM = étapes du SSO, normalement franchies seules
    # (Kerberos). On attend sans rien afficher ; la fenêtre n'apparaît qu'en dernier
    # recours si l'on n'est pas revenu sur l'instance avant le délai (cf. Step-SnowPump).
    $pageLogin = $u.AbsolutePath -match 'login|logout|sso|saml|side_door|auth_redirect|auth\.do|welcome'
    if (-not $surInstance -or $pageLogin) {
        Write-AppLog "[SNOW] Étape SSO : $($u.Host)$($u.AbsolutePath)"
        if ($global:Snow.Phase -in @('kick', 'poll')) { Restore-SnowEnCours }
        if ($global:Snow.Phase -notin @('sso', 'auth')) {
            $global:Snow.Phase = 'sso'
            $global:Snow.Deadline = (Get-Date).AddSeconds(12)
        }
        return
    }
    if (Test-SnowAuthVisible) { Hide-SnowAuth }
    if ($global:Snow.Phase -in @('kick', 'poll')) { Restore-SnowEnCours }   # page rechargée en cours de requête
    if ($global:Snow.Phase -in @('init', 'sso', 'auth', 'error', 'settle', 'kick', 'poll')) {
        # L'interface « Next Experience » continue de s'initialiser après le
        # chargement : on laisse 2 s avant d'envoyer la moindre requête.
        $global:Snow.Phase = 'settle'
        $global:Snow.Deadline = (Get-Date).AddSeconds(2)
        Write-AppLog "[SNOW] Page ServiceNow chargée : $($u.AbsolutePath)"
    }
}

# Demande une recherche JSONv2 ($Url relative, same-origin) pour un type ; $Cle est
# rendue au rappel avec les enregistrements. Démarre le moteur au besoin.
function Submit-SnowRequete {
    param([string]$Type, [string]$Cle, [string]$Url)
    if (-not $Url) { return }
    $req = @{ Type = $Type; Cle = $Cle; Url = $Url; Essais = 0 }
    if ($global:Snow.Phase -eq 'fake') {
        $fichier = if ($Type -eq 'doublon') { $env:ARRIVEE_COLLAB_DOUBLON_FAKE } else { $env:ARRIVEE_COLLAB_HOMO_FAKE }
        $records = @()
        if ($fichier -and (Test-Path -LiteralPath $fichier)) { $records = @((Get-Content -LiteralPath $fichier -Raw -Encoding UTF8 | ConvertFrom-Json).records) }
        $cb = $global:Snow.OnResultat[$Type]
        if ($cb) { & $cb $Cle $records }
        return
    }
    $global:Snow.Pending[$Type] = $req
    if ($global:Snow.Phase -eq 'error' -and $global:Snow.WebView) {
        # Nouvelle tentative après une erreur (réseau, connexion annulée) : on recharge.
        $global:Snow.Phase = 'init'
        Send-SnowStatut 'info' 'Connexion à ServiceNow…' $Type
        $global:Snow.WebView.Source = [uri]$global:Snow.StartUrl
    }
}

# Script de lancement de la requête : le littéral d'URL est produit par ConvertTo-Json
# (échappement JS sûr). La requête n'est lancée que si la page est complètement
# chargée ; elle a son propre délai (20 s) et rapporte le code HTTP et le type de
# contenu pour le diagnostic. Résultat déposé dans window.__acSnow (relevé par polling :
# ExecuteScriptAsync ne résout pas les promesses).
function Get-SnowKickJs {
    param([string]$Url)
    $lit = ConvertTo-Json -InputObject $Url -Compress
    return @"
(function(){
  if (document.readyState !== 'complete') { return 'notready'; }
  window.__acSnow = 'PENDING';
  var h = { 'Accept': 'application/json' };
  try { if (window.g_ck) { h['X-UserToken'] = window.g_ck; } } catch (x) {}
  var ctl = (typeof AbortController !== 'undefined') ? new AbortController() : null;
  var tm = setTimeout(function(){ try { if (ctl) { ctl.abort(); } } catch (x) {} if (window.__acSnow === 'PENDING') { window.__acSnow = { error: 'timeout' }; } }, 20000);
  fetch($lit, { credentials: 'same-origin', headers: h, signal: ctl ? ctl.signal : undefined })
    .then(function(r){ return r.text().then(function(t){ return { status: r.status, ct: r.headers.get('content-type') || '', t: t }; }); })
    .then(function(o){
      clearTimeout(tm);
      if (o.status === 401 || o.status === 403) { window.__acSnow = { error: 'http', status: o.status, ct: o.ct }; return; }
      try { window.__acSnow = { status: o.status, data: JSON.parse(o.t) }; }
      catch (x) { window.__acSnow = { error: 'parse', status: o.status, ct: o.ct, len: o.t.length }; }
    })
    .catch(function(x){ clearTimeout(tm); if (window.__acSnow === 'PENDING') { window.__acSnow = { error: 'fetch', detail: String(x) }; } });
  return 'started';
})()
"@
}

# Machine d'état appelée toutes les 250 ms.
function Step-SnowPump {
    $h = $global:Snow
    switch ($h.Phase) {
        'sso' {
            # SSO silencieux bloqué (session Windows non reconnue par l'IdP) : dernier recours.
            if ((Get-Date) -gt $h.Deadline) { Show-SnowAuth }
        }
        'settle' {
            if ((Get-Date) -gt $h.Deadline) { $h.Phase = 'ready'; Write-AppLog '[SNOW] Session ServiceNow prête.' }
        }
        'ready' {
            if ($h.Pending.Count -eq 0) { return }
            # Sécurité : n'exécuter un script que sur l'instance elle-même.
            if (([uri][string]$h.WebView.Source).Host -ne $script:SnowInstanceHost) { return }
            $type = @($h.Pending.Keys)[0]
            $req = $h.Pending[$type]
            $h.Pending.Remove($type)
            $h.EnCours = $req
            if ([int]$req.Essais -eq 0) { Send-SnowStatut 'info' 'Recherche dans ServiceNow…' $type }
            $h.Task = $h.WebView.CoreWebView2.ExecuteScriptAsync((Get-SnowKickJs $req.Url))
            $h.Deadline = (Get-Date).AddSeconds(30)
            $h.Phase = 'kick'
        }
        'kick' {
            if (-not $h.Task.IsCompleted) { return }
            if ([string]$h.Task.Result -eq '"notready"') {
                # Page pas encore complète : on réessaiera au prochain tour.
                Restore-SnowEnCours
                $h.Phase = 'ready'
                return
            }
            $h.Task = $h.WebView.CoreWebView2.ExecuteScriptAsync('window.__acSnow')
            $h.Phase = 'poll'
        }
        'poll' {
            if (-not $h.Task.IsCompleted) { return }
            $req = $h.EnCours
            $res = [string]$h.Task.Result
            if ($res -eq '"PENDING"') {
                if ((Get-Date) -gt $h.Deadline) { Invoke-SnowResync 'délai dépassé'; return }
                $h.Task = $h.WebView.CoreWebView2.ExecuteScriptAsync('window.__acSnow')
                return
            }
            $o = $null
            try { $o = $res | ConvertFrom-Json } catch { }
            if ($null -eq $o) { Invoke-SnowResync 'page rechargée pendant la requête'; return }
            if ($o.error) {
                $diag = "$($o.error)" + $(if ($o.status) { " HTTP $($o.status)" } else { '' }) + $(if ($o.ct) { " ($($o.ct))" } else { '' }) + $(if ($o.detail) { " $($o.detail)" } else { '' })
                Write-AppLog "[SNOW] $($req.Type) : réponse inexploitable : $diag"
                # timeout / 401-403 / HTML au lieu du JSON (session expirée) / échec réseau :
                # resynchronisation SSO puis nouvel essai.
                Invoke-SnowResync $diag
                return
            }
            $h.Phase = 'ready'
            $h.EnCours = $null
            $records = @($o.data.records)
            Write-AppLog "[SNOW] $($req.Type) : HTTP $($o.status), $($records.Count) enregistrement(s)."
            # Résultat périmé (une nouvelle demande du même type attend) : elle suivra.
            if ($h.Pending.Contains($req.Type)) { return }
            $cb = $h.OnResultat[$req.Type]
            if ($cb) { & $cb $req.Cle $records }
        }
    }
}
