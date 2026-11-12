<#
.SYNOPSIS
Guided install of IB Gateway (brokersre-ib-gateway) on this Windows computer.
.DESCRIPTION
Checks the computer, creates the gateway folder, asks for the IBKR username and password with a
hidden prompt, writes them as two secret files (UTF-8, no byte-order mark, no newline), restricts
that folder to your Windows account, writes compose.yaml (API on 127.0.0.1 only), starts the
gateway and tells you in plain words what it is doing, including when to approve the 2FA prompt
on your phone. Safe to run again: existing secrets are kept unless you pass -ResetSecrets, and a
differing compose.yaml is never replaced unless you pass -Force. With -WhatIf nothing is created,
changed, asked or started.

The kit never automates 2FA, never restarts a running gateway and never places an order.

Works on Windows PowerShell 5.1 and PowerShell 7. If Windows refuses to run the script, allow
scripts for this window only:  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.PARAMETER Path
Gateway folder. Default C:\BrokerSRE\gateway.
.PARAMETER ImageRef
Image to run. Default is the 'stable' tag; in production pin a digest (name@sha256:...).
.PARAMETER Live
Live trading (API on 127.0.0.1:4001). Without it: paper trading (127.0.0.1:4002).
.PARAMETER AllowApiOrders
Let API clients place orders (READ_ONLY_API=no). Without it the API is read-only.
.PARAMETER TimeZone
IANA time zone of the gateway; the daily restart time is in this zone. Default America/New_York.
.PARAMETER AutoRestartTime
IBC daily restart time, for example '11:45 PM'. Keep it outside the IBKR reset windows.
.PARAMETER Runtime
Auto (default), DockerDesktop or WslEngine (Docker Engine inside a WSL 2 distribution).
.PARAMETER Distro
WSL distribution to use with WslEngine. Default: the first one whose docker answers.
.PARAMETER ResetSecrets
Ask for the credentials again and replace the secret files.
.PARAMETER NoStart
Write the files but do not start the gateway.
.PARAMETER Force
Replace an existing compose.yaml that differs (a backup is kept).
.PARAMETER LoginTimeoutSeconds
How long to follow the login before returning. Default 900.
.PARAMETER UserNameSecure
Username as a SecureString instead of the prompt (automation and tests; never plain text).
.PARAMETER PasswordSecure
Password as a SecureString instead of the prompt (automation and tests; never plain text).
.OUTPUTS
None. Exit code 0: done (or -NoStart / -WhatIf). 1: a prerequisite failed or an error occurred.
2: the gateway was started but is not logged in (2FA not approved in time, rejected login, ...).
.EXAMPLE
.\setup.ps1
Paper trading in C:\BrokerSRE\gateway.
.EXAMPLE
.\setup.ps1 -WhatIf
Shows what would happen without changing anything.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Path = 'C:\BrokerSRE\gateway',
    [string]$ImageRef = 'ghcr.io/rocketedge/brokersre-ib-gateway:stable',
    [switch]$Live,
    [switch]$AllowApiOrders,
    [string]$TimeZone = 'America/New_York',
    [string]$AutoRestartTime = '11:45 PM',
    [ValidateSet('Auto', 'DockerDesktop', 'WslEngine')][string]$Runtime = 'Auto',
    [string]$Distro = '',
    [switch]$ResetSecrets,
    [switch]$NoStart,
    [switch]$Force,
    [ValidateRange(30, 86400)][int]$LoginTimeoutSeconds = 900,
    [System.Security.SecureString]$UserNameSecure,
    [System.Security.SecureString]$PasswordSecure
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'BrokerSre.Gateway.psd1') -Force -DisableNameChecking
$result = Invoke-GwSetup @PSBoundParameters
exit $result.ExitCode
