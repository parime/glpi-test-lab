<#
.SYNOPSIS
    Capture de l'écran d'une VM Hyper-V (par exemple lab-proxmox pendant son installation), en PNG.

.DESCRIPTION
    Sans droits administrateur (membre d'« Administrateurs Hyper-V »). Utilise
    Msvm_VirtualSystemManagementService.GetVirtualSystemThumbnailImage, qui renvoie l'image en
    RGB565 : https://learn.microsoft.com/windows/win32/hyperv_v2/getvirtualsystemthumbnailimage-msvm-virtualsystemmanagementservice

.EXAMPLE
    .\vm\outils\capture-console.ps1 -Nom lab-proxmox -Fichier F:\Dev\glpi-test-lab-data\vm\journaux\console.png
#>
param(
    [string]$Nom = 'lab-proxmox',
    [Parameter(Mandatory)][string]$Fichier,
    [int]$Largeur = 1024,
    [int]$Hauteur = 768
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$ns = 'root\virtualization\v2'
$vm = Get-CimInstance -Namespace $ns -ClassName Msvm_ComputerSystem -Filter "ElementName='$Nom'"
if (-not $vm) { throw "VM introuvable : $Nom" }
$service = Get-CimInstance -Namespace $ns -ClassName Msvm_VirtualSystemManagementService
$parametres = Get-CimAssociatedInstance -InputObject $vm -ResultClassName Msvm_VirtualSystemSettingData |
    Where-Object { $_.VirtualSystemType -eq 'Microsoft:Hyper-V:System:Realized' } | Select-Object -First 1
$r = Invoke-CimMethod -InputObject $service -MethodName GetVirtualSystemThumbnailImage -Arguments @{
    TargetSystem = $parametres; WidthPixels = [uint16]$Largeur; HeightPixels = [uint16]$Hauteur
}
if ($r.ReturnValue -ne 0) { throw "Capture impossible (code $($r.ReturnValue))." }
$octets = $r.ImageData
$image = New-Object System.Drawing.Bitmap($Largeur, $Hauteur, [System.Drawing.Imaging.PixelFormat]::Format16bppRgb565)
$zone = $image.LockBits((New-Object System.Drawing.Rectangle(0, 0, $Largeur, $Hauteur)), 'WriteOnly', $image.PixelFormat)
$ligne = $Largeur * 2
if ($octets.Length -lt $ligne * $Hauteur) { $image.UnlockBits($zone); throw "Image reçue trop petite ($($octets.Length) octets)." }
for ($y = 0; $y -lt $Hauteur; $y++) {
    [System.Runtime.InteropServices.Marshal]::Copy([byte[]]$octets, $y * $ligne, [IntPtr]($zone.Scan0.ToInt64() + $y * $zone.Stride), $ligne)
}
$image.UnlockBits($zone)
$image.Save($Fichier, [System.Drawing.Imaging.ImageFormat]::Png)
$image.Dispose()
Write-Host "Capture : $Fichier"
