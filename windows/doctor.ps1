<#
.SYNOPSIS
Read-only check of this Windows computer as a host for IB Gateway.
.DESCRIPTION
Looks at everything that can interrupt an unattended gateway on Windows: sleep and hibernate,
Windows Update restarts, whether the stack returns after a restart without a sign-in, the WSL
configuration, the Docker Desktop version, update setting and licence terms, firewall rules and
port proxies that would expose the API, the Windows clock and the clock inside the container VM,
disk space, the encoding and access list of the secret files, and the compose file.

Each check reports PASS, WARN, FAIL or SKIP. SKIP means "could not be measured", never "fine".
Nothing is changed. The first run pulls a 2 MB image for the clock check.

Works on Windows PowerShell 5.1 and PowerShell 7.
.PARAMETER Path
Gateway folder. Default C:\BrokerSRE\gateway.
.PARAMETER Json
Print the report as JSON on standard output instead of a table (for automation).
.OUTPUTS
With -Json: one JSON document (schema 1) on standard output. Exit code 0: no FAIL. 1: at least
one FAIL.
.EXAMPLE
.\doctor.ps1
.EXAMPLE
.\doctor.ps1 -Json | Out-File doctor.json
#>
[CmdletBinding()]
param(
    [string]$Path = 'C:\BrokerSRE\gateway',
    [switch]$Json
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'BrokerSre.Gateway.psd1') -Force -DisableNameChecking
$report = Invoke-GwDoctor @PSBoundParameters
if ($Json) { Write-Output $report.Json }
exit $report.ExitCode
