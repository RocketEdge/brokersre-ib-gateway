# Shared helpers for the Windows host kit test suite (dot-sourced from BeforeAll blocks).
# Nothing here touches the host: every helper works on values or on a caller-supplied temp path.

Set-StrictMode -Version Latest

function Import-KitModule {
    <#
    .SYNOPSIS
    Imports a fresh copy of the BrokerSre.Gateway module for one test file.
    .DESCRIPTION
    Removes any loaded copy first so that a test file never sees mocks or state left behind by
    another one, then imports the manifest that sits next to the tests directory.
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param()
    $manifest = Join-Path (Split-Path -Parent $PSScriptRoot) 'BrokerSre.Gateway.psd1'
    Get-Module -Name 'BrokerSre.Gateway' | Remove-Module -Force
    Import-Module -Name $manifest -Force -DisableNameChecking
}

function ConvertTo-TestSecureString {
    <#
    .SYNOPSIS
    Builds a SecureString from an obviously fake test value.
    .DESCRIPTION
    Appends the characters one by one instead of calling ConvertTo-SecureString -AsPlainText, so
    the analyzer rule against plain-text conversion stays enabled for the whole kit and no test
    needs a suppression. Only fake values (hunter2hunter2, CANARY_*) are ever passed in.
    .PARAMETER Text
    The fake secret. Any Unicode character is allowed.
    .OUTPUTS
    System.Security.SecureString, read-only.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)
    $secure = New-Object System.Security.SecureString
    foreach ($character in $Text.ToCharArray()) { $secure.AppendChar($character) }
    $secure.MakeReadOnly()
    return $secure
}

function Get-TestTreeSnapshot {
    <#
    .SYNOPSIS
    Returns a sorted list describing every file and directory under a path.
    .DESCRIPTION
    Used by the -WhatIf tests: the snapshot taken before a run must equal the one taken after
    it. A file entry is "<relative path>|file|<length>|<SHA-256>|<last write ticks>|<SDDL>", so a
    created, deleted, rewritten (even with the same content) or re-permissioned file changes
    the snapshot. A directory entry is "<relative path>|dir|<SDDL>": its timestamp is left out
    because NTFS refreshes the copy kept in the parent's index lazily, which made an untouched
    folder look changed. File times are read from the file itself, not from the listing.
    .PARAMETER Path
    Directory to describe. A missing directory yields an empty list.
    .OUTPUTS
    System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [string[]]@() }
    $root = (Resolve-Path -LiteralPath $Path).ProviderPath
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($item in (Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        $relative = $item.FullName.Substring($root.Length).TrimStart('\')
        $sddl = (Get-Acl -LiteralPath $item.FullName).Sddl
        if ($item.PSIsContainer) {
            $entries.Add(('{0}|dir|{1}' -f $relative, $sddl))
            continue
        }
        $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        $ticks = [System.IO.File]::GetLastWriteTimeUtc($item.FullName).Ticks
        $entries.Add(('{0}|file|{1}|{2}|{3}|{4}' -f $relative, $item.Length, $hash, $ticks, $sddl))
    }
    $sorted = [string[]]($entries | Sort-Object)
    if ($null -eq $sorted) { return [string[]]@() }
    return $sorted
}

function Get-TestNativeResult {
    <#
    .SYNOPSIS
    Builds the object the external-command wrappers return, for use in mocks.
    .PARAMETER ExitCode
    Exit code the mocked command reports.
    .PARAMETER Output
    Output lines the mocked command reports.
    .PARAMETER ReceivedUtc
    Optional receipt time per output line; defaults to the current time for every line.
    .OUTPUTS
    PSCustomObject with ExitCode, Output, ReceivedUtc and NotFound.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [int]$ExitCode = 0,
        [string[]]$Output = @(),
        [datetime[]]$ReceivedUtc = @(),
        [switch]$NotFound
    )
    $stamps = $ReceivedUtc
    if ($stamps.Count -eq 0 -and $Output.Count -gt 0) {
        $stamps = [datetime[]]@($Output | ForEach-Object { [DateTime]::UtcNow })
    }
    return [pscustomobject]@{
        ExitCode    = $ExitCode
        Output      = [string[]]$Output
        ReceivedUtc = [datetime[]]$stamps
        NotFound    = [bool]$NotFound
    }
}
