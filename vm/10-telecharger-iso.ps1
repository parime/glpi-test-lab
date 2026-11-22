<#
.SYNOPSIS
    Télécharge les ISO gratuites du labo et GLPI Agent, avec vérification des sommes de contrôle.

.DESCRIPTION
    Aucun droit administrateur requis. Relançable : un fichier déjà présent et vérifié n'est pas
    retéléchargé ; un téléchargement interrompu reprend où il s'était arrêté.

    - Windows Server 2025 (évaluation 180 jours) et Windows 11 Entreprise (évaluation 90 jours) :
      liens directs du Centre d'évaluation Microsoft. Microsoft ne publie pas de somme pour ces ISO :
      la somme est relevée au premier téléchargement dans iso\SHA256SUMS.lab, puis vérifiée aux
      lancements suivants (ou comparée à Sha256 si vms.psd1 le renseigne). Si le lien direct échoue
      (formulaire d'inscription exigé, lien changé), le script affiche la page et le nom de fichier
      attendu, puis attend que vous y déposiez le fichier.
    - Ubuntu Server LTS : SHA256SUMS officiel de releases.ubuntu.com.
    - pfSense CE : fichier .sha256 officiel du miroir Netgate (somme du .gz), puis décompression.
    - GLPI Agent : fichier .sha256 officiel de la publication GitHub et somme épinglée dans vms.psd1.
    - Proxmox VE : SHA256SUMS officiel de enterprise.proxmox.com/iso.
    - Pilotes VirtIO pour Windows (projet Fedora) : pas de somme publiée pour l'ISO (le fichier
      CHECKSUM ne couvre que les RPM) : somme relevée au premier téléchargement, comme pour Microsoft.

.PARAMETER Seulement
    Limite le téléchargement à certaines entrées : WindowsServer2025, Windows11Entreprise,
    UbuntuServer, PfSense, GlpiAgent, Proxmox, VirtIO.

.PARAMETER SansAttente
    Ne pas attendre un dépôt manuel : signaler seulement le fichier manquant.

.EXAMPLE
    .\vm\10-telecharger-iso.ps1
.EXAMPLE
    .\vm\10-telecharger-iso.ps1 -Seulement UbuntuServer,GlpiAgent
#>
[CmdletBinding()]
param(
    [ValidateSet('WindowsServer2025', 'Windows11Entreprise', 'UbuntuServer', 'PfSense', 'GlpiAgent', 'Proxmox', 'VirtIO')]
    [string[]]$Seulement,
    [switch]$SansAttente
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib\LabVm.psm1') -Force
$config = Get-LabConfig
$dossierIso = Get-LabChemin -Config $config -Type iso
$dossierLogiciels = Get-LabChemin -Config $config -Type logiciels
$fichierSommes = Join-Path $dossierIso 'SHA256SUMS.lab'
$bilan = New-Object System.Collections.Generic.List[string]

function Test-Demande { param([string]$Nom) return (-not $Seulement) -or ($Seulement -contains $Nom) }

function Get-SommeRelevee {
    param([string]$Fichier)
    if (-not (Test-Path $fichierSommes)) { return $null }
    foreach ($ligne in Get-Content -Path $fichierSommes) {
        if ($ligne -match '^([0-9a-f]{64})\s+\*?(.+)$' -and $Matches[2] -eq $Fichier) { return $Matches[1] }
    }
    return $null
}

function Save-SommeRelevee {
    param([string]$Fichier, [string]$Somme)
    $lignes = @()
    if (Test-Path $fichierSommes) { $lignes = @(Get-Content -Path $fichierSommes | Where-Object { $_ -notmatch "\s\*?$([regex]::Escape($Fichier))$" }) }
    $lignes += "$Somme *$Fichier"
    Set-Content -Path $fichierSommes -Value $lignes -Encoding ASCII
}

function Wait-DepotManuel {
    param([string]$Chemin, [string]$Page, [string]$Url)
    Write-LabAvert "Téléchargement automatique impossible."
    Write-LabInfo "1. Ouvrez la page officielle : $Page"
    if ($Url) { Write-LabInfo "   (lien direct essayé : $Url)" }
    Write-LabInfo "2. Remplissez le formulaire si la page le demande et téléchargez l'ISO 64 bits."
    Write-LabInfo "3. Enregistrez-la sous ce nom exact : $Chemin"
    if ($SansAttente) { return $false }
    Write-LabInfo "En attente du fichier (Ctrl+C pour abandonner)..."
    $tailleAvant = -1
    while ($true) {
        if (Test-Path $Chemin) {
            $taille = (Get-Item $Chemin).Length
            if ($taille -gt 0 -and $taille -eq $tailleAvant) { return $true }
            $tailleAvant = $taille
        }
        Start-Sleep -Seconds 15
    }
}

function Get-IsoMicrosoft {
    param([string]$Cle)
    $iso = $config.Iso[$Cle]
    $chemin = Join-Path $dossierIso $iso.Fichier
    $duree = ''; if ($iso.ContainsKey('EvaluationJours')) { $duree = " ($($iso.EvaluationJours) jours d'évaluation)" }
    Write-LabEtape "$Cle$duree : $($iso.Fichier)"
    if (-not (Test-Path $chemin)) {
        try {
            Invoke-LabTelechargement -Url $iso.Url -Destination $chemin
        } catch {
            Write-LabAvert $_.Exception.Message
            if (-not (Wait-DepotManuel -Chemin $chemin -Page $iso.Page -Url $iso.Url)) {
                $bilan.Add("$Cle : MANQUANT, à déposer dans $chemin"); return
            }
        }
    }
    # Un ISO fait plusieurs Go : une petite taille signale une page HTML reçue à la place.
    if ((Get-Item $chemin).Length -lt 100MB) {
        Remove-Item $chemin -Force
        throw "$($iso.Fichier) fait moins de 100 Mo : ce n'est pas une ISO (page d'erreur ?). Fichier supprimé, relancez."
    }
    $somme = Get-LabSha256 -Fichier $chemin
    $attendue = $iso.Sha256
    if (-not $attendue) { $attendue = Get-SommeRelevee -Fichier $iso.Fichier }
    if ($attendue) {
        if ($somme -ne $attendue.ToLowerInvariant()) {
            throw "Somme SHA-256 différente pour $($iso.Fichier) : $somme au lieu de $attendue. Supprimez le fichier et relancez."
        }
        Write-LabOk "SHA-256 vérifiée : $somme"
    } else {
        Save-SommeRelevee -Fichier $iso.Fichier -Somme $somme
        Write-LabOk "SHA-256 relevée (l'éditeur n'en publie pas pour ce fichier) : $somme"
    }
    $bilan.Add("$Cle : $chemin")
}

function Get-IsoUbuntu {
    $iso = $config.Iso.UbuntuServer
    Write-LabEtape "Ubuntu Server LTS ($($iso.Base))"
    $sommes = Get-LabTexteWeb -Url ($iso.Base + 'SHA256SUMS')
    $candidats = @()
    foreach ($ligne in ($sommes -split "`n")) {
        if ($ligne -notmatch '^([0-9a-f]{64}) \*?(\S+)$') { continue }
        $nom = $Matches[2]; $somme = $Matches[1]
        if ($nom -match $iso.Motif) {
            $version = [version]'0.0'
            if ($nom -match '^ubuntu-(\d+(\.\d+)+)-') { $version = [version]$Matches[1] }
            $candidats += [pscustomobject]@{ Nom = $nom; Somme = $somme; Version = $version }
        }
    }
    if (-not $candidats) { throw "Aucune ISO correspondant à $($iso.Motif) dans $($iso.Base)SHA256SUMS." }
    $choix = $candidats | Sort-Object Version | Select-Object -Last 1
    $chemin = Join-Path $dossierIso $choix.Nom
    Write-LabInfo "Version retenue : $($choix.Nom)"
    $verifiee = $false
    if (Test-Path $chemin) {
        if ((Get-LabSha256 -Fichier $chemin) -eq $choix.Somme) { $verifiee = $true }
        else { Write-LabAvert 'Somme différente : nouveau téléchargement.'; Remove-Item $chemin -Force }
    }
    if (-not $verifiee) {
        Invoke-LabTelechargement -Url ($iso.Base + $choix.Nom) -Destination $chemin
        if ((Get-LabSha256 -Fichier $chemin) -ne $choix.Somme) { throw "Somme SHA-256 invalide pour $($choix.Nom)." }
    }
    Write-LabOk "SHA-256 vérifiée (SHA256SUMS officiel) : $($choix.Somme)"
    # Nom stable pour les autres scripts.
    Set-Content -Path (Join-Path $dossierIso 'ubuntu-server.txt') -Value $choix.Nom -Encoding ASCII
    $bilan.Add("UbuntuServer : $chemin")
}

function Get-IsoPfSense {
    $iso = $config.Iso.PfSense
    Write-LabEtape "pfSense CE : $($iso.Fichier)"
    $chemin = Join-Path $dossierIso $iso.Fichier
    if (Test-Path $chemin) { Write-LabOk 'Déjà présente (décompressée).'; $bilan.Add("PfSense : $chemin"); return }
    $gz = "$chemin.gz"
    $ligne = Get-LabTexteWeb -Url $iso.UrlSha256
    if ($ligne -notmatch '([0-9a-f]{64})') { throw "Somme introuvable dans $($iso.UrlSha256)." }
    $attendue = $Matches[1]
    if (Test-Path $gz) {
        if ((Get-LabSha256 -Fichier $gz) -ne $attendue) { Remove-Item $gz -Force }
    }
    if (-not (Test-Path $gz)) { Invoke-LabTelechargement -Url $iso.UrlGz -Destination $gz }
    if ((Get-LabSha256 -Fichier $gz) -ne $attendue) { throw "Somme SHA-256 invalide pour $gz." }
    Write-LabOk "SHA-256 du .gz vérifiée (fichier .sha256 officiel) : $attendue"
    Write-LabInfo 'Décompression...'
    $entree = [System.IO.File]::OpenRead($gz)
    try {
        $flux = New-Object System.IO.Compression.GZipStream($entree, [System.IO.Compression.CompressionMode]::Decompress)
        $sortie = [System.IO.File]::Create("$chemin.partiel")
        try { $flux.CopyTo($sortie) } finally { $sortie.Dispose(); $flux.Dispose() }
    } finally { $entree.Dispose() }
    Move-Item "$chemin.partiel" $chemin -Force
    Remove-Item $gz -Force
    Write-LabOk "Décompressée : $chemin"
    $bilan.Add("PfSense : $chemin")
}

function Get-GlpiAgent {
    $ga = $config.GlpiAgent
    Write-LabEtape "GLPI Agent $($ga.Version) (publication officielle GitHub)"
    $base = "https://github.com/glpi-project/glpi-agent/releases/download/$($ga.Version)/"
    $officiel = Get-LabTexteWeb -Url ($base + "glpi-agent-$($ga.Version).sha256")
    foreach ($paire in @(@($ga.Msi, $ga.MsiSha256), @($ga.Linux, $ga.LinuxSha256))) {
        $nom = $paire[0]; $epinglee = $paire[1].ToLowerInvariant()
        $publiee = $null
        foreach ($ligne in ($officiel -split "`n")) {
            if ($ligne -match '^([0-9a-f]{64})\s+\*?(\S+)$' -and $Matches[2] -eq $nom) { $publiee = $Matches[1] }
        }
        if ($publiee -ne $epinglee) { throw "La somme publiée de $nom ($publiee) ne correspond pas à celle épinglée dans vms.psd1 ($epinglee)." }
        $chemin = Join-Path $dossierLogiciels $nom
        if ((Test-Path $chemin) -and ((Get-LabSha256 -Fichier $chemin) -ne $epinglee)) { Remove-Item $chemin -Force }
        if (-not (Test-Path $chemin)) { Invoke-LabTelechargement -Url ($base + $nom) -Destination $chemin }
        if ((Get-LabSha256 -Fichier $chemin) -ne $epinglee) { throw "Somme SHA-256 invalide pour $nom." }
        Write-LabOk "$nom vérifié"
        $bilan.Add("GlpiAgent : $chemin")
    }
}

function Get-IsoProxmox {
    $iso = $config.Iso.Proxmox
    $chemin = Join-Path $dossierIso $iso.Fichier
    Write-LabEtape "Proxmox VE : $($iso.Fichier)"
    $sommes = Get-LabTexteWeb -Url ($iso.Base + 'SHA256SUMS')
    $attendue = $null
    foreach ($ligne in ($sommes -split "`n")) { if ($ligne -match '^([0-9a-f]{64})\s+\*?(\S+)$' -and $Matches[2] -eq $iso.Fichier) { $attendue = $Matches[1] } }
    if (-not $attendue) { throw "$($iso.Fichier) absent de $($iso.Base)SHA256SUMS." }
    $verifiee = $false
    if (Test-Path $chemin) { if ((Get-LabSha256 -Fichier $chemin) -eq $attendue) { $verifiee = $true } else { Remove-Item $chemin -Force } }
    if (-not $verifiee) {
        Invoke-LabTelechargement -Url ($iso.Base + $iso.Fichier) -Destination $chemin
        if ((Get-LabSha256 -Fichier $chemin) -ne $attendue) { throw "Somme SHA-256 invalide pour $($iso.Fichier)." }
    }
    Write-LabOk "SHA-256 vérifiée (SHA256SUMS officiel) : $attendue"
    $bilan.Add("Proxmox : $chemin")
}

if (Test-Demande 'Proxmox') { Get-IsoProxmox }
if (Test-Demande 'VirtIO') { Get-IsoMicrosoft -Cle 'VirtIO' }
if (Test-Demande 'GlpiAgent') { Get-GlpiAgent }
if (Test-Demande 'UbuntuServer') { Get-IsoUbuntu }
if (Test-Demande 'PfSense') { Get-IsoPfSense }
if (Test-Demande 'WindowsServer2025') { Get-IsoMicrosoft -Cle 'WindowsServer2025' }
if (Test-Demande 'Windows11Entreprise') { Get-IsoMicrosoft -Cle 'Windows11Entreprise' }

Write-LabEtape 'Bilan'
$bilan | ForEach-Object { Write-LabInfo $_ }
