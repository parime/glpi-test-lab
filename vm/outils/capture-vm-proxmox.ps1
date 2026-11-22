<#
.SYNOPSIS
    Capture de l'écran d'une VM de Proxmox, en PNG (pour suivre une installation sans navigateur).

.DESCRIPTION
    Commande « screendump » du moniteur QEMU (« qm monitor », réservée à root : lancée en SSH avec
    la clé du labo ; https://pve.proxmox.com/pve-docs/qm.1.html), image PPM récupérée puis
    convertie en PNG.

.EXAMPLE
    .\vm\outils\capture-vm-proxmox.ps1 -VmId 101 -Fichier F:\Dev\glpi-test-lab-data\vm\journaux\pfsense.png
#>
param([Parameter(Mandatory)][int]$VmId, [Parameter(Mandatory)][string]$Fichier)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot) 'lib\LabVm.psm1') -Force
Add-Type -AssemblyName System.Drawing
$config = Get-LabConfig
$distant = "/tmp/capture-$VmId.ppm"
$cle = Get-LabSshCle -Config $config
$connus = Join-Path (Split-Path $cle) 'known_hosts'
& ssh.exe -i $cle -o "UserKnownHostsFile=$connus" -o BatchMode=yes "root@$($config.Proxmox.IpLan)" "echo 'screendump $distant' | qm monitor $VmId >/dev/null"
if ($LASTEXITCODE -ne 0) { throw 'screendump impossible.' }
$local = "$Fichier.ppm"
& scp.exe -q -i $cle -o "UserKnownHostsFile=$connus" -o BatchMode=yes "root@$($config.Proxmox.IpLan):$distant" $local
if ($LASTEXITCODE -ne 0) { throw 'Récupération de la capture impossible.' }
$octets = [IO.File]::ReadAllBytes($local)
# En-tête PPM binaire : P6, largeur, hauteur, valeur maximale, puis RGB.
$pos = 0; $champs = @()
while ($champs.Count -lt 4) {
    while ([char]$octets[$pos] -match '\s') { $pos++ }
    if ([char]$octets[$pos] -eq '#') { while ($octets[$pos] -ne 10) { $pos++ }; continue }
    $debut = $pos; while (-not ([char]$octets[$pos] -match '\s')) { $pos++ }
    $champs += [Text.Encoding]::ASCII.GetString($octets, $debut, $pos - $debut)
}
$pos++
$l = [int]$champs[1]; $h = [int]$champs[2]
$image = New-Object System.Drawing.Bitmap($l, $h, [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$zone = $image.LockBits((New-Object System.Drawing.Rectangle(0, 0, $l, $h)), 'WriteOnly', $image.PixelFormat)
$ligne = New-Object byte[] ($l * 3)
for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $l; $x++) {
        $i = $pos + ($y * $l + $x) * 3
        $ligne[$x * 3] = $octets[$i + 2]; $ligne[$x * 3 + 1] = $octets[$i + 1]; $ligne[$x * 3 + 2] = $octets[$i]
    }
    [Runtime.InteropServices.Marshal]::Copy($ligne, 0, [IntPtr]($zone.Scan0.ToInt64() + $y * $zone.Stride), $ligne.Length)
}
$image.UnlockBits($zone)
$image.Save($Fichier, [System.Drawing.Imaging.ImageFormat]::Png)
$image.Dispose()
Remove-Item $local -Force
Write-Host "Capture : $Fichier"
