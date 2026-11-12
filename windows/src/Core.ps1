# Core helpers of the BrokerSRE Windows host kit: result objects, console output, atomic UTF-8
# file writes, INI text editing, small converters, the kit state file and the bounded kit log.
# Pure PowerShell and .NET; nothing here calls an external command. Works on Windows PowerShell
# 5.1 and PowerShell 7, so no ternary, no '&&', no '??' and no non-ASCII characters (5.1 reads a
# script without byte-order mark as ANSI).

function New-GwCheckResult {
    <#
    .SYNOPSIS
    Creates the result object every prerequisite and doctor check returns.
    .DESCRIPTION
    One shape for every check keeps the table view, the JSON view and the exit code logic in one
    place. Status is restricted to four values: PASS (measured and fine), WARN (measured, works
    today, will hurt later), FAIL (measured and broken) and SKIP (could not be measured; the
    reason is in Detail). A check that cannot measure must return SKIP, never PASS.
    .PARAMETER Name
    Short stable identifier of the check, for example 'SleepOnAc'. Used as a key in JSON.
    .PARAMETER Status
    PASS, WARN, FAIL or SKIP.
    .PARAMETER Detail
    What was observed, in plain language. Never contains a secret.
    .PARAMETER Fix
    What the operator should do; empty when nothing needs doing.
    .OUTPUTS
    PSCustomObject with the properties Name, Status, Detail and Fix, in that order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds an in-memory object; nothing on the host changes.')]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('PASS', 'WARN', 'FAIL', 'SKIP')][string]$Status,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Detail,
        [AllowEmptyString()][string]$Fix = ''
    )
    return [pscustomobject][ordered]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
        Fix    = $Fix
    }
}

function Write-GwConsole {
    <#
    .SYNOPSIS
    Writes one line for the person at the keyboard.
    .DESCRIPTION
    The single place where the kit talks to the console. It uses the information stream
    (Write-Host), never the success stream, so 'doctor.ps1 -Json > file' captures JSON only and
    functions can still return objects. Colour follows the check status when one is given.
    .PARAMETER Message
    Text to show. Callers never pass a secret here.
    .PARAMETER Status
    Optional PASS, WARN, FAIL, SKIP or INFO; selects the colour.
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
        Justification = 'Deliberate: operator-facing text goes to the information stream so that pipeline output stays machine-readable.')]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateSet('PASS', 'WARN', 'FAIL', 'SKIP', 'INFO')][string]$Status = 'INFO'
    )
    $colour = $null
    switch ($Status) {
        'PASS' { $colour = [ConsoleColor]::Green }
        'WARN' { $colour = [ConsoleColor]::Yellow }
        'FAIL' { $colour = [ConsoleColor]::Red }
        'SKIP' { $colour = [ConsoleColor]::DarkGray }
    }
    if ($null -eq $colour) { Write-Host $Message }
    else { Write-Host $Message -ForegroundColor $colour }
}

function Get-GwPropertyValue {
    <#
    .SYNOPSIS
    Reads a property that may not exist, without tripping strict mode.
    .DESCRIPTION
    Objects parsed from JSON carry only the keys that were present. Under Set-StrictMode a
    plain '$object.Missing' throws, so every optional read goes through this function.
    .PARAMETER InputObject
    Any object, or null.
    .PARAMETER Name
    Property name (case-insensitive, as PowerShell properties are).
    .PARAMETER Default
    Value returned when the object is null or has no such property. Defaults to null.
    .OUTPUTS
    The property value, or the default.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Resolve-GwFullPath {
    <#
    .SYNOPSIS
    Turns a PowerShell path into an absolute file-system path without requiring it to exist.
    .DESCRIPTION
    The file APIs of .NET resolve relative paths against the process directory, which is not the
    PowerShell location. Every path handed to System.IO goes through this function first.
    A trailing backslash (tab completion adds one to folders) is removed, except on a drive
    root, so the same folder always has the same text in the state file, in task command
    lines and in comparisons.
    .PARAMETER Path
    Relative or absolute path; it may not exist yet.
    .OUTPUTS
    System.String, absolute path without trailing backslash (a drive root keeps its backslash).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $rootPath = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $rootPath.Length) { $full = $full.TrimEnd([char]92, [char]47) }
    return $full
}

function Move-GwFileOverwrite {
    <#
    .SYNOPSIS
    Moves a finished temporary file onto its target in one step, retrying when the target is briefly locked.
    .DESCRIPTION
    The second half of every atomic write in the kit. An existing target is replaced with
    File.Replace (atomic on NTFS, keeps the target's access list); a new target is created with
    File.Move. Antivirus and indexing services open a file right after it is written, and the
    replace then fails with "Unable to remove the file to be replaced" (observed 2026-11-12), so
    a sharing or access error is retried with exponential back-off and jitter: 50, 100, 200,
    400, 800 ms, at most 1.6 s in total, then the error is raised. Bounded, never silent.
    .PARAMETER Source
    The temporary file, in the same directory as the target.
    .PARAMETER Destination
    The target file.
    .PARAMETER MaxAttempts
    Number of attempts before the error is raised; default 6.
    .OUTPUTS
    None. On failure the last System.IO.IOException or UnauthorizedAccessException is thrown;
    the caller removes the temporary file.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Internal step of an atomic write; the functions that decide to write own ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [ValidateRange(1, 12)][int]$MaxAttempts = 6
    )
    $random = New-Object System.Random
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            if ([System.IO.File]::Exists($Destination)) { [System.IO.File]::Replace($Source, $Destination, [NullString]::Value) }
            else { [System.IO.File]::Move($Source, $Destination) }
            return
        }
        catch {
            # .NET surfaces a locked target as IOException or UnauthorizedAccessException (wrapped
            # by PowerShell in MethodInvocationException). Anything else is not a lock: rethrow.
            $cause = $_.Exception
            while ($null -ne $cause.InnerException) { $cause = $cause.InnerException }
            $transient = ($cause -is [System.IO.IOException]) -or ($cause -is [System.UnauthorizedAccessException])
            if (-not $transient -or $attempt -ge $MaxAttempts) { throw }
            $delay = [Math]::Min(800, 50 * [Math]::Pow(2, $attempt - 1)) + $random.Next(0, 25)
            Write-Verbose ('Target busy (attempt {0} of {1}); retrying in {2} ms.' -f $attempt, $MaxAttempts, [int]$delay)
            Start-Sleep -Milliseconds ([int]$delay)
        }
    }
}

function Write-GwFileAtomic {
    <#
    .SYNOPSIS
    Writes text to a file as UTF-8 without byte-order mark, atomically.
    .DESCRIPTION
    Writes a temporary file in the same directory and then replaces the target in one step, so
    a crash or a power cut never leaves a half-written compose file, journal or secret. The text
    is written exactly as given: no byte-order mark and no newline are added. Windows
    PowerShell 5.1 cmdlets (Out-File, Set-Content -Encoding UTF8, '>') add a mark or write
    UTF-16, which is why this function uses System.IO.File with UTF8Encoding($false).
    The final step is Move-GwFileOverwrite, which keeps the target's access list and retries
    when the target is briefly locked.
    .PARAMETER Path
    Target file. Its directory must exist.
    .PARAMETER Text
    Content to write. Line endings are the caller's (the kit uses LF).
    .OUTPUTS
    None. Side effect: the file at Path holds exactly the UTF-8 bytes of Text.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $target = Resolve-GwFullPath -Path $Path
    $directory = Split-Path -Parent $target
    $temporary = Join-Path $directory ('.{0}.{1}.tmp' -f (Split-Path -Leaf $target), [guid]::NewGuid().ToString('N'))
    $encoding = New-Object System.Text.UTF8Encoding($false)
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $encoding)
        Move-GwFileOverwrite -Source $temporary -Destination $target
    }
    finally {
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Read-GwTextFile {
    <#
    .SYNOPSIS
    Reads a UTF-8 text file; returns null when it does not exist.
    .DESCRIPTION
    Get-Content in Windows PowerShell 5.1 decodes a file without byte-order mark as ANSI, so the
    kit reads through System.IO.File with UTF-8 (a mark, when present, is consumed).
    .PARAMETER Path
    File to read.
    .OUTPUTS
    System.String with the whole content, or null for a missing file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $target = Resolve-GwFullPath -Path $Path
    if (-not [System.IO.File]::Exists($target)) { return $null }
    return [System.IO.File]::ReadAllText($target, (New-Object System.Text.UTF8Encoding($false)))
}

function Split-GwIniLine {
    <#
    .SYNOPSIS
    Splits INI text into lines with LF semantics.
    .DESCRIPTION
    Normalises CRLF to LF and drops the final empty element produced by a trailing newline, so
    that joining the lines with LF and appending one LF reproduces a normalised file.
    .PARAMETER Text
    INI text, possibly empty.
    .OUTPUTS
    System.String[] (empty for empty text).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return [string[]]@() }
    $normalised = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($normalised.EndsWith("`n")) { $normalised = $normalised.Substring(0, $normalised.Length - 1) }
    return [string[]]($normalised -split "`n")
}

function Find-GwIniKey {
    <#
    .SYNOPSIS
    Locates a section and a key inside INI lines.
    .DESCRIPTION
    Shared by the read, set and remove helpers so they agree on what a section header, a key
    line and a comment are. Section and key names compare case-insensitively (the example in the
    documentation of .wslconfig itself mixes 'localhostForwarding' and 'localhostforwarding'). Lines
    starting with '#' or ';' are comments.
    .PARAMETER Line
    Lines from Split-GwIniLine.
    .PARAMETER Section
    Section name without brackets.
    .PARAMETER Key
    Key name.
    .OUTPUTS
    PSCustomObject: SectionIndex (header line or -1), KeyIndex (key line or -1), InsertIndex
    (where a new key of this section belongs, or -1), Value (text right of '=' or null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowEmptyCollection()][string[]]$Line = @(),
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key
    )
    # An empty array returned by a function arrives here as null; normalise before counting.
    if ($null -eq $Line) { $Line = [string[]]@() }
    $sectionIndex = -1
    $keyIndex = -1
    $insertIndex = -1
    $value = $null
    $inSection = $false
    for ($index = 0; $index -lt $Line.Count; $index++) {
        $text = $Line[$index]
        if ($text -match '^\s*\[([^\]]+)\]\s*$') {
            if ($inSection) { break }
            if ($Matches[1].Trim() -ieq $Section) {
                $inSection = $true
                $sectionIndex = $index
                $insertIndex = $index + 1
            }
            continue
        }
        if (-not $inSection) { continue }
        if ($text.Trim().Length -gt 0) { $insertIndex = $index + 1 }
        if ($text -match '^\s*([^#;=\s][^=]*?)\s*=\s*(.*?)\s*$') {
            if ($Matches[1] -ieq $Key) {
                $keyIndex = $index
                $value = $Matches[2]
            }
        }
    }
    return [pscustomobject]@{ SectionIndex = $sectionIndex; KeyIndex = $keyIndex; InsertIndex = $insertIndex; Value = $value }
}

function Get-GwIniValue {
    <#
    .SYNOPSIS
    Reads one value from INI text such as %UserProfile%\.wslconfig.
    .PARAMETER Text
    INI text; empty or null means "no file".
    .PARAMETER Section
    Section name without brackets, case-insensitive.
    .PARAMETER Key
    Key name, case-insensitive.
    .OUTPUTS
    System.String with the value (may be empty), or null when section or key is absent.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key
    )
    $lines = [string[]]@(Split-GwIniLine -Text $Text)
    $found = Find-GwIniKey -Line $lines -Section $Section -Key $Key
    if ($found.KeyIndex -lt 0) { return $null }
    return [string]$found.Value
}

function Set-GwIniValue {
    <#
    .SYNOPSIS
    Returns INI text with one key set, leaving every other line untouched.
    .DESCRIPTION
    Text in, text out: nothing is written to disk here, so the function has no side effect and
    the caller decides about backup and ShouldProcess. An existing key is replaced in place, a
    new key is appended after the last non-blank line of its section, and a missing section is
    appended at the end. Comments and unknown keys survive, which matters because .wslconfig
    belongs to the operator, not to the kit. Output always uses LF and ends with one LF.
    .PARAMETER Text
    Current INI text; empty or null creates the content from nothing.
    .PARAMETER Section
    Section name without brackets.
    .PARAMETER Key
    Key name; written with exactly this casing.
    .PARAMETER Value
    Value to set.
    .OUTPUTS
    System.String, the new INI text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure text transformation; the caller that writes the file owns ShouldProcess.')]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Split-GwIniLine -Text $Text)) { $lines.Add($line) }
    $found = Find-GwIniKey -Line $lines.ToArray() -Section $Section -Key $Key
    $newLine = '{0}={1}' -f $Key, $Value
    if ($found.KeyIndex -ge 0) {
        $lines[$found.KeyIndex] = $newLine
    }
    elseif ($found.SectionIndex -ge 0) {
        $lines.Insert($found.InsertIndex, $newLine)
    }
    else {
        if ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim().Length -gt 0) { $lines.Add('') }
        $lines.Add('[{0}]' -f $Section)
        $lines.Add($newLine)
    }
    return (($lines.ToArray() -join "`n") + "`n")
}

function Remove-GwIniValue {
    <#
    .SYNOPSIS
    Returns INI text with one key removed; every other line stays.
    .DESCRIPTION
    Counterpart of Set-GwIniValue, used by the undo path to restore "this key was not set".
    Text in, text out; an absent key returns the input unchanged. With -RemoveEmptySection a
    section left without any key or comment is removed too, together with the blank lines that
    separated it, so that undoing "add a key to a new section" restores the original text.
    .PARAMETER Text
    Current INI text.
    .PARAMETER Section
    Section name without brackets.
    .PARAMETER Key
    Key name.
    .PARAMETER RemoveEmptySection
    Also remove the section header when nothing but blank lines remains in the section.
    .OUTPUTS
    System.String, the new INI text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Pure text transformation; the caller that writes the file owns ShouldProcess.')]
    param(
        [AllowEmptyString()][AllowNull()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [switch]$RemoveEmptySection
    )
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in (Split-GwIniLine -Text $Text)) { $lines.Add($line) }
    $found = Find-GwIniKey -Line $lines.ToArray() -Section $Section -Key $Key
    if ($found.KeyIndex -lt 0) { return [string]$Text }
    $lines.RemoveAt($found.KeyIndex)
    if ($RemoveEmptySection) {
        # The section spans from its header to the line before the next header (or the end).
        $header = $found.SectionIndex
        $next = $lines.Count
        for ($index = $header + 1; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\s*\[[^\]]+\]\s*$') {
                $next = $index
                break
            }
        }
        $hasContent = $false
        for ($index = $header + 1; $index -lt $next; $index++) {
            if ($lines[$index].Trim().Length -gt 0) { $hasContent = $true }
        }
        if (-not $hasContent) {
            $lines.RemoveRange($header, $next - $header)
            # Drop the blank lines that separated the removed section from the text above it,
            # unless another section follows and still needs one separator.
            $above = $header - 1
            while ($above -ge 0 -and $lines[$above].Trim().Length -eq 0) {
                $lines.RemoveAt($above)
                $above--
            }
            if ($above -ge 0 -and ($above + 1) -lt $lines.Count) { $lines.Insert($above + 1, '') }
        }
    }
    if ($lines.Count -eq 0) { return '' }
    return (($lines.ToArray() -join "`n") + "`n")
}

function ConvertTo-GwDurationSecond {
    <#
    .SYNOPSIS
    Converts a Go-style duration such as '1m30s' to seconds.
    .DESCRIPTION
    'docker compose config --format json' prints durations (stop_grace_period) in Go notation.
    Supports hours, minutes, seconds and milliseconds; anything else returns null so the caller
    reports "not measured" instead of guessing.
    .PARAMETER Text
    Duration text, for example '90s', '1m30s', '1h0m5s' or '500ms'.
    .OUTPUTS
    System.Double seconds, or null when the text is not a duration.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $pattern = '^(?:(?<h>\d+(?:\.\d+)?)h)?(?:(?<m>\d+(?:\.\d+)?)m(?!s))?(?:(?<s>\d+(?:\.\d+)?)s)?(?:(?<ms>\d+(?:\.\d+)?)ms)?$'
    $match = [regex]::Match($Text.Trim(), $pattern)
    if (-not $match.Success) { return $null }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $total = [double]0
    if ($match.Groups['h'].Success) { $total += [double]::Parse($match.Groups['h'].Value, $culture) * 3600 }
    if ($match.Groups['m'].Success) { $total += [double]::Parse($match.Groups['m'].Value, $culture) * 60 }
    if ($match.Groups['s'].Success) { $total += [double]::Parse($match.Groups['s'].Value, $culture) }
    if ($match.Groups['ms'].Success) { $total += [double]::Parse($match.Groups['ms'].Value, $culture) / 1000 }
    return $total
}

function ConvertTo-GwSizeByte {
    <#
    .SYNOPSIS
    Converts a .wslconfig size such as '4GB' to bytes.
    .DESCRIPTION
    Microsoft documents that size values default to bytes and accept a unit suffix such as
    '8GB' or '512MB'. Units are binary (1 KB = 1024 bytes). Unknown text returns null.
    .PARAMETER Text
    Size text.
    .OUTPUTS
    System.Int64 bytes, or null when the text is not a size.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $null }
    $match = [regex]::Match($Text.Trim(), '^(?<n>\d+)\s*(?<u>B|KB|MB|GB|TB)?$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $match.Success) { return $null }
    $number = [long]::Parse($match.Groups['n'].Value, [System.Globalization.CultureInfo]::InvariantCulture)
    $multiplier = [long]1
    switch ($match.Groups['u'].Value.ToUpperInvariant()) {
        'KB' { $multiplier = [long]1024 }
        'MB' { $multiplier = [long]1048576 }
        'GB' { $multiplier = [long]1073741824 }
        'TB' { $multiplier = [long]1099511627776 }
    }
    return ($number * $multiplier)
}

function ConvertTo-GwTimestampText {
    <#
    .SYNOPSIS
    Normalises a timestamp to the text form 'yyyy-MM-ddTHH:mm:ssZ'.
    .DESCRIPTION
    PowerShell 7 turns ISO 8601 strings into DateTime when it parses JSON, Windows PowerShell
    5.1 does not, and 5.1 serialises a DateTime as '\/Date(...)\/'. The kit therefore stores
    timestamps as text and passes every value read back from JSON through this function before
    writing it again, so a journal survives being edited by either edition.
    .PARAMETER Value
    A DateTime, a DateTimeOffset or text.
    .OUTPUTS
    System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $culture) }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $culture) }
    return [string]$Value
}

function Get-GwKitStatePath {
    <#
    .SYNOPSIS
    Returns the path of the kit state file inside a gateway folder.
    .PARAMETER Path
    Gateway folder.
    .OUTPUTS
    System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Join-Path (Resolve-GwFullPath -Path $Path) 'kit-state.json')
}

function Get-GwKitState {
    <#
    .SYNOPSIS
    Loads kit-state.json from a gateway folder.
    .DESCRIPTION
    setup.ps1 records what it generated (runtime, distro, trading mode, container and project
    names, API port, image reference) so doctor, harden, start and uninstall act on the same
    stack without asking again. A missing or unreadable file returns null; callers then report
    "setup has not run here" instead of failing.
    .PARAMETER Path
    Gateway folder.
    .OUTPUTS
    PSCustomObject with the stored properties, or null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Read-GwTextFile -Path (Get-GwKitStatePath -Path $Path)
    if ([string]::IsNullOrEmpty($text)) { return $null }
    try { return ($text | ConvertFrom-Json) }
    catch [System.ArgumentException] {
        Write-Verbose ('kit-state.json is not valid JSON: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Save-GwKitState {
    <#
    .SYNOPSIS
    Writes kit-state.json into a gateway folder.
    .DESCRIPTION
    Adds Schema = 1 and writes atomically as UTF-8 without byte-order mark. The state never
    contains a credential: only names, ports and the image reference.
    .PARAMETER Path
    Gateway folder (must exist).
    .PARAMETER State
    Object with Runtime, Distro, TradingMode, ContainerName, ProjectName, ApiPort, ImageRef.
    .OUTPUTS
    None. Side effect: <Path>\kit-state.json is replaced.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][pscustomobject]$State
    )
    $document = [ordered]@{ Schema = 1 }
    foreach ($property in $State.PSObject.Properties) {
        if ($property.Name -ne 'Schema') { $document[$property.Name] = $property.Value }
    }
    $json = ([pscustomobject]$document | ConvertTo-Json -Depth 4)
    Write-GwFileAtomic -Path (Get-GwKitStatePath -Path $Path) -Text ($json.Replace("`r`n", "`n") + "`n")
}

function Get-GwLoginRejection {
    <#
    .SYNOPSIS
    Returns when IBKR last rejected the stored credentials, as recorded in kit-state.json.
    .DESCRIPTION
    The record (LoginRejectedUtc) is what keeps setup.ps1 and start.ps1 from sending the same
    credentials again; only writing both secret files again clears it. The value is returned
    as the text that was stored: PowerShell 7 parses an ISO timestamp in JSON into a DateTime,
    and a plain string cast would turn that into '11/12/2026 01:00:00', which was then shown
    and written back. ConvertTo-GwTimestampText gives the same text under both editions.
    .PARAMETER Path
    Gateway folder.
    .OUTPUTS
    System.String: 'yyyy-MM-ddTHH:mm:ssZ', or an empty string when nothing is recorded (or
    setup has not run in the folder).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $state = Get-GwKitState -Path $Path
    if ($null -eq $state) { return '' }
    return (ConvertTo-GwTimestampText -Value (Get-GwPropertyValue -InputObject $state -Name 'LoginRejectedUtc' -Default ''))
}

function Save-GwLoginRejection {
    <#
    .SYNOPSIS
    Records in kit-state.json that IBKR rejected the stored credentials now.
    .DESCRIPTION
    Sets LoginRejectedUtc to the current UTC time and rewrites the state file atomically. From
    then on setup.ps1 (without -ResetSecrets) and start.ps1 refuse to start the stack. A
    failure to write is thrown: the caller stops the stack in a finally block, so the
    credentials are not sent again even when the record could not be saved.
    .PARAMETER Path
    Gateway folder (setup.ps1 must have run there).
    .OUTPUTS
    System.String: the recorded time.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $state = Get-GwKitState -Path $Path
    if ($null -eq $state) {
        throw (New-Object System.InvalidOperationException(('No kit-state.json in {0}: the rejected login could not be recorded.' -f (Resolve-GwFullPath -Path $Path))))
    }
    $stamp = ConvertTo-GwTimestampText -Value (Get-GwUtcNow)
    $state | Add-Member -NotePropertyName 'LoginRejectedUtc' -NotePropertyValue $stamp -Force
    Save-GwKitState -Path $Path -State $state
    return $stamp
}

function Write-GwLog {
    <#
    .SYNOPSIS
    Appends one timestamped line to a size-bounded log file.
    .DESCRIPTION
    The start-at-boot and clock-fix tasks run with nobody watching, so they leave a trace here.
    Growth is bounded: when the file exceeds MaxBytes it is renamed to '<file>.1' (replacing an
    older '.1') before the new line is written, so at most two files of MaxBytes exist. A log
    line never contains a credential; callers pass phase tokens, exit codes and fixed text.
    .PARAMETER Path
    Log file; its directory must exist.
    .PARAMETER Message
    Text of the line.
    .PARAMETER MaxBytes
    Rotation threshold in bytes; default 262144.
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [ValidateRange(64, 104857600)][int]$MaxBytes = 262144
    )
    $target = Resolve-GwFullPath -Path $Path
    if ([System.IO.File]::Exists($target)) {
        $length = (New-Object System.IO.FileInfo($target)).Length
        if ($length -gt $MaxBytes) {
            $rotated = $target + '.1'
            if ([System.IO.File]::Exists($rotated)) { [System.IO.File]::Delete($rotated) }
            [System.IO.File]::Move($target, $rotated)
        }
    }
    $stamp = ConvertTo-GwTimestampText -Value ([DateTime]::UtcNow)
    $line = '{0} {1}{2}' -f $stamp, $Message.Replace("`r", ' ').Replace("`n", ' '), "`n"
    [System.IO.File]::AppendAllText($target, $line, (New-Object System.Text.UTF8Encoding($false)))
}
