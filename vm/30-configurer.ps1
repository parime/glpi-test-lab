<#
.SYNOPSIS
    Configuration après installation : contrôleur de domaine lab.local et annuaire de démonstration,
    jonction de Windows 11 au domaine, GLPI Agent sur Windows 11 et Ubuntu, point de contrôle
    « propre ».

.DESCRIPTION
    Sans droits administrateur (membre d'« Administrateurs Hyper-V »). Idempotent : chaque étape
    vérifie l'état avant d'agir ; relancer le script reprend là où il s'était arrêté.

    Les VM Windows sont pilotées par PowerShell Direct (sans réseau, par le bus de la VM), la VM
    Ubuntu par SSH avec la clé du labo.

    - AD : adresse fixe, rôles AD DS et AD CS, nouvelle forêt lab.local (DNS intégré), autorité de
      certification d'entreprise (LDAPS sur 636 : Windows Server 2025 refuse par défaut les liaisons
      simples LDAP en clair sur 389 pour une nouvelle forêt), redirecteur DNS vers pfSense, annuaire
      de démonstration (vm\modeles\annuaire-demo.psd1), export du certificat de l'autorité.
    - Windows 11 : adresse fixe, DNS de l'AD, jonction au domaine dans OU=Postes, GLPI Agent (MSI).
    - Ubuntu : vérification ou relance de l'installation de GLPI Agent.
    - pfSense : vérification seulement (installation manuelle, docs/vm.md).

    Références :
    - PowerShell Direct : https://learn.microsoft.com/virtualization/hyper-v-on-windows/user-guide/powershell-direct
    - Install-ADDSForest : https://learn.microsoft.com/powershell/module/addsdeployment/install-addsforest
    - Install-AdcsCertificationAuthority : https://learn.microsoft.com/powershell/module/adcsdeployment/install-adcscertificationauthority
    - Signature LDAP par défaut sous Windows Server 2025 : https://learn.microsoft.com/windows-server/identity/ad-ds/ldap-signing
    - Add-Computer : https://learn.microsoft.com/powershell/module/microsoft.powershell.management/add-computer
    - MSI de GLPI Agent : https://glpi-agent.readthedocs.io/en/latest/installation/windows-command-line.html
    - Points de contrôle : https://learn.microsoft.com/powershell/module/hyper-v/checkpoint-vm

.PARAMETER Nom
    VM à configurer (par défaut : toutes, dans l'ordre de vms.psd1).

.PARAMETER NouveauPointDeControle
    Remplacer le point de contrôle « propre » s'il existe déjà.

.PARAMETER SansPointDeControle
    Ne pas créer de point de contrôle.
#>
[CmdletBinding()]
param(
    [string[]]$Nom,
    [switch]$NouveauPointDeControle,
    [switch]$SansPointDeControle
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\LabVm.psm1') -Force
Import-Module Hyper-V -ErrorAction SilentlyContinue
$config = Get-LabConfig
Assert-LabAccesHyperV
$secrets = Get-LabSecrets -Config $config
$domaine = $config.Domaine
$interne = $config.Reseau.Interne
$longueur = [int]$interne.Prefixe.Split('/')[1]
$vmAd = $config.Vm | Where-Object { $_.Role -eq 'ad' } | Select-Object -First 1
$credDomaine = Get-LabCredential -Utilisateur "$($domaine.NetBios)\Administrator" -MotDePasse $secrets.AdminWindows
$bilan = New-Object System.Collections.Generic.List[string]

# Adresse fixe et DNS dans une VM Windows (exécuté dans la VM).
$blocReseau = {
    param([string]$Ip, [int]$Longueur, [string]$Passerelle, [string[]]$Dns)
    $carte = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1
    if (-not $carte) { throw 'Aucune carte réseau active.' }
    $actuelle = Get-NetIPAddress -InterfaceIndex $carte.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $Ip }
    if (-not $actuelle) {
        Set-NetIPInterface -InterfaceIndex $carte.ifIndex -Dhcp Disabled
        Get-NetIPAddress -InterfaceIndex $carte.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:$false
        Get-NetRoute -InterfaceIndex $carte.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:$false
        New-NetIPAddress -InterfaceIndex $carte.ifIndex -IPAddress $Ip -PrefixLength $Longueur -DefaultGateway $Passerelle | Out-Null
    }
    Set-DnsClientServerAddress -InterfaceIndex $carte.ifIndex -ServerAddresses $Dns
    # Le réseau du labo est privé (pare-feu de l'invité moins fermé que « Public »).
    Get-NetConnectionProfile -InterfaceIndex $carte.ifIndex -ErrorAction SilentlyContinue |
        Where-Object { $_.NetworkCategory -eq 'Public' } | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
    return "$Ip/$Longueur, passerelle $Passerelle, DNS $($Dns -join ', ')"
}

function Invoke-Vm {
    param([string]$Nom, [pscredential]$Credential, [scriptblock]$Bloc, [object[]]$Arguments = @())
    return Invoke-Command -VMName $Nom -Credential $Credential -ScriptBlock $Bloc -ArgumentList $Arguments
}

function Test-Session {
    param([string]$Nom, [pscredential]$Credential)
    try { Invoke-Command -VMName $Nom -Credential $Credential -ScriptBlock { 1 } -ErrorAction Stop | Out-Null; return $true } catch { return $false }
}

function Set-PointDeControlePropre {
    param([hashtable]$Vm)
    if ($SansPointDeControle) { return }
    $nomPoint = $config.PointDeControle
    $existant = Get-VMSnapshot -VMName $Vm.Nom -Name $nomPoint -ErrorAction SilentlyContinue
    if ($existant -and -not $NouveauPointDeControle) { Write-LabInfo "Point de contrôle « $nomPoint » déjà présent (gardé)."; return }
    Write-LabInfo "Arrêt propre pour le point de contrôle « $nomPoint »..."
    Stop-VM -Name $Vm.Nom
    if ($existant) { Remove-VMSnapshot -VMName $Vm.Nom -Name $nomPoint }
    Checkpoint-VM -Name $Vm.Nom -SnapshotName $nomPoint
    Start-VM -Name $Vm.Nom
    Write-LabOk "Point de contrôle « $nomPoint » créé (VM arrêtée)."
}

function Wait-RetourSession {
    param([string]$Nom, [pscredential]$Credential, [int]$Minutes = 30)
    Start-Sleep -Seconds 30
    if (-not (Wait-LabPowerShellDirect -Nom $Nom -Credential $Credential -Minutes $Minutes)) {
        throw "$Nom ne répond pas après redémarrage (console : vmconnect localhost $Nom)."
    }
}

function Set-Ad {
    param([hashtable]$Vm)
    $credLocal = Get-LabCredential -Utilisateur 'Administrator' -MotDePasse $secrets.AdminWindows
    $estDc = $false
    if (Test-Session -Nom $Vm.Nom -Credential $credDomaine) {
        $estDc = (Invoke-Vm -Nom $Vm.Nom -Credential $credDomaine -Bloc { (Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4 })
    }
    if (-not $estDc) {
        if (-not (Test-Session -Nom $Vm.Nom -Credential $credLocal)) { throw "$($Vm.Nom) injoignable par PowerShell Direct : la VM est-elle installée et démarrée ?" }
        $r = Invoke-Vm -Nom $Vm.Nom -Credential $credLocal -Bloc $blocReseau -Arguments @($Vm.Ip, $longueur, $interne.Passerelle, @($interne.Passerelle))
        Write-LabOk "Réseau : $r"
        Write-LabInfo 'Rôles AD DS et AD CS, puis promotion en contrôleur de la forêt (redémarrage)...'
        Invoke-Vm -Nom $Vm.Nom -Credential $credLocal -Arguments @($domaine.Nom, $domaine.NetBios, $secrets.Dsrm) -Bloc {
            param([string]$Domaine, [string]$NetBios, [string]$Dsrm)
            Install-WindowsFeature -Name AD-Domain-Services, ADCS-Cert-Authority -IncludeManagementTools | Out-Null
            Import-Module ADDSDeployment
            Install-ADDSForest -DomainName $Domaine -DomainNetbiosName $NetBios -InstallDns `
                -SafeModeAdministratorPassword (ConvertTo-SecureString $Dsrm -AsPlainText -Force) -NoRebootOnCompletion -Force | Out-Null
            & shutdown.exe /r /t 5 | Out-Null   # redémarrage différé : la session se termine proprement
        }
        Wait-RetourSession -Nom $Vm.Nom -Credential $credDomaine -Minutes 40
        $bilan.Add("$($Vm.Nom) : forêt $($domaine.Nom) créée")
    } else {
        Write-LabOk "Déjà contrôleur de domaine de $($domaine.Nom)."
    }

    Write-LabInfo 'Attente des services d''annuaire (ADWS)...'
    $pret = $false
    for ($i = 0; $i -lt 40 -and -not $pret; $i++) {
        try { Invoke-Vm -Nom $Vm.Nom -Credential $credDomaine -Bloc { Get-ADDomain | Out-Null } | Out-Null; $pret = $true } catch { Start-Sleep -Seconds 15 }
    }
    if (-not $pret) { throw 'Les services d''annuaire ne répondent pas.' }

    $r = Invoke-Vm -Nom $Vm.Nom -Credential $credDomaine -Arguments @($interne.Passerelle) -Bloc {
        param([string]$Pfsense)
        $sortie = @()
        $carte = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $carte.ifIndex -ServerAddresses @('127.0.0.1')
        if (-not ((Get-DnsServerForwarder).IPAddress | Where-Object { $_.IPAddressToString -eq $Pfsense })) {
            Add-DnsServerForwarder -IPAddress $Pfsense; $sortie += "redirecteur DNS $Pfsense"
        }
        $configure = Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\*'
        if (-not $configure) {
            Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName 'LAB-CA' -ValidityPeriod Years -ValidityPeriodUnits 10 -Force | Out-Null
            $sortie += 'autorité de certification LAB-CA'
        }
        # Inscription automatique du certificat de contrôleur de domaine (LDAPS).
        & certutil.exe -pulse | Out-Null
        & gpupdate.exe /target:computer /force | Out-Null
        New-Item -ItemType Directory -Force -Path 'C:\lab' | Out-Null
        & certutil.exe -f -ca.cert 'C:\lab\lab-ca.cer' | Out-Null
        return ($sortie -join ', ')
    }
    if ($r) { Write-LabOk $r; $bilan.Add("$($Vm.Nom) : $r") }

    Write-LabInfo 'Annuaire de démonstration...'
    $session = New-PSSession -VMName $Vm.Nom -Credential $credDomaine
    try {
        Invoke-Command -Session $session -ScriptBlock { New-Item -ItemType Directory -Force -Path 'C:\lab' | Out-Null }
        Copy-Item -ToSession $session -Path (Join-Path $PSScriptRoot 'modeles\annuaire-demo.psd1') -Destination 'C:\lab\annuaire-demo.psd1' -Force
        Copy-Item -ToSession $session -Path (Join-Path $PSScriptRoot 'invite\annuaire-demo.ps1') -Destination 'C:\lab\annuaire-demo.ps1' -Force
        $resultat = Invoke-Command -Session $session -ArgumentList @($secrets.UtilisateursDemo, $secrets.CompteLdapGlpi) -ScriptBlock {
            param([string]$Mdp, [string]$MdpLdap)
            & 'C:\lab\annuaire-demo.ps1' -Fichier 'C:\lab\annuaire-demo.psd1' -MotDePasseUtilisateurs $Mdp -MotsDePasseNommes @{ CompteLdapGlpi = $MdpLdap }
        }
        Write-LabOk "Annuaire : $($resultat.UnitesCreees) OU, $($resultat.GroupesCrees) groupes, $($resultat.ComptesCrees) comptes créés, $($resultat.AppartenancesAjoutees) appartenances ajoutées."
        $bilan.Add("$($Vm.Nom) : annuaire de démonstration à jour")
        $dossierCa = Get-LabChemin -Config $config -Type ca
        Copy-Item -FromSession $session -Path 'C:\lab\lab-ca.cer' -Destination (Join-Path $dossierCa 'lab-ca.cer') -Force
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Join-Path $dossierCa 'lab-ca.cer'))
        $pem = "-----BEGIN CERTIFICATE-----`n" + ([Convert]::ToBase64String($cert.RawData, 'InsertLineBreaks')).Replace("`r`n", "`n") + "`n-----END CERTIFICATE-----`n"
        Write-LabFichierUtf8 -Chemin (Join-Path $dossierCa 'lab-ca.pem') -Texte $pem
        Write-LabOk "Certificat de l'autorité LAB-CA : $dossierCa\lab-ca.pem (à faire approuver par GLPI pour LDAPS)."
    } finally {
        Remove-PSSession $session
    }
    if (Test-NetConnection -ComputerName $Vm.Ip -Port 636 -InformationLevel Quiet -WarningAction SilentlyContinue) {
        Write-LabOk "LDAPS joignable depuis l'hôte : ldaps://$($Vm.Ip):636"
    } else {
        Write-LabAvert 'LDAPS (636) pas encore joignable : le certificat du contrôleur peut mettre quelques minutes à arriver. Relancez ce script plus tard pour vérifier.'
    }
}

function Install-AgentWindows {
    param([hashtable]$Vm, [pscredential]$Credential)
    $ga = $config.GlpiAgent
    $msi = Join-Path (Get-LabChemin -Config $config -Type logiciels) $ga.Msi
    if (-not (Test-Path $msi)) { throw "MSI absent ($msi) : lancez vm\10-telecharger-iso.ps1." }
    $present = Invoke-Vm -Nom $Vm.Nom -Credential $Credential -Bloc { [bool](Get-Service | Where-Object { $_.Name -eq 'glpi-agent' -or $_.DisplayName -like 'GLPI Agent*' }) }
    if ($present) { Write-LabOk 'GLPI Agent déjà installé.'; return }
    $session = New-PSSession -VMName $Vm.Nom -Credential $Credential
    try {
        Invoke-Command -Session $session -ScriptBlock { New-Item -ItemType Directory -Force -Path 'C:\lab' | Out-Null }
        Copy-Item -ToSession $session -Path $msi -Destination "C:\lab\$($ga.Msi)" -Force
        $code = Invoke-Command -Session $session -ArgumentList @($ga.Msi, $ga.MsiSha256, $config.Glpi.UrlAgent, $config.Glpi.Tag, $ga.AddLocalWindows) -ScriptBlock {
            param([string]$Msi, [string]$Somme, [string]$Url, [string]$Tag, [string]$AddLocal)
            $chemin = "C:\lab\$Msi"
            if ((Get-FileHash -Algorithm SHA256 $chemin).Hash.ToLowerInvariant() -ne $Somme) { throw "Somme du MSI invalide dans la VM." }
            # La doc de GLPI Agent déconseille PowerShell comme interpréteur de msiexec : passage par cmd.exe.
            $ligne = "msiexec /i `"$chemin`" /quiet SERVER=`"$Url`" ADD_FIREWALL_EXCEPTION=1 RUNNOW=1 EXECMODE=1 TAG=`"$Tag`" ADDLOCAL=$AddLocal /l*v C:\lab\glpi-agent-installation.log"
            & cmd.exe /c $ligne
            return $LASTEXITCODE
        }
        if ($code -ne 0) { throw "msiexec a renvoyé $code (journal dans la VM : C:\lab\glpi-agent-installation.log)." }
        Write-LabOk "GLPI Agent $($ga.Version) installé, serveur $($config.Glpi.UrlAgent)."
        $bilan.Add("$($Vm.Nom) : GLPI Agent $($ga.Version)")
    } finally {
        Remove-PSSession $session
    }
}

function Set-PosteWindows {
    param([hashtable]$Vm)
    $credLocal = Get-LabCredential -Utilisateur "$($Vm.NomMachine)\labadmin" -MotDePasse $secrets.AdminWindows
    if (-not (Test-Session -Nom $Vm.Nom -Credential $credLocal)) { throw "$($Vm.Nom) injoignable par PowerShell Direct : la VM est-elle installée et démarrée ?" }
    $dns = @($interne.Passerelle)
    if ($vmAd) { $dns = @($vmAd.Ip) }
    $r = Invoke-Vm -Nom $Vm.Nom -Credential $credLocal -Bloc $blocReseau -Arguments @($Vm.Ip, $longueur, $interne.Passerelle, $dns)
    Write-LabOk "Réseau : $r"
    if ($vmAd) {
        $joint = Invoke-Vm -Nom $Vm.Nom -Credential $credLocal -Bloc { (Get-CimInstance Win32_ComputerSystem).PartOfDomain }
        if (-not $joint) {
            $ou = "OU=Postes,OU=Ordinateurs,OU=Lab,$($domaine.BaseDn)"
            Write-LabInfo "Jonction au domaine $($domaine.Nom) ($ou), puis redémarrage..."
            Invoke-Vm -Nom $Vm.Nom -Credential $credLocal -Arguments @($domaine.Nom, $ou, $credDomaine) -Bloc {
                param([string]$Domaine, [string]$Ou, [pscredential]$Cred)
                Add-Computer -DomainName $Domaine -OUPath $Ou -Credential $Cred -Force
                & shutdown.exe /r /t 5 | Out-Null   # redémarrage différé : la session se termine proprement
            }
            Wait-RetourSession -Nom $Vm.Nom -Credential $credLocal
            $bilan.Add("$($Vm.Nom) : joint au domaine $($domaine.Nom)")
            Write-LabOk "Joint au domaine $($domaine.Nom)."
        } else {
            Write-LabOk "Déjà membre du domaine $($domaine.Nom)."
        }
    }
    Install-AgentWindows -Vm $Vm -Credential $credLocal
    $hoteGlpi = ([uri]$config.Glpi.UrlAgent).Host; $portGlpi = ([uri]$config.Glpi.UrlAgent).Port
    $ok = Invoke-Vm -Nom $Vm.Nom -Credential $credLocal -Arguments @($hoteGlpi, $portGlpi) -Bloc {
        param([string]$Hote, [int]$Port)
        Test-NetConnection -ComputerName $Hote -Port $Port -InformationLevel Quiet -WarningAction SilentlyContinue
    }
    if ($ok) { Write-LabOk "GLPI joignable depuis la VM ($($config.Glpi.UrlAgent))." } else { Write-LabAvert "GLPI injoignable depuis la VM ($($config.Glpi.UrlAgent)) : instance démarrée ? règle de pare-feu de l'hôte ?" }
}

function Set-PosteUbuntu {
    param([hashtable]$Vm)
    if ((Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande 'true') -ne 0) { throw "SSH vers labadmin@$($Vm.Ip) impossible : la VM est-elle installée et démarrée ?" }
    if ((Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande 'systemctl is-active --quiet glpi-agent') -eq 0) {
        Write-LabOk 'GLPI Agent actif.'
    } else {
        Write-LabInfo 'GLPI Agent inactif : relance de /opt/lab/glpi-agent-setup.sh...'
        [void](Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande 'sudo bash /opt/lab/glpi-agent-setup.sh')
        if ((Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande 'systemctl is-active --quiet glpi-agent') -ne 0) {
            throw 'GLPI Agent toujours inactif : voir /var/log/lab-glpi-agent.log dans la VM (accès Internet par pfSense ?).'
        }
        Write-LabOk 'GLPI Agent installé et actif.'
        $bilan.Add("$($Vm.Nom) : GLPI Agent $($config.GlpiAgent.Version)")
    }
    $test = "curl -s -o /dev/null -w '%{http_code}' --max-time 10 '$($config.Glpi.UrlAgent)'"
    if ((Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande $test) -eq 0) { Write-LabOk "GLPI joignable depuis la VM ($($config.Glpi.UrlAgent))." }
    else { Write-LabAvert "GLPI injoignable depuis la VM ($($config.Glpi.UrlAgent))." }
}

function Test-PareFeu {
    param([hashtable]$Vm)
    if (Test-NetConnection -ComputerName $Vm.Ip -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) {
        Write-LabOk "pfSense répond sur https://$($Vm.Ip)/ (LAN)."
        return $true
    }
    Write-LabAvert "pfSense ne répond pas sur https://$($Vm.Ip)/ : installation et configuration manuelles à faire (docs/vm.md). Les VM n'auront pas Internet sans lui."
    return $false
}

foreach ($vm in (Get-LabVmListe -Config $config -Noms $Nom)) {
    Write-LabEtape "$($vm.Nom) ($($vm.Role))"
    $hv = Get-VM -Name $vm.Nom -ErrorAction SilentlyContinue
    if (-not $hv) { Write-LabAvert 'VM absente : lancez vm\20-creer-vm.ps1.'; continue }
    if ($hv.State -ne 'Running') { Start-VM -Name $vm.Nom; Start-Sleep -Seconds 30 }
    try {
        $pret = $true
        switch ($vm.Role) {
            'pare-feu' { $pret = Test-PareFeu -Vm $vm }
            'ad' { Set-Ad -Vm $vm }
            'poste-windows' { Set-PosteWindows -Vm $vm }
            'poste-ubuntu' { Set-PosteUbuntu -Vm $vm }
        }
        if ($pret) {
            Set-LabEtat -Config $config -Nom $vm.Nom -Valeurs @{ Configure = $true; ConfigureLe = (Get-Date -Format s) }
            Set-PointDeControlePropre -Vm $vm
        }
    } catch {
        Write-LabErreur $_.Exception.Message
        $bilan.Add("$($vm.Nom) : ÉCHEC, $($_.Exception.Message)")
    }
}

Write-LabEtape 'Bilan'
$bilan | ForEach-Object { Write-LabInfo $_ }
if ($vmAd) {
    Write-LabEtape 'Annuaire LDAP pour GLPI (détail dans docs/vm.md)'
    Write-LabInfo "Serveur        : ldaps://$($vmAd.Ip) port 636 (ou ldaps://$($vmAd.NomMachine).$($domaine.Nom))"
    Write-LabInfo "BaseDN         : $($domaine.BaseDn)"
    Write-LabInfo "DN de connexion: svc-glpi-ldap@$($domaine.Nom) (mot de passe : CompteLdapGlpi dans secrets.json)"
}
