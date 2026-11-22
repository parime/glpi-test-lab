<#
.SYNOPSIS
    SEULE étape du labo qui demande les droits administrateur : Hyper-V, commutateurs, NAT,
    pare-feu, groupe « Administrateurs Hyper-V ».

.DESCRIPTION
    À lancer UNE fois, dans une console PowerShell ouverte « en tant qu'administrateur » :

        powershell -ExecutionPolicy Bypass -File F:\Dev\glpi-test-lab-vm\vm\00-prerequis-admin.ps1

    Le script est idempotent : relancé, il ne refait que ce qui manque et ne casse rien. Il :
      1. vérifie Hyper-V et l'active si besoin (un redémarrage de Windows est alors nécessaire,
         puis relancez le script) ;
      2. vérifie que les réseaux du labo (vms.psd1) ne chevauchent ni les adresses et routes de
         l'hôte, ni les réseaux Docker, ni un réseau NAT existant ;
      3. crée le commutateur interne « lab-interne » (LAN du labo, l'hôte y a une adresse) ;
      4. crée le commutateur interne « lab-nat » et son réseau NAT (sortie Internet du WAN pfSense) ;
      5. ouvre dans le pare-feu de Windows les ports GLPI du labo, depuis les réseaux du labo
         seulement ;
      6. range par défaut les disques et VM Hyper-V sous la racine du labo (rien sur C:) ;
      7. prépare le gardien local « UntrustedGuardian » qui protège le TPM virtuel de Windows 11 ;
      8. ajoute votre compte au groupe « Administrateurs Hyper-V » (SID S-1-5-32-578), pour que
         tous les autres scripts tournent sans élévation ;
      9. avec -CreerVm, crée aussi les VM (20-creer-vm.ps1) dans cette session élevée ;
     10. affiche le bilan.

    Références Microsoft :
    - Activer Hyper-V : https://learn.microsoft.com/windows-server/virtualization/hyper-v/get-started/install-hyper-v
    - Réseau NAT (un seul par hôte) : https://learn.microsoft.com/windows-server/virtualization/hyper-v/setup-nat-network
    - New-VMSwitch : https://learn.microsoft.com/powershell/module/hyper-v/new-vmswitch
    - New-HgsGuardian : https://learn.microsoft.com/powershell/module/hgsclient/new-hgsguardian
    - Groupe Administrateurs Hyper-V (S-1-5-32-578) :
      https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-identifiers

.PARAMETER Utilisateur
    Compte à ajouter au groupe « Administrateurs Hyper-V » (par défaut, le compte qui lance le script).

.PARAMETER SansGroupe
    Ne pas modifier le groupe « Administrateurs Hyper-V ».

.PARAMETER CreerVm
    Créer aussi les VM dans cette session (recommandé : le TPM virtuel de Windows 11 peut exiger
    l'élévation).
#>
[CmdletBinding()]
param(
    [string]$Utilisateur = "$env:USERDOMAIN\$env:USERNAME",
    [switch]$SansGroupe,
    [switch]$CreerVm
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\LabVm.psm1') -Force
$config = Get-LabConfig
$fait = New-Object System.Collections.Generic.List[string]
$deja = New-Object System.Collections.Generic.List[string]
$avertissements = New-Object System.Collections.Generic.List[string]

function Show-Bilan {
    Write-LabEtape 'Bilan'
    foreach ($l in $fait) { Write-LabOk "fait : $l" }
    foreach ($l in $deja) { Write-LabInfo "déjà en place : $l" }
    foreach ($l in $avertissements) { Write-LabAvert $l }
}

if (-not (Test-LabAdministrateur)) {
    Write-LabErreur 'Ce script doit être lancé dans une console PowerShell ouverte « en tant qu''administrateur ».'
    Write-LabInfo 'Menu Démarrer > PowerShell > clic droit > Exécuter en tant qu''administrateur, puis :'
    Write-LabInfo "powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit 1
}

# --- 1. Hyper-V --------------------------------------------------------------------------------
Write-LabEtape 'Hyper-V'
$edition = (Get-CimInstance Win32_OperatingSystem).Caption
$fonction = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All'
if (-not $fonction) {
    Write-LabErreur "Hyper-V n'existe pas sur cette édition ($edition) : Windows Pro, Entreprise ou Éducation requis."
    exit 1
}
if ($fonction.State -ne 'Enabled') {
    Write-LabInfo "Activation de Hyper-V ($edition)..."
    $r = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V' -All -NoRestart
    $fait.Add('Hyper-V activé')
    if ($r.RestartNeeded) {
        $avertissements.Add('REDÉMARRAGE DE WINDOWS NÉCESSAIRE : redémarrez, puis relancez ce même script pour la suite.')
        Show-Bilan
        exit 0
    }
} else {
    $deja.Add('Hyper-V activé')
}
Import-Module Hyper-V
if ((Get-Service vmms).Status -ne 'Running') { Start-Service vmms }

# --- 2. Vérification des plages d'adresses -------------------------------------------------------
function ConvertTo-Plage {
    param([string]$Cidr)
    $ip, $long = $Cidr.Split('/')
    $o = ([System.Net.IPAddress]::Parse($ip)).GetAddressBytes()
    [Array]::Reverse($o)
    $n = [BitConverter]::ToUInt32($o, 0)
    $masque = if ([int]$long -eq 0) { [uint32]0 } else { [uint32]([math]::Pow(2, 32) - [math]::Pow(2, 32 - [int]$long)) }
    $debut = $n -band $masque
    $fin = $debut + [uint32]([math]::Pow(2, 32 - [int]$long) - 1)
    return @($debut, $fin)
}
function Test-Chevauchement {
    param([string]$A, [string]$B)
    $pa = ConvertTo-Plage $A; $pb = ConvertTo-Plage $B
    return ($pa[0] -le $pb[1]) -and ($pb[0] -le $pa[1])
}

Write-LabEtape 'Plages d''adresses du labo'
$nat = $config.Reseau.Nat
$interne = $config.Reseau.Interne
$nosAdaptateurs = @("vEthernet ($($nat.Commutateur))", "vEthernet ($($interne.Commutateur))")
$occupes = New-Object System.Collections.Generic.List[object]
foreach ($a in Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $nosAdaptateurs -notcontains $_.InterfaceAlias -and $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' }) {
    $occupes.Add([pscustomobject]@{ Prefixe = "$($a.IPAddress)/$($a.PrefixLength)"; Source = "adresse de l'hôte ($($a.InterfaceAlias))" })
}
foreach ($r in Get-NetRoute -AddressFamily IPv4 | Where-Object { $nosAdaptateurs -notcontains $_.InterfaceAlias }) {
    $long = [int]($r.DestinationPrefix.Split('/')[1])
    if ($long -ge 8 -and $long -le 30 -and $r.DestinationPrefix -notlike '169.254.*' -and $r.DestinationPrefix -notlike '127.*' -and $r.DestinationPrefix -notlike '224.*') {
        $occupes.Add([pscustomobject]@{ Prefixe = $r.DestinationPrefix; Source = "route de l'hôte ($($r.InterfaceAlias))" })
    }
}
$docker = Get-Command docker -ErrorAction SilentlyContinue
if ($docker) {
    try {
        $ids = & docker network ls -q 2>$null
        if ($LASTEXITCODE -eq 0 -and $ids) {
            foreach ($ligne in (& docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' $ids 2>$null)) {
                $parts = $ligne.Trim() -split '\s+'
                foreach ($s in ($parts | Select-Object -Skip 1)) {
                    if ($s -match '^\d+\.\d+\.\d+\.\d+/\d+$') { $occupes.Add([pscustomobject]@{ Prefixe = $s; Source = "réseau Docker $($parts[0])" }) }
                }
            }
            # Réserve d'adresses de Docker Swarm (réseaux overlay créés plus tard).
            $info = & docker info --format '{{range .Swarm.Cluster.DefaultAddrPool}}{{.}} {{end}}' 2>$null
            foreach ($s in (($info -join ' ') -split '\s+')) {
                if ($s -match '^\d+\.\d+\.\d+\.\d+/\d+$') { $occupes.Add([pscustomobject]@{ Prefixe = $s; Source = 'réserve Docker Swarm' }) }
            }
        } else {
            $avertissements.Add('Docker ne répond pas : réseaux Docker non vérifiés (relancez le script avec Docker Desktop démarré).')
        }
    } catch {
        $avertissements.Add("Docker non interrogé : $($_.Exception.Message)")
    }
} else {
    $avertissements.Add('Commande docker absente : réseaux Docker non vérifiés.')
}
$conflits = @()
foreach ($plage in @($nat.Prefixe, $interne.Prefixe)) {
    foreach ($o in $occupes) {
        if (Test-Chevauchement $plage $o.Prefixe) { $conflits += "$plage chevauche $($o.Prefixe) ($($o.Source))" }
    }
}
if ($conflits) {
    Write-LabErreur 'Conflit d''adresses : choisissez d''autres plages dans vm\vms.local.psd1 (clé Reseau), puis relancez.'
    $conflits | ForEach-Object { Write-LabInfo $_ }
    exit 1
}
Write-LabOk "$($nat.Prefixe) et $($interne.Prefixe) libres ($($occupes.Count) plages de l'hôte et de Docker comparées)."

# --- 3 et 4. Commutateurs -------------------------------------------------------------------------
function Set-CommutateurInterne {
    param([string]$Nom, [string]$IpHote, [int]$Longueur)
    if (-not (Get-VMSwitch -Name $Nom -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $Nom -SwitchType Internal | Out-Null
        $fait.Add("commutateur interne $Nom")
    } else {
        $deja.Add("commutateur $Nom")
    }
    $alias = "vEthernet ($Nom)"
    $adaptateur = $null
    for ($i = 0; $i -lt 10 -and -not $adaptateur; $i++) {
        $adaptateur = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
        if (-not $adaptateur) { Start-Sleep -Seconds 2 }
    }
    if (-not $adaptateur) { throw "Carte $alias introuvable après création du commutateur." }
    $actuelle = Get-NetIPAddress -InterfaceIndex $adaptateur.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq $IpHote }
    if (-not $actuelle) {
        New-NetIPAddress -InterfaceIndex $adaptateur.ifIndex -IPAddress $IpHote -PrefixLength $Longueur | Out-Null
        $fait.Add("adresse $IpHote/$Longueur sur $alias")
    } else {
        $deja.Add("adresse $IpHote sur $alias")
    }
}

Write-LabEtape "Commutateur $($interne.Commutateur) (LAN du labo)"
Set-CommutateurInterne -Nom $interne.Commutateur -IpHote $interne.IpHote -Longueur ([int]$interne.Prefixe.Split('/')[1])

Write-LabEtape "Commutateur $($nat.Commutateur) et réseau NAT"
Set-CommutateurInterne -Nom $nat.Commutateur -IpHote $nat.IpHote -Longueur ([int]$nat.Prefixe.Split('/')[1])
$natsExistants = @(Get-NetNat -ErrorAction SilentlyContinue)
$notreNat = $natsExistants | Where-Object { $_.Name -eq $nat.NomNat }
if ($notreNat) {
    if ($notreNat.InternalIPInterfaceAddressPrefix -ne $nat.Prefixe) {
        $avertissements.Add("Le NAT $($nat.NomNat) existe avec le préfixe $($notreNat.InternalIPInterfaceAddressPrefix) au lieu de $($nat.Prefixe) : supprimez-le (Remove-NetNat -Name $($nat.NomNat)) puis relancez.")
    } else {
        $deja.Add("NAT $($nat.NomNat) ($($nat.Prefixe))")
    }
} elseif ($natsExistants.Count -gt 0) {
    $autres = ($natsExistants | ForEach-Object { "$($_.Name) ($($_.InternalIPInterfaceAddressPrefix))" }) -join ', '
    $avertissements.Add("Un réseau NAT existe déjà ($autres) et Windows n'en accepte qu'un : le NAT du labo n'est PAS créé. Le WAN de pfSense n'aura pas Internet tant que ce NAT existe. Voir docs/vm.md, « Un autre réseau NAT existe déjà ».")
} else {
    New-NetNat -Name $nat.NomNat -InternalIPInterfaceAddressPrefix $nat.Prefixe | Out-Null
    $fait.Add("NAT $($nat.NomNat) ($($nat.Prefixe))")
}

# --- 5. Pare-feu ----------------------------------------------------------------------------------
Write-LabEtape 'Pare-feu de Windows : GLPI joignable depuis les VM'
$regle = 'glpi-test-lab-vm-glpi'
$distantes = @($interne.Prefixe, $nat.Prefixe)
$existante = Get-NetFirewallRule -Name $regle -ErrorAction SilentlyContinue
if (-not $existante) {
    New-NetFirewallRule -Name $regle -DisplayName 'glpi-test-lab : GLPI depuis les VM du labo' -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort $config.Reseau.PortsGlpi -RemoteAddress $distantes -Profile Any | Out-Null
    $fait.Add("règle de pare-feu $regle (TCP $($config.Reseau.PortsGlpi) depuis $($distantes -join ', '))")
} else {
    Set-NetFirewallRule -Name $regle -RemoteAddress $distantes -LocalPort $config.Reseau.PortsGlpi -Protocol TCP | Out-Null
    $deja.Add("règle de pare-feu $regle")
}

# --- 6. Emplacements par défaut de Hyper-V -------------------------------------------------------
Write-LabEtape 'Emplacements par défaut de Hyper-V'
$machines = Get-LabChemin -Config $config -Type machines
$hote = Get-VMHost
if ($hote.VirtualMachinePath -ne $machines -or $hote.VirtualHardDiskPath -ne $machines) {
    Set-VMHost -VirtualMachinePath $machines -VirtualHardDiskPath $machines
    $fait.Add("VM et disques Hyper-V par défaut dans $machines (au lieu de $($hote.VirtualHardDiskPath))")
} else {
    $deja.Add("emplacements Hyper-V dans $machines")
}

# --- 7. Gardien local du TPM virtuel -------------------------------------------------------------
Write-LabEtape 'Gardien local du TPM virtuel (Windows 11)'
if (Get-Command Get-HgsGuardian -ErrorAction SilentlyContinue) {
    if (-not (Get-HgsGuardian -Name 'UntrustedGuardian' -ErrorAction SilentlyContinue)) {
        New-HgsGuardian -Name 'UntrustedGuardian' -GenerateCertificates | Out-Null
        $fait.Add('gardien local UntrustedGuardian (certificats dans le magasin de l''ordinateur)')
    } else {
        $deja.Add('gardien local UntrustedGuardian')
    }
} else {
    $avertissements.Add('Module HgsClient absent : le TPM virtuel sera préparé par Set-VMKeyProtector à la création de la VM.')
}

# --- 8. Groupe Administrateurs Hyper-V -----------------------------------------------------------
Write-LabEtape 'Groupe « Administrateurs Hyper-V »'
if (-not $SansGroupe) {
    $groupe = Get-LocalGroup -SID 'S-1-5-32-578'
    $membres = @(Get-LocalGroupMember -SID 'S-1-5-32-578' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    if ($membres -contains $Utilisateur) {
        $deja.Add("$Utilisateur membre de « $($groupe.Name) »")
    } else {
        try {
            Add-LocalGroupMember -SID 'S-1-5-32-578' -Member $Utilisateur
            $fait.Add("$Utilisateur ajouté à « $($groupe.Name) »")
            $avertissements.Add('FERMEZ PUIS ROUVREZ VOTRE SESSION WINDOWS pour que l''appartenance au groupe « Administrateurs Hyper-V » soit prise en compte.')
        } catch [Microsoft.PowerShell.Commands.MemberExistsException] {
            $deja.Add("$Utilisateur membre de « $($groupe.Name) »")
        }
    }
} else {
    $deja.Add('groupe « Administrateurs Hyper-V » non modifié (-SansGroupe)')
}

# --- 9. Création des VM (facultatif) --------------------------------------------------------------
if ($CreerVm) {
    Write-LabEtape 'Création des VM (20-creer-vm.ps1)'
    & (Join-Path $PSScriptRoot '20-creer-vm.ps1')
    $fait.Add('VM créées (voir le détail ci-dessus)')
}

Show-Bilan
Write-LabEtape 'Suite (sans droits administrateur, dans une session ordinaire)'
Write-LabInfo '1. .\vm\10-telecharger-iso.ps1     (si ce n''est pas déjà fait)'
if (-not $CreerVm) { Write-LabInfo '2. .\vm\20-creer-vm.ps1' }
Write-LabInfo '3. Installer pfSense (étapes manuelles, docs/vm.md), puis .\vm\30-configurer.ps1'
