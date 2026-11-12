<#
.SYNOPSIS
Removes the gateway container and the kit's scheduled tasks; optionally the data too.
.DESCRIPTION
Stops and removes the gateway container and deletes the scheduled tasks the kit created. Your
gateway folder, the secret files and the Docker volumes (gateway settings, logs) stay unless you
pass -RemoveData. PowerShell asks before each removal; secrets are never deleted silently.

Changes made by harden.ps1 (power, active hours, .wslconfig, firewall) are not reverted here:
run 'harden.ps1 -Undo' first. While such changes are still recorded, -RemoveData refuses to
delete the folder (it holds the journal undo needs) unless you add -KeepHostChanges.

Works on Windows PowerShell 5.1 and PowerShell 7.
.PARAMETER Path
Gateway folder. Default C:\BrokerSRE\gateway.
.PARAMETER RemoveData
Also delete the Docker volumes and the gateway folder, including the secret files.
.PARAMETER KeepHostChanges
With -RemoveData: delete the folder although harden changes are still in place.
.OUTPUTS
None. Exit code 0: done. 1: something was left behind (the messages say what).
.EXAMPLE
.\uninstall.ps1 -WhatIf
.EXAMPLE
.\uninstall.ps1 -RemoveData
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$Path = 'C:\BrokerSRE\gateway',
    [switch]$RemoveData,
    [switch]$KeepHostChanges
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'BrokerSre.Gateway.psd1') -Force -DisableNameChecking
$result = Invoke-GwUninstall @PSBoundParameters
exit $result.ExitCode
