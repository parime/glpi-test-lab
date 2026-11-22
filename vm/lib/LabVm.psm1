# Fonctions communes aux scripts vm\*.ps1 du laboratoire (lot #5).
# Compatible Windows PowerShell 5.1 (pas d'opérateur ternaire ni « ?? »).
#
# Références :
# - Hyper-V (module PowerShell) : https://learn.microsoft.com/powershell/module/hyper-v/
# - PowerShell Direct : https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct
# - Clavier virtuel Msvm_Keyboard (TypeText, TypeKey) : https://learn.microsoft.com/windows/win32/hyperv_v2/msvm-keyboard
# - Création d'images ISO par IMAPI2 (IMAPI2FS.MsftFileSystemImage) :
#   https://learn.microsoft.com/windows/win32/imapi/creating-a-file-system-image

Set-StrictMode -Version 2.0

$script:DossierVm = Split-Path -Parent $PSScriptRoot

function Write-LabEtape { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-LabOk { param([string]$Message) Write-Host "    [ok] $Message" -ForegroundColor Green }
function Write-LabInfo { param([string]$Message) Write-Host "    $Message" }
function Write-LabAvert { param([string]$Message) Write-Host "    [attention] $Message" -ForegroundColor Yellow }
function Write-LabErreur { param([string]$Message) Write-Host "    [erreur] $Message" -ForegroundColor Red }

function Merge-LabTable {
    # Fusion récursive : les clés de $Surcharge remplacent celles de $Base (tables imbriquées fusionnées).
    param([hashtable]$Base, [hashtable]$Surcharge)
    $resultat = @{}
    foreach ($cle in $Base.Keys) { $resultat[$cle] = $Base[$cle] }
    foreach ($cle in $Surcharge.Keys) {
        if ($resultat.ContainsKey($cle) -and ($resultat[$cle] -is [hashtable]) -and ($Surcharge[$cle] -is [hashtable])) {
            $resultat[$cle] = Merge-LabTable -Base $resultat[$cle] -Surcharge $Surcharge[$cle]
        } else {
            $resultat[$cle] = $Surcharge[$cle]
        }
    }
    return $resultat
}

function Get-LabConfig {
    param([string]$Fichier = (Join-Path $script:DossierVm 'vms.psd1'))
    $config = Import-PowerShellDataFile -Path $Fichier
    $local = Join-Path (Split-Path -Parent $Fichier) 'vms.local.psd1'
    if (Test-Path $local) {
        $config = Merge-LabTable -Base $config -Surcharge (Import-PowerShellDataFile -Path $local)
    }
    if ($config.Racine -match '^[Cc]:') {
        throw "La racine des VM ($($config.Racine)) est sur C: : interdit dans ce labo, choisissez un dossier sur F:."
    }
    return $config
}

function Get-LabChemin {
    # Dossiers de travail sous la racine (créés à la demande).
    param([hashtable]$Config, [ValidateSet('racine', 'iso', 'logiciels', 'machines', 'supports', 'journaux', 'ca', 'proxmox')][string]$Type)
    $chemin = switch ($Type) {
        'racine' { $Config.Racine }
        'iso' { Join-Path $Config.Racine 'iso' }
        'logiciels' { Join-Path $Config.Racine 'logiciels' }
        'machines' { Join-Path $Config.Racine 'machines' }
        'supports' { Join-Path $Config.Racine 'supports' }
        'journaux' { Join-Path $Config.Racine 'journaux' }
        'ca' { Join-Path $Config.Racine 'ca' }
        'proxmox' { Join-Path $Config.Racine 'proxmox' }
    }
    if (-not (Test-Path $chemin)) { New-Item -ItemType Directory -Path $chemin -Force | Out-Null }
    return $chemin
}

function Get-LabVmConfig {
    param([hashtable]$Config, [string]$Nom)
    $vm = $Config.Vm | Where-Object { $_.Nom -eq $Nom }
    if (-not $vm) {
        $noms = ($Config.Vm | ForEach-Object { $_.Nom }) -join ', '
        throw "VM inconnue : $Nom (VM déclarées dans vms.psd1 : $noms)"
    }
    return $vm
}

function Get-LabVmListe {
    # Liste ordonnée (champ Ordre) des VM demandées ; « tout » ou rien = toutes.
    param([hashtable]$Config, [string[]]$Noms)
    if (-not $Noms -or $Noms -contains 'tout' -or $Noms -contains 'all') {
        return @($Config.Vm | Sort-Object { $_.Ordre })
    }
    return @($Noms | ForEach-Object { Get-LabVmConfig -Config $Config -Nom $_ } | Sort-Object { $_.Ordre })
}

function New-LabMotDePasse {
    # 20 caractères, au moins une majuscule, une minuscule, un chiffre et un symbole ; pas de
    # caractère gênant en XML, YAML ou ligne de commande.
    $maj = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; $min = 'abcdefghijkmnopqrstuvwxyz'; $chi = '23456789'; $sym = '-_.+='
    $tous = $maj + $min + $chi + $sym
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $octet = New-Object byte[] 1
    $tirer = {
        param([string]$Jeu)
        do { $rng.GetBytes($octet) } while ($octet[0] -ge (256 - (256 % $Jeu.Length)))
        return $Jeu[$octet[0] % $Jeu.Length]
    }
    $car = New-Object System.Collections.Generic.List[char]
    $car.Add((& $tirer $maj)); $car.Add((& $tirer $min)); $car.Add((& $tirer $chi)); $car.Add((& $tirer $sym))
    while ($car.Count -lt 20) { $car.Add((& $tirer $tous)) }
    # Mélange (Fisher-Yates).
    for ($i = $car.Count - 1; $i -gt 0; $i--) {
        $rng.GetBytes($octet); $j = $octet[0] % ($i + 1)
        $t = $car[$i]; $car[$i] = $car[$j]; $car[$j] = $t
    }
    return -join $car
}

function Get-LabSecrets {
    # Secrets générés une fois, conservés hors dépôt dans <Racine>\secrets.json.
    param([hashtable]$Config)
    $fichier = Join-Path (Get-LabChemin -Config $Config -Type racine) 'secrets.json'
    $secrets = @{}
    if (Test-Path $fichier) {
        $lu = Get-Content -Raw -Path $fichier -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $lu.PSObject.Properties) { $secrets[$p.Name] = $p.Value }
    }
    $modifie = $false
    foreach ($cle in @('AdminWindows', 'Dsrm', 'UtilisateursDemo', 'CompteLdapGlpi', 'Ubuntu', 'PfSense', 'SnmpPfSense', 'RootProxmox')) {
        if (-not $secrets.ContainsKey($cle) -or -not $secrets[$cle]) { $secrets[$cle] = New-LabMotDePasse; $modifie = $true }
    }
    if ($modifie) {
        ($secrets | ConvertTo-Json) | Set-Content -Path $fichier -Encoding UTF8
        Write-LabInfo "Secrets du labo enregistrés dans $fichier (hors dépôt)."
    }
    return $secrets
}

function Get-LabCredential {
    param([string]$Utilisateur, [string]$MotDePasse)
    $secure = ConvertTo-SecureString -String $MotDePasse -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential($Utilisateur, $secure)
}

function Get-LabEtat {
    param([hashtable]$Config)
    $fichier = Join-Path (Get-LabChemin -Config $Config -Type racine) 'etat.json'
    $etat = @{}
    if (Test-Path $fichier) {
        $lu = Get-Content -Raw -Path $fichier -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $lu.PSObject.Properties) {
            $vm = @{}
            foreach ($q in $p.Value.PSObject.Properties) { $vm[$q.Name] = $q.Value }
            $etat[$p.Name] = $vm
        }
    }
    return $etat
}

function Set-LabEtat {
    param([hashtable]$Config, [string]$Nom, [hashtable]$Valeurs)
    $etat = Get-LabEtat -Config $Config
    if (-not $etat.ContainsKey($Nom)) { $etat[$Nom] = @{} }
    foreach ($cle in $Valeurs.Keys) { $etat[$Nom][$cle] = $Valeurs[$cle] }
    $fichier = Join-Path (Get-LabChemin -Config $Config -Type racine) 'etat.json'
    ($etat | ConvertTo-Json -Depth 5) | Set-Content -Path $fichier -Encoding UTF8
}

function Remove-LabEtat {
    param([hashtable]$Config, [string]$Nom)
    $etat = Get-LabEtat -Config $Config
    if ($etat.ContainsKey($Nom)) {
        $etat.Remove($Nom)
        $fichier = Join-Path (Get-LabChemin -Config $Config -Type racine) 'etat.json'
        ($etat | ConvertTo-Json -Depth 5) | Set-Content -Path $fichier -Encoding UTF8
    }
}

function Test-LabAccesHyperV {
    # Vrai si la session peut piloter Hyper-V (administrateur ou membre d'« Administrateurs Hyper-V »).
    try { Get-VMHost -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Assert-LabAccesHyperV {
    if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
        throw "Le module Hyper-V est absent : lancez d'abord vm\00-prerequis-admin.ps1 en administrateur."
    }
    if (-not (Test-LabAccesHyperV)) {
        throw ("Cette session ne peut pas piloter Hyper-V. Lancez vm\00-prerequis-admin.ps1 en administrateur " +
            "(il ajoute votre compte au groupe « Administrateurs Hyper-V »), puis fermez et rouvrez votre session Windows.")
    }
}

function Test-LabAdministrateur {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LabSha256 {
    param([string]$Fichier)
    return (Get-FileHash -Algorithm SHA256 -Path $Fichier).Hash.ToLowerInvariant()
}

function Invoke-LabTelechargement {
    # Téléchargement reprenable avec curl.exe (fourni avec Windows 10 1803 et suivants).
    param([string]$Url, [string]$Destination)
    $partiel = "$Destination.partiel"
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    & $curl --location --fail --retry 3 --progress-bar --continue-at - --output $partiel $Url
    if ($LASTEXITCODE -ne 0) {
        throw "Échec du téléchargement de $Url (curl, code $LASTEXITCODE)."
    }
    Move-Item -Path $partiel -Destination $Destination -Force
}

function Get-LabTexteWeb {
    param([string]$Url)
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (-not (Test-Path $curl)) { $curl = 'curl.exe' }
    $texte = & $curl --location --fail --silent --show-error $Url
    if ($LASTEXITCODE -ne 0) { throw "Lecture impossible : $Url (curl, code $LASTEXITCODE)." }
    return ($texte -join "`n")
}

$script:CodeIsoCharge = $false
function New-LabIso {
    # Crée une image ISO (ISO 9660 + Joliet) à partir d'un dossier, sans outil externe ni droits
    # administrateur, avec l'API IMAPI2 de Windows. Sert au fichier autounattend.xml (Windows) et
    # au support cloud-init « CIDATA » (Ubuntu).
    param([string]$Dossier, [string]$Destination, [string]$Etiquette)
    if (-not $script:CodeIsoCharge) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class LabIsoEcriture {
    public static void Ecrire(string chemin, object flux, int tailleBloc, int nombreBlocs) {
        IStream source = (IStream)flux;
        byte[] tampon = new byte[tailleBloc];
        IntPtr lus = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (FileStream sortie = File.Create(chemin)) {
                for (int i = 0; i < nombreBlocs; i++) {
                    source.Read(tampon, tailleBloc, lus);
                    sortie.Write(tampon, 0, Marshal.ReadInt32(lus));
                }
            }
        } finally {
            Marshal.FreeHGlobal(lus);
        }
    }
}
'@
        $script:CodeIsoCharge = $true
    }
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    # 1 = ISO 9660, 2 = Joliet (FsiFileSystems).
    $image.FileSystemsToCreate = 3
    $image.VolumeName = $Etiquette
    $image.Root.AddTree($Dossier, $false)
    $resultat = $image.CreateResultImage()
    if (Test-Path $Destination) { Remove-Item -Path $Destination -Force }
    [LabIsoEcriture]::Ecrire($Destination, $resultat.ImageStream, $resultat.BlockSize, $resultat.TotalBlocks)
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($image)
}

function Get-LabClavierVm {
    param([string]$Nom)
    $vm = Get-CimInstance -Namespace 'root\virtualization\v2' -ClassName 'Msvm_ComputerSystem' -Filter "ElementName='$Nom'"
    if (-not $vm) { throw "VM introuvable par WMI : $Nom" }
    return Get-CimAssociatedInstance -InputObject $vm -ResultClassName 'Msvm_Keyboard'
}

function Send-LabTexte {
    # Saisit du texte ASCII au clavier virtuel de la VM (méthode Msvm_Keyboard.TypeText).
    param([string]$Nom, [string]$Texte)
    $clavier = Get-LabClavierVm -Nom $Nom
    [void](Invoke-CimMethod -InputObject $clavier -MethodName 'TypeText' -Arguments @{ asciiText = $Texte })
}

function Send-LabTouche {
    # Appuie sur une touche (code de touche virtuelle Windows, par exemple 13 = Entrée).
    param([string]$Nom, [int]$Code)
    $clavier = Get-LabClavierVm -Nom $Nom
    [void](Invoke-CimMethod -InputObject $clavier -MethodName 'TypeKey' -Arguments @{ keyCode = [uint32]$Code })
}

function Wait-LabPowerShellDirect {
    # Attend que la VM Windows accepte une session PowerShell Direct avec ces identifiants.
    param([string]$Nom, [pscredential]$Credential, [int]$Minutes = 90)
    $limite = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $limite) {
        try {
            $r = Invoke-Command -VMName $Nom -Credential $Credential -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            if ($r) { return $true }
        } catch {
            Start-Sleep -Seconds 20
        }
    }
    return $false
}

function Wait-LabVmArretee {
    param([string]$Nom, [int]$Minutes = 60)
    $limite = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $limite) {
        if ((Get-VM -Name $Nom).State -eq 'Off') { return $true }
        Start-Sleep -Seconds 15
    }
    return $false
}

function Get-LabSshCle {
    # Paire de clés SSH du labo (accès à la VM Ubuntu), générée sous la racine.
    param([hashtable]$Config)
    $cle = Join-Path (Get-LabChemin -Config $Config -Type racine) 'ssh\lab_ed25519'
    if (-not (Test-Path $cle)) {
        New-Item -ItemType Directory -Force -Path (Split-Path $cle) | Out-Null
        & ssh-keygen.exe -q -t ed25519 -N '""' -C 'glpi-test-lab' -f $cle
        if ($LASTEXITCODE -ne 0) { throw 'ssh-keygen a échoué (client OpenSSH de Windows requis).' }
    }
    return $cle
}

function Invoke-LabSsh {
    param([hashtable]$Config, [string]$Ip, [string]$Commande)
    $cle = Get-LabSshCle -Config $Config
    $connus = Join-Path (Split-Path $cle) 'known_hosts'
    & ssh.exe -i $cle -o "UserKnownHostsFile=$connus" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "labadmin@$Ip" $Commande
    return $LASTEXITCODE
}

function Get-LabTexteModele {
    # Lit un modèle de vm\modeles et remplace les {{CLES}}.
    param([string]$Nom, [hashtable]$Valeurs)
    $texte = Get-Content -Raw -Encoding UTF8 -Path (Join-Path $script:DossierVm "modeles\$Nom")
    foreach ($cle in $Valeurs.Keys) { $texte = $texte.Replace("{{$cle}}", [string]$Valeurs[$cle]) }
    if ($texte -match '\{\{[A-Z_]+\}\}') { throw "Modèle $Nom : clé non remplacée $($Matches[0])." }
    return $texte
}

function Write-LabFichierUtf8 {
    # UTF-8 sans BOM (attendu par cloud-init et accepté par Windows Setup).
    param([string]$Chemin, [string]$Texte)
    [System.IO.File]::WriteAllText($Chemin, $Texte.Replace("`r`n", "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-LabXml {
    param([string]$Texte)
    return [System.Security.SecurityElement]::Escape($Texte)
}

function Set-LabSecret {
    param([hashtable]$Config, [string]$Cle, [string]$Valeur)
    $secrets = Get-LabSecrets -Config $Config
    $secrets[$Cle] = $Valeur
    $fichier = Join-Path (Get-LabChemin -Config $Config -Type racine) 'secrets.json'
    ($secrets | ConvertTo-Json) | Set-Content -Path $fichier -Encoding UTF8
}

# --- API de Proxmox VE --------------------------------------------------------------------------
# Référence : https://pve.proxmox.com/pve-docs/api-viewer/ ; jetons d'API (en-tête
# « Authorization: PVEAPIToken=USER@REALM!ID=SECRET ») : https://pve.proxmox.com/wiki/Proxmox_VE_API
# Le certificat de Proxmox est vérifié avec son autorité (pve-root-ca.pem, lue en SSH à
# l'installation) ; --ssl-no-revoke : cette autorité privée ne publie pas de liste de révocation,
# que le curl de Windows (Schannel) cherche sinon à vérifier ; le nom du nœud est résolu vers son adresse LAN (option --resolve de curl).

function Get-LabPveContexte {
    param([hashtable]$Config)
    $dossier = Get-LabChemin -Config $Config -Type proxmox
    $ca = Join-Path $dossier 'pve-root-ca.pem'
    $entete = Join-Path $dossier 'entete-api.txt'
    if (-not (Test-Path $ca) -or -not (Test-Path $entete)) {
        throw 'Accès à l''API de Proxmox non préparé : lancez d''abord vm\20-proxmox.ps1.'
    }
    $px = $Config.Proxmox
    return @{
        Base    = "https://$($px.Fqdn):8006/api2/json"
        Resolve = "$($px.Fqdn):8006:$($px.IpLan)"
        Ca      = $ca
        Entete  = $entete
        Noeud   = $px.Noeud
    }
}

function Invoke-LabPve {
    # Appel de l'API (GET, POST, PUT, DELETE) ; renvoie le champ « data » de la réponse JSON.
    param(
        [hashtable]$Config,
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string]$Methode = 'GET',
        [string]$Chemin,
        [hashtable]$Parametres = @{},
        [hashtable]$Fichiers = @{}
    )
    $ctx = Get-LabPveContexte -Config $Config
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $arguments = @('--silent', '--show-error', '--ssl-no-revoke', '--cacert', $ctx.Ca, '--resolve', $ctx.Resolve, '-H', "@$($ctx.Entete)", '-X', $Methode)
    $url = $ctx.Base + $Chemin
    if ($Fichiers.Count -gt 0) {
        foreach ($cle in $Parametres.Keys) { $arguments += @('--form-string', "$cle=$($Parametres[$cle])") }
        foreach ($cle in $Fichiers.Keys) { $arguments += @('-F', "$cle=@$($Fichiers[$cle])") }
    } elseif ($Methode -eq 'GET' -and $Parametres.Count -gt 0) {
        $arguments += '-G'
        foreach ($cle in $Parametres.Keys) { $arguments += @('--data-urlencode', "$cle=$($Parametres[$cle])") }
    } else {
        foreach ($cle in $Parametres.Keys) { $arguments += @('--data-urlencode', "$cle=$($Parametres[$cle])") }
    }
    $arguments += @('-w', "`n%{http_code}", $url)
    $sortie = (& $curl @arguments) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "API Proxmox injoignable ($Methode $Chemin) : curl, code $LASTEXITCODE." }
    $code = [int]($sortie.Substring($sortie.LastIndexOf("`n") + 1))
    $corps = $sortie.Substring(0, $sortie.LastIndexOf("`n"))
    if ($code -ge 400) { throw "API Proxmox $Methode $Chemin : HTTP $code $corps" }
    if (-not $corps) { return $null }
    return ($corps | ConvertFrom-Json).data
}

function Wait-LabPveTache {
    # Attend la fin d'une tâche asynchrone (UPID) et vérifie son code de sortie.
    param([hashtable]$Config, [string]$Upid, [int]$Minutes = 30)
    if (-not $Upid) { return }
    $noeud = $Config.Proxmox.Noeud
    $limite = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $limite) {
        $etat = Invoke-LabPve -Config $Config -Chemin "/nodes/$noeud/tasks/$([uri]::EscapeDataString($Upid))/status"
        if ($etat.status -eq 'stopped') {
            if ($etat.exitstatus -ne 'OK') { throw "Tâche Proxmox en échec : $($etat.exitstatus) ($Upid)" }
            return
        }
        Start-Sleep -Seconds 3
    }
    throw "Tâche Proxmox trop longue : $Upid"
}

function Get-LabPveVm {
    param([hashtable]$Config, [int]$VmId)
    $noeud = $Config.Proxmox.Noeud
    $liste = Invoke-LabPve -Config $Config -Chemin "/nodes/$noeud/qemu"
    return $liste | Where-Object { [int]$_.vmid -eq $VmId } | Select-Object -First 1
}

function Send-LabPveTouche {
    # Touche au clavier de la VM (nom QEMU : « ret », « c », « slash », « shift-a »...).
    param([hashtable]$Config, [int]$VmId, [string]$Touche)
    [void](Invoke-LabPve -Config $Config -Methode PUT -Chemin "/nodes/$($Config.Proxmox.Noeud)/qemu/$VmId/sendkey" -Parametres @{ key = $Touche })
}

function Send-LabPveTexte {
    # Saisit un texte simple (minuscules, chiffres, espace, « / », « - », « . », « = ») touche par touche.
    param([hashtable]$Config, [int]$VmId, [string]$Texte)
    $noms = @{ ' ' = 'spc'; '/' = 'slash'; '-' = 'minus'; '.' = 'dot'; '=' = 'equal'; '_' = 'shift-minus' }
    foreach ($c in $Texte.ToCharArray()) {
        $s = [string]$c
        if ($noms.ContainsKey($s)) { $touche = $noms[$s] }
        elseif ($s -cmatch '^[a-z0-9]$') { $touche = $s }
        elseif ($s -cmatch '^[A-Z]$') { $touche = 'shift-' + $s.ToLowerInvariant() }
        else { throw "Caractère non pris en charge par Send-LabPveTexte : $s" }
        Send-LabPveTouche -Config $Config -VmId $VmId -Touche $touche
    }
}

function Invoke-LabPveAgent {
    # Exécute une commande dans une VM par l'agent invité QEMU (API agent/exec) et renvoie
    # @{ Code; Sortie; Erreur }. Remplace PowerShell Direct, indisponible dans une VM imbriquée.
    # https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu/{vmid}/agent/exec
    param([hashtable]$Config, [int]$VmId, [string[]]$Commande, [string]$Entree, [int]$Minutes = 30)
    $noeud = $Config.Proxmox.Noeud
    $p = @{}
    # L'API attend « command » répété : curl le transmet avec plusieurs --data-urlencode.
    $ctx = Get-LabPveContexte -Config $Config
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    $arguments = @('--silent', '--show-error', '--fail', '--ssl-no-revoke', '--cacert', $ctx.Ca, '--resolve', $ctx.Resolve, '-H', "@$($ctx.Entete)", '-X', 'POST')
    foreach ($morceau in $Commande) { $arguments += @('--data-urlencode', "command=$morceau") }
    if ($Entree) { $arguments += @('--data-urlencode', "input-data=$Entree") }
    $arguments += "$($ctx.Base)/nodes/$noeud/qemu/$VmId/agent/exec"
    $reponse = (& $curl @arguments) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "agent/exec refusé pour la VM $VmId (agent invité absent ?)." }
    $pid_ = ($reponse | ConvertFrom-Json).data.pid
    $limite = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $limite) {
        Start-Sleep -Seconds 2
        $etat = Invoke-LabPve -Config $Config -Chemin "/nodes/$noeud/qemu/$VmId/agent/exec-status" -Parametres @{ pid = $pid_ }
        if ($etat.exited -eq 1) {
            $sortie = ''; $erreur = ''
            if ($etat.PSObject.Properties['out-data']) { $sortie = $etat.'out-data' }
            if ($etat.PSObject.Properties['err-data']) { $erreur = $etat.'err-data' }
            return @{ Code = [int]$etat.exitcode; Sortie = $sortie; Erreur = $erreur }
        }
    }
    throw "Commande trop longue dans la VM $VmId."
}

function Invoke-LabPvePowerShell {
    # Lance un script PowerShell dans une VM Windows par l'agent invité (encodé en Base64 UTF-16).
    param([hashtable]$Config, [int]$VmId, [string]$Script, [int]$Minutes = 30)
    $code = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("`$ProgressPreference='SilentlyContinue'; `$ErrorActionPreference='Stop'; " + $Script))
    return Invoke-LabPveAgent -Config $Config -VmId $VmId -Commande @('powershell.exe', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $code) -Minutes $Minutes
}

function Test-LabPveAgent {
    param([hashtable]$Config, [int]$VmId)
    try { [void](Invoke-LabPve -Config $Config -Methode POST -Chemin "/nodes/$($Config.Proxmox.Noeud)/qemu/$VmId/agent/ping"); return $true } catch { return $false }
}
Export-ModuleMember -Function *-Lab*
