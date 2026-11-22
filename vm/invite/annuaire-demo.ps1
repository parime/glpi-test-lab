<#
.SYNOPSIS
    Crée les unités d'organisation, groupes et comptes de démonstration (exécuté SUR le contrôleur
    de domaine, par vm\30-configurer.ps1 via PowerShell Direct). Relançable : rien n'est dupliqué.

    Module ActiveDirectory : https://learn.microsoft.com/powershell/module/activedirectory/
#>
param(
    [Parameter(Mandatory)][string]$Fichier,
    [Parameter(Mandatory)][string]$MotDePasseUtilisateurs,
    [Parameter(Mandatory)][hashtable]$MotsDePasseNommes
)

$ErrorActionPreference = 'Stop'
Import-Module ActiveDirectory
$donnees = Import-PowerShellDataFile -Path $Fichier
$domaine = Get-ADDomain
$base = $domaine.DistinguishedName
$suffixe = $domaine.DNSRoot
$racine = "OU=$($donnees.UniteRacine),$base"
$compte = @{ Unites = 0; Groupes = 0; Comptes = 0; Appartenances = 0 }

function Get-DnUnite {
    param([string]$Chemin)
    $parts = $Chemin.Split('/')
    [array]::Reverse($parts)
    return (($parts | ForEach-Object { "OU=$_" }) -join ',') + ",$racine"
}

function Set-Unite {
    param([string]$Nom, [string]$Parent)
    $dn = "OU=$Nom,$Parent"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Nom -Path $Parent -ProtectedFromAccidentalDeletion $false
        $compte.Unites++
    }
}

function Resolve-Groupe {
    param([string]$Nom)
    switch ($Nom) {
        '@AdminsDuDomaine' { return Get-ADGroup -Identity "$($domaine.DomainSID)-512" }
        '@OperateursSauvegarde' { return Get-ADGroup -Identity 'S-1-5-32-551' }
        default { return Get-ADGroup -Identity $Nom }
    }
}

function Add-Appartenance {
    param([string]$Groupe, $Membre)
    $g = Resolve-Groupe -Nom $Groupe
    $dnMembre = $Membre.DistinguishedName
    $actuels = @(Get-ADGroupMember -Identity $g | ForEach-Object { $_.DistinguishedName })
    if ($actuels -notcontains $dnMembre) {
        Add-ADGroupMember -Identity $g -Members $Membre
        $compte.Appartenances++
    }
}

function Get-MotDePasseSecurise {
    param([string]$Texte)
    return ConvertTo-SecureString -String $Texte -AsPlainText -Force
}

# Unités d'organisation.
Set-Unite -Nom $donnees.UniteRacine -Parent $base
foreach ($chemin in $donnees.Unites) {
    $parts = $chemin.Split('/')
    $parent = $racine
    for ($i = 0; $i -lt $parts.Count - 1; $i++) { $parent = "OU=$($parts[$i]),$parent" }
    Set-Unite -Nom $parts[-1] -Parent $parent
}

# Groupes.
$dnGroupes = Get-DnUnite 'Groupes'
foreach ($g in $donnees.Groupes) {
    if (-not (Get-ADGroup -Filter "SamAccountName -eq '$($g.Nom)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $g.Nom -SamAccountName $g.Nom -GroupScope Global -GroupCategory Security -Path $dnGroupes -Description $g.Description
        $compte.Groupes++
    }
}

# Utilisateurs.
$tous = @()
foreach ($u in $donnees.Utilisateurs) {
    $nomAffiche = "$($u.Prenom) $($u.Nom)"
    $existant = Get-ADUser -Filter "SamAccountName -eq '$($u.Sam)'" -ErrorAction SilentlyContinue
    if (-not $existant) {
        $params = @{
            Name              = $nomAffiche
            SamAccountName    = $u.Sam
            UserPrincipalName = "$($u.Sam)@$suffixe"
            GivenName         = $u.Prenom
            Surname           = $u.Nom
            DisplayName       = $nomAffiche
            Title             = $u.Titre
            Department        = $u.Service
            Company           = 'Labo GRC (fictif)'
            EmailAddress      = "$($u.Sam)@$suffixe"
            Path              = (Get-DnUnite $u.Unite)
            AccountPassword   = (Get-MotDePasseSecurise $MotDePasseUtilisateurs)
            Enabled           = $true
        }
        if ($u.ContainsKey('Telephone')) { $params.OfficePhone = $u.Telephone }
        if ($u.ContainsKey('Description')) { $params.Description = $u.Description }
        New-ADUser @params
        $compte.Comptes++
    }
    $tous += $u
}
foreach ($u in $tous) {
    $ad = Get-ADUser -Identity $u.Sam
    if ($u.ContainsKey('Responsable')) { Set-ADUser -Identity $ad -Manager (Get-ADUser -Identity $u.Responsable) }
    if ($u.ContainsKey('MotDePasseNExpireJamais') -and $u.MotDePasseNExpireJamais) { Set-ADUser -Identity $ad -PasswordNeverExpires $true }
    if ($u.ContainsKey('ExpireIlYaJours')) {
        $ex = Get-ADUser -Identity $ad -Properties AccountExpirationDate
        if (-not $ex.AccountExpirationDate) { Set-ADAccountExpiration -Identity $ad -DateTime (Get-Date).AddDays(-[int]$u.ExpireIlYaJours) }
    }
    foreach ($g in @($u.Groupes)) { if ($g) { Add-Appartenance -Groupe $g -Membre $ad } }
    if ($u.ContainsKey('Desactive') -and $u.Desactive -and $ad.Enabled) { Disable-ADAccount -Identity $ad }
}

# Comptes de service.
$dnService = Get-DnUnite 'Comptes de service'
foreach ($s in $donnees.ComptesService) {
    $mdp = $MotDePasseUtilisateurs
    if ($s.ContainsKey('MotDePasse')) { $mdp = $MotsDePasseNommes[$s.MotDePasse] }
    $existant = Get-ADUser -Filter "SamAccountName -eq '$($s.Sam)'" -ErrorAction SilentlyContinue
    if (-not $existant) {
        New-ADUser -Name $s.Sam -SamAccountName $s.Sam -UserPrincipalName "$($s.Sam)@$suffixe" -Description $s.Description `
            -Path $dnService -AccountPassword (Get-MotDePasseSecurise $mdp) -Enabled $true -PasswordNeverExpires $true -CannotChangePassword $true
        $compte.Comptes++
    } elseif ($s.ContainsKey('MotDePasse')) {
        # Garde le compte de liaison GLPI aligné sur secrets.json.
        Set-ADAccountPassword -Identity $s.Sam -Reset -NewPassword (Get-MotDePasseSecurise $mdp)
    }
    $ad = Get-ADUser -Identity $s.Sam -Properties ServicePrincipalName
    foreach ($spn in @($s.Spn)) {
        if ($spn -and ($ad.ServicePrincipalName -notcontains $spn)) { Set-ADUser -Identity $ad -ServicePrincipalNames @{ Add = $spn } }
    }
    foreach ($g in @($s.Groupes)) { if ($g) { Add-Appartenance -Groupe $g -Membre $ad } }
}

# Groupes imbriqués.
foreach ($g in $donnees.Groupes) {
    foreach ($m in @($g.Membres)) { if ($m) { Add-Appartenance -Groupe $g.Nom -Membre (Get-ADGroup -Identity $m) } }
}

# Les postes joints au domaine arrivent dans OU=Postes.
$dnPostes = Get-DnUnite 'Ordinateurs/Postes'

[pscustomobject]@{
    UnitesCreees        = $compte.Unites
    GroupesCrees        = $compte.Groupes
    ComptesCrees        = $compte.Comptes
    AppartenancesAjoutees = $compte.Appartenances
    UnitePostes         = $dnPostes
}
