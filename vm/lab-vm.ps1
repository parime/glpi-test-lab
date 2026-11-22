<#
.SYNOPSIS
    Pilotage des VM du labo (Proxmox VE et ses VM) : up, down, status, reset, cycle de vie des
    évaluations.

.DESCRIPTION
    Sans droits administrateur. La VM Hyper-V « lab-proxmox » est démarrée ou arrêtée avec le
    module Hyper-V (membre d'« Administrateurs Hyper-V ») ; les VM du labo par l'API de Proxmox.

    lab-vm.ps1 up [vm...]           démarre Proxmox puis les VM (toutes par défaut) : pfSense, AD, postes
    lab-vm.ps1 down [vm...]         arrêt propre des VM (ordre inverse) ; sans nom, Proxmox aussi
    lab-vm.ps1 status [vm...]       état, mémoire, instantané « propre », fin d'évaluation
    lab-vm.ps1 reset <vm...>        retour à l'instantané « propre », puis démarrage
    lab-vm.ps1 installer [vm...]    crée, installe et configure (30-creer-vm.ps1 puis 40-configurer.ps1)
    lab-vm.ps1 reinstaller <vm...>  supprime puis réinstalle (l'AD entraîne les postes joints au domaine)
    lab-vm.ps1 renouveler [vm...]   réinstalle les évaluations qui expirent dans moins de SeuilJours
    lab-vm.ps1 planifier            tâche planifiée quotidienne « renouveler » (compte courant)
    lab-vm.ps1 deplanifier          retire cette tâche
    lab-vm.ps1 modele <vm>          copie complète de la VM (arrêtée) convertie en modèle Proxmox « tpl-<vm> »
    lab-vm.ps1 supprimer <vm...>    supprime la VM et ses disques (-Force : sans confirmation)

    Durées d'évaluation : Windows Server 2025, 180 jours ; Windows 11 Entreprise, 90 jours. Les jours
    restants viennent de la licence de l'invité quand la VM tourne (SoftwareLicensingProduct,
    lu par l'agent invité), sinon de la date d'installation (etat.json).
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('up', 'down', 'status', 'reset', 'installer', 'reinstaller', 'renouveler', 'planifier', 'deplanifier', 'modele', 'supprimer')]
    [string]$Commande,
    [Parameter(Position = 1, ValueFromRemainingArguments)]
    [string[]]$Vm,
    [int]$SeuilJours = -1,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\LabVm.psm1') -Force
Import-Module Hyper-V -ErrorAction SilentlyContinue
$config = Get-LabConfig
$px = $config.Proxmox
$noeud = $px.Noeud
if ($SeuilJours -lt 0) { $SeuilJours = [int]$config.Renouvellement.SeuilJours }
$nomTache = 'glpi-test-lab - renouvellement des VM'

function Test-Api { try { [void](Invoke-LabPve -Config $config -Chemin '/version'); return $true } catch { return $false } }

function Start-Proxmox {
    $hv = Get-VM -Name $px.NomVm -ErrorAction SilentlyContinue
    if (-not $hv) { throw "VM Hyper-V $($px.NomVm) absente : lancez vm\20-proxmox.ps1." }
    if ($hv.State -ne 'Running') { Start-VM -Name $px.NomVm; Write-LabOk "$($px.NomVm) démarrée." }
    $limite = (Get-Date).AddMinutes(10)
    while (-not (Test-Api)) {
        if ((Get-Date) -gt $limite) { throw "API de Proxmox injoignable sur $($px.IpLan):8006." }
        Start-Sleep -Seconds 10
    }
}

function Invoke-Etat {
    param([int]$VmId, [string]$Action, [hashtable]$P = @{})
    Wait-LabPveTache -Config $config -Minutes 10 -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$VmId/status/$Action" -Parametres $P)
}

function Get-JoursRestant {
    param([hashtable]$VmConfig, [hashtable]$Etat, [switch]$SansInvite)
    $jours = 0
    if ($Etat -and $Etat.ContainsKey('EvaluationJours')) { $jours = [int]$Etat.EvaluationJours }
    if ($jours -le 0) { return $null }
    if (-not $SansInvite -and $VmConfig.Role -in @('ad', 'poste-windows') -and (Test-LabPveAgent -Config $config -VmId $VmConfig.VmId)) {
        try {
            $r = Invoke-LabPvePowerShell -Config $config -VmId $VmConfig.VmId -Minutes 2 -Script "(Get-CimInstance SoftwareLicensingProduct -Filter `"ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL`" | Select-Object -First 1).GracePeriodRemaining"
            $minutes = [int](($r.Sortie -replace '\s', ''))
            if ($r.Code -eq 0 -and $minutes -gt 0) { return [pscustomobject]@{ Jours = [math]::Floor($minutes / 1440); Source = 'licence' } }
        } catch { Write-Verbose "Licence illisible : $($_.Exception.Message)" }
    }
    if ($Etat.ContainsKey('InstalleLe')) {
        $fin = ([datetime]$Etat.InstalleLe).AddDays($jours)
        return [pscustomobject]@{ Jours = [math]::Floor(($fin - (Get-Date)).TotalDays); Source = 'installation' }
    }
    return $null
}

function Remove-PveVm {
    param([hashtable]$VmConfig)
    $pve = Get-LabPveVm -Config $config -VmId $VmConfig.VmId
    if ($pve) {
        if ($pve.status -ne 'stopped') { Invoke-Etat -VmId $VmConfig.VmId -Action 'stop' }
        Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode DELETE -Chemin "/nodes/$noeud/qemu/$($VmConfig.VmId)" -Parametres @{ purge = 1; 'destroy-unreferenced-disks' = 1 })
    }
    Remove-LabEtat -Config $config -Nom $VmConfig.Nom
    Write-LabOk "$($VmConfig.Nom) supprimée (VM, disques, instantanés)."
}

function Invoke-Installation {
    param([string[]]$Noms)
    & (Join-Path $PSScriptRoot '30-creer-vm.ps1') -Nom $Noms
    & (Join-Path $PSScriptRoot '40-configurer.ps1') -Nom $Noms
}

function Invoke-Reinstallation {
    param([object[]]$Liste)
    $noms = New-Object System.Collections.Generic.List[string]
    foreach ($v in $Liste) { if (-not $noms.Contains($v.Nom)) { $noms.Add($v.Nom) } }
    if ($Liste | Where-Object { $_.Role -eq 'ad' }) {
        foreach ($p in ($config.Vm | Where-Object { $_.Role -in @('poste-windows', 'poste-ubuntu') })) {
            if (-not $noms.Contains($p.Nom)) { $noms.Add($p.Nom); Write-LabInfo "$($p.Nom) sera réinstallée aussi (nouveau domaine)." }
        }
    }
    if (-not $Force) {
        $reponse = Read-Host "Réinstaller $($noms -join ', ') ? Tout leur contenu sera perdu (o/N)"
        if ($reponse -notmatch '^[oOyY]') { Write-LabInfo 'Abandon.'; return }
    }
    foreach ($v in (Get-LabVmListe -Config $config -Noms $noms.ToArray())) { Remove-PveVm -VmConfig $v }
    Invoke-Installation -Noms $noms.ToArray()
}

function Get-Instantanes {
    param([int]$VmId)
    return @(Invoke-LabPve -Config $config -Chemin "/nodes/$noeud/qemu/$VmId/snapshot" | ForEach-Object { $_.name })
}

$liste = @(Get-LabVmListe -Config $config -Noms $Vm)
if ($Commande -notin @('planifier', 'deplanifier', 'down', 'status')) { Assert-LabAccesHyperV; Start-Proxmox }

switch ($Commande) {
    'up' {
        foreach ($v in $liste) {
            $pve = Get-LabPveVm -Config $config -VmId $v.VmId
            if (-not $pve) { Write-LabAvert "$($v.Nom) n'existe pas (lab-vm.ps1 installer $($v.Nom))."; continue }
            if ($pve.status -eq 'running') { Write-LabInfo "$($v.Nom) tourne déjà."; continue }
            Invoke-Etat -VmId $v.VmId -Action 'start'
            Write-LabOk "$($v.Nom) démarrée."
            if ($v.Role -in @('pare-feu', 'ad') -and $liste.Count -gt 1) { Start-Sleep -Seconds 45 }
        }
    }
    'down' {
        if (Test-Api) {
            [array]::Reverse($liste)
            foreach ($v in $liste) {
                $pve = Get-LabPveVm -Config $config -VmId $v.VmId
                if (-not $pve -or $pve.status -eq 'stopped') { continue }
                try { Invoke-Etat -VmId $v.VmId -Action 'shutdown' -P @{ timeout = 180 } }
                catch { Write-LabAvert "Arrêt propre refusé par $($v.Nom) : arrêt forcé."; Invoke-Etat -VmId $v.VmId -Action 'stop' }
                Write-LabOk "$($v.Nom) arrêtée."
            }
        }
        if (-not $Vm) {
            Assert-LabAccesHyperV
            $hv = Get-VM -Name $px.NomVm -ErrorAction SilentlyContinue
            if ($hv -and $hv.State -ne 'Off') { Stop-VM -Name $px.NomVm; Write-LabOk "$($px.NomVm) arrêtée." }
        }
    }
    'status' {
        Assert-LabAccesHyperV
        $hv = Get-VM -Name $px.NomVm -ErrorAction SilentlyContinue
        $etatHv = if ($hv) { [string]$hv.State } else { 'absente' }
        Write-LabInfo "Proxmox ($($px.NomVm), Hyper-V) : $etatHv, $($px.Processeurs) processeurs, $($px.MemoireMo) Mo statiques, https://$($px.IpLan):8006"
        if (-not (Test-Api)) { Write-LabAvert 'API de Proxmox injoignable : lab-vm.ps1 up'; return }
        $etat = Get-LabEtat -Config $config
        $lignes = foreach ($v in $liste) {
            $pve = Get-LabPveVm -Config $config -VmId $v.VmId
            $e = $null; if ($etat.ContainsKey($v.Nom)) { $e = $etat[$v.Nom] }
            $restant = $null
            if ($e) { $restant = Get-JoursRestant -VmConfig $v -Etat $e -SansInvite:(-not ($pve -and $pve.status -eq 'running')) }
            $propre = 'non'
            if ($pve -and ((Get-Instantanes -VmId $v.VmId) -contains $config.PointDeControle)) { $propre = 'oui' }
            [pscustomobject]@{
                VM               = $v.Nom
                Id               = $v.VmId
                Role             = $v.Role
                Etat             = if ($pve) { $pve.status } else { 'absente' }
                'Mo utilises'    = if ($pve -and $pve.status -eq 'running') { [math]::Round($pve.mem / 1MB) } else { 0 }
                'Mo prevus'      = $v.MemoireMo
                IP               = $v.Ip
                Propre           = $propre
                Installee        = if ($e -and $e.ContainsKey('InstalleLe')) { ([datetime]$e.InstalleLe).ToString('dd/MM/yyyy') } else { '' }
                'Eval. restante' = if ($restant -and $null -ne $restant.Jours) { "$($restant.Jours) j ($($restant.Source))" } else { '' }
            }
        }
        $lignes | Format-Table -AutoSize
        $total = ($liste | ForEach-Object { $_.MemoireMo } | Measure-Object -Sum).Sum
        Write-LabInfo "Mémoire des VM du labo : $total Mo au plus, dans les $($px.MemoireMo) Mo de la VM Proxmox."
    }
    'reset' {
        if (-not $Vm) { throw 'Précisez la ou les VM : lab-vm.ps1 reset <vm>' }
        foreach ($v in $liste) {
            if ((Get-Instantanes -VmId $v.VmId) -notcontains $config.PointDeControle) { Write-LabAvert "$($v.Nom) : pas d'instantané « $($config.PointDeControle) » (40-configurer.ps1 le crée)."; continue }
            Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$($v.VmId)/snapshot/$($config.PointDeControle)/rollback")
            if ((Get-LabPveVm -Config $config -VmId $v.VmId).status -ne 'running') { Invoke-Etat -VmId $v.VmId -Action 'start' }
            Write-LabOk "$($v.Nom) revenue à « $($config.PointDeControle) » et démarrée."
        }
    }
    'installer' { Invoke-Installation -Noms ($liste | ForEach-Object { $_.Nom }) }
    'reinstaller' {
        if (-not $Vm) { throw 'Précisez la ou les VM : lab-vm.ps1 reinstaller <vm>' }
        Invoke-Reinstallation -Liste $liste
    }
    'renouveler' {
        $etat = Get-LabEtat -Config $config
        $aRefaire = @()
        foreach ($v in $liste) {
            if (-not $etat.ContainsKey($v.Nom)) { continue }
            $r = Get-JoursRestant -VmConfig $v -Etat $etat[$v.Nom]
            if (-not $r -or $null -eq $r.Jours) { continue }
            if ($r.Jours -le $SeuilJours) { Write-LabAvert "$($v.Nom) : $($r.Jours) jour(s) restants ($($r.Source)) : réinstallation."; $aRefaire += $v }
            else { Write-LabOk "$($v.Nom) : $($r.Jours) jour(s) d'évaluation restants." }
        }
        if ($aRefaire) { $Force = $true; Invoke-Reinstallation -Liste $aRefaire }
    }
    'planifier' {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" renouveler"
        $declencheur = New-ScheduledTaskTrigger -Daily -At '09:00'
        $reglages = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6)
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $nomTache -Action $action -Trigger $declencheur -Settings $reglages -Principal $principal -Force | Out-Null
        Write-LabOk "Tâche planifiée « $nomTache » : chaque jour à 9 h, quand votre session est ouverte."
    }
    'deplanifier' {
        if (Get-ScheduledTask -TaskName $nomTache -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $nomTache -Confirm:$false; Write-LabOk "Tâche « $nomTache » retirée." }
        else { Write-LabInfo 'Aucune tâche planifiée.' }
    }
    'modele' {
        if ($liste.Count -ne 1 -or -not $Vm) { throw 'Précisez une VM : lab-vm.ps1 modele <vm>' }
        $v = $liste[0]; $idModele = 900 + ($v.VmId % 100)
        if (Get-LabPveVm -Config $config -VmId $idModele) { Write-LabInfo "Le modèle $idModele existe déjà."; return }
        if ((Get-LabPveVm -Config $config -VmId $v.VmId).status -ne 'stopped') { Invoke-Etat -VmId $v.VmId -Action 'shutdown' -P @{ timeout = 180 } }
        Wait-LabPveTache -Config $config -Minutes 60 -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$($v.VmId)/clone" -Parametres @{ newid = $idModele; name = "tpl-$($v.Nom)"; full = 1 })
        Wait-LabPveTache -Config $config -Upid (Invoke-LabPve -Config $config -Methode POST -Chemin "/nodes/$noeud/qemu/$idModele/template")
        Write-LabOk "Modèle tpl-$($v.Nom) (VM $idModele) créé : clonable depuis l'interface ou l'API de Proxmox."
    }
    'supprimer' {
        if (-not $Vm) { throw 'Précisez la ou les VM : lab-vm.ps1 supprimer <vm>' }
        if (-not $Force) {
            $reponse = Read-Host "Supprimer $(($liste | ForEach-Object { $_.Nom }) -join ', ') et leurs disques (o/N)"
            if ($reponse -notmatch '^[oOyY]') { Write-LabInfo 'Abandon.'; return }
        }
        foreach ($v in $liste) { Remove-PveVm -VmConfig $v }
    }
}
