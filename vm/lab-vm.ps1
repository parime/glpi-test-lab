<#
.SYNOPSIS
    Pilotage des VM Hyper-V du labo : up, down, status, reset, et cycle de vie des évaluations.

.DESCRIPTION
    Sans droits administrateur (membre d'« Administrateurs Hyper-V »).

    lab-vm.ps1 up [vm...]           démarre les VM (toutes par défaut), pfSense puis AD puis postes
    lab-vm.ps1 down [vm...]         arrête proprement les VM (ordre inverse)
    lab-vm.ps1 status [vm...]       état, mémoire, point de contrôle, fin d'évaluation
    lab-vm.ps1 reset <vm...>        revient au point de contrôle « propre » (état connu)
    lab-vm.ps1 installer [vm...]    crée, installe et configure (20-creer-vm.ps1 puis 30-configurer.ps1)
    lab-vm.ps1 reinstaller <vm...>  supprime puis réinstalle (réinstaller l'AD réinstalle aussi
                                    Windows 11, dont la jonction au domaine serait perdue)
    lab-vm.ps1 renouveler [vm...]   réinstalle les évaluations qui expirent dans moins de
                                    Renouvellement.SeuilJours jours (vms.psd1)
    lab-vm.ps1 planifier            tâche planifiée quotidienne « renouveler » (compte courant)
    lab-vm.ps1 deplanifier          retire cette tâche
    lab-vm.ps1 supprimer <vm...>    supprime la VM et ses fichiers (-Force : sans confirmation)

    Durée d'évaluation : Windows Server 2025, 180 jours ; Windows 11 Entreprise, 90 jours
    (Centre d'évaluation Microsoft). La date de fin vient de la licence de l'invité quand la VM
    tourne (SoftwareLicensingProduct.GracePeriodRemaining), sinon de la date d'installation.

.EXAMPLE
    .\vm\lab-vm.ps1 status
.EXAMPLE
    .\vm\lab-vm.ps1 reset lab-win11
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory)]
    [ValidateSet('up', 'down', 'status', 'reset', 'installer', 'reinstaller', 'renouveler', 'planifier', 'deplanifier', 'supprimer')]
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
if ($SeuilJours -lt 0) { $SeuilJours = [int]$config.Renouvellement.SeuilJours }
$nomTache = 'glpi-test-lab - renouvellement des VM'

function Get-JoursRestants {
    # Jours d'évaluation restants : licence de l'invité si la VM tourne, sinon date d'installation.
    param([hashtable]$VmConfig, [hashtable]$Etat)
    $jours = 0
    if ($Etat -and $Etat.ContainsKey('EvaluationJours')) { $jours = [int]$Etat.EvaluationJours }
    if ($jours -le 0) { return $null }
    $source = 'installation'
    $restants = $null
    $hv = Get-VM -Name $VmConfig.Nom -ErrorAction SilentlyContinue
    if ($hv -and $hv.State -eq 'Running' -and $VmConfig.Role -in @('ad', 'poste-windows')) {
        try {
            $secrets = Get-LabSecrets -Config $config
            $utilisateur = if ($VmConfig.Role -eq 'ad') { "$($config.Domaine.NetBios)\Administrator" } else { "$($VmConfig.NomMachine)\labadmin" }
            $cred = Get-LabCredential -Utilisateur $utilisateur -MotDePasse $secrets.AdminWindows
            $minutes = Invoke-Command -VMName $VmConfig.Nom -Credential $cred -ErrorAction Stop -ScriptBlock {
                # ApplicationId de Windows : 55c92734-d682-4d71-983e-d6ec3f16059f
                (Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
                    Select-Object -First 1).GracePeriodRemaining
            }
            if ($minutes -gt 0) { $restants = [math]::Floor($minutes / 1440); $source = 'licence' }
        } catch { Write-Verbose "Licence de l'invité illisible : $($_.Exception.Message)" }
    }
    if ($null -eq $restants -and $Etat.InstalleLe) {
        $fin = ([datetime]$Etat.InstalleLe).AddDays($jours)
        $restants = [math]::Floor(($fin - (Get-Date)).TotalDays)
    }
    return [pscustomobject]@{ Jours = $restants; Source = $source }
}

function Remove-LabVm {
    param([hashtable]$VmConfig)
    $machines = Get-LabChemin -Config $config -Type machines
    $hv = Get-VM -Name $VmConfig.Nom -ErrorAction SilentlyContinue
    if ($hv) {
        if ($hv.State -ne 'Off') { Stop-VM -Name $VmConfig.Nom -TurnOff -Force }
        Remove-VM -Name $VmConfig.Nom -Force
    }
    $dossier = Join-Path $machines $VmConfig.Nom
    # Garde-fou : ne supprimer que sous <Racine>\machines.
    if ((Test-Path $dossier) -and ([IO.Path]::GetFullPath($dossier)).StartsWith([IO.Path]::GetFullPath($machines) + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -Path $dossier -Recurse -Force
    }
    Remove-LabEtat -Config $config -Nom $VmConfig.Nom
    Write-LabOk "$($VmConfig.Nom) supprimée (VM, disque, points de contrôle)."
}

function Invoke-Installation {
    param([string[]]$Noms)
    & (Join-Path $PSScriptRoot '20-creer-vm.ps1') -Nom $Noms
    & (Join-Path $PSScriptRoot '30-configurer.ps1') -Nom $Noms
}

function Invoke-Reinstallation {
    param([object[]]$Liste)
    $noms = New-Object System.Collections.Generic.List[string]
    foreach ($v in $Liste) { if (-not $noms.Contains($v.Nom)) { $noms.Add($v.Nom) } }
    if ($Liste | Where-Object { $_.Role -eq 'ad' }) {
        foreach ($p in ($config.Vm | Where-Object { $_.Role -eq 'poste-windows' })) {
            if (-not $noms.Contains($p.Nom)) { $noms.Add($p.Nom); Write-LabInfo "$($p.Nom) sera réinstallée aussi (nouveau domaine)." }
        }
    }
    $complete = Get-LabVmListe -Config $config -Noms $noms.ToArray()
    if (-not $Force) {
        $reponse = Read-Host "Réinstaller $($noms -join ', ') ? Tout leur contenu sera perdu (o/N)"
        if ($reponse -notmatch '^[oOyY]') { Write-LabInfo 'Abandon.'; return }
    }
    foreach ($v in $complete) { Remove-LabVm -VmConfig $v }
    Invoke-Installation -Noms $noms.ToArray()
}

if ($Commande -notin @('planifier', 'deplanifier')) { Assert-LabAccesHyperV }
$liste = Get-LabVmListe -Config $config -Noms $Vm

switch ($Commande) {
    'up' {
        foreach ($v in $liste) {
            $hv = Get-VM -Name $v.Nom -ErrorAction SilentlyContinue
            if (-not $hv) { Write-LabAvert "$($v.Nom) n'existe pas (lab-vm.ps1 installer $($v.Nom))."; continue }
            if ($hv.State -eq 'Running') { Write-LabInfo "$($v.Nom) tourne déjà."; continue }
            Start-VM -Name $v.Nom
            Write-LabOk "$($v.Nom) démarrée."
            # Laisser la passerelle et l'annuaire démarrer avant les postes.
            if ($v.Role -in @('pare-feu', 'ad') -and $liste.Count -gt 1) { Start-Sleep -Seconds 45 }
        }
    }
    'down' {
        [array]::Reverse($liste)
        foreach ($v in $liste) {
            $hv = Get-VM -Name $v.Nom -ErrorAction SilentlyContinue
            if (-not $hv -or $hv.State -eq 'Off') { continue }
            try { Stop-VM -Name $v.Nom -ErrorAction Stop } catch { Write-LabAvert "Arrêt propre refusé par $($v.Nom) : extinction forcée."; Stop-VM -Name $v.Nom -TurnOff -Force }
            Write-LabOk "$($v.Nom) arrêtée."
        }
    }
    'status' {
        $etat = Get-LabEtat -Config $config
        $lignes = foreach ($v in $liste) {
            $hv = Get-VM -Name $v.Nom -ErrorAction SilentlyContinue
            $e = $null; if ($etat.ContainsKey($v.Nom)) { $e = $etat[$v.Nom] }
            $memConf = if ($v.MemoireDynamique) { "$($v.MemoireMinMo)-$($v.MemoireMaxMo)" } else { "$($v.MemoireDemarrageMo)" }
            $restant = $null; if ($e) { $restant = Get-JoursRestants -VmConfig $v -Etat $e }
            [pscustomobject]@{
                VM              = $v.Nom
                Role            = $v.Role
                Etat            = if ($hv) { [string]$hv.State } else { 'absente' }
                'Mo utilises'   = if ($hv) { [math]::Round($hv.MemoryAssigned / 1MB) } else { 0 }
                'Mo prevus'     = $memConf
                IP              = $v.Ip
                Propre          = if ($hv -and (Get-VMSnapshot -VMName $v.Nom -Name $config.PointDeControle -ErrorAction SilentlyContinue)) { 'oui' } else { 'non' }
                Installee       = if ($e -and $e.ContainsKey('InstalleLe')) { ([datetime]$e.InstalleLe).ToString('dd/MM/yyyy') } else { '' }
                'Eval. restante' = if ($restant -and $null -ne $restant.Jours) { "$($restant.Jours) j ($($restant.Source))" } else { '' }
            }
        }
        $lignes | Format-Table -AutoSize
        $total = ($lignes | Measure-Object -Property 'Mo utilises' -Sum).Sum
        $max = 0; foreach ($v in $liste) { if ($v.MemoireDynamique) { $max += $v.MemoireMaxMo } else { $max += $v.MemoireDemarrageMo } }
        Write-LabInfo "Mémoire utilisée maintenant : $total Mo ; au plus : $max Mo."
    }
    'reset' {
        if (-not $Vm) { throw 'Précisez la ou les VM : lab-vm.ps1 reset <vm>' }
        foreach ($v in $liste) {
            $point = Get-VMSnapshot -VMName $v.Nom -Name $config.PointDeControle -ErrorAction SilentlyContinue
            if (-not $point) { Write-LabAvert "$($v.Nom) : pas de point de contrôle « $($config.PointDeControle) » (30-configurer.ps1 le crée)."; continue }
            Restore-VMSnapshot -VMSnapshot $point -Confirm:$false
            # Le point « propre » est pris VM arrêtée : on redémarre ensuite.
            Start-VM -Name $v.Nom
            Write-LabOk "$($v.Nom) revenue à « $($config.PointDeControle) » ($($point.CreationTime)) et redémarrée."
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
            $r = Get-JoursRestants -VmConfig $v -Etat $etat[$v.Nom]
            if (-not $r -or $null -eq $r.Jours) { continue }
            if ($r.Jours -le $SeuilJours) {
                Write-LabAvert "$($v.Nom) : évaluation à $($r.Jours) jour(s) de la fin ($($r.Source)), seuil $SeuilJours : réinstallation."
                $aRefaire += $v
            } else {
                Write-LabOk "$($v.Nom) : $($r.Jours) jour(s) d'évaluation restants."
            }
        }
        if ($aRefaire) {
            $Force = $true
            Invoke-Reinstallation -Liste $aRefaire
        }
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
        if (Get-ScheduledTask -TaskName $nomTache -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $nomTache -Confirm:$false
            Write-LabOk "Tâche « $nomTache » retirée."
        } else { Write-LabInfo 'Aucune tâche planifiée.' }
    }
    'supprimer' {
        if (-not $Vm) { throw 'Précisez la ou les VM : lab-vm.ps1 supprimer <vm>' }
        if (-not $Force) {
            $reponse = Read-Host "Supprimer $(($liste | ForEach-Object { $_.Nom }) -join ', ') et leurs disques (o/N)"
            if ($reponse -notmatch '^[oOyY]') { Write-LabInfo 'Abandon.'; return }
        }
        foreach ($v in $liste) { Remove-LabVm -VmConfig $v }
    }
}
