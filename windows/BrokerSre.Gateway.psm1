# BrokerSre.Gateway: the Windows host kit for the brokersre-ib-gateway container image.
#
# All logic of setup.ps1, doctor.ps1, harden.ps1, start.ps1 and uninstall.ps1 lives in this
# module as documented functions, so that Pester can mock the external-command wrappers
# (src/Native.ps1) and exercise everything else for real. The module is split into one file per
# concern to keep each file small enough to read and regenerate in one piece; the load order
# below is the dependency order (a file uses only functions from files above it at load time,
# and any function at call time).
#
# Compatibility contract: Windows PowerShell 5.1 and PowerShell 7 on Windows 10 22H2 / 11.
# No ternary, no '&&' / '||', no '??', ASCII-only source (5.1 reads BOM-less files as ANSI).

Set-StrictMode -Version Latest

$script:GwModuleRoot = $PSScriptRoot

foreach ($part in @('Native', 'Core', 'Secrets', 'Stack', 'Checks', 'Harden', 'Commands')) {
    $partPath = Join-Path (Join-Path $PSScriptRoot 'src') ('{0}.ps1' -f $part)
    if (Test-Path -LiteralPath $partPath) { . $partPath }
}

Export-ModuleMember -Function '*-Gw*'
