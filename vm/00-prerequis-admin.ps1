<#
.SYNOPSIS
    Seule étape qui demande les droits administrateur, et seulement sur un PC neuf : activer
    Hyper-V et mettre le compte dans le groupe « Administrateurs Hyper-V ».

.DESCRIPTION
    Sur le PC du mainteneur, c'est DÉJÀ FAIT (Hyper-V actif, compte membre du groupe) : ce script
    n'a pas à être lancé. Tout le reste (commutateur interne, VM Proxmox avec virtualisation
    imbriquée, VM du labo) se fait sans élévation.

    À lancer dans une console PowerShell ouverte « en tant qu'administrateur » :

        powershell -ExecutionPolicy Bypass -File <dépôt>\vm\00-prerequis-admin.ps1

    Idempotent. Après un ajout au groupe, fermer puis rouvrir la session Windows.

    Références :
    - Activer Hyper-V : https://learn.microsoft.com/windows-server/virtualization/hyper-v/get-started/install-hyper-v
    - Groupe « Administrateurs Hyper-V » (SID S-1-5-32-578) :
      https://learn.microsoft.com/windows-server/identity/ad-ds/manage/understand-security-identifiers
#>
[CmdletBinding()]
param([string]$Utilisateur = "$env:USERDOMAIN\$env:USERNAME")

$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Lancez ce script dans une console PowerShell « en tant qu''administrateur ».' -ForegroundColor Red
    exit 1
}

$fonction = Get-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V-All'
if (-not $fonction) { Write-Host 'Hyper-V n''existe pas sur cette édition de Windows (Pro, Entreprise ou Éducation requis).' -ForegroundColor Red; exit 1 }
if ($fonction.State -ne 'Enabled') {
    $r = Enable-WindowsOptionalFeature -Online -FeatureName 'Microsoft-Hyper-V' -All -NoRestart
    Write-Host '[fait] Hyper-V activé.' -ForegroundColor Green
    if ($r.RestartNeeded) { Write-Host 'REDÉMARREZ WINDOWS, puis relancez ce script.' -ForegroundColor Yellow }
} else {
    Write-Host '[déjà en place] Hyper-V activé.'
}

$membres = @(Get-LocalGroupMember -SID 'S-1-5-32-578' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
if ($membres -contains $Utilisateur) {
    Write-Host "[déjà en place] $Utilisateur membre d'« Administrateurs Hyper-V »."
} else {
    Add-LocalGroupMember -SID 'S-1-5-32-578' -Member $Utilisateur
    Write-Host "[fait] $Utilisateur ajouté à « Administrateurs Hyper-V »." -ForegroundColor Green
    Write-Host 'FERMEZ PUIS ROUVREZ VOTRE SESSION WINDOWS avant de lancer les autres scripts.' -ForegroundColor Yellow
}
