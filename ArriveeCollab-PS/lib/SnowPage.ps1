# ============================================================================
#  Page ServiceNow CACHÉE, partagée par les vérifications (homonymes, doublons).
#
#  Même principe que SNOW Widget : une page ServiceNow est chargée dans un
#  WebView2 CACHÉ (fenêtre hors écran, sans prendre le focus) qui réutilise la
#  session SSO de l'entreprise (Kerberos/OpenAM). Aucun jeton, aucune API REST :
#  chaque recherche est une requête JSONv2 « same-origin » (fetch avec le cookie
#  de session) exécutée dans la page. Le SSO est attendu en silence ; si une
#  connexion interactive est vraiment nécessaire, la fenêtre est ramenée au
#  centre de l'écran le temps de se connecter, puis re-cachée.
#
#  Une requête en attente PAR TYPE (la dernière demande d'un type remplace la
#  précédente) ; les types sont traités l'un après l'autre. Rien n'est lancé au
#  simple dot-sourcing : Initialize-SnowEngine crée la page à la première demande.
# ============================================================================

# État du moteur (global : les gestionnaires d'événements WinForms s'exécutent
# hors de la portée du script).
#   Phase : off | init | sso (SSO silencieux en cours) | auth (fenêtre affichée)
#           | ready | kick | poll | error | fake (test hors réseau)
$global:Snow = @{
    Phase      = 'off'
    Form       = $null
    WebView    = $null
    Timer      = $null
    Task       = $null
    Deadline   = [datetime]::MinValue
    Pending    = [ordered]@{}   # Type -> @{ Type; Cle; Url }
    EnCours    = $null          # requête en cours d'exécution
    OnResultat = @{}            # Type -> { param($Cle, $Records) }
    OnStatut   = @{}            # Type -> { param($Etat, $Texte) } Etat = info | auth | erreur
    StartUrl   = 'https://sncf.service-now.com/now/nav/ui/classic/params/target/sys_user_list.do'
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

# Remet en file une requête interrompue (redirection SSO, session expirée…).
function Restore-SnowEnCours {
    $r = $global:Snow.EnCours
    if ($r -and -not $global:Snow.Pending.Contains($r.Type)) { $global:Snow.Pending[$r.Type] = $r }
    $global:Snow.EnCours = $null
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

# Enregistre les rappels d'un type et crée la page cachée au premier appel
# (profil WebView2 persistant = session SSO conservée d'un lancement à l'autre).
function Initialize-SnowEngine {
    param([string]$LibDir, [string]$DataDir, [string]$Type, [scriptblock]$OnResultat, [scriptblock]$OnStatut)
    $global:Snow.OnResultat[$Type] = $OnResultat
    $global:Snow.OnStatut[$Type] = $OnStatut
    if ($global:Snow.Phase -ne 'off') { return }
    # Test hors réseau SNCF (poste de dev sans VPN) : ARRIVEE_COLLAB_HOMO_FAKE et/ou
    # ARRIVEE_COLLAB_DOUBLON_FAKE = chemin d'un JSON { "records": [...] } renvoyé à la
    # place de ServiceNow pour ce type. Jamais défini en production.
    if ($env:ARRIVEE_COLLAB_HOMO_FAKE -or $env:ARRIVEE_COLLAB_DOUBLON_FAKE) {
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
    if (Test-Path $icon) { try { $f.Icon = New-Object Drawing.Icon($icon) } catch {} }
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
    $cp.AdditionalBrowserArguments = '--auth-server-allowlist=*.sncf.fr,*.service-now.com --auth-negotiate-delegate-allowlist=*.sncf.fr,*.service-now.com'
    $wv.CreationProperties = $cp
    $wv.Dock = 'Fill'
    $wv.Add_CoreWebView2InitializationCompleted({
        param($s, $e)
        if (-not $e.IsSuccess) {
            $global:Snow.Phase = 'error'
            Write-AppLog "[SNOW] Init WebView2 KO : $($e.InitializationException.Message)"
            Send-SnowStatut 'erreur' 'Vérification indisponible (WebView2)'
        }
    })
    $wv.Add_NavigationCompleted({ param($s, $e) try { Invoke-SnowNavigation $e } catch { Write-AppLog "[SNOW] Navigation KO : $($_.Exception.Message)" } })
    $f.Controls.Add($wv)
    $global:Snow.Form = $f
    $global:Snow.WebView = $wv

    # Pompe non bloquante (250 ms) : relève les Task<string> d'ExecuteScriptAsync.
    $t = New-Object Windows.Forms.Timer
    $t.Interval = 250
    $t.Add_Tick({ try { Step-SnowPump } catch { Write-AppLog "[SNOW] Pompe KO : $($_.Exception.Message)"; $global:Snow.EnCours = $null; $global:Snow.Phase = 'ready' } })
    $global:Snow.Timer = $t
    $t.Start()

    $f.Show()   # un WebView2 jamais affiché ne charge pas (fenêtre hors écran, sans focus)
    Send-SnowStatut 'info' 'Connexion à ServiceNow…'
    $wv.Source = [uri]$global:Snow.StartUrl
    Write-AppLog '[SNOW] Page cachée initialisée.'
}

# Page chargée : soit on est sur l'instance (prêt), soit sur une étape du SSO.
function Invoke-SnowNavigation {
    param($e)
    $url = [string]$global:Snow.WebView.Source
    if (-not $e.IsSuccess) {
        Write-AppLog "[SNOW] Navigation en échec ($($e.WebErrorStatus)) : $url"
        if ($global:Snow.Phase -in @('init', 'sso', 'auth')) {
            $global:Snow.Phase = 'error'
            Send-SnowStatut 'erreur' 'ServiceNow injoignable (réseau / VPN ?)'
        }
        return
    }
    $u = [uri]$url
    $surInstance = $u.Host -like '*service-now.com'
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
    if ($global:Snow.Phase -in @('init', 'sso', 'auth', 'error')) {
        $global:Snow.Phase = 'ready'
        Write-AppLog "[SNOW] Session ServiceNow prête : $url"
    }
}

# Demande une recherche JSONv2 ($Url relative, same-origin) pour un type ; $Cle est
# rendue au rappel avec les enregistrements. Démarre le moteur au besoin.
function Submit-SnowRequete {
    param([string]$Type, [string]$Cle, [string]$Url)
    if (-not $Url) { return }
    $req = @{ Type = $Type; Cle = $Cle; Url = $Url }
    if ($global:Snow.Phase -eq 'fake') {
        $fichier = if ($Type -eq 'doublon') { $env:ARRIVEE_COLLAB_DOUBLON_FAKE } else { $env:ARRIVEE_COLLAB_HOMO_FAKE }
        $records = @()
        if ($fichier -and (Test-Path $fichier)) { $records = @((Get-Content -Raw -Encoding UTF8 $fichier | ConvertFrom-Json).records) }
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

# Machine d'état appelée toutes les 250 ms.
function Step-SnowPump {
    $h = $global:Snow
    switch ($h.Phase) {
        'sso' {
            # SSO silencieux bloqué (session Windows non reconnue par l'IdP) : dernier recours.
            if ((Get-Date) -gt $h.Deadline) { Show-SnowAuth }
        }
        'ready' {
            if ($h.Pending.Count -eq 0) { return }
            $type = @($h.Pending.Keys)[0]
            $req = $h.Pending[$type]
            $h.Pending.Remove($type)
            $h.EnCours = $req
            Send-SnowStatut 'info' 'Recherche dans ServiceNow…' $type
            $url = $req.Url.Replace('\', '\\').Replace("'", "\'")   # littéral JS entre apostrophes
            # ExecuteScriptAsync ne résout pas les promesses : on lance le fetch, le
            # résultat est déposé dans window.__acSnow puis relevé par polling.
            $js = "(function(){window.__acSnow='PENDING';fetch('$url',{credentials:'same-origin',headers:{Accept:'application/json'}})" +
                  ".then(function(r){return r.text();}).then(function(t){try{window.__acSnow=JSON.parse(t);}catch(x){window.__acSnow={error:'parse',body:t.slice(0,200)};}})" +
                  ".catch(function(x){window.__acSnow={error:String(x)};});return 'started';})()"
            $h.Task = $h.WebView.CoreWebView2.ExecuteScriptAsync($js)
            $h.Deadline = (Get-Date).AddSeconds(25)
            $h.Phase = 'kick'
        }
        'kick' {
            if (-not $h.Task.IsCompleted) { return }
            $h.Task = $h.WebView.CoreWebView2.ExecuteScriptAsync('window.__acSnow')
            $h.Phase = 'poll'
        }
        'poll' {
            if (-not $h.Task.IsCompleted) { return }
            $req = $h.EnCours
            $res = [string]$h.Task.Result
            if ($res -eq '"PENDING"') {
                if ((Get-Date) -gt $h.Deadline) {
                    $h.EnCours = $null; $h.Phase = 'ready'
                    Write-AppLog "[SNOW] Délai dépassé ($($req.Type))."
                    Send-SnowStatut 'erreur' 'ServiceNow ne répond pas (cliquer pour relancer)' $req.Type
                    return
                }
                $h.Task = $h.WebView.CoreWebView2.ExecuteScriptAsync('window.__acSnow')
                return
            }
            $h.Phase = 'ready'
            $o = $null
            try { $o = $res | ConvertFrom-Json } catch { }
            if ($null -eq $o -or $o.error) {
                $detail = if ($o) { "$($o.error) $($o.body)" } else { $res }
                Write-AppLog "[SNOW] Réponse inexploitable ($($req.Type)) : $detail"
                # Une page HTML à la place du JSON = session expirée -> reconnexion puis rejeu.
                if ($o -and $o.error -eq 'parse') {
                    Restore-SnowEnCours
                    $h.Phase = 'init'
                    $h.WebView.Source = [uri]$h.StartUrl
                    return
                }
                $h.EnCours = $null
                Send-SnowStatut 'erreur' 'Réponse ServiceNow inexploitable (cliquer pour relancer)' $req.Type
                return
            }
            $h.EnCours = $null
            $records = @($o.records)
            Write-AppLog "[SNOW] $($req.Type) « $($req.Cle) » : $($records.Count) enregistrement(s)."
            # Résultat périmé (une nouvelle demande du même type attend) : elle suivra.
            if ($h.Pending.Contains($req.Type)) { return }
            $cb = $h.OnResultat[$req.Type]
            if ($cb) { & $cb $req.Cle $records }
        }
    }
}
