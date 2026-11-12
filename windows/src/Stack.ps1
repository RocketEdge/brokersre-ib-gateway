# The container side of the Windows host kit: which runtime is present (Docker Desktop or Docker
# Engine inside a WSL distribution), how docker and docker compose are invoked for each, how the
# compose file is rendered from the template, how the gateway's login is followed through its
# phase file, and the connection snippets shown at the end of setup.
#
# Rules that shape this file: the kit never restarts a running gateway (a restart forces a new
# login with 2FA), never retries a failed login (repeated failures can lock an IBKR account),
# never automates 2FA, and treats an unknown phase token as "not ready", never as healthy.

function Get-GwComposeSetting {
    <#
    .SYNOPSIS
    Derives the names and ports that follow from the trading mode.
    .DESCRIPTION
    One brokerage session per container: paper and live get different project names, container
    names and host ports, so both can exist on one computer (in two folders, with two IBKR
    usernames). The API listens on 4002 (paper) or 4001 (live); inside the container a relay
    publishes it on 4004 or 4003, and the compose file maps 127.0.0.1:<api> to that relay port.
    .PARAMETER TradingMode
    'paper' or 'live'.
    .OUTPUTS
    PSCustomObject: TradingMode, ProjectName, ContainerName, ApiPort, RelayPort.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][ValidateSet('paper', 'live')][string]$TradingMode)
    $mode = $TradingMode.ToLowerInvariant()
    $apiPort = 4002
    $relayPort = 4004
    if ($mode -eq 'live') {
        $apiPort = 4001
        $relayPort = 4003
    }
    return [pscustomobject][ordered]@{
        TradingMode   = $mode
        ProjectName   = 'brokersre-gateway-{0}' -f $mode
        ContainerName = 'brokersre-ib-gateway-{0}' -f $mode
        ApiPort       = $apiPort
        RelayPort     = $relayPort
    }
}

function ConvertTo-GwComposeText {
    <#
    .SYNOPSIS
    Renders compose.yaml from the template text.
    .DESCRIPTION
    Pure text transformation: replaces the __TOKEN__ placeholders of
    windows/templates/compose.yaml.tmpl. Every input is validated against a strict pattern
    first, because the values land in YAML: an image reference with a space, quote, '#' or line
    break is refused rather than escaped. A placeholder left over after rendering is an error,
    so a template change cannot silently ship a broken file. Credentials are never an input:
    the template refers to the two secret files only.
    .PARAMETER TemplateText
    Content of compose.yaml.tmpl.
    .PARAMETER ImageRef
    Image reference, a tag ('ghcr.io/rocketedge/brokersre-ib-gateway:stable') or, better, a
    digest ('...@sha256:<64 hex>').
    .PARAMETER TradingMode
    'paper' or 'live'.
    .PARAMETER TimeZone
    IANA time zone for the gateway (the AutoRestartTime is in this zone), e.g. 'America/New_York'.
    .PARAMETER AutoRestartTime
    IBC daily restart time, 'hh:mm AM|PM'; keep it outside the IBKR reset windows.
    .PARAMETER AllowApiOrders
    Sets READ_ONLY_API to "no" so API clients can place orders. Off by default: least privilege.
    .OUTPUTS
    System.String, the compose file with LF line endings.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$TemplateText,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ImageRef,
        [Parameter(Mandatory = $true)][ValidateSet('paper', 'live')][string]$TradingMode,
        [Parameter(Mandatory = $true)][string]$TimeZone,
        [Parameter(Mandatory = $true)][string]$AutoRestartTime,
        [switch]$AllowApiOrders
    )
    if ($ImageRef -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/:-]{0,200}(@sha256:[0-9a-f]{64})?$') {
        throw (New-Object System.ArgumentException('ImageRef must be an image reference such as ghcr.io/rocketedge/brokersre-ib-gateway:stable or name@sha256:<64 hex digits>.'))
    }
    if ($TimeZone -cnotmatch '^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+){0,2}$') {
        throw (New-Object System.ArgumentException('TimeZone must be an IANA zone name such as America/New_York or Etc/UTC.'))
    }
    if ($AutoRestartTime -cnotmatch '^(0?[1-9]|1[0-2]):[0-5][0-9] (AM|PM)$') {
        throw (New-Object System.ArgumentException('AutoRestartTime must look like 11:45 PM.'))
    }
    $setting = Get-GwComposeSetting -TradingMode $TradingMode
    $readOnlyApi = 'yes'
    if ($AllowApiOrders) { $readOnlyApi = 'no' }
    $values = [ordered]@{
        '__PROJECT_NAME__'      = $setting.ProjectName
        '__CONTAINER_NAME__'    = $setting.ContainerName
        '__IMAGE_REF__'         = $ImageRef
        '__TRADING_MODE__'      = $setting.TradingMode
        '__READ_ONLY_API__'     = $readOnlyApi
        '__AUTO_RESTART_TIME__' = $AutoRestartTime
        '__TIME_ZONE__'         = $TimeZone
        '__HOST_PORT__'         = [string]$setting.ApiPort
        '__RELAY_PORT__'        = [string]$setting.RelayPort
    }
    $text = $TemplateText.Replace("`r`n", "`n")
    foreach ($token in $values.Keys) { $text = $text.Replace($token, $values[$token]) }
    $leftover = [regex]::Match($text, '__[A-Z][A-Z_]*__')
    if ($leftover.Success) {
        throw (New-Object System.InvalidOperationException(('The compose template contains a placeholder the kit does not know: {0}.' -f $leftover.Value)))
    }
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    return $text
}

function Get-GwRuntime {
    <#
    .SYNOPSIS
    Finds the container runtime: Docker Desktop, or Docker Engine inside a WSL distribution.
    .DESCRIPTION
    Read-only. With Preference Auto it asks docker.exe first ('docker info'); an answer whose
    operating system is 'Docker Desktop' means mode DockerDesktop, any other engine reached
    through docker.exe means WindowsCli. When docker.exe is missing or cannot reach an engine it
    asks each WSL distribution (never Docker Desktop's own 'docker-desktop' distributions) and
    the first one whose 'docker info' succeeds becomes mode WslEngine. Nothing answering gives
    mode None with the reason in Detail. Linux versus Windows containers is reported in OsType;
    the prerequisite check judges it.
    .PARAMETER Preference
    Auto (default), DockerDesktop (docker.exe only) or WslEngine (WSL only).
    .PARAMETER Distro
    WSL distribution to use for WslEngine; empty means "the first that answers".
    .OUTPUTS
    PSCustomObject: Mode (DockerDesktop, WindowsCli, WslEngine, None), Distro, EngineName,
    OsType, ServerVersion, Detail.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('Auto', 'DockerDesktop', 'WslEngine')][string]$Preference = 'Auto',
        [string]$Distro = ''
    )
    $format = '{{.OSType}}|{{.OperatingSystem}}|{{.ServerVersion}}'
    $reasons = New-Object System.Collections.Generic.List[string]

    if ($Preference -ne 'WslEngine') {
        $probe = Invoke-GwDocker -ArgumentList @('info', '--format', $format)
        $line = [string]($probe.Output | Where-Object { $_ -match '^[a-z]+\|.*\|' } | Select-Object -First 1)
        if ($probe.ExitCode -eq 0 -and $line.Length -gt 0) {
            $parts = $line.Split('|')
            $mode = 'WindowsCli'
            if ($parts[1] -eq 'Docker Desktop') { $mode = 'DockerDesktop' }
            return [pscustomobject][ordered]@{
                Mode = $mode; Distro = ''; EngineName = $parts[1]; OsType = $parts[0]; ServerVersion = $parts[2]; Detail = ''
            }
        }
        if ($probe.NotFound) { $reasons.Add('docker.exe is not installed on Windows') }
        else { $reasons.Add('docker.exe cannot reach a running engine') }
    }

    if ($Preference -ne 'DockerDesktop') {
        $candidates = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrEmpty($Distro)) {
            $candidates.Add($Distro)
        }
        else {
            $list = Invoke-GwWsl -ArgumentList @('--list', '--quiet')
            if ($list.ExitCode -eq 0) {
                foreach ($name in $list.Output) {
                    $trimmed = $name.Trim()
                    if ($trimmed.Length -gt 0 -and $trimmed -notlike 'docker-desktop*') { $candidates.Add($trimmed) }
                }
            }
            if ($candidates.Count -eq 0) { $reasons.Add('no WSL distribution other than Docker Desktop''s own was found') }
        }
        foreach ($candidate in $candidates) {
            $probe = Invoke-GwWsl -ArgumentList @('-d', $candidate, '--', 'docker', 'info', '--format', $format)
            $line = [string]($probe.Output | Where-Object { $_ -match '^[a-z]+\|.*\|' } | Select-Object -First 1)
            if ($probe.ExitCode -eq 0 -and $line.Length -gt 0) {
                $parts = $line.Split('|')
                return [pscustomobject][ordered]@{
                    Mode = 'WslEngine'; Distro = $candidate; EngineName = $parts[1]; OsType = $parts[0]; ServerVersion = $parts[2]; Detail = ''
                }
            }
            $reasons.Add(('docker in the WSL distribution {0} did not answer' -f $candidate))
        }
    }

    return [pscustomobject][ordered]@{
        Mode = 'None'; Distro = ''; EngineName = ''; OsType = ''; ServerVersion = ''; Detail = (($reasons.ToArray() -join '; ') + '.')
    }
}

function Invoke-GwContainerCli {
    <#
    .SYNOPSIS
    Runs a docker command against the detected runtime.
    .DESCRIPTION
    The one place that decides between docker.exe (Docker Desktop, WindowsCli) and
    'wsl -d <distro> -- docker' (Docker Engine in WSL). With a working directory the WSL form
    uses 'wsl --cd <Windows path>', which wsl.exe translates itself, so the kit never converts
    paths. Mode None is an error: callers check the runtime first.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER ArgumentList
    docker arguments.
    .PARAMETER WorkingDirectory
    Windows folder to run in (WslEngine only; docker.exe calls use absolute paths instead).
    .PARAMETER Interactive
    Show the command's own output instead of capturing it.
    .OUTPUTS
    PSCustomObject from the wrapper: ExitCode, Output, ReceivedUtc, NotFound.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [string]$WorkingDirectory = '',
        [switch]$Interactive
    )
    switch ([string]$Runtime.Mode) {
        'WslEngine' {
            $wslArguments = New-Object System.Collections.Generic.List[string]
            $wslArguments.Add('-d')
            $wslArguments.Add([string]$Runtime.Distro)
            if (-not [string]::IsNullOrEmpty($WorkingDirectory)) {
                $wslArguments.Add('--cd')
                $wslArguments.Add($WorkingDirectory)
            }
            $wslArguments.Add('--')
            $wslArguments.Add('docker')
            foreach ($argument in $ArgumentList) { $wslArguments.Add($argument) }
            return (Invoke-GwWsl -ArgumentList $wslArguments.ToArray() -Interactive:$Interactive)
        }
        { $_ -eq 'DockerDesktop' -or $_ -eq 'WindowsCli' } {
            return (Invoke-GwDocker -ArgumentList $ArgumentList -Interactive:$Interactive)
        }
        default {
            throw (New-Object System.InvalidOperationException('No container runtime was detected; run doctor.ps1 to see why.'))
        }
    }
}

function Invoke-GwCompose {
    <#
    .SYNOPSIS
    Runs 'docker compose' for the stack in a gateway folder.
    .DESCRIPTION
    Docker Desktop: 'docker compose -f <folder>\compose.yaml <arguments>' (the project directory
    is the file's folder, so './secrets/...' resolves there). Docker Engine in WSL:
    'wsl -d <distro> --cd <folder> -- docker compose -f compose.yaml <arguments>'.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER Path
    Gateway folder holding compose.yaml.
    .PARAMETER ArgumentList
    compose arguments, for example 'up', '-d'.
    .PARAMETER Interactive
    Show compose's own output (image pull progress).
    .OUTPUTS
    PSCustomObject from the wrapper.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [switch]$Interactive
    )
    $folder = Resolve-GwFullPath -Path $Path
    if ([string]$Runtime.Mode -eq 'WslEngine') {
        $arguments = [string[]](@('compose', '-f', 'compose.yaml') + $ArgumentList)
        return (Invoke-GwContainerCli -Runtime $Runtime -ArgumentList $arguments -WorkingDirectory $folder -Interactive:$Interactive)
    }
    $arguments = [string[]](@('compose', '-f', (Join-Path $folder 'compose.yaml')) + $ArgumentList)
    return (Invoke-GwContainerCli -Runtime $Runtime -ArgumentList $arguments -Interactive:$Interactive)
}

function Start-GwStack {
    <#
    .SYNOPSIS
    Starts the gateway stack with 'docker compose up -d'.
    .DESCRIPTION
    'up -d' is idempotent: a running container with an unchanged definition is left alone. With
    -NoRecreate a running container is left alone even when the definition changed, which is
    what the unattended start tasks use: they may start a stopped gateway but must never replace
    a running one (that would force a new login with 2FA).
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER Path
    Gateway folder.
    .PARAMETER NoRecreate
    Pass --no-recreate.
    .PARAMETER ShowProgress
    Let compose print its progress (image pull) to the console.
    .OUTPUTS
    System.Boolean: true when compose exited with 0. Nothing is started under -WhatIf (returns false).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$NoRecreate,
        [switch]$ShowProgress
    )
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('up')
    $arguments.Add('-d')
    if ($NoRecreate) { $arguments.Add('--no-recreate') }
    if (-not $PSCmdlet.ShouldProcess($Path, ('docker compose {0}' -f ($arguments.ToArray() -join ' ')))) { return $false }
    $result = Invoke-GwCompose -Runtime $Runtime -Path $Path -ArgumentList $arguments.ToArray() -Interactive:$ShowProgress
    if ($result.ExitCode -ne 0) {
        foreach ($line in $result.Output) { Write-GwConsole -Message $line -Status 'FAIL' }
        return $false
    }
    return $true
}

function Stop-GwStack {
    <#
    .SYNOPSIS
    Stops the gateway stack with 'docker compose stop'.
    .DESCRIPTION
    An explicit stop: with 'restart: unless-stopped' Docker does not start the container again
    until someone runs setup.ps1 or start.ps1. Used by uninstall and after a rejected login, so
    that the restart policy cannot retry a bad password.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER Path
    Gateway folder.
    .OUTPUTS
    System.Boolean: true when compose exited with 0; false under -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if (-not $PSCmdlet.ShouldProcess($Path, 'docker compose stop (the gateway logs out; the next start needs a new login with 2FA)')) { return $false }
    $result = Invoke-GwCompose -Runtime $Runtime -Path $Path -ArgumentList @('stop')
    return ($result.ExitCode -eq 0)
}

function Remove-GwStack {
    <#
    .SYNOPSIS
    Removes the stack's container and network with 'docker compose down', optionally its volumes.
    .DESCRIPTION
    Without -RemoveVolumes the named volumes (gateway settings, logs) stay, so a later setup
    finds its settings again. With -RemoveVolumes they are deleted for good.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER Path
    Gateway folder.
    .PARAMETER RemoveVolumes
    Also delete the named volumes ('down --volumes').
    .OUTPUTS
    System.Boolean: true when compose exited with 0; false under -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RemoveVolumes
    )
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('down')
    if ($RemoveVolumes) { $arguments.Add('--volumes') }
    if (-not $PSCmdlet.ShouldProcess($Path, ('docker compose {0}' -f ($arguments.ToArray() -join ' ')))) { return $false }
    $result = Invoke-GwCompose -Runtime $Runtime -Path $Path -ArgumentList $arguments.ToArray()
    return ($result.ExitCode -eq 0)
}

function Wait-GwContainerEngine {
    <#
    .SYNOPSIS
    Waits, with a deadline, until the container engine answers.
    .DESCRIPTION
    After sign-in Docker Desktop needs up to a minute before 'docker info' works, and dockerd in
    a WSL distribution needs a few seconds after the distribution starts. The start task calls
    this before 'docker compose up'. Bounded: it never waits forever.
    .PARAMETER Runtime
    Object from Get-GwRuntime (the mode decides how docker is called).
    .PARAMETER TimeoutSeconds
    Give up after this many seconds.
    .PARAMETER PollSeconds
    Pause between attempts.
    .OUTPUTS
    System.Boolean: true when the engine answered within the deadline.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [ValidateRange(1, 60)][int]$PollSeconds = 5
    )
    $deadline = (Get-GwUtcNow).AddSeconds($TimeoutSeconds)
    while ($true) {
        $probe = Invoke-GwContainerCli -Runtime $Runtime -ArgumentList @('info', '--format', '{{.ServerVersion}}')
        if ($probe.ExitCode -eq 0) { return $true }
        if ((Get-GwUtcNow) -ge $deadline) { return $false }
        Wait-GwDelay -Seconds $PollSeconds
    }
}

function Get-GwGatewayPhase {
    <#
    .SYNOPSIS
    Reads the gateway's lifecycle phase from /var/log/ibgateway/state/phase.
    .DESCRIPTION
    The image writes one token to that file (log contract): starting, login, 2fa-pending,
    logged-in, restarting, existing-session, needs-human, stopping, stopped, exited, test-mode.
    The kit reads it with 'docker exec <container> cat ...'. Content that does not look like a
    token is reported as 'unknown' and never echoed, because raw gateway text may contain the
    IBKR username. An unreadable file (container not up yet, no such container) returns null.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER ContainerName
    Container to read from.
    .OUTPUTS
    System.String: a token, 'unknown', or null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$ContainerName
    )
    $result = Invoke-GwContainerCli -Runtime $Runtime -ArgumentList @('exec', $ContainerName, 'cat', '/var/log/ibgateway/state/phase')
    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) { return $null }
    $token = $result.Output[0].Trim()
    if ($token -cmatch '^[a-z0-9][a-z0-9-]{0,31}$') { return $token }
    return 'unknown'
}

function Get-GwContainerState {
    <#
    .SYNOPSIS
    Returns Docker's state of a container (running, exited, restarting, ...), or null when it does not exist.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER ContainerName
    Container to inspect.
    .OUTPUTS
    System.String or null.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$ContainerName
    )
    $result = Invoke-GwContainerCli -Runtime $Runtime -ArgumentList @('inspect', '--format', '{{.State.Status}}', $ContainerName)
    if ($result.ExitCode -ne 0 -or $result.Output.Count -eq 0) { return $null }
    $state = $result.Output[0].Trim()
    if ($state -cmatch '^[a-z]{1,20}$') { return $state }
    return $null
}

function Test-GwLoginFailure {
    <#
    .SYNOPSIS
    Tells whether the gateway reported a rejected login since a given time.
    .DESCRIPTION
    The image prints one JSON event per line on stdout; a rejected username or password shows
    as the events login_failed or login_failed_dialog (the phase stays 'login'). The kit looks
    for exactly those two event names in 'docker logs --since <time> --tail 400'. Stdout never
    carries a credential by the image's log contract, and the lines are matched, not printed.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER ContainerName
    Container whose stdout is read.
    .PARAMETER SinceUtc
    Only events after this UTC time count, so an old failure does not stop a new attempt.
    .OUTPUTS
    System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][datetime]$SinceUtc
    )
    $since = ConvertTo-GwTimestampText -Value $SinceUtc
    $result = Invoke-GwContainerCli -Runtime $Runtime -ArgumentList @('logs', '--since', $since, '--tail', '400', $ContainerName)
    if ($result.ExitCode -ne 0) { return $false }
    foreach ($line in $result.Output) {
        if ($line -match '"event"\s*:\s*"login_failed(_dialog)?"') { return $true }
    }
    return $false
}

function Get-GwPhaseMessage {
    <#
    .SYNOPSIS
    Translates a phase token into plain language and says whether to keep waiting.
    .DESCRIPTION
    Kind is Progress (keep following), Success (logged in) or Stop (a person must act; the
    follower ends). Only 'logged-in' is Success. Any token the kit does not know is Progress
    with an "unknown state" text: it can never count as healthy, and the follower's timeout
    bounds the wait.
    .PARAMETER Phase
    Token from Get-GwGatewayPhase.
    .PARAMETER ApiPort
    Host port of the API, shown in the success text.
    .PARAMETER ContainerName
    Container name, shown in instructions.
    .OUTPUTS
    PSCustomObject: Kind, Outcome (for Stop and Success), Text.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Phase,
        [Parameter(Mandatory = $true)][int]$ApiPort,
        [Parameter(Mandatory = $true)][string]$ContainerName
    )
    $kind = 'Progress'
    $outcome = ''
    $text = ''
    switch -CaseSensitive ($Phase) {
        'starting' { $text = 'Starting the gateway...' }
        'login' { $text = 'Logging in...' }
        '2fa-pending' { $text = 'Approve the IBKR Mobile prompt on your phone now' }
        'logged-in' {
            $kind = 'Success'
            $outcome = 'LoggedIn'
            $text = 'Logged in. API ready on 127.0.0.1:{0}' -f $ApiPort
        }
        'restarting' { $text = 'The gateway is doing its own restart (daily restart, or a new 2FA prompt after a timeout). Waiting...' }
        'existing-session' {
            $kind = 'Stop'
            $outcome = 'ExistingSession'
            $text = ('Another session is using this IBKR username (Trader Workstation, the mobile app or another gateway). ' +
                'Log that session out, or use a second username for the gateway, then run setup.ps1 again.')
        }
        'needs-human' {
            $kind = 'Stop'
            $outcome = 'NeedsHuman'
            $text = ('The gateway needs a person and will not continue by itself. Look at the last events: docker logs {0} ' +
                '(for a rejected username or password run setup.ps1 -ResetSecrets).') -f $ContainerName
        }
        'stopping' {
            $kind = 'Stop'
            $outcome = 'Stopped'
            $text = 'The gateway is stopping. Start it again with setup.ps1 when you are ready to log in.'
        }
        'stopped' {
            $kind = 'Stop'
            $outcome = 'Stopped'
            $text = 'The gateway has stopped. Start it again with setup.ps1 when you are ready to log in.'
        }
        'exited' {
            $kind = 'Stop'
            $outcome = 'Stopped'
            $text = 'The gateway process exited. See why with: docker logs {0}' -f $ContainerName
        }
        'test-mode' {
            $kind = 'Stop'
            $outcome = 'TestMode'
            $text = 'The container runs in test mode (IBC_LAUNCH=no): IB Gateway is not started. Remove IBC_LAUNCH and run setup.ps1 again.'
        }
        default {
            $text = 'Unknown state reported by the gateway image; treating it as not ready. Waiting...'
        }
    }
    return [pscustomobject]@{ Kind = $kind; Outcome = $outcome; Text = $text }
}

function Wait-GwGatewayLogin {
    <#
    .SYNOPSIS
    Follows the gateway from start to login and tells the operator what is happening.
    .DESCRIPTION
    Polls the phase token and prints one plain-language line per change. Read-only: it only
    runs 'docker exec ... cat', 'docker logs' and 'docker inspect'. It never starts, restarts
    or recreates anything and never touches 2FA; the operator approves on the phone.
    It ends on the first of: logged-in (LoggedIn); a phase that needs a person (NeedsHuman,
    ExistingSession, Stopped, TestMode); a rejected login reported on stdout (LoginFailed, on
    the first such event, without another poll: a failed login is never retried); a container
    that is not running (ContainerNotRunning); or the deadline (Timeout). An unknown token is
    never success: the follower keeps waiting until the deadline.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER ContainerName
    Gateway container.
    .PARAMETER ApiPort
    Host API port, for the success message.
    .PARAMETER TimeoutSeconds
    Overall deadline. Default 600: a first start pulls nothing here (the image is already
    present) but the Gateway needs a few minutes and the 2FA prompt needs the operator.
    .PARAMETER PollSeconds
    Pause between polls.
    .PARAMETER SinceUtc
    Start of the window for login_failed events; defaults to now.
    .OUTPUTS
    PSCustomObject: Outcome, Phase (last token seen, or empty), ElapsedSeconds, Message.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [Parameter(Mandatory = $true)][int]$ApiPort,
        [ValidateRange(1, 86400)][int]$TimeoutSeconds = 600,
        [ValidateRange(1, 60)][int]$PollSeconds = 3,
        [datetime]$SinceUtc = [DateTime]::MinValue
    )
    $started = Get-GwUtcNow
    if ($SinceUtc -eq [DateTime]::MinValue) { $SinceUtc = $started }
    $deadline = $started.AddSeconds($TimeoutSeconds)
    $lastShown = $null
    $lastPhase = ''
    $logsHint = 'See the events with: docker logs {0}' -f $ContainerName

    while ($true) {
        $phase = Get-GwGatewayPhase -Runtime $Runtime -ContainerName $ContainerName
        if ($null -eq $phase) {
            $state = Get-GwContainerState -Runtime $Runtime -ContainerName $ContainerName
            if ($state -ne 'running' -and $state -ne 'created') {
                $shownState = 'missing'
                if ($null -ne $state) { $shownState = $state }
                $message = 'The gateway container is not running (state: {0}). {1}' -f $shownState, $logsHint
                Write-GwConsole -Message $message -Status 'FAIL'
                return [pscustomobject]@{
                    Outcome = 'ContainerNotRunning'; Phase = $lastPhase; ElapsedSeconds = [int]((Get-GwUtcNow) - $started).TotalSeconds; Message = $message
                }
            }
            if ($lastShown -ne '<waiting>') {
                Write-GwConsole -Message 'Waiting for the gateway container...'
                $lastShown = '<waiting>'
            }
        }
        else {
            $lastPhase = $phase
            $info = Get-GwPhaseMessage -Phase $phase -ApiPort $ApiPort -ContainerName $ContainerName
            if ($lastShown -ne $phase) {
                $status = 'INFO'
                if ($info.Kind -eq 'Success') { $status = 'PASS' }
                elseif ($info.Kind -eq 'Stop') { $status = 'FAIL' }
                elseif ($phase -eq '2fa-pending') { $status = 'WARN' }
                Write-GwConsole -Message $info.Text -Status $status
                $lastShown = $phase
            }
            if ($info.Kind -ne 'Progress') {
                return [pscustomobject]@{
                    Outcome = $info.Outcome; Phase = $phase; ElapsedSeconds = [int]((Get-GwUtcNow) - $started).TotalSeconds; Message = $info.Text
                }
            }
        }

        if (Test-GwLoginFailure -Runtime $Runtime -ContainerName $ContainerName -SinceUtc $SinceUtc) {
            $message = ('IBKR rejected the username or password. The kit does not try again: repeated failed logins can lock the account. ' +
                'Check the credentials, then run setup.ps1 -ResetSecrets.')
            Write-GwConsole -Message $message -Status 'FAIL'
            return [pscustomobject]@{
                Outcome = 'LoginFailed'; Phase = $lastPhase; ElapsedSeconds = [int]((Get-GwUtcNow) - $started).TotalSeconds; Message = $message
            }
        }

        if ((Get-GwUtcNow) -ge $deadline) {
            $message = 'Stopped waiting after {0} seconds; the gateway keeps running. {1}' -f $TimeoutSeconds, $logsHint
            if ($lastPhase -eq '2fa-pending') {
                $message = ('Stopped waiting after {0} seconds. The gateway is still waiting for you and keeps prompting: ' +
                    'approve the IBKR Mobile prompt on your phone, then run setup.ps1 again to see the result.') -f $TimeoutSeconds
            }
            Write-GwConsole -Message $message -Status 'WARN'
            return [pscustomobject]@{
                Outcome = 'Timeout'; Phase = $lastPhase; ElapsedSeconds = [int]((Get-GwUtcNow) - $started).TotalSeconds; Message = $message
            }
        }
        Wait-GwDelay -Seconds $PollSeconds
    }
}

function Get-GwConnectionSnippet {
    <#
    .SYNOPSIS
    Returns two short connection examples: Python (ib_async) and C# (IBKR's TWS API client).
    .DESCRIPTION
    Shown at the end of setup so the operator can prove the API answers. Both examples are
    read-only: they connect and ask for the server time. Neither places, changes or cancels an
    order. The C# example uses the IBApi classes from IBKR's TWS API download; it is not
    compiled by this repository's tests.
    .PARAMETER ApiPort
    Host API port (4002 paper, 4001 live).
    .OUTPUTS
    PSCustomObject: Python (five lines) and CSharp (text), LF line endings.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][int]$ApiPort)
    $python = @(
        'from ib_async import IB'
        'ib = IB()'
        ('ib.connect("127.0.0.1", {0}, clientId=1, readonly=True)' -f $ApiPort)
        'print(ib.reqCurrentTime())'
        'ib.disconnect()'
    ) -join "`n"
    $csharp = @(
        '// IBApi comes with IBKR''s TWS API download (CSharpClient). Read-only: asks for the server time.'
        'class Wrapper : IBApi.DefaultEWrapper {'
        '    public override void currentTime(long time) => System.Console.WriteLine(System.DateTimeOffset.FromUnixTimeSeconds(time));'
        '}'
        'var signal = new IBApi.EReaderMonitorSignal();'
        'var client = new IBApi.EClientSocket(new Wrapper(), signal);'
        ('client.eConnect("127.0.0.1", {0}, 1);' -f $ApiPort)
        'var reader = new IBApi.EReader(client, signal); reader.Start();'
        'new System.Threading.Thread(() => { while (client.IsConnected()) { signal.waitForSignal(); reader.processMsgs(); } }) { IsBackground = true }.Start();'
        'client.reqCurrentTime();'
    ) -join "`n"
    return [pscustomobject]@{ Python = $python; CSharp = $csharp }
}
