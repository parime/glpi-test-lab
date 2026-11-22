# Réécrit les scripts PowerShell de vm\ en UTF-8 avec BOM : Windows PowerShell 5.1 lit un fichier
# sans BOM comme du texte ANSI et abîme les accents. À lancer après avoir édité un .ps1/.psm1/.psd1.
$racine = Split-Path -Parent $PSScriptRoot
$avecBom = New-Object System.Text.UTF8Encoding($true)
Get-ChildItem -Path $racine -Recurse -Include *.ps1, *.psm1, *.psd1 | ForEach-Object {
    $octets = [System.IO.File]::ReadAllBytes($_.FullName)
    $aBom = $octets.Length -ge 3 -and $octets[0] -eq 0xEF -and $octets[1] -eq 0xBB -and $octets[2] -eq 0xBF
    if (-not $aBom) {
        $texte = (New-Object System.Text.UTF8Encoding($false)).GetString($octets)
        [System.IO.File]::WriteAllText($_.FullName, $texte, $avecBom)
        Write-Host "BOM ajouté : $($_.FullName)"
    }
}
