<#
.SYNOPSIS
Applies the host changes doctor.ps1 recommends, one switch each, and can undo all of them.
.DESCRIPTION
Nothing happens unless you ask for it with a switch. Every change is shown first with -WhatIf,
asks for confirmation where it matters (power settings), and is recorded with its previous value
in <Path>\harden-journal.json so that 'harden.ps1 -Undo' restores the computer.

  -DisableSleep             never sleep or hibernate on AC power
  -SetActiveHours 6,23      Windows Update does not restart between 06:00 and 23:00 (max 18 h)
  -StartAtBoot DockerDesktop  start the stack after you sign in (Docker Desktop needs a sign-in)
  -StartAtBoot WslEngine      start the WSL distribution and the stack at startup, no sign-in
  -ResumeClockFix           re-sync the container clock after every resume from sleep
  -WslConfig                merge the recommended keys into .wslconfig (backup kept)
  -FirewallLoopbackOnly     block ports 4001, 4002 and 9810 from the network
  -Undo                     revert everything recorded in the journal

-SetActiveHours, -FirewallLoopbackOnly and -StartAtBoot WslEngine need an elevated PowerShell.
Windows auto-logon is never configured by this kit; the README explains how and what it costs.

Works on Windows PowerShell 5.1 and PowerShell 7.
.PARAMETER Path
Gateway folder. Default C:\BrokerSRE\gateway.
.PARAMETER DisableSleep
Set "sleep after" and "hibernate after" to never on AC power.
.PARAMETER SetActiveHours
Start and end hour (0-23), at most 18 hours apart, for example 6,23.
.PARAMETER StartAtBoot
DockerDesktop or WslEngine.
.PARAMETER AfterSignIn
With -StartAtBoot WslEngine: start after sign-in instead of at startup.
.PARAMETER TaskLogonType
Password (Windows stores your account password; it asks for it itself) or S4U (nothing stored):
how a task that runs without sign-in logs on.
.PARAMETER ResumeClockFix
Register the task that runs 'hwclock -s' in the container VM after a resume.
.PARAMETER WslConfig
Set networkingMode=nat when another mode is configured and, for Docker Engine in WSL,
instanceIdleTimeout=-1.
.PARAMETER WslMemoryGB
With -WslConfig: also limit the WSL VM to this many GB.
.PARAMETER WslConfigPath
Path of .wslconfig. Default %UserProfile%\.wslconfig.
.PARAMETER FirewallLoopbackOnly
Add one inbound block rule for TCP 4001, 4002 and 9810.
.PARAMETER Undo
Revert every recorded change, newest first.
.OUTPUTS
None. Exit code 0: everything asked for was applied. 1: nothing was asked for, or something failed.
.EXAMPLE
.\harden.ps1 -DisableSleep -WhatIf
.EXAMPLE
.\harden.ps1 -Undo
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$Path = 'C:\BrokerSRE\gateway',
    [switch]$DisableSleep,
    [ValidateCount(2, 2)][int[]]$SetActiveHours,
    [ValidateSet('DockerDesktop', 'WslEngine')][string]$StartAtBoot,
    [switch]$AfterSignIn,
    [ValidateSet('Password', 'S4U')][string]$TaskLogonType,
    [switch]$ResumeClockFix,
    [switch]$WslConfig,
    [ValidateRange(2, 1024)][int]$WslMemoryGB,
    [string]$WslConfigPath,
    [switch]$FirewallLoopbackOnly,
    [switch]$Undo
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module -Name (Join-Path $PSScriptRoot 'BrokerSre.Gateway.psd1') -Force -DisableNameChecking
$result = Invoke-GwHarden @PSBoundParameters
exit $result.ExitCode
