<#
.SYNOPSIS
    Configuration après installation : domaine lab.local et annuaire de démonstration, GPO de
    GLPI Agent, jonction de Windows 11 et d'Ubuntu au domaine, allègement des Windows, instantanés
    « propre ».

.DESCRIPTION
    Sans droits administrateur ni accès Hyper-V. Les VM Windows sont pilotées par l'agent invité
    QEMU (API agent/exec de Proxmox), Ubuntu par SSH avec la clé du labo. Idempotent : chaque étape
    vérifie l'état avant d'agir.

    - AD (Server Core) : adresse fixe, Windows Update automatique coupé, rôles AD DS, AD CS et
      GPMC, nouvelle forêt lab.local avec DNS, autorité d'entreprise LAB-CA (LDAPS : Windows
      Server 2025 refuse par défaut les liaisons simples en clair d'une nouvelle forêt),
      redirecteur DNS vers pfSense, annuaire de démonstration, GPO « Labo - GLPI Agent » liée à
      OU=Postes, export du certificat de LAB-CA.
    - Windows 11 : adresse fixe, DNS de l'AD, Windows Update automatique, indexation et veille
      prolongée coupés, jonction au domaine dans OU=Postes, redémarrage : la GPO installe GLPI
      Agent au démarrage et l'agent envoie aussitôt un inventaire (RUNNOW).
    - Ubuntu : GLPI Agent (cloud-init) vérifié, jonction au domaine par realmd et SSSD.
    - pfSense : vérification seulement (installation manuelle, docs/vm.md).
    - Chaque VM configurée est arrêtée proprement et reçoit l'instantané « propre ».

    Références :
    - Agent invité : https://pve.proxmox.com/wiki/Qemu-guest-agent
    - Install-ADDSForest : https://learn.microsoft.com/powershell/module/addsdeployment/install-addsforest
    - Install-AdcsCertificationAuthority : https://learn.microsoft.com/powershell/module/adcsdeployment/install-adcscertificationauthority
    - Signature LDAP de Windows Server 2025 : https://learn.microsoft.com/windows-server/identity/ad-ds/ldap-signing
    - Stratégie « Configurer les mises à jour automatiques » (NoAutoUpdate) :
      https://learn.microsoft.com/windows/deployment/update/waas-wu-settings
    - Add-Computer : https://learn.microsoft.com/powershell/module/microsoft.powershell.management/add-computer
    - Ubuntu et Active Directory (realmd, SSSD) : https://documentation.ubuntu.com/server/how-to/sssd/with-active-directory/
    - Instantanés : https://pve.proxmox.com/pve-docs/api-viewer/#/nodes/{node}/qemu/{vmid}/snapshot

.PARAMETER Nom
    VM à configurer (par défaut : toutes, dans l'ordre de vms.psd1).

.PARAMETER NouvelInstantane
    Remplacer l'instantané « propre » s'il existe déjà.

.PARAMETER SansInstantane
    Ne pas créer d'instantané.
#>
[CmdletBinding()]
param(
    [string[]]$Nom,
    [switch]$NouvelInstantane,
    [switch]$SansInstantane
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\LabVm.psm1') -Force
$config = Get-LabConfig
$secrets = Get-LabSecrets -Config $config
$px = $config.Proxmox
$noeud = $px.Noeud
$domaine = $config.Domaine
$reseau = $config.Reseau
$longueur = [int]$reseau.Prefixe.Split('/')[1]
$vmAd = $config.Vm | Where-Object { $_.Role -eq 'ad' } | Select-Object -First 1
$ouPostes = "OU=Postes,OU=Ordinateurs,OU=Lab,$($domaine.BaseDn)"
$ouServeurs = "OU=Serveurs,OU=Ordinateurs,OU=Lab,$($domaine.BaseDn)"
$bilan = New-Object System.Collections.Generic.List[string]

function ConvertTo-Litteral { param([string]$Texte) return "'" + $Texte.Replace("'", "''") + "'" }

function Invoke-Windows {
    # Script PowerShell dans la VM (SYSTEM) ; échoue si le code de sortie n'est pas 0.
    param([hashtable]$Vm, [string]$Script, [int]$Minutes = 30)
    $r = Invoke-LabPvePowerShell -Config $config -VmId $Vm.VmId -Script $Script -Minutes $Minutes
    if ($r.Code -ne 0) { throw "$($Vm.Nom) : échec dans la VM (code $($r.Code)) $($r.Erreur) $($r.Sortie)" }
    return ($r.Sortie -replace "`r", '').Trim()
}

function Wait-Agent {
    param([hashtable]$Vm, [int]$Minutes = 30)
    Start-Sleep -Seconds 30
    $limite = (Get-Date).AddMinutes($Minutes)
    while ((Get-Date) -lt $limite) {
        if (Test-LabPveAgent -Config $config -VmId $Vm.VmId) {
            # L'agent répond avant la fin du démarrage : petite marge.
            Start-Sleep -Seconds 20
            return
        }
        Start-Sleep -Seconds 15
    }
    throw "$($Vm.Nom) : l'agent invité ne répond plus (console : https://$($px.IpLan):8006, VM $($Vm.VmId))."
}

function Get-EtatPve { param([int]$VmId) return (Invoke-LabPve -Config $config -Chemin "/nodes/$noeud/qemu/$VmId/status/current").status }

function Set-InstantanePropre {
    param([hashtable]$Vm)
    if ($SansInstantane) { return }
    $nomPoint = $config.PointDeControle
    $existants = @(Invoke-LabPve -Config $config -Chemin "/nodes/$noeud/qemu/$($Vm.VmId)/snapshot" | ForEach-Object { $_.name })
    if (($existants -contains $nomPoint) -and -not $NouvelInstantane) { Write-LabInfo "Instantané « $nomPoint » déjà présent (gardé)."; return }
    Write-LabInfo "Arrêt propre pour l'instantané « $nomPoint »..."
    if ((Get-EtatPve -VmId $Vm.VmId) -ne 'stopped') {
        Wait-LabPveTache -Config $config -Minutes 10 -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$($Vm.VmId)/status/shutdown" -Parametres @{ timeout = 300 })
    }
    if ($existants -contains $nomPoint) {
        Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode DELETE -Chemin "/nodes/$noeud/qemu/$($Vm.VmId)/snapshot/$nomPoint")
    }
    Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$($Vm.VmId)/snapshot" -Parametres @{ snapname = $nomPoint; description = 'État connu après configuration (glpi-test-lab)' })
    Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$($Vm.VmId)/status/start")
    Write-LabOk "Instantané « $nomPoint » pris (VM arrêtée), VM redémarrée."
}

# Script commun : adresse fixe, DNS, allègement (exécuté dans la VM).
function Get-ScriptBase {
    param([string]$Ip, [string[]]$Dns, [switch]$Poste)
    $dnsListe = ($Dns | ForEach-Object { ConvertTo-Litteral $_ }) -join ','
    $script = @"
`$carte = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1
if (-not (Get-NetIPAddress -InterfaceIndex `$carte.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { `$_.IPAddress -eq '$Ip' })) {
    Set-NetIPInterface -InterfaceIndex `$carte.ifIndex -Dhcp Disabled
    Get-NetIPAddress -InterfaceIndex `$carte.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Remove-NetIPAddress -Confirm:`$false
    Get-NetRoute -InterfaceIndex `$carte.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Remove-NetRoute -Confirm:`$false
    New-NetIPAddress -InterfaceIndex `$carte.ifIndex -IPAddress '$Ip' -PrefixLength $longueur -DefaultGateway '$($reseau.Passerelle)' | Out-Null
}
Set-DnsClientServerAddress -InterfaceIndex `$carte.ifIndex -ServerAddresses @($dnsListe)
Get-NetConnectionProfile -InterfaceIndex `$carte.ifIndex -ErrorAction SilentlyContinue | Where-Object { `$_.NetworkCategory -eq 'Public' } | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue
# Mises à jour automatiques coupées (stratégie NoAutoUpdate) ; veille prolongée coupée.
New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Force | Out-Null
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -Value 1 -Type DWord
& powercfg.exe /hibernate off | Out-Null
"@
    if ($Poste) {
        $script += @"

# Indexation du contenu coupée (service Windows Search).
Get-Service WSearch -ErrorAction SilentlyContinue | ForEach-Object { Stop-Service `$_ -Force -ErrorAction SilentlyContinue; Set-Service `$_.Name -StartupType Disabled }
"@
    }
    return $script
}

function Set-Ad {
    param([hashtable]$Vm)
    $estDc = Invoke-Windows -Vm $Vm -Script '[int]((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4)'
    if ($estDc -ne '1') {
        [void](Invoke-Windows -Vm $Vm -Script (Get-ScriptBase -Ip $Vm.Ip -Dns @($reseau.Passerelle)))
        Write-LabOk 'Réseau et allègement appliqués.'
        Write-LabInfo 'Rôles AD DS et GPMC, puis promotion en contrôleur de la forêt (redémarrage)...'
        $promo = @"
# Le rôle AD CS empêche la promotion (« Certificate Server is installed ») : il est installé après.
if ((Get-WindowsFeature ADCS-Cert-Authority).Installed) {
    `$r = Uninstall-WindowsFeature ADCS-Cert-Authority
    if ([string]`$r.RestartNeeded -eq 'Yes') { & shutdown.exe /r /t 15 | Out-Null; 'redemarrage'; return }
}
Install-WindowsFeature -Name AD-Domain-Services, GPMC -IncludeManagementTools | Out-Null
Import-Module ADDSDeployment
Install-ADDSForest -DomainName '$($domaine.Nom)' -DomainNetbiosName '$($domaine.NetBios)' -InstallDns ``
    -SafeModeAdministratorPassword (ConvertTo-SecureString $(ConvertTo-Litteral $secrets.Dsrm) -AsPlainText -Force) -NoRebootOnCompletion -Force | Out-Null
& shutdown.exe /r /t 15 | Out-Null
'promotion lancée'
"@
        $r = Invoke-Windows -Vm $Vm -Script $promo -Minutes 40
        if ($r -match 'redemarrage') {
            Write-LabInfo 'Rôle AD CS retiré (redémarrage) avant la promotion...'
            Wait-Agent -Vm $Vm -Minutes 40
            $r = Invoke-Windows -Vm $Vm -Script $promo -Minutes 40
        }
        Write-LabInfo $r
        Wait-Agent -Vm $Vm -Minutes 40
        $bilan.Add("$($Vm.Nom) : forêt $($domaine.Nom) créée")
    } else {
        Write-LabOk "Déjà contrôleur de domaine de $($domaine.Nom)."
    }

    # Opérations d'annuaire avec le compte Administrator du domaine (session locale WinRM).
    $ga = $config.GlpiAgent
    $domaineAdmin = @"
`$cred = New-Object System.Management.Automation.PSCredential('$($domaine.NetBios)\Administrator', (ConvertTo-SecureString $(ConvertTo-Litteral $secrets.AdminWindows) -AsPlainText -Force))
`$support = (Get-PSDrive -PSProvider FileSystem | Where-Object { Test-Path (Join-Path `$_.Root 'lab-support.txt') } | Select-Object -First 1).Root
if (-not `$support) { throw 'Support du labo (lab-support.txt) introuvable : ISO LABSUPPORT jointe ?' }
for (`$i = 0; `$i -lt 40; `$i++) { try { Get-ADDomain -Server localhost | Out-Null; break } catch { Start-Sleep -Seconds 15 } }
Invoke-Command -ComputerName localhost -Credential `$cred -ArgumentList `$support -ScriptBlock {
    param(`$Support)
    `$ErrorActionPreference = 'Stop'
    `$sortie = @()
    `$carte = Get-NetAdapter | Where-Object { `$_.Status -eq 'Up' } | Sort-Object ifIndex | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex `$carte.ifIndex -ServerAddresses @('127.0.0.1')
    if (-not ((Get-DnsServerForwarder).IPAddress | Where-Object { `$_.IPAddressToString -eq '$($reseau.Passerelle)' })) { Add-DnsServerForwarder -IPAddress '$($reseau.Passerelle)'; `$sortie += 'redirecteur DNS' }
    if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\*')) {
        Install-WindowsFeature -Name ADCS-Cert-Authority -IncludeManagementTools | Out-Null
        # Une erreur sur les modèles de certificats (objet déjà présent, après un premier essai) n'empêche
        # pas l'autorité d'être configurée : on vérifie ensuite et on réinstalle les modèles par défaut.
        try { Install-AdcsCertificationAuthority -CAType EnterpriseRootCA -CACommonName 'LAB-CA' -ValidityPeriod Years -ValidityPeriodUnits 10 -Force -ErrorAction Stop | Out-Null }
        catch { if (-not (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\*')) { throw } }
        & certutil.exe -installdefaulttemplates | Out-Null
        `$sortie += 'autorité LAB-CA'
    }
    & certutil.exe -pulse | Out-Null
    `$r = & (Join-Path `$Support 'annuaire-demo.ps1') -Fichier (Join-Path `$Support 'annuaire-demo.psd1') -MotDePasseUtilisateurs $(ConvertTo-Litteral $secrets.UtilisateursDemo) -MotsDePasseNommes @{ CompteLdapGlpi = $(ConvertTo-Litteral $secrets.CompteLdapGlpi) }
    `$sortie += "annuaire : `$(`$r.ComptesCrees) comptes, `$(`$r.GroupesCrees) groupes, `$(`$r.UnitesCreees) OU créés"
    `$sortie += & (Join-Path `$Support 'gpo-glpi-agent.ps1') -DossierSource `$Support -Msi '$($ga.Msi)' -Url '$($config.Glpi.UrlAgent)' -Tag '$($config.Glpi.Tag)' -AddLocal '$($ga.AddLocalWindows)' -OuPostes '$ouPostes'
    New-Item -ItemType Directory -Force -Path 'C:\lab' | Out-Null
    & certutil.exe -f '-ca.cert' 'C:\lab\lab-ca.cer'   # verbe entre guillemets : PowerShell couperait « -ca.cert » | Out-Null
    `$sortie -join ' ; '
}
"@
    $r = Invoke-Windows -Vm $Vm -Script $domaineAdmin -Minutes 40
    Write-LabOk $r
    $bilan.Add("$($Vm.Nom) : $r")
    $b64 = Invoke-Windows -Vm $Vm -Script '[Convert]::ToBase64String([IO.File]::ReadAllBytes(''C:\lab\lab-ca.cer''))'
    $dossierCa = Get-LabChemin -Config $config -Type ca
    [IO.File]::WriteAllBytes((Join-Path $dossierCa 'lab-ca.cer'), [Convert]::FromBase64String($b64))
    $pem = "-----BEGIN CERTIFICATE-----`n" + ([Convert]::ToBase64String([Convert]::FromBase64String($b64), 'InsertLineBreaks')).Replace("`r`n", "`n") + "`n-----END CERTIFICATE-----`n"
    Write-LabFichierUtf8 -Chemin (Join-Path $dossierCa 'lab-ca.pem') -Texte $pem
    Write-LabOk "Certificat de LAB-CA : $dossierCa\lab-ca.pem"
    if (Test-NetConnection -ComputerName $Vm.Ip -Port 636 -InformationLevel Quiet -WarningAction SilentlyContinue) {
        Write-LabOk "LDAPS joignable depuis l'hôte : ldaps://$($Vm.Ip):636"
    } else {
        Write-LabAvert 'LDAPS (636) pas encore joignable : le certificat du contrôleur peut mettre quelques minutes à arriver.'
    }
}

function Set-PosteWindows {
    param([hashtable]$Vm)
    $dns = @($reseau.Passerelle); if ($vmAd) { $dns = @($vmAd.Ip) }
    [void](Invoke-Windows -Vm $Vm -Script (Get-ScriptBase -Ip $Vm.Ip -Dns $dns -Poste))
    Write-LabOk 'Réseau et allègement appliqués (mises à jour automatiques, indexation, veille prolongée).'
    $joint = Invoke-Windows -Vm $Vm -Script '[int](Get-CimInstance Win32_ComputerSystem).PartOfDomain'
    if ($joint -ne '1') {
        Write-LabInfo "Jonction au domaine $($domaine.Nom) ($ouPostes), puis redémarrage..."
        $jonction = @"
`$cred = New-Object System.Management.Automation.PSCredential('$($domaine.NetBios)\Administrator', (ConvertTo-SecureString $(ConvertTo-Litteral $secrets.AdminWindows) -AsPlainText -Force))
Add-Computer -DomainName '$($domaine.Nom)' -OUPath '$ouPostes' -Credential `$cred -Force
& shutdown.exe /r /t 15 | Out-Null
'jonction faite'
"@
        Write-LabInfo (Invoke-Windows -Vm $Vm -Script $jonction)
        Wait-Agent -Vm $Vm
        $bilan.Add("$($Vm.Nom) : joint au domaine $($domaine.Nom)")
    } else {
        Write-LabOk "Déjà membre du domaine $($domaine.Nom)."
    }
    # La GPO installe l'agent au démarrage qui suit la jonction ; un second redémarrage peut être
    # nécessaire si la stratégie n'était pas encore lue.
    $present = $false
    for ($essai = 1; $essai -le 2 -and -not $present; $essai++) {
        $limite = (Get-Date).AddMinutes(10)
        while (-not $present -and (Get-Date) -lt $limite) {
            $present = (Invoke-Windows -Vm $Vm -Script '[int](Test-Path ''HKLM:\SOFTWARE\GLPI-Agent'')') -eq '1'
            if (-not $present) { Start-Sleep -Seconds 30 }
        }
        if (-not $present -and $essai -eq 1) {
            Write-LabInfo 'GLPI Agent pas encore installé : gpupdate puis nouveau redémarrage...'
            [void](Invoke-Windows -Vm $Vm -Script "& gpupdate.exe /target:computer /force | Out-Null; & shutdown.exe /r /t 15 | Out-Null; 'ok'")
            Wait-Agent -Vm $Vm
        }
    }
    if ($present) {
        Write-LabOk "GLPI Agent installé par la GPO « Labo - GLPI Agent » (serveur $($config.Glpi.UrlAgent))."
        $bilan.Add("$($Vm.Nom) : GLPI Agent installé par GPO")
        $limite = (Get-Date).AddMinutes(10); $vu = $false
        while (-not $vu -and (Get-Date) -lt $limite) { $vu = Test-OrdinateurGlpi -NomMachine $Vm.NomMachine; if (-not $vu) { Start-Sleep -Seconds 30 } }
        if ($vu) { Write-LabOk "$($Vm.NomMachine) est dans GLPI (Parc > Ordinateurs)."; $bilan.Add("$($Vm.Nom) : présent dans GLPI") }
        else { Write-LabAvert "$($Vm.NomMachine) pas encore dans GLPI : journal de l'agent dans C:\Program Files\GLPI-Agent\logs, ou attendre l'inventaire suivant." }
    } else {
        throw 'GLPI Agent absent après deux démarrages : voir C:\Windows\Temp\glpi-agent-gpo.log et « gpresult /r » dans la VM.'
    }
}

function Set-PosteUbuntu {
    param([hashtable]$Vm)
    if ((Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande 'true') -ne 0) { throw "SSH vers labadmin@$($Vm.Ip) impossible." }
    if ((Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande 'systemctl is-active --quiet glpi-agent') -ne 0) {
        Write-LabInfo 'GLPI Agent inactif : relance de /opt/lab/glpi-agent-setup.sh...'
        [void](Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande 'sudo bash /opt/lab/glpi-agent-setup.sh')
        if ((Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande 'systemctl is-active --quiet glpi-agent') -ne 0) {
            throw 'GLPI Agent toujours inactif : voir /var/log/lab-glpi-agent.log dans la VM.'
        }
    }
    Write-LabOk 'GLPI Agent actif.'
    if ($vmAd -and (Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande "realm list --name-only | grep -qx $($domaine.Nom)") -ne 0) {
        Write-LabInfo "Jonction au domaine $($domaine.Nom) par realmd et SSSD..."
        $paquets = 'realmd sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin oddjob oddjob-mkhomedir packagekit'
        if ((Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q $paquets >/dev/null") -ne 0) { throw 'Installation de realmd et SSSD impossible (accès Internet par pfSense ?).' }
        $mdp = $secrets.AdminWindows
        if ((Invoke-LabSsh -Config $config -Ip $Vm.Ip -Commande "printf '%s' '$mdp' | sudo realm join --user=Administrator --computer-ou='$ouServeurs' $($domaine.Nom)") -ne 0) { throw 'realm join a échoué.' }
        $bilan.Add("$($Vm.Nom) : joint au domaine $($domaine.Nom) (realmd/SSSD)")
    }
    Write-LabOk "Membre du domaine $($domaine.Nom)."
}

function Get-ConteneurGlpi {
    # Conteneur GLPI du labo qui publie le port de Glpi.UrlAgent (instances.txt du socle, étiquettes
    # lab.instance et lab.role posées par stack/glpi.yml).
    $port = ([uri]$config.Glpi.UrlAgent).Port
    $fichier = Join-Path (Split-Path $PSScriptRoot) 'instances.txt'
    if (-not (Test-Path $fichier)) { return $null }
    $instance = $null
    foreach ($l in Get-Content $fichier) {
        if ($l -match '^\s*([^#\s]\S*)\s+\S+\s+(\d+)\s*$' -and [int]$Matches[2] -eq $port) { $instance = $Matches[1] }
    }
    if (-not $instance) { return $null }
    $nom = (& docker ps --filter "label=lab.instance=$instance" --filter 'label=lab.role=glpi' --format '{{.Names}}' | Select-Object -First 1)
    if (-not $nom) { return $null }
    return @{ Instance = $instance; Conteneur = $nom }
}

function Enable-InventaireGlpi {
    # L'inventaire natif de GLPI est désactivé par défaut (Administration > Inventaire) : sans lui,
    # GLPI refuse les inventaires des agents. Activation par la console de GLPI (config:set).
    $g = Get-ConteneurGlpi
    if (-not $g) { Write-LabAvert "Instance GLPI de $($config.Glpi.UrlAgent) introuvable dans Docker : activez l'inventaire à la main (Administration > Inventaire)."; return }
    & docker exec $g.Conteneur php /var/www/glpi/bin/console config:set --context=inventory enabled_inventory 1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-LabOk "Inventaire natif activé dans $($g.Instance) (Administration > Inventaire)." }
    else { Write-LabAvert "Activation de l'inventaire impossible dans $($g.Instance) : à faire à la main." }
}

function Test-OrdinateurGlpi {
    # Vérifie par la base de l'instance que l'ordinateur a été inventorié (lecture seule).
    param([string]$NomMachine)
    $g = Get-ConteneurGlpi
    if (-not $g) { return $false }
    $db = (& docker ps --filter "label=lab.instance=$($g.Instance)" --filter 'label=lab.role=db' --format '{{.Names}}' | Select-Object -First 1)
    if (-not $db) { return $false }
    $requete = "select count(*) from glpi_computers where name='$NomMachine' and is_deleted=0"
    # Requête passée sur l'entrée standard : Windows PowerShell 5.1 abîme les guillemets des arguments.
    $n = $requete | & docker exec -i $db sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" glpi -N'
    return ([int]($n | Select-Object -Last 1)) -gt 0
}
function Test-PareFeu {
    param([hashtable]$Vm)
    if (Test-NetConnection -ComputerName $Vm.Ip -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) { Write-LabOk "pfSense répond sur https://$($Vm.Ip)/."; return $true }
    Write-LabAvert "pfSense ne répond pas sur https://$($Vm.Ip)/ : installation manuelle à faire (docs/vm.md)."
    return $false
}

Write-LabEtape 'Instance GLPI du labo'
Enable-InventaireGlpi

foreach ($vm in (Get-LabVmListe -Config $config -Noms $Nom)) {
    Write-LabEtape "$($vm.Nom) (VM $($vm.VmId), $($vm.Role))"
    $pve = Get-LabPveVm -Config $config -VmId $vm.VmId
    if (-not $pve) { Write-LabAvert 'VM absente : lancez vm\30-creer-vm.ps1.'; continue }
    try {
        if ($pve.status -ne 'running') {
            Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$($vm.VmId)/status/start")
            if ($vm.Role -in 'ad', 'poste-windows') { Wait-Agent -Vm $vm } else { Start-Sleep -Seconds 60 }
        } elseif ($vm.Role -in 'ad', 'poste-windows' -and -not (Test-LabPveAgent -Config $config -VmId $vm.VmId)) {
            Write-LabInfo 'Attente de l''agent invité (démarrage en cours)...'
            Wait-Agent -Vm $vm -Minutes 60
        }
        $pret = $true
        switch ($vm.Role) {
            'pare-feu' { $pret = Test-PareFeu -Vm $vm }
            'ad' { Set-Ad -Vm $vm }
            'poste-windows' { Set-PosteWindows -Vm $vm }
            'poste-ubuntu' { Set-PosteUbuntu -Vm $vm }
        }
        if ($pret) {
            Set-LabEtat -Config $config -Nom $vm.Nom -Valeurs @{ Configure = $true; ConfigureLe = (Get-Date -Format s) }
            Set-InstantanePropre -Vm $vm
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
    Write-LabInfo "Serveur        : ldaps://$($vmAd.NomMachine).$($domaine.Nom) port 636 ($($vmAd.Ip))"
    Write-LabInfo "BaseDN         : $($domaine.BaseDn)"
    Write-LabInfo "DN de connexion: svc-glpi-ldap@$($domaine.Nom) (mot de passe : CompteLdapGlpi dans secrets.json)"
}
