<#
.SYNOPSIS
    Crée la VM Hyper-V « lab-proxmox », installe Proxmox VE sans intervention et prépare son API.

.DESCRIPTION
    Sans droits administrateur : il suffit d'être membre du groupe « Administrateurs Hyper-V ».
    Idempotent : chaque étape vérifie l'existant (relancer reprend où le script s'était arrêté).

    1. Commutateur interne « lab-interne » (LAN du labo) ; « Default Switch » sert de WAN.
    2. answer.toml et script de premier démarrage générés sous <Racine>\proxmox\ (mot de passe root
       et clé SSH du labo), puis ISO d'installation automatique préparée par l'outil officiel
       proxmox-auto-install-assistant dans un conteneur Debian (Docker Desktop).
    3. VM de génération 2 : mémoire statique, virtualisation imbriquée, deux cartes à adresse MAC
       fixe avec usurpation d'adresse MAC autorisée (trafic des VM invitées), VHDX dynamique.
    4. Installation (entrée « Automated Installation », choisie seule après 10 s), premier démarrage
       (pont WAN, dépôts, DHCP réservé à l'hôte, jeton d'API).
    5. Lecture en SSH du jeton d'API et de l'autorité de certification de Proxmox.
    6. Envoi des ISO du labo dans le stockage « local » de Proxmox par l'API (upload).

    Références :
    - Installation automatique : https://pve.proxmox.com/wiki/Automated_Installation
    - Virtualisation imbriquée : https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/enable-nested-virtualization
    - Proxmox VE dans une VM : https://pve.proxmox.com/wiki/Nested_Virtualization
    - Envoi de fichiers dans un stockage : https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/storage/{storage}/upload

.PARAMETER SansIso
    Ne pas envoyer les ISO du labo dans Proxmox.

.PARAMETER NouvelleIso
    Refaire l'ISO d'installation automatique même si elle existe.
#>
[CmdletBinding()]
param(
    [switch]$SansIso,
    [switch]$NouvelleIso
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\LabVm.psm1') -Force
Import-Module Hyper-V -ErrorAction SilentlyContinue
$config = Get-LabConfig
Assert-LabAccesHyperV
$secrets = Get-LabSecrets -Config $config
$px = $config.Proxmox
$reseau = $config.Reseau
$dossierPx = Get-LabChemin -Config $config -Type proxmox
$dossierIso = Get-LabChemin -Config $config -Type iso
$cleSsh = Get-LabSshCle -Config $config
$connus = Join-Path (Split-Path $cleSsh) 'known_hosts'

function Invoke-PxSsh {
    param([string]$Commande)
    $sortie = & ssh.exe -i $cleSsh -o "UserKnownHostsFile=$connus" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "root@$($px.IpLan)" $Commande
    return @{ Code = $LASTEXITCODE; Sortie = ($sortie -join "`n") }
}

function Format-Mac {
    param([string]$Mac, [string]$Separateur = '')
    $brut = ($Mac -replace '[^0-9A-Fa-f]', '').ToLowerInvariant()
    return (($brut -split '(..)' | Where-Object { $_ }) -join $Separateur)
}

# --- 1. Commutateurs ------------------------------------------------------------------------------
Write-LabEtape 'Commutateurs Hyper-V'
if (-not (Get-VMSwitch -Name $reseau.CommutateurWan -ErrorAction SilentlyContinue)) {
    throw "Commutateur « $($reseau.CommutateurWan) » absent (il est créé par Windows avec Hyper-V)."
}
if (-not (Get-VMSwitch -Name $reseau.CommutateurLan -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $reseau.CommutateurLan -SwitchType Internal | Out-Null
    Write-LabOk "Commutateur interne « $($reseau.CommutateurLan) » créé."
} else {
    Write-LabOk "Commutateur « $($reseau.CommutateurLan) » présent."
}
$carteHote = $null
for ($i = 0; $i -lt 10 -and -not $carteHote; $i++) {
    $carteHote = Get-NetAdapter -Name "vEthernet ($($reseau.CommutateurLan))" -ErrorAction SilentlyContinue
    if (-not $carteHote) { Start-Sleep -Seconds 2 }
}
if (-not $carteHote) { throw "Carte « vEthernet ($($reseau.CommutateurLan)) » introuvable." }
$macHote = Format-Mac -Mac $carteHote.MacAddress -Separateur ':'
Write-LabInfo "Carte de l'hôte sur le LAN : $($carteHote.Name), MAC $macHote (recevra $($reseau.IpHote) par le DHCP de Proxmox)."

# --- 2. ISO d'installation automatique ------------------------------------------------------------
Write-LabEtape 'ISO d''installation automatique de Proxmox VE'
$longueur = $reseau.Prefixe.Split('/')[1]
$answer = Get-LabTexteModele -Nom '..\proxmox\answer.toml' -Valeurs @{
    CLAVIER = $px.Clavier; PAYS = $px.Pays; FQDN = $px.Fqdn; DOMAINE = $config.Domaine.Nom; FUSEAU = $px.Fuseau
    MDP_ROOT = $secrets.RootProxmox; CLE_SSH = (Get-Content "$cleSsh.pub" -TotalCount 1).Trim()
    IP = $px.IpLan; LONGUEUR = $longueur; DNS = $px.Dns; PASSERELLE = $reseau.Passerelle
    MAC_LAN = (Format-Mac -Mac $px.MacLan)
}
$bits = ('1' * [int]$longueur).PadRight(32, '0')
$masque = (0..3 | ForEach-Object { [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }) -join '.'
$premier = Get-LabTexteModele -Nom '..\proxmox\premier-demarrage.sh' -Valeurs @{
    MAC_WAN_DEUX_POINTS = (Format-Mac -Mac $px.MacWan -Separateur ':'); PONT_WAN = $reseau.PontWan; PONT_LAN = $reseau.PontLan
    RESEAU_LAN = $reseau.Prefixe.Split('/')[0]; MASQUE_LAN = $masque; MAC_HOTE = $macHote; IP_HOTE = $reseau.IpHote
}
$fichierAnswer = Join-Path $dossierPx 'answer.toml'
$fichierPremier = Join-Path $dossierPx 'premier-demarrage.sh'
$isoAuto = Join-Path $dossierPx 'proxmox-ve-auto.iso'
$empreinte = Join-Path $dossierPx 'proxmox-ve-auto.empreinte'
$nouvelleEmpreinte = [BitConverter]::ToString((New-Object Security.Cryptography.SHA256Managed).ComputeHash([Text.Encoding]::UTF8.GetBytes($answer + $premier + $px.Iso))).Replace('-', '')
$aRefaire = $NouvelleIso -or -not (Test-Path $isoAuto) -or -not (Test-Path $empreinte) -or ((Get-Content $empreinte -TotalCount 1) -ne $nouvelleEmpreinte)
if ($aRefaire) {
    Write-LabFichierUtf8 -Chemin $fichierAnswer -Texte $answer
    Write-LabFichierUtf8 -Chemin $fichierPremier -Texte $premier
    if (Test-Path $isoAuto) { Remove-Item $isoAuto -Force }
    # L'ISO officielle est téléchargée DANS le conteneur et vérifiée avec SHA256SUMS : un dossier
    # Windows monté dans un conteneur est trop lent pour 1,7 Go. Le résultat sort par « docker cp ».
    $base = $config.Iso.Proxmox.Base
    $somme = $null
    foreach ($ligne in ((Get-LabTexteWeb -Url ($base + 'SHA256SUMS')) -split "`n")) {
        if ($ligne -match '^([0-9a-f]{64})\s+\*?(\S+)$' -and $Matches[2] -eq $px.Iso) { $somme = $Matches[1] }
    }
    if (-not $somme) { throw "$($px.Iso) absent de $($base)SHA256SUMS." }
    Write-LabInfo 'Préparation dans un conteneur debian:trixie (outil officiel proxmox-auto-install-assistant)...'
    $scripts = Join-Path $PSScriptRoot 'proxmox'
    $conteneur = 'glpi-test-lab-pve-iso'
    try { $ErrorActionPreference = 'Continue'; & docker rm -f $conteneur 2>&1 | Out-Null } finally { $ErrorActionPreference = 'Stop' }
    & docker run --name $conteneur -v "${dossierPx}:/travail:ro" -v "${scripts}:/scripts:ro" debian:trixie `
        bash /scripts/preparer-iso.sh $px.Iso $base $somme
    $code = $LASTEXITCODE
    if ($code -eq 0) { & docker cp "${conteneur}:/sortie/proxmox-ve-auto.iso" $isoAuto; $code = $LASTEXITCODE }
    try { $ErrorActionPreference = 'Continue'; & docker rm -f $conteneur 2>&1 | Out-Null } finally { $ErrorActionPreference = 'Stop' }
    if ($code -ne 0 -or -not (Test-Path $isoAuto)) { throw 'La préparation de l''ISO automatique a échoué (voir ci-dessus).' }
    Set-Content -Path $empreinte -Value $nouvelleEmpreinte -Encoding ASCII
    Write-LabOk "ISO préparée : $isoAuto"
} else {
    Write-LabOk "ISO déjà préparée : $isoAuto"
}

# --- 3. VM Hyper-V ----------------------------------------------------------------------------------
Write-LabEtape "VM Hyper-V $($px.NomVm)"
$vm = Get-VM -Name $px.NomVm -ErrorAction SilentlyContinue
if (-not $vm) {
    $dossierVm = Join-Path (Get-LabChemin -Config $config -Type machines) $px.NomVm
    New-Item -ItemType Directory -Force -Path $dossierVm | Out-Null
    $vhd = Join-Path $dossierVm "$($px.NomVm).vhdx"
    if (-not (Test-Path $vhd)) { New-VHD -Path $vhd -SizeBytes ([int64]$px.DisqueGo * 1GB) -Dynamic | Out-Null }
    New-VM -Name $px.NomVm -Generation 2 -MemoryStartupBytes ([int64]$px.MemoireMo * 1MB) -VHDPath $vhd `
        -Path (Get-LabChemin -Config $config -Type machines) -SwitchName $reseau.CommutateurWan | Out-Null
    Set-VMMemory -VMName $px.NomVm -DynamicMemoryEnabled $false -StartupBytes ([int64]$px.MemoireMo * 1MB)
    Set-VMProcessor -VMName $px.NomVm -Count $px.Processeurs -ExposeVirtualizationExtensions $true
    Set-VM -Name $px.NomVm -AutomaticCheckpointsEnabled $false -AutomaticStartAction Nothing -AutomaticStopAction ShutDown `
        -SnapshotFileLocation $dossierVm -SmartPagingFilePath $dossierVm -Notes 'glpi-test-lab (vm/vms.psd1) : Proxmox VE'
    $wan = Get-VMNetworkAdapter -VMName $px.NomVm | Select-Object -First 1
    Rename-VMNetworkAdapter -VMNetworkAdapter $wan -NewName 'wan'
    Set-VMNetworkAdapter -VMName $px.NomVm -Name 'wan' -StaticMacAddress $px.MacWan -MacAddressSpoofing On
    Add-VMNetworkAdapter -VMName $px.NomVm -Name 'lan' -SwitchName $reseau.CommutateurLan -StaticMacAddress $px.MacLan
    Set-VMNetworkAdapter -VMName $px.NomVm -Name 'lan' -MacAddressSpoofing On
    Set-VMFirmware -VMName $px.NomVm -EnableSecureBoot Off
    Add-VMDvdDrive -VMName $px.NomVm -Path $isoAuto
    $disque = Get-VMHardDiskDrive -VMName $px.NomVm
    $dvd = Get-VMDvdDrive -VMName $px.NomVm
    Set-VMFirmware -VMName $px.NomVm -BootOrder @($disque, $dvd)
    Write-LabOk "VM créée : $($px.Processeurs) processeurs, $($px.MemoireMo) Mo (statique), virtualisation imbriquée, disque $($px.DisqueGo) Go dynamique."
    $vm = Get-VM -Name $px.NomVm
} else {
    Write-LabOk "VM présente (état : $($vm.State))."
}

# --- 4. Installation --------------------------------------------------------------------------------
$installe = (Invoke-PxSsh -Commande 'test -f /root/lab-premier-demarrage.ok').Code -eq 0
if (-not $installe) {
    if ($vm.State -ne 'Running') {
        if (-not (Get-VMDvdDrive -VMName $px.NomVm).Path) { Set-VMDvdDrive -VMName $px.NomVm -Path $isoAuto }
        Start-VM -Name $px.NomVm
        Write-LabInfo 'Installation de Proxmox VE lancée (10 à 20 minutes) ; console : vmconnect localhost lab-proxmox'
    }
    Write-LabInfo "Attente de Proxmox ($($px.IpLan)) et de l'adresse $($reseau.IpHote) de l'hôte..."
    $limite = (Get-Date).AddMinutes(45)
    while ((Get-Date) -lt $limite -and -not $installe) {
        Start-Sleep -Seconds 20
        # Windows ne redemande une adresse DHCP que toutes les 5 minutes : demande immédiate (sans élévation).
        if (-not (Get-NetIPAddress -InterfaceIndex $carteHote.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $reseau.IpHote })) {
            & ipconfig.exe /renew "vEthernet ($($reseau.CommutateurLan))" | Out-Null
        }
        $installe = (Invoke-PxSsh -Commande 'test -f /root/lab-premier-demarrage.ok').Code -eq 0
    }
    if (-not $installe) {
        $ip = (Get-NetIPAddress -InterfaceIndex $carteHote.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress -join ', '
        throw "Proxmox ne répond pas en SSH sur $($px.IpLan) (adresse de l'hôte sur le LAN : $ip). Console : vmconnect localhost $($px.NomVm)"
    }
    Set-VMDvdDrive -VMName $px.NomVm -Path $null
}
Write-LabOk "Proxmox VE installé : https://$($px.IpLan):8006/ (root, mot de passe RootProxmox de secrets.json)."

# --- 5. Jeton d'API et autorité de certification ----------------------------------------------------
Write-LabEtape 'Accès à l''API'
$r = Invoke-PxSsh -Commande 'cat /etc/pve/pve-root-ca.pem'
if ($r.Code -ne 0) { throw 'Lecture de /etc/pve/pve-root-ca.pem impossible.' }
Write-LabFichierUtf8 -Chemin (Join-Path $dossierPx 'pve-root-ca.pem') -Texte ($r.Sortie + "`n")
$r = Invoke-PxSsh -Commande 'cat /root/lab-jeton.json'
if ($r.Code -ne 0) { throw 'Jeton d''API absent (/root/lab-jeton.json) : voir /var/log/lab-premier-demarrage.log dans Proxmox.' }
$jeton = $r.Sortie | ConvertFrom-Json
$valeur = "$($jeton.'full-tokenid')=$($jeton.value)"
Set-LabSecret -Config $config -Cle 'JetonProxmox' -Valeur $valeur
# En-tête lu par curl (« -H @fichier ») : le jeton n'apparaît pas sur la ligne de commande.
Write-LabFichierUtf8 -Chemin (Join-Path $dossierPx 'entete-api.txt') -Texte "Authorization: PVEAPIToken=$valeur`n"
$version = Invoke-LabPve -Config $config -Chemin '/version'
Write-LabOk "API joignable : Proxmox VE $($version.version) (jeton $($jeton.'full-tokenid'))."

# --- 6. ISO du labo dans le stockage Proxmox --------------------------------------------------------
if (-not $SansIso) {
    Write-LabEtape "ISO du labo dans le stockage « $($px.StockageIso) »"
    $noeud = $px.Noeud
    $presentes = @(Invoke-LabPve -Config $config -Chemin "/nodes/$noeud/storage/$($px.StockageIso)/content" -Parametres @{ content = 'iso' } | ForEach-Object { ($_.volid -split '/')[-1] })
    $aEnvoyer = @($config.Iso.VirtIO.Fichier, $config.Iso.PfSense.Fichier, $config.Iso.WindowsServer2025.Fichier, $config.Iso.Windows11Entreprise.Fichier)
    $repere = Join-Path $dossierIso 'ubuntu-server.txt'
    if (Test-Path $repere) { $aEnvoyer += (Get-Content $repere -TotalCount 1).Trim() }
    foreach ($nom in $aEnvoyer) {
        $chemin = Join-Path $dossierIso $nom
        if ($presentes -contains $nom) { Write-LabOk "$nom déjà présente."; continue }
        if (-not (Test-Path $chemin)) { Write-LabAvert "$nom absente sur l'hôte (10-telecharger-iso.ps1)."; continue }
        Write-LabInfo "Envoi de $nom ($([math]::Round((Get-Item $chemin).Length / 1GB, 1)) Go)..."
        $upid = Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/storage/$($px.StockageIso)/upload" -Parametres @{ content = 'iso' } -Fichiers @{ filename = $chemin }
        Wait-LabPveTache -Config $config -Upid $upid -Minutes 30
        Write-LabOk "$nom envoyée."
    }
}

Write-LabEtape 'Suite'
Write-LabInfo '.\vm\30-creer-vm.ps1   (VM du labo par l''API de Proxmox)'
