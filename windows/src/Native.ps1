# Thin wrappers around everything outside PowerShell: docker, wsl, powercfg, schtasks, w32tm, the
# registry, Windows Firewall, CIM, the clock and the console prompt. Each external dependency is
# reached through exactly ONE function in this file, so the unit tests mock that function and the
# logic above it never runs a real command. Keep these wrappers free of decisions: they pass
# arguments through, capture output and report exit codes; they never interpret.

function ConvertTo-GwNativeArgument {
    <#
    .SYNOPSIS
    Quotes one argument for a Windows command line.
    .DESCRIPTION
    Windows passes a process one command-line string; the program splits it again with the
    rules of CommandLineToArgvW (used by docker, wsl, schtasks, powershell and the C runtime).
    An argument without space, tab or double quote is passed as it is. Otherwise it is wrapped
    in double quotes, each embedded quote becomes \" and backslashes are doubled only where
    they precede a quote (including the closing one). Doing this here, instead of relying on
    PowerShell, gives the same result on Windows PowerShell 5.1 and PowerShell 7, whose native
    argument passing differs for embedded quotes.
    .PARAMETER Argument
    The argument; may be empty.
    .OUTPUTS
    System.String, ready to be joined with spaces.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Argument)
    if ($Argument.Length -gt 0 -and $Argument.IndexOfAny([char[]]@([char]32, [char]9, [char]34)) -lt 0) { return $Argument }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append([char]34)
    $backslashes = 0
    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq [char]92) {
            $backslashes++
            continue
        }
        if ($character -eq [char]34) {
            [void]$builder.Append([char]92, ($backslashes * 2) + 1)
        }
        else {
            [void]$builder.Append([char]92, $backslashes)
        }
        [void]$builder.Append($character)
        $backslashes = 0
    }
    [void]$builder.Append([char]92, $backslashes * 2)
    [void]$builder.Append([char]34)
    return $builder.ToString()
}

function Invoke-GwNative {
    <#
    .SYNOPSIS
    Runs an executable with a deadline and returns its exit code and output lines.
    .DESCRIPTION
    Shared engine of the per-command wrappers. It starts the process itself
    (System.Diagnostics.Process) instead of using PowerShell's call operator, for four reasons:
    a deadline can be enforced (a hung docker or wsl must not hang doctor or the unattended
    start task: the process is killed and the result says TimedOut); standard input is closed,
    so no command can sit waiting for a keyboard nobody is at; arguments are quoted the same
    way on both PowerShell editions; and stderr text never becomes a PowerShell error record
    (Windows PowerShell 5.1 turns it into a terminating error under 'Stop').
    Standard output lines are stamped with the UTC time they arrived, which the clock check
    uses to compare a timestamp printed inside a container with the host clock. Standard error
    is appended after the output as plain text. A missing executable is a result (NotFound,
    exit code -1), not an exception, so a check can report "not installed".
    With -Interactive nothing is redirected: the command uses the console directly (image pull
    progress, the password prompt of schtasks, the keep-alive session), no deadline applies
    unless one is given, and Output is empty.
    .PARAMETER FilePath
    Executable name or path, resolved through PATH.
    .PARAMETER ArgumentList
    Arguments, one array element per argument; no shell is involved.
    .PARAMETER Interactive
    Do not capture; let the command use the console.
    .PARAMETER Utf8Output
    Decode the captured output as UTF-8 (docker and wsl print UTF-8; the default is the
    console's OEM code page).
    .PARAMETER TimeoutSeconds
    Deadline for a captured command; 0 means none. Default 120. Ignored with -Interactive.
    .OUTPUTS
    PSCustomObject: ExitCode (int; -1 not found, -2 timed out), Output (string[]), ReceivedUtc
    (datetime[], one per stdout line; stderr lines carry the completion time), NotFound (bool),
    TimedOut (bool).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyCollection()][string[]]$ArgumentList = @(),
        [switch]$Interactive,
        [switch]$Utf8Output,
        [ValidateRange(0, 86400)][int]$TimeoutSeconds = 120
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $stamps = New-Object System.Collections.Generic.List[datetime]
    $finish = {
        param([int]$Code, [bool]$Missing, [bool]$Expired)
        [pscustomobject]@{
            ExitCode    = $Code
            Output      = [string[]]$lines.ToArray()
            ReceivedUtc = [datetime[]]$stamps.ToArray()
            NotFound    = $Missing
            TimedOut    = $Expired
        }
    }
    $command = Get-Command -Name $FilePath -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        $lines.Add(('{0} was not found on this computer.' -f $FilePath))
        $stamps.Add([DateTime]::UtcNow)
        return (& $finish -1 $true $false)
    }
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $command.Source
    $startInfo.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-GwNativeArgument -Argument $_ }) -join ' ')
    $startInfo.UseShellExecute = $false
    $startInfo.WorkingDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
    if (-not $Interactive) {
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.CreateNoWindow = $true
        if ($Utf8Output) {
            $utf8 = New-Object System.Text.UTF8Encoding($false)
            $startInfo.StandardOutputEncoding = $utf8
            $startInfo.StandardErrorEncoding = $utf8
        }
    }
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        try { [void]$process.Start() }
        catch [System.ComponentModel.Win32Exception] {
            $lines.Add(('{0} could not be started: {1}' -f $FilePath, $_.Exception.Message))
            $stamps.Add([DateTime]::UtcNow)
            return (& $finish -1 $true $false)
        }
        if ($Interactive) {
            $process.WaitForExit()
            return (& $finish $process.ExitCode $false $false)
        }
        $process.StandardInput.Close()
        $errorTask = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::MaxValue
        if ($TimeoutSeconds -gt 0) { $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds) }
        $expired = $false
        while ($true) {
            $lineTask = $process.StandardOutput.ReadLineAsync()
            $wait = -1
            if ($TimeoutSeconds -gt 0) { $wait = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds) }
            $arrived = $false
            try { $arrived = $lineTask.Wait($wait) }
            catch [System.AggregateException] { break }
            if (-not $arrived) {
                $expired = $true
                break
            }
            $line = $lineTask.Result
            if ($null -eq $line) { break }
            $stamps.Add([DateTime]::UtcNow)
            $lines.Add($line)
        }
        if (-not $expired) {
            $wait = -1
            if ($TimeoutSeconds -gt 0) { $wait = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds) }
            if (-not $process.WaitForExit($wait)) { $expired = $true }
        }
        if ($expired) {
            try { $process.Kill() }
            catch [System.InvalidOperationException] { Write-Verbose 'The process had already exited.' }
            catch [System.ComponentModel.Win32Exception] { Write-Verbose ('The process could not be killed: {0}' -f $_.Exception.Message) }
            $lines.Add(('{0} timed out after {1} s and was stopped.' -f $FilePath, $TimeoutSeconds))
            $stamps.Add([DateTime]::UtcNow)
            return (& $finish -2 $false $true)
        }
        # Bounded: a grandchild that inherited the pipe must not keep this call waiting.
        $errorText = ''
        try {
            if ($errorTask.Wait(5000)) { $errorText = [string]$errorTask.Result }
        }
        catch [System.AggregateException] { Write-Verbose 'Standard error could not be read.' }
        foreach ($errorLine in ($errorText -split "`r?`n")) {
            if ($errorLine.Length -eq 0) { continue }
            $stamps.Add([DateTime]::UtcNow)
            $lines.Add($errorLine)
        }
        return (& $finish $process.ExitCode $false $false)
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-GwDocker {
    <#
    .SYNOPSIS
    The only place the kit runs docker.exe.
    .DESCRIPTION
    Used when the container runtime is Docker Desktop (docker.exe on the Windows PATH). For
    Docker Engine inside a WSL distribution the kit goes through Invoke-GwWsl instead; the
    choice is made by Invoke-GwContainerCli, never here.
    .PARAMETER ArgumentList
    docker arguments, one element each.
    .PARAMETER Interactive
    Show docker's own progress output instead of capturing it (no deadline).
    .PARAMETER TimeoutSeconds
    Deadline for a captured call; default 120.
    .OUTPUTS
    PSCustomObject from Invoke-GwNative.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [switch]$Interactive,
        [ValidateRange(0, 86400)][int]$TimeoutSeconds = 120
    )
    return (Invoke-GwNative -FilePath 'docker.exe' -ArgumentList $ArgumentList -Interactive:$Interactive -Utf8Output -TimeoutSeconds $TimeoutSeconds)
}

function Invoke-GwWsl {
    <#
    .SYNOPSIS
    The only place the kit runs wsl.exe.
    .DESCRIPTION
    wsl.exe prints its own messages (--version, --list) as UTF-16 unless WSL_UTF8=1 is set, so
    the variable is set for the call and restored afterwards; NUL characters are stripped as a
    fallback for WSL builds that ignore the variable. Output of Linux commands is unaffected.
    .PARAMETER ArgumentList
    wsl arguments, one element each.
    .PARAMETER Interactive
    Do not capture output (no deadline); used for the keep-alive session.
    .PARAMETER TimeoutSeconds
    Deadline for a captured call; default 120.
    .OUTPUTS
    PSCustomObject from Invoke-GwNative, Output cleaned of NUL characters and empty lines.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [switch]$Interactive,
        [ValidateRange(0, 86400)][int]$TimeoutSeconds = 120
    )
    $previous = $env:WSL_UTF8
    $env:WSL_UTF8 = '1'
    try {
        $result = Invoke-GwNative -FilePath 'wsl.exe' -ArgumentList $ArgumentList -Interactive:$Interactive -Utf8Output -TimeoutSeconds $TimeoutSeconds
    }
    finally {
        $env:WSL_UTF8 = $previous
    }
    $cleanLines = New-Object System.Collections.Generic.List[string]
    $cleanStamps = New-Object System.Collections.Generic.List[datetime]
    for ($index = 0; $index -lt $result.Output.Count; $index++) {
        $line = $result.Output[$index].Replace([string][char]0, '')
        if ($line.Trim().Length -eq 0) { continue }
        $cleanLines.Add($line)
        $cleanStamps.Add($result.ReceivedUtc[$index])
    }
    return [pscustomobject]@{
        ExitCode    = $result.ExitCode
        Output      = [string[]]$cleanLines.ToArray()
        ReceivedUtc = [datetime[]]$cleanStamps.ToArray()
        NotFound    = $result.NotFound
        TimedOut    = $result.TimedOut
    }
}

function Invoke-GwPowerCfg {
    <#
    .SYNOPSIS
    The only place the kit runs powercfg.exe.
    .PARAMETER ArgumentList
    powercfg arguments, for example '/query', 'SCHEME_CURRENT', 'SUB_SLEEP', 'STANDBYIDLE'.
    .OUTPUTS
    PSCustomObject from Invoke-GwNative.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)
    return (Invoke-GwNative -FilePath 'powercfg.exe' -ArgumentList $ArgumentList)
}

function Invoke-GwSchTasks {
    <#
    .SYNOPSIS
    The only place the kit runs schtasks.exe.
    .DESCRIPTION
    The kit creates tasks from XML ('/Create /XML'), because only the XML form expresses an
    event trigger (resume from sleep). With -Interactive schtasks talks to the console itself;
    that is how Windows asks for the account password of a "run whether logged on or not" task,
    so the password never passes through the kit or a command line.
    .PARAMETER ArgumentList
    schtasks arguments.
    .PARAMETER Interactive
    Let schtasks prompt on the console.
    .OUTPUTS
    PSCustomObject from Invoke-GwNative.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '',
        Justification = 'Named after the executable it wraps, schtasks.exe.')]
    param(
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [switch]$Interactive
    )
    return (Invoke-GwNative -FilePath 'schtasks.exe' -ArgumentList $ArgumentList -Interactive:$Interactive)
}

function Invoke-GwW32tm {
    <#
    .SYNOPSIS
    The only place the kit runs w32tm.exe.
    .PARAMETER ArgumentList
    w32tm arguments, for example '/stripchart', '/computer:time.windows.com', '/samples:1', '/dataonly'.
    .OUTPUTS
    PSCustomObject from Invoke-GwNative.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)
    return (Invoke-GwNative -FilePath 'w32tm.exe' -ArgumentList $ArgumentList)
}

function Invoke-GwRegistry {
    <#
    .SYNOPSIS
    The only place the kit touches the registry.
    .DESCRIPTION
    Get returns a value or null (missing key or value); Test reports whether a key exists;
    GetValues returns every value of a key as a hashtable (empty for a missing key); Set writes
    a DWord or String value, creating the key; Remove deletes one value. Set and Remove are
    called only from the harden functions, behind ShouldProcess and the change journal.
    .PARAMETER Operation
    Get, Test, GetValues, Set or Remove.
    .PARAMETER Path
    Registry path in provider form, for example 'HKLM:\SOFTWARE\...'.
    .PARAMETER Name
    Value name (Get, Set, Remove).
    .PARAMETER Value
    Data to write (Set).
    .PARAMETER Kind
    DWord or String (Set); default DWord.
    .OUTPUTS
    Get: the value or null. Test: bool. GetValues: hashtable. Set, Remove: nothing.
    #>
    [CmdletBinding()]
    [OutputType([object], [bool], [hashtable])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Get', 'Test', 'GetValues', 'Set', 'Remove')][string]$Operation,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Name,
        $Value,
        [ValidateSet('DWord', 'String')][string]$Kind = 'DWord'
    )
    switch ($Operation) {
        'Test' { return (Test-Path -LiteralPath $Path) }
        'Get' {
            if (-not (Test-Path -LiteralPath $Path)) { return $null }
            $item = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
            if ($null -eq $item) { return $null }
            return $item.$Name
        }
        'GetValues' {
            $values = @{}
            if (Test-Path -LiteralPath $Path) {
                $key = Get-Item -LiteralPath $Path
                foreach ($valueName in $key.GetValueNames()) { $values[$valueName] = $key.GetValue($valueName) }
            }
            return $values
        }
        'Set' {
            if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
            New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
        }
        'Remove' {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        }
    }
}

function Test-GwPortSpecMatch {
    <#
    .SYNOPSIS
    Tells whether a firewall port specification names a given port.
    .DESCRIPTION
    Windows Firewall stores local ports as single numbers ('4002'), ranges ('4000-4010') or
    keywords ('Any', 'RPC'). Only an explicit number or range counts as naming the port: a
    program-scoped rule with 'Any' does not single out the gateway's ports.
    .PARAMETER Spec
    One port specification from a firewall rule.
    .PARAMETER Port
    Port to look for.
    .OUTPUTS
    System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Spec,
        [Parameter(Mandatory = $true)][int]$Port
    )
    $text = $Spec.Trim()
    if ($text -match '^(\d+)$') { return ([int]$Matches[1] -eq $Port) }
    if ($text -match '^(\d+)\s*-\s*(\d+)$') { return ($Port -ge [int]$Matches[1] -and $Port -le [int]$Matches[2]) }
    return $false
}

function Invoke-GwFirewall {
    <#
    .SYNOPSIS
    The only place the kit talks to Windows Firewall.
    .DESCRIPTION
    List returns the enabled inbound ALLOW rules whose TCP local ports name one of the given
    ports. It reads through the Windows Firewall COM API (HNetCfg.FwPolicy2), which needs no
    elevation and enumerates every rule in about 0.3 s on both PowerShell editions; the
    NetSecurity cmdlets need one association query per rule for the port filter, which took
    7 s in PowerShell 7 and about three minutes in Windows PowerShell 5.1 (measured
    2026-11-12, 272 rules). Exists reports whether a rule with a given name (ID) is present.
    Add creates an inbound BLOCK rule for TCP ports on all profiles; Remove deletes a rule by
    name. Add and Remove use the NetSecurity cmdlets, need elevation and are called only from
    the harden functions, behind ShouldProcess and the change journal. netsh is not used: its
    output is localised.
    .PARAMETER Operation
    List, Exists, Add or Remove.
    .PARAMETER Port
    Ports to look for (List) or to block (Add).
    .PARAMETER Name
    Rule name (Exists, Add, Remove).
    .PARAMETER DisplayName
    Rule display name (Add).
    .PARAMETER Description
    Rule description (Add).
    .OUTPUTS
    List: PSCustomObject per rule with Name, DisplayName, Profile, LocalPort, RemoteAddress and
    Program ('Any' when the rule is not tied to one executable). Exists: bool. Add, Remove: nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('List', 'Exists', 'Add', 'Remove')][string]$Operation,
        [int[]]$Port = @(),
        [string]$Name,
        [string]$DisplayName,
        [string]$Description
    )
    switch ($Operation) {
        'List' {
            # INetFwRule constants: Direction 1 = inbound, Action 1 = allow, Protocol 6 = TCP;
            # Profiles is a bit mask (1 domain, 2 private, 4 public, 0x7FFFFFFF all).
            $policy = New-Object -ComObject HNetCfg.FwPolicy2
            try {
                foreach ($rule in @($policy.Rules)) {
                    if (-not $rule.Enabled -or $rule.Direction -ne 1 -or $rule.Action -ne 1 -or $rule.Protocol -ne 6) { continue }
                    $localPorts = [string[]]@(([string]$rule.LocalPorts).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
                    $named = $false
                    foreach ($spec in $localPorts) {
                        foreach ($candidate in $Port) {
                            if (Test-GwPortSpecMatch -Spec $spec -Port $candidate) { $named = $true }
                        }
                    }
                    if (-not $named) { continue }
                    $remote = [string[]]@(([string]$rule.RemoteAddresses).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
                    if ($remote.Count -eq 0 -or $remote -contains '*') { $remote = [string[]]@('Any') }
                    $program = 'Any'
                    if (-not [string]::IsNullOrEmpty([string]$rule.ApplicationName)) { $program = [string]$rule.ApplicationName }
                    $mask = [int]$rule.Profiles
                    $profileNames = New-Object System.Collections.Generic.List[string]
                    if ($mask -eq 0x7FFFFFFF) { $profileNames.Add('Any') }
                    else {
                        if (($mask -band 1) -ne 0) { $profileNames.Add('Domain') }
                        if (($mask -band 2) -ne 0) { $profileNames.Add('Private') }
                        if (($mask -band 4) -ne 0) { $profileNames.Add('Public') }
                    }
                    [pscustomobject][ordered]@{
                        Name          = [string]$rule.Name
                        DisplayName   = [string]$rule.Name
                        Profile       = ($profileNames.ToArray() -join ', ')
                        LocalPort     = $localPorts
                        RemoteAddress = $remote
                        Program       = $program
                    }
                }
            }
            finally {
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($policy)
            }
        }
        'Exists' {
            $existing = Get-NetFirewallRule -Name $Name -ErrorAction SilentlyContinue
            return ($null -ne $existing)
        }
        'Add' {
            New-NetFirewallRule -Name $Name -DisplayName $DisplayName -Description $Description -Direction Inbound `
                -Action Block -Protocol TCP -LocalPort $Port -Profile Any -ErrorAction Stop | Out-Null
        }
        'Remove' {
            Remove-NetFirewallRule -Name $Name -ErrorAction Stop
        }
    }
}

function Get-GwVirtualizationInfo {
    <#
    .SYNOPSIS
    Reads the two CIM facts that tell whether hardware virtualization is usable.
    .DESCRIPTION
    Win32_ComputerSystem.HypervisorPresent is true once a hypervisor runs (WSL 2 needs one);
    Win32_Processor.VirtualizationFirmwareEnabled reports the firmware switch, but reads false
    while a hypervisor is already running, so the check looks at both. A failed query yields
    null for that fact; the check then reports SKIP.
    .OUTPUTS
    PSCustomObject: HypervisorPresent (bool or null), FirmwareEnabled (bool or null).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $hypervisor = $null
    $firmware = $null
    try {
        $system = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $hypervisor = [bool]$system.HypervisorPresent
        $processor = Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $firmware = [bool]$processor.VirtualizationFirmwareEnabled
    }
    catch [Microsoft.Management.Infrastructure.CimException] {
        Write-Verbose ('CIM query failed: {0}' -f $_.Exception.Message)
    }
    return [pscustomobject][ordered]@{ HypervisorPresent = $hypervisor; FirmwareEnabled = $firmware }
}

function Get-GwTcpListenerPort {
    <#
    .SYNOPSIS
    Lists the TCP ports something on this computer is listening on.
    .DESCRIPTION
    Reads the listener table through .NET (no elevation, no external command). Used to tell
    whether 4001, 4002 or 9810 are already taken before the stack starts.
    .OUTPUTS
    System.Int32[] of distinct port numbers.
    #>
    [CmdletBinding()]
    [OutputType([int[]])]
    param()
    $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
    return [int[]]@($listeners | ForEach-Object { [int]$_.Port } | Sort-Object -Unique)
}

function Get-GwDriveFreeByte {
    <#
    .SYNOPSIS
    Returns the free space of the drive that holds a path.
    .PARAMETER Path
    Any path on the drive; it need not exist.
    .OUTPUTS
    System.Int64 bytes, or null when the drive is missing, not ready or not a local drive.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory = $true)][string]$Path)
    try {
        $root = [System.IO.Path]::GetPathRoot((Resolve-GwFullPath -Path $Path))
        $drive = New-Object System.IO.DriveInfo($root)
        if (-not $drive.IsReady) { return $null }
        return [long]$drive.AvailableFreeSpace
    }
    catch [System.ArgumentException] {
        Write-Verbose ('Free space not readable for {0}: {1}' -f $Path, $_.Exception.Message)
        return $null
    }
    catch [System.Management.Automation.DriveNotFoundException] {
        Write-Verbose ('Drive not found for {0}' -f $Path)
        return $null
    }
}

function Test-GwIsAdministrator {
    <#
    .SYNOPSIS
    Tells whether this PowerShell session is elevated.
    .DESCRIPTION
    The harden steps that write HKLM, register a boot task or add a firewall rule need
    elevation; they ask this function first and stop with a plain instruction otherwise.
    .OUTPUTS
    System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-GwCurrentUser {
    <#
    .SYNOPSIS
    Returns the Windows account this session runs as.
    .OUTPUTS
    PSCustomObject: Name ('COMPUTER\user' or 'DOMAIN\user') and Sid ('S-1-...').
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return [pscustomobject]@{ Name = [string]$identity.Name; Sid = [string]$identity.User.Value }
}

function Get-GwUtcNow {
    <#
    .SYNOPSIS
    Returns the current UTC time.
    .DESCRIPTION
    Exists so that timeouts and clock comparisons can be tested with a mocked clock.
    .OUTPUTS
    System.DateTime with Kind = Utc.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param()
    return [DateTime]::UtcNow
}

function Wait-GwDelay {
    <#
    .SYNOPSIS
    Pauses for a number of seconds.
    .DESCRIPTION
    Every polling loop of the kit sleeps through this function, so tests replace it with a fake
    clock and a loop that waits minutes in production finishes in milliseconds under test.
    .PARAMETER Seconds
    Length of the pause.
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateRange(0, 3600)][int]$Seconds)
    Start-Sleep -Seconds $Seconds
}

function Read-GwSecureInput {
    <#
    .SYNOPSIS
    Asks the operator for a secret without echoing it.
    .DESCRIPTION
    Read-Host -AsSecureString shows asterisks, keeps the text out of the transcript and returns
    a SecureString; the value never appears on a command line or in the command history.
    .PARAMETER Prompt
    Prompt text.
    .OUTPUTS
    System.Security.SecureString.
    #>
    [CmdletBinding()]
    [OutputType([System.Security.SecureString])]
    param([Parameter(Mandatory = $true)][string]$Prompt)
    return (Read-Host -Prompt $Prompt -AsSecureString)
}

function Get-GwBstr {
    <#
    .SYNOPSIS
    Copies a SecureString into unmanaged memory as a BSTR.
    .DESCRIPTION
    The caller owns the returned pointer and MUST pass it to Clear-GwBstr in a finally block.
    Split out as its own function so a test can prove the pointer is always freed.
    .PARAMETER SecureValue
    The secret.
    .OUTPUTS
    System.IntPtr to the BSTR.
    #>
    [CmdletBinding()]
    [OutputType([IntPtr])]
    param([Parameter(Mandatory = $true)][System.Security.SecureString]$SecureValue)
    return [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
}

function Clear-GwBstr {
    <#
    .SYNOPSIS
    Zeroes and frees a BSTR obtained from Get-GwBstr.
    .PARAMETER Pointer
    The BSTR pointer; IntPtr.Zero is accepted and ignored.
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][IntPtr]$Pointer)
    if ($Pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer) }
}
