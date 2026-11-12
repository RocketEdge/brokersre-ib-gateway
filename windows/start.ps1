<#
.SYNOPSIS
Starts the gateway stack without asking anything. Run by the kit's scheduled tasks; safe by hand.
.DESCRIPTION
Waits (bounded) for the container engine recorded by setup.ps1 and runs
'docker compose up -d --no-recreate': a stopped stack is started, a running gateway is left as it
is. It never restarts a gateway and never touches 2FA; if the gateway has to log in, IBKR sends
the prompt to your phone. Each run leaves lines in <Path>\kit.log (size bounded).

With -KeepAlive and Docker Engine inside WSL the script then keeps one WSL session open and does
not return, because WSL shuts an idle distribution down. The scheduled task uses this.

Works on Windows PowerShell 5.1 and PowerShell 7.
.PARAMETER Path
Gateway folder. Default C:\BrokerSRE\gateway.
.PARAMETER KeepAlive
Docker Engine in WSL only: hold a WSL session open after starting.
.PARAMETER WaitSeconds
How long to wait for the container engine. Default 600.
.OUTPUTS
None. Exit code 0: the stack is up. 1: it was not started.
.EXAMPLE
.\start.ps1
#>
[CmdletBinding()]
param(
    [string]$Path = 'C:\BrokerSRE\gateway',
    [switch]$KeepAlive,
    [ValidateRange(5, 3600)][int]$WaitSeconds = 600
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'BrokerSre.Gateway.psd1') -Force -DisableNameChecking
$result = Invoke-GwStart @PSBoundParameters
exit $result.ExitCode
