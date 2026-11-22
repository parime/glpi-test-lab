<#
.SYNOPSIS
    Crée les VM du labo dans Proxmox VE, par son API, et lance leur installation sans intervention.

.DESCRIPTION
    Sans droits administrateur ni accès Hyper-V : tout passe par l'API de Proxmox (jeton préparé
    par 20-proxmox.ps1). Idempotent : une VM qui existe déjà n'est pas recréée ; une VM marquée
    installée (etat.json) n'est pas réinstallée.

    Pour chaque VM de vms.psd1 :
    - disque VirtIO SCSI en allocation fine sur « local-lvm », carte réseau VirtIO, agent invité
      QEMU activé ; Windows : UEFI (OVMF) avec démarrage sécurisé et clés Microsoft préchargées,
      TPM 2.0 virtuel pour Windows 11, ISO VirtIO jointe ;
    - support d'installation généré (autounattend.xml ou CIDATA cloud-init) et envoyé dans le
      stockage « local » ;
    - démarrage, puis saisie au clavier virtuel (API sendkey) de ce qu'un humain taperait : Entrée
      pour « Press any key to boot from CD or DVD » (Windows), la ligne de commande GRUB avec
      « autoinstall » (Ubuntu) ;
    - attente de la fin de l'installation (agent invité joignable, ou VM arrêtée pour Ubuntu),
      retrait de l'ISO du système et retour à la mémoire de fonctionnement.
    pfSense est créé et démarré sur son ISO ; son installation se fait à la console (docs/vm.md).

    Références :
    - Création d'une VM : https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu (POST)
    - Paramètres des VM (disques, efidisk0, tpmstate0, agent) : https://pve.proxmox.com/pve-docs/qm.1.html
    - Bonnes pratiques Windows (VirtIO, OVMF, TPM) : https://pve.proxmox.com/wiki/Windows_2025_guest_best_practices
      et https://pve.proxmox.com/wiki/Windows_11_guest_best_practices
    - Clavier : https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu/{vmid}/sendkey

.PARAMETER Nom
    VM à créer (par défaut : toutes, dans l'ordre de vms.psd1).

.PARAMETER SansInstallation
    Créer les VM sans les démarrer.

.PARAMETER SansAttente
    Lancer les installations sans attendre leur fin.

.PARAMETER SupportsSeulement
    Générer seulement les supports d'installation (sans Proxmox), pour les relire.
#>
[CmdletBinding()]
param(
    [string[]]$Nom,
    [switch]$SansInstallation,
    [switch]$SansAttente,
    [switch]$SupportsSeulement
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\LabVm.psm1') -Force
$config = Get-LabConfig
$secrets = Get-LabSecrets -Config $config
$px = $config.Proxmox
$reseau = $config.Reseau
$noeud = $px.Noeud
$dossierIso = Get-LabChemin -Config $config -Type iso
$dossierSupports = Get-LabChemin -Config $config -Type supports
$dossierLogiciels = Get-LabChemin -Config $config -Type logiciels

function Get-NomIsoSysteme {
    param([hashtable]$Vm)
    if ($Vm.Iso -eq 'UbuntuServer') {
        $repere = Join-Path $dossierIso 'ubuntu-server.txt'
        if (-not (Test-Path $repere)) { throw 'ISO Ubuntu absente : lancez vm\10-telecharger-iso.ps1.' }
        return (Get-Content $repere -TotalCount 1).Trim()
    }
    return $config.Iso[$Vm.Iso].Fichier
}

function Get-PilotesXml {
    # Chemins de pilotes VirtIO (disque, réseau, port série) pour chaque lettre de lecteur possible.
    param([string]$Version)
    $lignes = @(); $n = 1
    foreach ($lettre in 'D', 'E', 'F', 'G', 'H', 'I') {
        foreach ($pilote in 'vioscsi', 'NetKVM', 'vioserial') {
            $lignes += "        <PathAndCredentials wcm:action=`"add`" wcm:keyValue=`"$n`"><Path>${lettre}:\$pilote\$Version\amd64</Path></PathAndCredentials>"
            $n++
        }
    }
    return $lignes -join "`n"
}

function New-SupportWindows {
    param([hashtable]$Vm)
    $langue = $config.Langue
    if ($Vm.Role -eq 'ad') {
        $comptes = @"
        <AdministratorPassword>
          <Value>$(ConvertTo-LabXml $secrets.AdminWindows)</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
"@
        $versionPilotes = '2k25'
    } else {
        $comptes = @"
        <LocalAccounts>
          <LocalAccount wcm:action="add">
            <Name>labadmin</Name>
            <DisplayName>Administrateur du labo</DisplayName>
            <Group>Administrators</Group>
            <Password>
              <Value>$(ConvertTo-LabXml $secrets.AdminWindows)</Value>
              <PlainText>true</PlainText>
            </Password>
          </LocalAccount>
        </LocalAccounts>
"@
        $versionPilotes = 'w11'
    }
    $xml = Get-LabTexteModele -Nom 'autounattend-windows.xml' -Valeurs @{
        UI = $langue.WindowsUi; REGION = $langue.WindowsRegion; CLAVIER = $langue.WindowsClavier
        FUSEAU = $langue.WindowsFuseau; INDEX = $Vm.IndexImage; NOM_MACHINE = $Vm.NomMachine; COMPTES = $comptes
        PILOTES = (Get-PilotesXml -Version $versionPilotes)
    }
    [void][xml]$xml
    $dossier = Join-Path $dossierSupports $Vm.Nom
    if (Test-Path $dossier) { Remove-Item $dossier -Recurse -Force }
    New-Item -ItemType Directory -Path $dossier | Out-Null
    Write-LabFichierUtf8 -Chemin (Join-Path $dossier 'autounattend.xml') -Texte $xml
    # Fichiers utilisés après l'installation (40-configurer.ps1) : repère, scripts de l'invité, MSI.
    Set-Content -Path (Join-Path $dossier 'lab-support.txt') -Value $Vm.Nom -Encoding ASCII
    if ($Vm.Role -eq 'ad') {
        Copy-Item (Join-Path $PSScriptRoot 'modeles\annuaire-demo.psd1') $dossier
        Copy-Item (Join-Path $PSScriptRoot 'invite\annuaire-demo.ps1') $dossier
        Copy-Item (Join-Path $PSScriptRoot 'invite\gpo-glpi-agent.ps1') $dossier
        $msi = Join-Path $dossierLogiciels $config.GlpiAgent.Msi
        if (-not (Test-Path $msi)) { throw "MSI de GLPI Agent absent ($msi) : lancez vm\10-telecharger-iso.ps1." }
        Copy-Item $msi $dossier
    }
    $iso = Join-Path $dossierSupports "$($Vm.Nom)-installation.iso"
    New-LabIso -Dossier $dossier -Destination $iso -Etiquette 'LABSUPPORT'
    return $iso
}

function New-SupportUbuntu {
    param([hashtable]$Vm)
    $langue = $config.Langue
    $ga = $config.GlpiAgent
    $agent = Join-Path $dossierLogiciels $ga.Linux
    if (-not (Test-Path $agent)) { throw "Installeur GLPI Agent absent ($agent) : lancez vm\10-telecharger-iso.ps1." }
    $clePublique = (Get-Content -Path ((Get-LabSshCle -Config $config) + '.pub') -TotalCount 1).Trim()
    $ad = $config.Vm | Where-Object { $_.Role -eq 'ad' } | Select-Object -First 1
    $dns = @(); if ($ad) { $dns += $ad.Ip }; $dns += $reseau.Passerelle
    $userData = Get-LabTexteModele -Nom 'ubuntu-user-data.yml' -Valeurs @{
        LOCALE = $langue.UbuntuLocale; CLAVIER = $langue.UbuntuClavier; FUSEAU = $langue.UbuntuFuseau
        IP = $Vm.Ip; LONGUEUR = $reseau.Prefixe.Split('/')[1]; PASSERELLE = $reseau.Passerelle
        DNS = ($dns -join ', '); DOMAINE = $config.Domaine.Nom; CLE_SSH = $clePublique
        AGENT_LINUX = $ga.Linux; NOM_MACHINE = $Vm.NomMachine; MDP = $secrets.Ubuntu
    }
    $script = Get-LabTexteModele -Nom 'glpi-agent-setup.sh' -Valeurs @{
        VERSION = $ga.Version; SHA256 = $ga.LinuxSha256; AGENT_LINUX = $ga.Linux
        URL = $config.Glpi.UrlAgent; TAG = $config.Glpi.Tag; TYPE = $ga.TypeLinux
    }
    $dossier = Join-Path $dossierSupports $Vm.Nom
    if (Test-Path $dossier) { Remove-Item $dossier -Recurse -Force }
    New-Item -ItemType Directory -Path $dossier | Out-Null
    Write-LabFichierUtf8 -Chemin (Join-Path $dossier 'user-data') -Texte $userData
    Write-LabFichierUtf8 -Chemin (Join-Path $dossier 'meta-data') -Texte ("instance-id: $($Vm.Nom)-$(Get-Date -Format yyyyMMddHHmmss)`nlocal-hostname: $($Vm.NomMachine)`n")
    Write-LabFichierUtf8 -Chemin (Join-Path $dossier 'glpi-agent-setup.sh') -Texte $script
    Copy-Item -Path $agent -Destination $dossier
    $iso = Join-Path $dossierSupports "$($Vm.Nom)-cidata.iso"
    New-LabIso -Dossier $dossier -Destination $iso -Etiquette 'CIDATA'
    return $iso
}

function Send-IsoProxmox {
    # Envoie (ou remplace) une ISO dans le stockage « local » ; renvoie son identifiant de volume.
    param([string]$Chemin, [switch]$Remplacer)
    $nomIso = Split-Path $Chemin -Leaf
    $volid = "$($px.StockageIso):iso/$nomIso"
    $presentes = @(Invoke-LabPve -Config $config -Chemin "/nodes/$noeud/storage/$($px.StockageIso)/content" -Parametres @{ content = 'iso' } | ForEach-Object { $_.volid })
    if ($presentes -contains $volid) {
        if (-not $Remplacer) { return $volid }
        Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode DELETE -Chemin "/nodes/$noeud/storage/$($px.StockageIso)/content/$([uri]::EscapeDataString($volid))")
    }
    $upid = Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/storage/$($px.StockageIso)/upload" -Parametres @{ content = 'iso' } -Fichiers @{ filename = $Chemin }
    Wait-LabPveTache -Config $config -Upid $upid -Minutes 30
    return $volid
}

function New-PveVm {
    param([hashtable]$Vm, [string]$VolIso, [string]$VolSupport)
    $stock = $px.StockageDisque
    $memoire = $Vm.MemoireMo
    if ($Vm.ContainsKey('MemoireInstallationMo')) { $memoire = $Vm.MemoireInstallationMo }
    $p = @{
        vmid = $Vm.VmId; name = $Vm.Nom; cores = $Vm.Coeurs; sockets = 1; memory = $memoire
        scsihw = 'virtio-scsi-single'; agent = 'enabled=1'
        scsi0 = "${stock}:$($Vm.DisqueGo),discard=on,iothread=1,ssd=1"
        ide2 = "$VolIso,media=cdrom"
        description = "glpi-test-lab (vm/vms.psd1) : $($Vm.Role)"
        onboot = 0
    }
    switch ($Vm.Role) {
        'pare-feu' {
            # WAN (vtnet0) sur le pont WAN, LAN (vtnet1) sur le pont LAN.
            $p.ostype = 'other'; $p.net0 = "virtio,bridge=$($reseau.PontWan)"; $p.net1 = "virtio,bridge=$($reseau.PontLan)"
            $p.boot = 'order=scsi0;ide2'; $p.agent = 'enabled=0'
        }
        'poste-ubuntu' {
            $p.ostype = 'l26'; $p.bios = 'ovmf'; $p.machine = 'q35'
            $p.efidisk0 = "${stock}:1,efitype=4m,pre-enrolled-keys=1"
            $p.net0 = "virtio,bridge=$($reseau.PontLan)"; $p.ide0 = "$VolSupport,media=cdrom"; $p.boot = 'order=scsi0;ide2'
        }
        default {
            # Windows : UEFI, clés Microsoft préchargées (démarrage sécurisé), ISO VirtIO en ide0,
            # support d'installation en ide1. TPM 2.0 pour Windows 11.
            $volVirtio = "$($px.StockageIso):iso/$($config.Iso.VirtIO.Fichier)"
            $p.ostype = 'win11'; $p.bios = 'ovmf'; $p.machine = 'q35'
            $p.efidisk0 = "${stock}:1,efitype=4m,pre-enrolled-keys=1"
            $p.net0 = "virtio,bridge=$($reseau.PontLan)"
            $p.ide0 = "$volVirtio,media=cdrom"; $p.ide1 = "$VolSupport,media=cdrom"; $p.boot = 'order=scsi0;ide2'
            if ($Vm.Role -eq 'poste-windows') { $p.tpmstate0 = "${stock}:1,version=v2.0" }
        }
    }
    Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu" -Parametres $p)
}

function Start-PveVm {
    param([int]$VmId)
    Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$VmId/status/start")
}

function Get-EtatPve {
    param([int]$VmId)
    return (Invoke-LabPve -Config $config -Chemin "/nodes/$noeud/qemu/$VmId/status/current").status
}

function Wait-PveArret {
    param([int]$VmId, [int]$Minutes)
    $limite = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $limite) { if ((Get-EtatPve -VmId $VmId) -eq 'stopped') { return $true }; Start-Sleep -Seconds 15 }
    return $false
}

function Stop-PveVmPropre {
    param([int]$VmId)
    if ((Get-EtatPve -VmId $VmId) -eq 'stopped') { return }
    Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$VmId/status/shutdown" -Parametres @{ timeout = 300 }) -Minutes 10
}

function Start-Installation {
    param([hashtable]$Vm)
    Start-PveVm -VmId $Vm.VmId
    switch ($Vm.Role) {
        { $_ -in 'ad', 'poste-windows' } {
            # « Press any key to boot from CD or DVD » : Entrée chaque seconde pendant 5 minutes (sur un
            # hôte chargé, la VM imbriquée a mis plus de 2 minutes à afficher ce message, qui ne reste
            # que quelques secondes ; une touche en trop une fois l'installeur lancé est sans effet).
            for ($i = 0; $i -lt 300; $i++) { Start-Sleep -Seconds 1; try { Send-LabPveTouche -Config $config -VmId $Vm.VmId -Touche 'ret' } catch { } }
        }
        'poste-ubuntu' {
            Start-Sleep -Seconds $Vm.DelaiGrubSecondes
            Send-LabPveTouche -Config $config -VmId $Vm.VmId -Touche 'c'
            Start-Sleep -Seconds 2
            foreach ($ligne in @('linux /casper/vmlinuz autoinstall ---', 'initrd /casper/initrd', 'boot')) {
                Send-LabPveTexte -Config $config -VmId $Vm.VmId -Texte $ligne
                Send-LabPveTouche -Config $config -VmId $Vm.VmId -Touche 'ret'
                Start-Sleep -Seconds 3
            }
        }
    }
}

function Complete-Installation {
    # Attente de la fin, retrait de l'ISO du système, mémoire de fonctionnement, redémarrage.
    param([hashtable]$Vm)
    if ($Vm.Role -eq 'poste-ubuntu') {
        if (-not (Wait-PveArret -VmId $Vm.VmId -Minutes 60)) { return $false }
    } else {
        $limite = (Get-Date).AddMinutes(90); $pret = $false
        while (-not $pret -and (Get-Date) -lt $limite) { Start-Sleep -Seconds 30; $pret = Test-LabPveAgent -Config $config -VmId $Vm.VmId }
        if (-not $pret) { return $false }
        Stop-PveVmPropre -VmId $Vm.VmId
    }
    $p = @{ ide2 = 'none,media=cdrom'; memory = $Vm.MemoireMo }
    if ($Vm.Role -eq 'poste-ubuntu') { $p.delete = 'ide0' }
    [void](Invoke-LabPve -Config $config -Methode PUT -Chemin "/nodes/$noeud/qemu/$($Vm.VmId)/config" -Parametres $p)
    Start-PveVm -VmId $Vm.VmId
    return $true
}

$vms = Get-LabVmListe -Config $config -Noms $Nom
if ($SupportsSeulement) {
    foreach ($vm in $vms) {
        switch ($vm.Role) {
            { $_ -in 'ad', 'poste-windows' } { Write-LabOk "$($vm.Nom) : $(New-SupportWindows -Vm $vm)" }
            'poste-ubuntu' { Write-LabOk "$($vm.Nom) : $(New-SupportUbuntu -Vm $vm)" }
            default { Write-LabInfo "$($vm.Nom) : pas de support (installation à la console)." }
        }
    }
    return
}

$version = Invoke-LabPve -Config $config -Chemin '/version'
Write-LabInfo "Proxmox VE $($version.version), nœud $noeud."
$etat = Get-LabEtat -Config $config
foreach ($vm in $vms) {
    Write-LabEtape "$($vm.Nom) (VM $($vm.VmId), $($vm.Role))"
    $existante = Get-LabPveVm -Config $config -VmId $vm.VmId
    if ($existante) {
        Write-LabInfo "La VM existe déjà (état : $($existante.status)) : pas de recréation."
        if ($etat.ContainsKey($vm.Nom) -and $etat[$vm.Nom].ContainsKey('InstalleLe')) { Write-LabOk "Installée le $($etat[$vm.Nom].InstalleLe)."; continue }
        if ($existante.status -ne 'stopped' -or $SansInstallation) { continue }
    } else {
        $volIso = Send-IsoProxmox -Chemin (Join-Path $dossierIso (Get-NomIsoSysteme -Vm $vm))
        $volSupport = $null
        switch ($vm.Role) {
            { $_ -in 'ad', 'poste-windows' } {
                [void](Send-IsoProxmox -Chemin (Join-Path $dossierIso $config.Iso.VirtIO.Fichier))
                $volSupport = Send-IsoProxmox -Chemin (New-SupportWindows -Vm $vm) -Remplacer
            }
            'poste-ubuntu' { $volSupport = Send-IsoProxmox -Chemin (New-SupportUbuntu -Vm $vm) -Remplacer }
        }
        New-PveVm -Vm $vm -VolIso $volIso -VolSupport $volSupport
        Write-LabOk "VM créée par l'API : $($vm.Coeurs) cœur(s), $($vm.MemoireMo) Mo, disque $($vm.DisqueGo) Go (allocation fine)."
    }
    if ($SansInstallation) { continue }

    if ($vm.Role -eq 'pare-feu') {
        if ((Get-EtatPve -VmId $vm.VmId) -eq 'stopped') { Start-PveVm -VmId $vm.VmId }
        Write-LabAvert "pfSense : installation à la console de Proxmox (https://$($px.IpLan):8006, VM $($vm.VmId), Console), voir docs/vm.md."
        Set-LabEtat -Config $config -Nom $vm.Nom -Valeurs @{ CreeLe = (Get-Date -Format s) }
        continue
    }
    if ($vm.Role -eq 'poste-ubuntu') {
        # L'installation télécharge des paquets : il faut Internet, donc pfSense.
        if (-not (Test-NetConnection -ComputerName $reseau.Passerelle -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)) {
            Write-LabAvert "pfSense ($($reseau.Passerelle)) ne répond pas : installez-le d'abord (docs/vm.md), puis relancez : .\vm\30-creer-vm.ps1 -Nom $($vm.Nom)"
            continue
        }
    }
    Start-Installation -Vm $vm
    Write-LabOk 'Installation lancée.'
    if ($SansAttente) { continue }
    Write-LabInfo 'Attente de la fin de l''installation (20 à 60 minutes)...'
    if (Complete-Installation -Vm $vm) {
        $jours = 0
        if ($config.Iso[$vm.Iso].ContainsKey('EvaluationJours')) { $jours = $config.Iso[$vm.Iso].EvaluationJours }
        Set-LabEtat -Config $config -Nom $vm.Nom -Valeurs @{ InstalleLe = (Get-Date -Format s); EvaluationJours = $jours; Configure = $false }
        Write-LabOk "Installation terminée ; mémoire ramenée à $($vm.MemoireMo) Mo."
    } else {
        Write-LabErreur "Installation non terminée dans le délai : console de la VM $($vm.VmId) dans https://$($px.IpLan):8006"
    }
}
Write-LabEtape 'Suite'
Write-LabInfo '.\vm\40-configurer.ps1   (domaine, annuaire, GPO de GLPI Agent, jonctions, instantanés « propre »)'
