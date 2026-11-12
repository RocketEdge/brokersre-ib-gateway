# Test helper, run as a separate process under one PowerShell edition:
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File Write-SecretProbe.ps1 -Path <file> -CodePoint 80,36,233
#   pwsh.exe       -NoProfile -File Write-SecretProbe.ps1 -Path <file> -CodePoint 80,36,233
# It builds a SecureString from Unicode code points (numbers survive any command-line encoding)
# and writes it with the kit's Write-GwSecretFile. The calling test then compares the file bytes
# with the expected UTF-8 bytes, proving that the edition under test writes no byte-order mark,
# no newline and no re-encoded characters. The fake secret is never printed.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$CodePoint
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'BrokerSre.Gateway.psd1') -Force -DisableNameChecking
$secure = New-Object System.Security.SecureString
foreach ($number in ($CodePoint -split ',')) {
    foreach ($character in [char]::ConvertFromUtf32([int]$number).ToCharArray()) { $secure.AppendChar($character) }
}
$secure.MakeReadOnly()
Write-GwSecretFile -Path $Path -SecureValue $secure -Confirm:$false
exit 0
