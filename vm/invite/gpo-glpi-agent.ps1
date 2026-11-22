<#
.SYNOPSIS
    Déploiement de GLPI Agent par GPO (exécuté SUR le contrôleur de domaine, par
    vm\40-configurer.ps1, avec un compte Admins du domaine). Relançable sans doublon.

.DESCRIPTION
    - Copie le MSI officiel (version épinglée) dans NETLOGON : \\<domaine>\NETLOGON\glpi-agent\.
    - Écrit un script de démarrage installer-glpi-agent.cmd qui lance msiexec avec SERVER, TAG,
      RUNNOW et les autres propriétés documentées du MSI, seulement si l'agent est absent (clé de
      registre HKLM\SOFTWARE\GLPI-Agent, où le MSI range sa configuration).
    - Crée la GPO « Labo - GLPI Agent » avec ce script de démarrage de l'ordinateur et la lie à
      l'OU des postes. Une GPO d'« installation de logiciel » ne permet pas de passer ces
      propriétés au MSI sans transformation (.mst) : d'où le script de démarrage.

    Références :
    - Propriétés du MSI de GLPI Agent :
      https://glpi-agent.readthedocs.io/en/latest/installation/windows-command-line.html
    - Configuration de l'agent dans le registre :
      https://glpi-agent.readthedocs.io/en/latest/configuration.html
    - Cmdlets GroupPolicy (New-GPO, New-GPLink) : https://learn.microsoft.com/powershell/module/grouppolicy/
    - Format de scripts.ini et extensions côté client des scripts ([MS-GPSCR]) :
      https://learn.microsoft.com/openspecs/windows_protocols/ms-gpscr/
    - Attribut gPCMachineExtensionNames et version des GPO ([MS-GPOL]) :
      https://learn.microsoft.com/openspecs/windows_protocols/ms-gpol/
#>
param(
    [Parameter(Mandatory)][string]$DossierSource,
    [Parameter(Mandatory)][string]$Msi,
    [Parameter(Mandatory)][string]$Url,
    [Parameter(Mandatory)][string]$Tag,
    [Parameter(Mandatory)][string]$AddLocal,
    [Parameter(Mandatory)][string]$OuPostes,
    [string]$NomGpo = 'Labo - GLPI Agent'
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
Import-Module GroupPolicy
$domaine = Get-ADDomain
$dns = $domaine.DNSRoot
$sortie = @()

# 1. MSI et script dans NETLOGON (dossier « scripts » de SYSVOL).
$netlogon = Join-Path $env:SystemRoot "SYSVOL\sysvol\$dns\scripts\glpi-agent"
New-Item -ItemType Directory -Force -Path $netlogon | Out-Null
$cible = Join-Path $netlogon $Msi
$source = Join-Path $DossierSource $Msi
if (-not (Test-Path $cible) -or (Get-FileHash $cible).Hash -ne (Get-FileHash $source).Hash) {
    Copy-Item $source $cible -Force
    $sortie += "MSI copié dans \\$dns\NETLOGON\glpi-agent"
}
$unc = "\\$dns\NETLOGON\glpi-agent"
$cmd = @"
@echo off
rem Script de démarrage de la GPO « $NomGpo » (glpi-test-lab, lot #5).
rem Installe GLPI Agent s'il est absent ; propriétés documentées du MSI :
rem https://glpi-agent.readthedocs.io/en/latest/installation/windows-command-line.html
reg query "HKLM\SOFTWARE\GLPI-Agent" >nul 2>&1 && exit /b 0
msiexec /i "$unc\$Msi" /quiet SERVER="$Url" TAG="$Tag" RUNNOW=1 ADD_FIREWALL_EXCEPTION=1 EXECMODE=1 ADDLOCAL=$AddLocal /l*v "%SystemRoot%\Temp\glpi-agent-gpo.log"
"@
Set-Content -Path (Join-Path $netlogon 'installer-glpi-agent.cmd') -Value $cmd -Encoding ASCII

# 2. GPO avec script de démarrage.
$gpo = Get-GPO -Name $NomGpo -ErrorAction SilentlyContinue
if (-not $gpo) {
    $gpo = New-GPO -Name $NomGpo -Comment 'glpi-test-lab : installation de GLPI Agent au démarrage des postes'
    $sortie += "GPO « $NomGpo » créée"
}
$dossierGpo = Join-Path $env:SystemRoot "SYSVOL\sysvol\$dns\Policies\{$($gpo.Id)}"
$dossierScripts = Join-Path $dossierGpo 'Machine\Scripts'
New-Item -ItemType Directory -Force -Path (Join-Path $dossierScripts 'Startup') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $dossierScripts 'Shutdown') | Out-Null
$ini = "`r`n[Startup]`r`n0CmdLine=$unc\installer-glpi-agent.cmd`r`n0Parameters=`r`n"
$fichierIni = Join-Path $dossierScripts 'scripts.ini'
$actuel = if (Test-Path $fichierIni) { [IO.File]::ReadAllText($fichierIni) } else { '' }
if ($actuel -ne $ini) {
    if (Test-Path $fichierIni) { (Get-Item $fichierIni -Force).Attributes = 'Normal' }
    [IO.File]::WriteAllText($fichierIni, $ini, [Text.Encoding]::Unicode)
    (Get-Item $fichierIni -Force).Attributes = 'Hidden'

    # Extensions côté client « Scripts » déclarées sur l'objet GPO, et version incrémentée
    # (partie ordinateur = 16 bits de poids faible) dans l'annuaire et dans GPT.INI.
    $dnGpo = "CN={$($gpo.Id)},CN=Policies,CN=System,$($domaine.DistinguishedName)"
    $objet = Get-ADObject -Identity $dnGpo -Properties versionNumber, gPCMachineExtensionNames
    $extensions = '[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]'
    $version = [int]$objet.versionNumber + 1
    Set-ADObject -Identity $dnGpo -Replace @{ gPCMachineExtensionNames = $extensions; versionNumber = $version }
    Set-Content -Path (Join-Path $dossierGpo 'GPT.INI') -Value "[General]`r`nVersion=$version" -Encoding ASCII
    $sortie += "script de démarrage déclaré (version $version)"
}

# 3. Lien vers l'OU des postes.
$liens = (Get-GPInheritance -Target $OuPostes).GpoLinks | Where-Object { $_.DisplayName -eq $NomGpo }
if (-not $liens) {
    New-GPLink -Name $NomGpo -Target $OuPostes -LinkEnabled Yes | Out-Null
    $sortie += "GPO liée à $OuPostes"
}
if (-not $sortie) { $sortie = @('GPO déjà en place') }
$sortie -join ' ; '
