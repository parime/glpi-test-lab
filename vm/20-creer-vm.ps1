<#
.SYNOPSIS
    Crée les VM Hyper-V du labo et lance leur installation sans intervention.

.DESCRIPTION
    Sans droits administrateur, à condition d'être membre du groupe « Administrateurs Hyper-V »
    (voir 00-prerequis-admin.ps1). Idempotent : une VM qui existe déjà n'est ni recréée ni
    modifiée ; une VM déjà installée (etat.json) n'est pas réinstallée.

    Pour chaque VM de vms.psd1 :
    - disque VHDX dynamique, VM de génération 2, mémoire dynamique (fixe pour pfSense), démarrage
      sécurisé selon le système, TPM virtuel pour Windows 11, points de contrôle standard et
      automatiques désactivés, fichiers sous <Racine>\machines\<vm> ;
    - support d'installation généré : autounattend.xml (Windows) ou CIDATA cloud-init (Ubuntu) ;
    - démarrage et saisie au clavier virtuel de ce qu'un humain taperait : une touche pour
      « Press any key to boot from CD or DVD » (Windows), la ligne de commande GRUB avec le
      paramètre « autoinstall » (Ubuntu, voir le démarrage rapide de Subiquity) ;
    - attente de la fin de l'installation, retrait des supports.
    pfSense est créé et démarré sur son ISO ; son installation se fait à la console (docs/vm.md).

    Références :
    - New-VM : https://learn.microsoft.com/powershell/module/hyper-v/new-vm
    - Set-VMFirmware (SecureBootTemplate, BootOrder) : https://learn.microsoft.com/powershell/module/hyper-v/set-vmfirmware
    - TPM virtuel : https://learn.microsoft.com/powershell/module/hyper-v/enable-vmtpm
    - Configuration requise de Windows 11 (TPM 2.0, démarrage sécurisé, 4 Go, 64 Go) :
      https://learn.microsoft.com/windows/whats-new/windows-11-requirements
    - pfSense sur Hyper-V (génération 2, démarrage sécurisé désactivé) :
      https://docs.netgate.com/pfsense/en/latest/recipes/virtualize-hyper-v.html

.PARAMETER Nom
    VM à créer (par défaut : toutes, dans l'ordre de vms.psd1).

.PARAMETER SansInstallation
    Créer les VM sans les démarrer.

.PARAMETER SansAttente
    Lancer les installations sans attendre leur fin (suivi avec lab-vm.ps1 status).

.EXAMPLE
    .\vm\20-creer-vm.ps1
.EXAMPLE
    .\vm\20-creer-vm.ps1 -Nom lab-ubuntu
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
Import-Module Hyper-V -ErrorAction SilentlyContinue
$config = Get-LabConfig
if (-not $SupportsSeulement) { Assert-LabAccesHyperV }
$secrets = Get-LabSecrets -Config $config
$dossierIso = Get-LabChemin -Config $config -Type iso
$dossierMachines = Get-LabChemin -Config $config -Type machines
$dossierSupports = Get-LabChemin -Config $config -Type supports
$dossierLogiciels = Get-LabChemin -Config $config -Type logiciels

foreach ($c in @($config.Reseau.Nat.Commutateur, $config.Reseau.Interne.Commutateur)) {
    if ($SupportsSeulement) { break }
    if (-not (Get-VMSwitch -Name $c -ErrorAction SilentlyContinue)) {
        throw "Commutateur $c absent : lancez d'abord vm\00-prerequis-admin.ps1 en administrateur."
    }
}

function Get-IsoSysteme {
    param([hashtable]$Vm)
    if ($Vm.Iso -eq 'UbuntuServer') {
        $repere = Join-Path $dossierIso 'ubuntu-server.txt'
        if (-not (Test-Path $repere)) { throw 'ISO Ubuntu absente : lancez vm\10-telecharger-iso.ps1.' }
        $chemin = Join-Path $dossierIso ((Get-Content $repere -TotalCount 1).Trim())
    } else {
        $chemin = Join-Path $dossierIso $config.Iso[$Vm.Iso].Fichier
    }
    if (-not (Test-Path $chemin)) { throw "ISO absente : $chemin. Lancez vm\10-telecharger-iso.ps1." }
    return $chemin
}

function New-SupportWindows {
    param([hashtable]$Vm)
    $langue = $config.Langue
    if ($Vm.Role -eq 'ad') {
        # Serveur : mot de passe du compte Administrator intégré.
        $comptes = @"
        <AdministratorPassword>
          <Value>$(ConvertTo-LabXml $secrets.AdminWindows)</Value>
          <PlainText>true</PlainText>
        </AdministratorPassword>
"@
    } else {
        # Windows 11 : le compte Administrator intégré reste désactivé ; compte local labadmin.
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
    }
    $xml = Get-LabTexteModele -Nom 'autounattend-windows.xml' -Valeurs @{
        UI = $langue.WindowsUi; REGION = $langue.WindowsRegion; CLAVIER = $langue.WindowsClavier
        FUSEAU = $langue.WindowsFuseau; INDEX = $Vm.IndexImage; NOM_MACHINE = $Vm.NomMachine; COMPTES = $comptes
    }
    [void][xml]$xml   # contrôle : XML bien formé
    $dossier = Join-Path $dossierSupports $Vm.Nom
    if (Test-Path $dossier) { Remove-Item $dossier -Recurse -Force }
    New-Item -ItemType Directory -Path $dossier | Out-Null
    Write-LabFichierUtf8 -Chemin (Join-Path $dossier 'autounattend.xml') -Texte $xml
    $iso = Join-Path $dossierSupports "$($Vm.Nom)-installation.iso"
    New-LabIso -Dossier $dossier -Destination $iso -Etiquette 'AUTOUNATTEND'
    return $iso
}

function New-SupportUbuntu {
    param([hashtable]$Vm)
    $langue = $config.Langue
    $interne = $config.Reseau.Interne
    $ga = $config.GlpiAgent
    $agent = Join-Path $dossierLogiciels $ga.Linux
    if (-not (Test-Path $agent)) { throw "Installeur GLPI Agent absent ($agent) : lancez vm\10-telecharger-iso.ps1." }
    $clePublique = (Get-Content -Path ((Get-LabSshCle -Config $config) + '.pub') -TotalCount 1).Trim()
    $ad = $config.Vm | Where-Object { $_.Role -eq 'ad' } | Select-Object -First 1
    $dns = @()
    if ($ad) { $dns += $ad.Ip }
    $dns += $interne.Passerelle
    $userData = Get-LabTexteModele -Nom 'ubuntu-user-data.yml' -Valeurs @{
        LOCALE = $langue.UbuntuLocale; CLAVIER = $langue.UbuntuClavier; FUSEAU = $langue.UbuntuFuseau
        IP = $Vm.Ip; LONGUEUR = $interne.Prefixe.Split('/')[1]; PASSERELLE = $interne.Passerelle
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

function New-LabVm {
    param([hashtable]$Vm, [string]$IsoSysteme, [string]$IsoSupport)
    $dossier = Join-Path $dossierMachines $Vm.Nom
    New-Item -ItemType Directory -Force -Path $dossier | Out-Null
    $vhd = Join-Path $dossier "$($Vm.Nom).vhdx"
    if (-not (Test-Path $vhd)) { New-VHD -Path $vhd -SizeBytes ([int64]$Vm.DisqueGo * 1GB) -Dynamic | Out-Null }
    New-VM -Name $Vm.Nom -Generation 2 -MemoryStartupBytes ([int64]$Vm.MemoireDemarrageMo * 1MB) -VHDPath $vhd `
        -Path $dossierMachines -SwitchName $Vm.Cartes[0] | Out-Null
    Set-VM -Name $Vm.Nom -ProcessorCount $Vm.Processeurs -AutomaticCheckpointsEnabled $false -CheckpointType Standard `
        -AutomaticStartAction Nothing -AutomaticStopAction ShutDown -SnapshotFileLocation $dossier -SmartPagingFilePath $dossier `
        -Notes "glpi-test-lab (vm/vms.psd1) : $($Vm.Role)"
    if ($Vm.MemoireDynamique) {
        Set-VMMemory -VMName $Vm.Nom -DynamicMemoryEnabled $true -StartupBytes ([int64]$Vm.MemoireDemarrageMo * 1MB) `
            -MinimumBytes ([int64]$Vm.MemoireMinMo * 1MB) -MaximumBytes ([int64]$Vm.MemoireMaxMo * 1MB)
    } else {
        Set-VMMemory -VMName $Vm.Nom -DynamicMemoryEnabled $false -StartupBytes ([int64]$Vm.MemoireDemarrageMo * 1MB)
    }
    Get-VMNetworkAdapter -VMName $Vm.Nom | Select-Object -First 1 | Rename-VMNetworkAdapter -NewName $Vm.Cartes[0]
    foreach ($carte in ($Vm.Cartes | Select-Object -Skip 1)) {
        Add-VMNetworkAdapter -VMName $Vm.Nom -SwitchName $carte -Name $carte
    }
    if ($Vm.SecureBoot -eq 'Off') {
        Set-VMFirmware -VMName $Vm.Nom -EnableSecureBoot Off
    } else {
        Set-VMFirmware -VMName $Vm.Nom -EnableSecureBoot On -SecureBootTemplate $Vm.SecureBoot
    }
    if ($Vm.ContainsKey('Tpm') -and $Vm.Tpm) {
        try {
            Set-VMKeyProtector -VMName $Vm.Nom -NewLocalKeyProtector
            Enable-VMTPM -VMName $Vm.Nom
            Write-LabOk 'TPM virtuel activé.'
        } catch {
            Write-LabErreur "TPM virtuel non activé ($($_.Exception.Message))."
            Write-LabInfo 'Windows 11 exige un TPM : supprimez la VM (lab-vm.ps1 supprimer lab-win11) et créez-la depuis une console'
            Write-LabInfo 'administrateur : vm\00-prerequis-admin.ps1 -CreerVm (ou vm\20-creer-vm.ps1 -Nom lab-win11).'
            throw
        }
    }
    Add-VMDvdDrive -VMName $Vm.Nom -Path $IsoSysteme
    if ($IsoSupport) { Add-VMDvdDrive -VMName $Vm.Nom -Path $IsoSupport }
    # Disque d'abord (vide, il est sauté jusqu'à l'installation), puis le DVD d'installation.
    $disque = Get-VMHardDiskDrive -VMName $Vm.Nom
    $dvd = Get-VMDvdDrive -VMName $Vm.Nom | Where-Object { $_.Path -eq $IsoSysteme } | Select-Object -First 1
    $cartes = @(Get-VMNetworkAdapter -VMName $Vm.Nom)
    Set-VMFirmware -VMName $Vm.Nom -BootOrder (@($disque, $dvd) + $cartes)
}

function Remove-SupportsInstallation {
    param([hashtable]$Vm)
    # Éjection des ISO (possible VM allumée) ; les lecteurs restent pour une réinstallation.
    foreach ($d in @(Get-VMDvdDrive -VMName $Vm.Nom)) {
        if ($d.Path) {
            Set-VMDvdDrive -VMName $Vm.Nom -ControllerNumber $d.ControllerNumber -ControllerLocation $d.ControllerLocation -Path $null
        }
    }
}

function Start-Installation {
    param([hashtable]$Vm)
    Start-VM -Name $Vm.Nom
    switch ($Vm.Role) {
        { $_ -in 'ad', 'poste-windows' } {
            # « Press any key to boot from CD or DVD... » : une touche par seconde pendant 25 s.
            for ($i = 0; $i -lt 25; $i++) { Start-Sleep -Seconds 1; Send-LabTouche -Nom $Vm.Nom -Code 13 }
        }
        'poste-ubuntu' {
            # Ligne de commande GRUB (touche « c ») : noyau avec « autoinstall », sans confirmation.
            Start-Sleep -Seconds $Vm.DelaiGrubSecondes
            Send-LabTexte -Nom $Vm.Nom -Texte 'c'
            Start-Sleep -Seconds 2
            foreach ($ligne in @('linux /casper/vmlinuz autoinstall ---', 'initrd /casper/initrd', 'boot')) {
                Send-LabTexte -Nom $Vm.Nom -Texte $ligne
                Send-LabTouche -Nom $Vm.Nom -Code 13
                Start-Sleep -Seconds 3
            }
        }
    }
}

function Wait-Installation {
    param([hashtable]$Vm)
    switch ($Vm.Role) {
        'ad' {
            $cred = Get-LabCredential -Utilisateur 'Administrator' -MotDePasse $secrets.AdminWindows
            return Wait-LabPowerShellDirect -Nom $Vm.Nom -Credential $cred -Minutes 90
        }
        'poste-windows' {
            $cred = Get-LabCredential -Utilisateur 'labadmin' -MotDePasse $secrets.AdminWindows
            return Wait-LabPowerShellDirect -Nom $Vm.Nom -Credential $cred -Minutes 90
        }
        'poste-ubuntu' {
            if (-not (Wait-LabVmArretee -Nom $Vm.Nom -Minutes 60)) { return $false }
            Remove-SupportsInstallation -Vm $Vm
            Start-VM -Name $Vm.Nom
            $limite = (Get-Date).AddMinutes(15)
            while ((Get-Date) -lt $limite) {
                if (Test-NetConnection -ComputerName $Vm.Ip -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue) { return $true }
                Start-Sleep -Seconds 10
            }
            return $false
        }
    }
    return $true
}

if ($SupportsSeulement) {
    # Contrôle sans Hyper-V ni droits : génère les supports d'installation pour les relire.
    foreach ($vm in (Get-LabVmListe -Config $config -Noms $Nom)) {
        switch ($vm.Role) {
            { $_ -in 'ad', 'poste-windows' } { Write-LabOk "$($vm.Nom) : $(New-SupportWindows -Vm $vm)" }
            'poste-ubuntu' { Write-LabOk "$($vm.Nom) : $(New-SupportUbuntu -Vm $vm)" }
            default { Write-LabInfo "$($vm.Nom) : pas de support (installation manuelle)." }
        }
    }
    Write-LabInfo "Contenu lisible dans $dossierSupports\<vm>\."
    return
}

$etat = Get-LabEtat -Config $config
foreach ($vm in (Get-LabVmListe -Config $config -Noms $Nom)) {
    Write-LabEtape "$($vm.Nom) ($($vm.Role))"
    $existe = Get-VM -Name $vm.Nom -ErrorAction SilentlyContinue
    if ($existe) {
        Write-LabInfo "La VM existe déjà (état : $($existe.State)) : pas de recréation."
        if ($etat.ContainsKey($vm.Nom) -and $etat[$vm.Nom].InstalleLe) { Write-LabOk "Installée le $($etat[$vm.Nom].InstalleLe)."; continue }
        if ($existe.State -ne 'Off' -or $SansInstallation) { continue }
        Write-LabInfo 'Elle n''est pas marquée installée : nouvelle tentative d''installation.'
        $isoSupport = $null
    } else {
        $isoSysteme = Get-IsoSysteme -Vm $vm
        $isoSupport = $null
        switch ($vm.Role) {
            { $_ -in 'ad', 'poste-windows' } { $isoSupport = New-SupportWindows -Vm $vm }
            'poste-ubuntu' { $isoSupport = New-SupportUbuntu -Vm $vm }
        }
        New-LabVm -Vm $vm -IsoSysteme $isoSysteme -IsoSupport $isoSupport
        $m = if ($vm.MemoireDynamique) { "$($vm.MemoireMinMo)-$($vm.MemoireMaxMo) Mo (dynamique, $($vm.MemoireDemarrageMo) au démarrage)" } else { "$($vm.MemoireDemarrageMo) Mo (fixe)" }
        Write-LabOk "VM créée : $($vm.Processeurs) processeur(s), $m, disque $($vm.DisqueGo) Go, cartes : $($vm.Cartes -join ', ')."
    }
    if ($SansInstallation) { continue }

    if ($vm.Role -eq 'pare-feu') {
        if ((Get-VM -Name $vm.Nom).State -eq 'Off') { Start-VM -Name $vm.Nom }
        Write-LabAvert 'pfSense : installation à la console (vmconnect localhost lab-pfsense), voir docs/vm.md, section pfSense.'
        Set-LabEtat -Config $config -Nom $vm.Nom -Valeurs @{ CreeLe = (Get-Date -Format s) }
        continue
    }

    Start-Installation -Vm $vm
    Write-LabOk 'Installation lancée.'
    if ($SansAttente) { continue }
    Write-LabInfo 'Attente de la fin de l''installation (20 à 60 minutes)...'
    if (Wait-Installation -Vm $vm) {
        if ($vm.Role -ne 'poste-ubuntu') { Remove-SupportsInstallation -Vm $vm }
        $jours = 0
        if ($config.Iso.ContainsKey($vm.Iso) -and $config.Iso[$vm.Iso].ContainsKey('EvaluationJours')) { $jours = $config.Iso[$vm.Iso].EvaluationJours }
        Set-LabEtat -Config $config -Nom $vm.Nom -Valeurs @{ InstalleLe = (Get-Date -Format s); EvaluationJours = $jours; Configure = $false }
        Write-LabOk 'Installation terminée.'
    } else {
        Write-LabErreur "Installation non terminée dans le délai. Regardez la console : vmconnect localhost $($vm.Nom)"
    }
}

Write-LabEtape 'Suite'
Write-LabInfo 'Après l''installation de pfSense (docs/vm.md) : .\vm\30-configurer.ps1'
