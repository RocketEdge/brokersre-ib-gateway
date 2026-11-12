# Entry points of the Windows host kit. setup.ps1, doctor.ps1, harden.ps1, start.ps1 and
# uninstall.ps1 are thin scripts that forward their parameters to the Invoke-Gw* functions in
# this file and exit with the returned exit code. The orchestration lives here, inside the
# module, for two reasons: Pester can mock the wrappers underneath it, and -WhatIf / -Confirm
# given to a script reach every function below (preference variables do not cross from a script
# into a module, but they do flow between functions of the same module).

function Write-GwCheckLine {
    <#
    .SYNOPSIS
    Prints one check result as a table row, with its fix on the next line.
    .PARAMETER Result
    Check result object.
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][pscustomobject]$Result)
    Write-GwConsole -Message ('{0,-5} {1,-24} {2}' -f $Result.Status, $Result.Name, $Result.Detail) -Status $Result.Status
    if (-not [string]::IsNullOrEmpty($Result.Fix) -and $Result.Status -ne 'PASS') {
        Write-GwConsole -Message ('      Fix: {0}' -f $Result.Fix)
    }
}

function Get-GwRuntimeFromState {
    <#
    .SYNOPSIS
    Builds the runtime object from kit-state.json without probing anything.
    .DESCRIPTION
    The unattended start task must not guess: it uses the runtime setup recorded (Docker Desktop
    or Docker Engine in a named WSL distribution) and then waits for that engine to answer.
    .PARAMETER State
    Object from Get-GwKitState.
    .OUTPUTS
    PSCustomObject shaped like the result of Get-GwRuntime (Mode, Distro, ...).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][pscustomobject]$State)
    $mode = [string](Get-GwPropertyValue -InputObject $State -Name 'Runtime' -Default 'DockerDesktop')
    if (@('DockerDesktop', 'WindowsCli', 'WslEngine') -notcontains $mode) { $mode = 'DockerDesktop' }
    return [pscustomobject][ordered]@{
        Mode          = $mode
        Distro        = [string](Get-GwPropertyValue -InputObject $State -Name 'Distro' -Default '')
        EngineName    = ''
        OsType        = 'linux'
        ServerVersion = ''
        Detail        = ''
    }
}

function Test-GwSecretMount {
    <#
    .SYNOPSIS
    Checks, with a harmless dummy file, that a container can read files in the protected secrets folder.
    .DESCRIPTION
    Writes '.winkit-probe' (fixed text, not a secret) into the secrets folder, bind-mounts it
    read-only into a tiny pinned container that runs as uid 1000 with no network, no
    capabilities and a read-only root, reads it with cat and deletes the file again. This is
    how the gateway will read the real secret files, so a "Permission denied" here means the
    restricted access list is too tight for this Docker installation.
    Observed 2026-11-12 on Docker Desktop 4.99.0 (WSL 2 backend): readable with an access list
    that names only the signed-in user. Not checked for Docker Engine inside WSL (the path
    translation is the distribution's business); that case returns NotChecked.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER SecretsPath
    The secrets folder.
    .OUTPUTS
    PSCustomObject: Result (Readable, NotReadable or NotChecked) and Reason.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$SecretsPath
    )
    if (@('DockerDesktop', 'WindowsCli') -notcontains [string]$Runtime.Mode) {
        return [pscustomobject]@{ Result = 'NotChecked'; Reason = 'not checked for Docker Engine inside WSL' }
    }
    $probe = Join-Path (Resolve-GwFullPath -Path $SecretsPath) '.winkit-probe'
    $containerName = 'winkit-acl-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8)
    try {
        Write-GwFileAtomic -Path $probe -Text 'winkit-probe'
        $arguments = @(
            'run', '--rm', '--name', $containerName, '--network', 'none', '--read-only', '--cap-drop', 'ALL',
            '--security-opt', 'no-new-privileges:true', '--user', '1000:1000',
            '-v', ('{0}:/run/secrets/winkit-probe:ro' -f $probe), $script:GwClockImage, 'cat', '/run/secrets/winkit-probe'
        )
        $result = Invoke-GwContainerCli -Runtime $Runtime -ArgumentList $arguments -TimeoutSeconds 300
    }
    finally {
        if ([System.IO.File]::Exists($probe)) { [System.IO.File]::Delete($probe) }
    }
    $text = $result.Output -join "`n"
    if ($result.ExitCode -eq 0 -and $text -match 'winkit-probe') { return [pscustomobject]@{ Result = 'Readable'; Reason = '' } }
    if ($text -match '(?i)permission denied|access is denied|operation not permitted') {
        return [pscustomobject]@{ Result = 'NotReadable'; Reason = 'the container got "permission denied" on the mounted file' }
    }
    return [pscustomobject]@{ Result = 'NotChecked'; Reason = 'the probe container could not run (the first run pulls a 2 MB image)' }
}

function Write-GwGatewayFolder {
    <#
    .SYNOPSIS
    Steps 2 to 5 of setup: the folder, the two secret files, the access list, compose.yaml and kit-state.json.
    .DESCRIPTION
    Everything setup writes to disk, in one place, so the caller can turn an access or I/O
    error into one plain message. Each write is behind ShouldProcess; under -WhatIf nothing is
    created, nothing is asked and no probe container runs. Existing secret files are kept
    unless -ResetSecrets is given. The values are read with a hidden prompt (or taken from the
    SecureString parameters), written byte-exact by Write-GwSecretFile and never printed.
    .PARAMETER Folder
    Gateway folder (absolute path).
    .PARAMETER Detected
    Runtime object from Get-GwRuntime; recorded in kit-state.json and used for the mount probe.
    .PARAMETER Setting
    Object from Get-GwComposeSetting (names and ports of the trading mode).
    .PARAMETER ImageRef
    Image reference, recorded in kit-state.json.
    .PARAMETER ComposeText
    Rendered compose.yaml.
    .PARAMETER ExistingCompose
    Current content of compose.yaml, or null when there is none.
    .PARAMETER ComposeDiffers
    True when compose.yaml exists and differs; it is then backed up and replaced (the caller
    has already checked -Force).
    .PARAMETER ResetSecrets
    Ask for the credentials again and replace the secret files.
    .PARAMETER AllowApiOrders
    Only used to print the warning that API clients may place orders.
    .PARAMETER UserNameSecure
    Username as a SecureString instead of the prompt.
    .PARAMETER PasswordSecure
    Password as a SecureString instead of the prompt.
    .OUTPUTS
    System.String: empty when everything was written, 'InvalidCredential' when a value was
    refused (empty or containing a line break). Access and I/O errors are thrown.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$Folder,
        [Parameter(Mandatory = $true)][pscustomobject]$Detected,
        [Parameter(Mandatory = $true)][pscustomobject]$Setting,
        [Parameter(Mandatory = $true)][string]$ImageRef,
        [Parameter(Mandatory = $true)][string]$ComposeText,
        [AllowNull()][AllowEmptyString()][string]$ExistingCompose,
        [bool]$ComposeDiffers,
        [switch]$ResetSecrets,
        [switch]$AllowApiOrders,
        [System.Security.SecureString]$UserNameSecure,
        [System.Security.SecureString]$PasswordSecure
    )
    $secrets = Join-Path $Folder 'secrets'
    $composePath = Join-Path $Folder 'compose.yaml'
    $hadCompose = $PSBoundParameters.ContainsKey('ExistingCompose') -and $null -ne $ExistingCompose -and $ExistingCompose.Length -gt 0

    Write-GwConsole -Message ''
    Write-GwConsole -Message 'Step 2 of 8: folder'
    foreach ($directory in @($Folder, $secrets)) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            if ($PSCmdlet.ShouldProcess($directory, 'Create folder')) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        }
    }

    Write-GwConsole -Message ''
    Write-GwConsole -Message 'Step 3 of 8: IBKR credentials (stored as two files in the secrets folder, never in compose.yaml)'
    $userFile = Join-Path $secrets 'ib-username'
    $passwordFile = Join-Path $secrets 'ib-password'
    $haveSecrets = (Test-Path -LiteralPath $userFile -PathType Leaf) -and (Test-Path -LiteralPath $passwordFile -PathType Leaf)
    if ($haveSecrets -and -not $ResetSecrets) {
        Write-GwConsole -Message 'Keeping the existing secret files (use -ResetSecrets to enter the credentials again).'
    }
    elseif ($PSCmdlet.ShouldProcess($secrets, 'Ask for the IBKR username and password and write the two secret files')) {
        $userValue = $UserNameSecure
        if ($null -eq $userValue) { $userValue = Read-GwSecureInput -Prompt 'IBKR username (typing is hidden)' }
        $passwordValue = $PasswordSecure
        if ($null -eq $passwordValue) { $passwordValue = Read-GwSecureInput -Prompt 'IBKR password (typing is hidden)' }
        try {
            Write-GwSecretFile -Path $userFile -SecureValue $userValue
            Write-GwSecretFile -Path $passwordFile -SecureValue $passwordValue
        }
        catch [System.ArgumentException] {
            Write-GwConsole -Message ('The credentials were not stored: {0}' -f $_.Exception.Message) -Status 'FAIL'
            return 'InvalidCredential'
        }
        Write-GwConsole -Message 'Secret files written (UTF-8, no byte-order mark, no newline).' -Status 'PASS'
    }

    Write-GwConsole -Message ''
    Write-GwConsole -Message 'Step 4 of 8: restricting the secrets folder to your Windows account'
    if (Test-Path -LiteralPath $secrets -PathType Container) {
        Protect-GwSecretFolder -Path $secrets
        if (-not $WhatIfPreference) {
            $mount = Test-GwSecretMount -Runtime $Detected -SecretsPath $secrets
            switch ($mount.Result) {
                'Readable' { Write-GwConsole -Message 'Only your account can read the folder, and a container can still read the files.' -Status 'PASS' }
                'NotReadable' {
                    Protect-GwSecretFolder -Path $secrets -IncludeSystem
                    $second = Test-GwSecretMount -Runtime $Detected -SecretsPath $secrets
                    $status = 'WARN'
                    if ($second.Result -eq 'NotReadable') { $status = 'FAIL' }
                    $explanation = ('With access for your account only, {0}. The folder now also allows SYSTEM and Administrators ' +
                        '(inheritance stays off), the tightest setting this Docker installation accepts. Result of the second check: {1}.') -f $mount.Reason, $second.Result
                    Write-GwConsole -Status $status -Message $explanation
                }
                default { Write-GwConsole -Message ('The folder is restricted to your account; whether a container can read it was not verified: {0}.' -f $mount.Reason) -Status 'WARN' }
            }
        }
    }

    Write-GwConsole -Message ''
    Write-GwConsole -Message 'Step 5 of 8: compose.yaml'
    if (-not $hadCompose -or $ComposeDiffers) {
        if ($PSCmdlet.ShouldProcess($composePath, 'Write compose.yaml')) {
            if ($ComposeDiffers) {
                $stamp = (Get-GwUtcNow).ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
                [System.IO.File]::Copy($composePath, ('{0}.bak-{1}' -f $composePath, $stamp), $true)
            }
            Write-GwFileAtomic -Path $composePath -Text $ComposeText
            Write-GwConsole -Message ('Wrote {0} (API on 127.0.0.1:{1}, read-only root, no capabilities).' -f $composePath, $Setting.ApiPort) -Status 'PASS'
        }
    }
    else {
        Write-GwConsole -Message 'compose.yaml is already up to date.'
    }
    if ($ImageRef -notmatch '@sha256:') {
        Write-GwConsole -Message ('Recommendation: pin the image by digest, a tag can move. Take the digest from the release notes and run setup.ps1 -ImageRef ' +
            'ghcr.io/rocketedge/brokersre-ib-gateway@sha256:<digest> -Force')
    }
    if ($AllowApiOrders) {
        Write-GwConsole -Message 'API clients may place orders (READ_ONLY_API=no). The kit itself never places, changes or cancels an order.' -Status 'WARN'
    }
    if ($PSCmdlet.ShouldProcess((Get-GwKitStatePath -Path $Folder), 'Write kit-state.json')) {
        Save-GwKitState -Path $Folder -State ([pscustomobject][ordered]@{
                Runtime       = [string]$Detected.Mode
                Distro        = [string]$Detected.Distro
                TradingMode   = $Setting.TradingMode
                ContainerName = $Setting.ContainerName
                ProjectName   = $Setting.ProjectName
                ApiPort       = $Setting.ApiPort
                ImageRef      = $ImageRef
            })
    }
    return ''
}

function Invoke-GwSetup {
    <#
    .SYNOPSIS
    Guided install of the gateway stack on this computer (the logic of setup.ps1).
    .DESCRIPTION
    Steps, each printed in plain language:
    1. Prerequisite checks (PASS/WARN/FAIL with the fix). Any FAIL stops here; nothing is created.
    2. Creates the gateway folder and its secrets folder.
    3. Asks for the IBKR username and password with a hidden prompt (or takes the SecureString
       parameters) and writes each as UTF-8 without byte-order mark and without newline.
       Existing secrets are kept unless -ResetSecrets is given.
    4. Restricts the secrets folder to the current account and verifies with a dummy file that
       a container can still read it; if not, widens the access list to SYSTEM and
       Administrators (inheritance stays off) and says so.
    5. Renders compose.yaml from the template. An existing, different compose.yaml is never
       replaced unless -Force is given (a backup is kept), so a re-run cannot silently switch
       paper to live or recreate a running gateway.
    6. 'docker compose up -d' (skipped with -NoStart).
    7. Follows the login through the phase file and tells the operator when to approve 2FA.
       A rejected login stops the stack once, so Docker's restart policy cannot retry it.
    8. Prints a Python and a C# connection snippet.
    Idempotent. Under -WhatIf nothing is created, changed, asked or started.
    .PARAMETER Path
    Gateway folder.
    .PARAMETER ImageRef
    Image reference; a tag by default, a digest is recommended.
    .PARAMETER Live
    Live trading mode (API on 127.0.0.1:4001). Without it: paper (127.0.0.1:4002).
    .PARAMETER AllowApiOrders
    Lets API clients place orders (READ_ONLY_API=no). Without it the API is read-only.
    .PARAMETER TimeZone
    IANA time zone of the gateway; AutoRestartTime is in this zone.
    .PARAMETER AutoRestartTime
    IBC daily restart time, 'hh:mm AM|PM'.
    .PARAMETER Runtime
    Auto (default), DockerDesktop or WslEngine.
    .PARAMETER Distro
    WSL distribution for WslEngine; empty means the first that answers.
    .PARAMETER ResetSecrets
    Ask for the credentials again and replace the secret files.
    .PARAMETER NoStart
    Stop after writing the files.
    .PARAMETER Force
    Replace an existing, different compose.yaml (a backup is kept).
    .PARAMETER LoginTimeoutSeconds
    How long to follow the login.
    .PARAMETER UserNameSecure
    Username as a SecureString instead of the prompt (automation and tests; never plain text).
    .PARAMETER PasswordSecure
    Password as a SecureString instead of the prompt (automation and tests; never plain text).
    .OUTPUTS
    PSCustomObject: ExitCode (0 done, 1 prerequisite or error, 2 started but not logged in),
    Outcome and Path.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
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
    $folder = Resolve-GwFullPath -Path $Path
    $tradingMode = 'paper'
    if ($Live) { $tradingMode = 'live' }
    $setting = Get-GwComposeSetting -TradingMode $tradingMode
    $done = { param([int]$Code, [string]$Outcome) [pscustomobject]@{ ExitCode = $Code; Outcome = $Outcome; Path = $folder } }

    Write-GwConsole -Message ('BrokerSRE gateway setup: {0} trading, folder {1}' -f $tradingMode, $folder)
    Write-GwConsole -Message ''
    Write-GwConsole -Message 'Step 1 of 8: checking this computer'
    $detected = Get-GwRuntime -Preference $Runtime -Distro $Distro
    $failed = 0
    foreach ($check in @(Get-GwPrerequisiteResult -Path $folder -TradingMode $tradingMode -Runtime $detected)) {
        Write-GwCheckLine -Result $check
        if ($check.Status -eq 'FAIL') { $failed++ }
    }
    if ($failed -gt 0) {
        Write-GwConsole -Message ('{0} check(s) FAIL. Fix them and run setup.ps1 again; nothing was changed.' -f $failed) -Status 'FAIL'
        return (& $done 1 'PrerequisiteFailed')
    }

    try {
        $composeText = ConvertTo-GwComposeText -TemplateText (Read-GwTextFile -Path (Join-Path (Join-Path $script:GwModuleRoot 'templates') 'compose.yaml.tmpl')) `
            -ImageRef $ImageRef -TradingMode $tradingMode -TimeZone $TimeZone -AutoRestartTime $AutoRestartTime -AllowApiOrders:$AllowApiOrders
    }
    catch [System.ArgumentException] {
        Write-GwConsole -Message $_.Exception.Message -Status 'FAIL'
        return (& $done 1 'InvalidParameter')
    }
    $composePath = Join-Path $folder 'compose.yaml'
    $existingCompose = Read-GwTextFile -Path $composePath
    $composeDiffers = ($null -ne $existingCompose -and $existingCompose -ne $composeText)
    if ($composeDiffers -and -not $Force) {
        Write-GwConsole -Message ('{0} exists and differs from what these options generate (for example another trading mode, image or time zone).' -f $composePath) -Status 'FAIL'
        Write-GwConsole -Message 'Run setup.ps1 with the options you used before, or add -Force to replace the file (a backup is kept; a running gateway is then recreated and needs a new login).'
        return (& $done 1 'ComposeDiffers')
    }

    try {
        $written = Write-GwGatewayFolder -Folder $folder -Detected $detected -Setting $setting -ImageRef $ImageRef -ComposeText $composeText `
            -ExistingCompose $existingCompose -ComposeDiffers $composeDiffers -ResetSecrets:$ResetSecrets -AllowApiOrders:$AllowApiOrders `
            -UserNameSecure $UserNameSecure -PasswordSecure $PasswordSecure
    }
    catch [System.UnauthorizedAccessException] {
        $denied = 'Windows denied access while preparing {0}: {1} Use a folder your account owns (-Path), or run from an elevated PowerShell.' -f $folder, $_.Exception.Message
        Write-GwConsole -Status 'FAIL' -Message $denied
        return (& $done 1 'AccessDenied')
    }
    catch [System.IO.IOException] {
        Write-GwConsole -Status 'FAIL' -Message ('A file in {0} could not be written: {1}' -f $folder, $_.Exception.Message)
        return (& $done 1 'WriteFailed')
    }
    if ($written -ne '') { return (& $done 1 $written) }

    if ($NoStart) {
        Write-GwConsole -Message ''
        Write-GwConsole -Message 'Stopped before starting the gateway (-NoStart). Run setup.ps1 again without -NoStart to start it and log in.'
        return (& $done 0 'NotStarted')
    }

    Write-GwConsole -Message ''
    Write-GwConsole -Message 'Step 6 of 8: starting the gateway (the first start downloads the image, about 1 GB)'
    $since = Get-GwUtcNow
    $started = Start-GwStack -Runtime $detected -Path $folder -ShowProgress
    if ($WhatIfPreference) {
        Write-GwConsole -Message 'Preview only (-WhatIf): nothing was created, changed, asked or started.'
        return (& $done 0 'WhatIf')
    }
    if (-not $started) {
        Write-GwConsole -Message 'docker compose up failed; see the messages above.' -Status 'FAIL'
        return (& $done 1 'StartFailed')
    }

    Write-GwConsole -Message ''
    Write-GwConsole -Message 'Step 7 of 8: logging in (have your phone with IBKR Mobile ready)'
    $login = Wait-GwGatewayLogin -Runtime $detected -ContainerName $setting.ContainerName -ApiPort $setting.ApiPort -TimeoutSeconds $LoginTimeoutSeconds -SinceUtc $since
    if ($login.Outcome -eq 'LoginFailed') {
        # Stop once, explicitly: with restart "unless-stopped" Docker would otherwise start the
        # container again and send the same rejected credentials to IBKR.
        Stop-GwStack -Runtime $detected -Path $folder -Confirm:$false | Out-Null
        Write-GwConsole -Message 'The gateway was stopped so the rejected credentials are not sent again.' -Status 'WARN'
        return (& $done 2 'LoginFailed')
    }
    if ($login.Outcome -ne 'LoggedIn') { return (& $done 2 $login.Outcome) }

    Write-GwConsole -Message ''
    Write-GwConsole -Message 'Step 8 of 8: connect your program'
    $snippet = Get-GwConnectionSnippet -ApiPort $setting.ApiPort
    Write-GwConsole -Message 'Python (pip install ib_async):'
    foreach ($line in ($snippet.Python -split "`n")) { Write-GwConsole -Message ('    {0}' -f $line) }
    Write-GwConsole -Message 'C# (IBKR TWS API client):'
    foreach ($line in ($snippet.CSharp -split "`n")) { Write-GwConsole -Message ('    {0}' -f $line) }
    Write-GwConsole -Message ''
    Write-GwConsole -Message 'Next: run doctor.ps1 to see what could interrupt the gateway on this computer (sleep, updates, restarts).'
    return (& $done 0 'LoggedIn')
}

function Invoke-GwDoctor {
    <#
    .SYNOPSIS
    Read-only health check of this computer as a gateway host (the logic of doctor.ps1).
    .DESCRIPTION
    Detects the runtime, runs every doctor check and reports. Without -Json it prints a table
    (status, name, detail and, for anything that is not PASS, the fix) and a summary. With
    -Json nothing is printed; the JSON text is in the result, for automation. ExitCode is 1
    when at least one check is FAIL and 0 otherwise; WARN and SKIP do not fail the run.
    .PARAMETER Path
    Gateway folder.
    .PARAMETER Json
    Build JSON instead of printing a table.
    .OUTPUTS
    PSCustomObject: Results, Summary (Pass, Warn, Fail, Skip), Mode, ExitCode and Json
    (JSON text when -Json was given, otherwise empty).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$Path = 'C:\BrokerSRE\gateway',
        [switch]$Json
    )
    $folder = Resolve-GwFullPath -Path $Path
    $runtime = Get-GwRuntime
    $results = @(Get-GwDoctorResult -Path $folder -Runtime $runtime)
    $summary = [pscustomobject][ordered]@{
        Pass = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
        Warn = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
        Fail = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
        Skip = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
    }
    $exitCode = 0
    if ($summary.Fail -gt 0) { $exitCode = 1 }
    $jsonText = ''
    if ($Json) {
        $document = [pscustomobject][ordered]@{
            schema       = 1
            generatedUtc = ConvertTo-GwTimestampText -Value (Get-GwUtcNow)
            path         = $folder
            mode         = [string]$runtime.Mode
            results      = @($results | ForEach-Object { [pscustomobject][ordered]@{ name = $_.Name; status = $_.Status; detail = $_.Detail; fix = $_.Fix } })
            summary      = [pscustomobject][ordered]@{ pass = $summary.Pass; warn = $summary.Warn; fail = $summary.Fail; skip = $summary.Skip }
            exitCode     = $exitCode
        }
        $jsonText = ($document | ConvertTo-Json -Depth 5).Replace("`r`n", "`n")
    }
    else {
        Write-GwConsole -Message ('BrokerSRE gateway doctor: folder {0}' -f $folder)
        Write-GwConsole -Message ('{0,-5} {1,-24} {2}' -f 'STATE', 'CHECK', 'DETAIL')
        foreach ($result in $results) { Write-GwCheckLine -Result $result }
        Write-GwConsole -Message ''
        $overall = 'PASS'
        if ($summary.Fail -gt 0) { $overall = 'FAIL' }
        elseif ($summary.Warn -gt 0) { $overall = 'WARN' }
        Write-GwConsole -Status $overall -Message ('{0} PASS, {1} WARN, {2} FAIL, {3} SKIP (SKIP means "could not be measured", not "fine").' -f `
                $summary.Pass, $summary.Warn, $summary.Fail, $summary.Skip)
    }
    return [pscustomobject]@{ Results = $results; Summary = $summary; Mode = [string]$runtime.Mode; ExitCode = $exitCode; Json = $jsonText }
}

function Invoke-GwHarden {
    <#
    .SYNOPSIS
    Applies the opt-in host changes doctor recommends, or undoes them (the logic of harden.ps1).
    .DESCRIPTION
    Nothing happens unless a switch asks for it. Every change goes through ShouldProcess
    (-WhatIf shows it, power changes ask for confirmation) and is journaled with its previous
    value in <Path>\harden-journal.json. -Undo reverts everything journaled, newest first, and
    cannot be combined with other options. One failing option is reported and the others still
    run; the exit code is then 1.
    For -StartAtBoot DockerDesktop only the start-after-sign-in task is configured. Windows
    auto-logon, which an unattended Docker Desktop host also needs, is explained but never
    configured: it stores the Windows password on the computer and lets anyone with physical
    access use the session, a trade-off the operator must make knowingly.
    .PARAMETER Path
    Gateway folder.
    .PARAMETER DisableSleep
    Never sleep or hibernate on AC power.
    .PARAMETER SetActiveHours
    Two hours, start and end (0-23, at most 18 hours apart), for example 6,23.
    .PARAMETER StartAtBoot
    DockerDesktop (task after sign-in) or WslEngine (task at startup, no sign-in).
    .PARAMETER AfterSignIn
    With -StartAtBoot WslEngine: register the sign-in variant instead of the boot task.
    .PARAMETER TaskLogonType
    Password or S4U: how a task that runs without sign-in logs on (boot task; clock-fix task
    when given).
    .PARAMETER ResumeClockFix
    Re-sync the container VM clock after every resume from sleep.
    .PARAMETER WslConfig
    Merge the recommended keys into .wslconfig (with a backup).
    .PARAMETER WslMemoryGB
    With -WslConfig: also set [wsl2] memory to this many GB.
    .PARAMETER WslConfigPath
    Path of .wslconfig; defaults to %UserProfile%\.wslconfig.
    .PARAMETER FirewallLoopbackOnly
    Block inbound TCP 4001, 4002 and 9810 from the network.
    .PARAMETER Undo
    Revert every journaled change.
    .OUTPUTS
    PSCustomObject: ExitCode (0 or 1).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '',
        Justification = 'Dispatcher: each harden function it calls asks ShouldProcess itself, and -WhatIf / -Confirm flow to them; asking here too would prompt twice.')]
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
        [string]$WslConfigPath = (Get-GwDefaultWslConfigPath),
        [switch]$FirewallLoopbackOnly,
        [switch]$Undo
    )
    $folder = Resolve-GwFullPath -Path $Path
    # Read the bound parameters here: inside the step script blocks below, $PSBoundParameters
    # would be the script block's own (empty) table.
    $hasLogonType = $PSBoundParameters.ContainsKey('TaskLogonType')
    $hasMemory = $PSBoundParameters.ContainsKey('WslMemoryGB')
    $steps = New-Object System.Collections.Generic.List[object]
    if ($Undo) {
        $steps.Add(@{ Name = 'Undo'; Run = { Undo-GwHardening -Path $folder | Out-Null } })
    }
    else {
        if ($DisableSleep) { $steps.Add(@{ Name = 'DisableSleep'; Run = { Disable-GwSleep -Path $folder } }) }
        if ($PSBoundParameters.ContainsKey('SetActiveHours')) {
            $steps.Add(@{ Name = 'SetActiveHours'; Run = { Set-GwUpdateActiveWindow -Path $folder -Start $SetActiveHours[0] -End $SetActiveHours[1] } })
        }
        if ($PSBoundParameters.ContainsKey('StartAtBoot')) {
            $steps.Add(@{
                    Name = 'StartAtBoot'
                    Run  = {
                        $logonType = 'Password'
                        if ($hasLogonType) { $logonType = $TaskLogonType }
                        Register-GwStartTask -Path $folder -Mode $StartAtBoot -AfterSignIn:$AfterSignIn -LogonType $logonType
                        if ($StartAtBoot -eq 'DockerDesktop' -or $AfterSignIn) {
                            Write-GwConsole -Message ('This task runs after sign-in. For a computer that must recover without anyone at the keyboard, also enable Windows ' +
                                'auto-logon with Sysinternals Autologon (it keeps the password as an encrypted LSA secret). The kit does not do this for you: ' +
                                'auto-logon lets anyone with physical access use your session. See the README, "Start after a restart".')
                        }
                        else {
                            Write-GwConsole -Message ('Validate the boot task once: restart Windows, do not sign in, and check from another device that the IBKR 2FA ' +
                                'prompt arrives. If WSL does not start without a sign-in on this computer, use -AfterSignIn and auto-logon instead (see the README).')
                        }
                    }
                })
        }
        if ($ResumeClockFix) {
            $steps.Add(@{
                    Name = 'ResumeClockFix'
                    Run  = {
                        $logonType = 'Interactive'
                        if ($hasLogonType) { $logonType = $TaskLogonType }
                        Register-GwResumeClockTask -Path $folder -LogonType $logonType
                    }
                })
        }
        if ($WslConfig) {
            $steps.Add(@{
                    Name = 'WslConfig'
                    Run  = {
                        $changes = New-Object System.Collections.Generic.List[object]
                        $text = Read-GwTextFile -Path $WslConfigPath
                        $networking = Get-GwIniValue -Text $text -Section 'wsl2' -Key 'networkingMode'
                        if (-not [string]::IsNullOrEmpty($networking) -and $networking.Trim() -ine 'nat') {
                            $changes.Add(@{ Section = 'wsl2'; Key = 'networkingMode'; Value = 'nat' })
                        }
                        $state = Get-GwKitState -Path $folder
                        if ([string](Get-GwPropertyValue -InputObject $state -Name 'Runtime' -Default '') -eq 'WslEngine') {
                            $idle = Get-GwIniValue -Text $text -Section 'general' -Key 'instanceIdleTimeout'
                            if ([string]::IsNullOrEmpty($idle) -or $idle.Trim() -ne '-1') { $changes.Add(@{ Section = 'general'; Key = 'instanceIdleTimeout'; Value = '-1' }) }
                        }
                        if ($hasMemory) {
                            $changes.Add(@{ Section = 'wsl2'; Key = 'memory'; Value = ('{0}GB' -f $WslMemoryGB) })
                        }
                        if ($changes.Count -eq 0) {
                            Write-GwConsole -Message '.wslconfig needs no change: networking is NAT and nothing else was asked for.'
                        }
                        foreach ($change in $changes) {
                            Set-GwWslConfigValue -Path $folder -WslConfigPath $WslConfigPath -Section $change.Section -Key $change.Key -Value $change.Value
                        }
                    }
                })
        }
        if ($FirewallLoopbackOnly) { $steps.Add(@{ Name = 'FirewallLoopbackOnly'; Run = { Add-GwFirewallBlockRule -Path $folder } }) }
    }
    if ($steps.Count -eq 0) {
        Write-GwConsole -Message ('Nothing to do. Choose what to apply: -DisableSleep, -SetActiveHours <start>,<end>, -StartAtBoot DockerDesktop|WslEngine, ' +
            '-ResumeClockFix, -WslConfig, -FirewallLoopbackOnly; or -Undo to revert. Add -WhatIf to preview. doctor.ps1 tells you which ones this computer needs.')
        return [pscustomobject]@{ ExitCode = 1 }
    }
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        # The change journal lives in the gateway folder; without it a change could not be undone.
        Write-GwConsole -Message ('The gateway folder {0} does not exist. Run setup.ps1 first (or pass -Path): harden records every change there.' -f $folder) -Status 'FAIL'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    $exitCode = 0
    foreach ($step in $steps) {
        try { & $step.Run }
        catch {
            $exitCode = 1
            Write-GwConsole -Message ('{0} was not applied: {1}' -f $step.Name, $_.Exception.Message) -Status 'FAIL'
        }
    }
    if ($WhatIfPreference) {
        Write-GwConsole -Message 'Preview only (-WhatIf): nothing was changed and nothing was recorded.'
    }
    elseif (-not $Undo -and $exitCode -eq 0) {
        Write-GwConsole -Message ('Every change is recorded in {0}; revert with: harden.ps1 -Undo' -f (Get-GwJournalPath -Path $folder))
    }
    return [pscustomobject]@{ ExitCode = $exitCode }
}

function Invoke-GwStart {
    <#
    .SYNOPSIS
    Starts the gateway stack unattended (the logic of start.ps1, run by the kit's scheduled tasks).
    .DESCRIPTION
    Uses the runtime recorded by setup, waits (bounded) for that engine to answer and runs
    'docker compose up -d --no-recreate': a stopped stack is started, a running gateway is never
    replaced or restarted. It never prompts and never touches 2FA; after a Windows restart the
    gateway logs in by itself and IBKR sends the 2FA prompt to the operator's phone.
    With -KeepAlive and Docker Engine in WSL the function then holds one wsl.exe session open
    ('sleep infinity') and returns only when that session ends, because WSL shuts an idle
    distribution down even while dockerd runs. Each run leaves lines in <Path>\kit.log (size
    bounded).
    .PARAMETER Path
    Gateway folder.
    .PARAMETER KeepAlive
    Docker Engine in WSL only: keep a session open after starting.
    .PARAMETER WaitSeconds
    How long to wait for the engine.
    .OUTPUTS
    PSCustomObject: ExitCode (0 started, 1 not started).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Not a state-changing verb by PowerShell''s list; it runs unattended from a scheduled task where a confirmation prompt would hang forever.')]
    param(
        [string]$Path = 'C:\BrokerSRE\gateway',
        [switch]$KeepAlive,
        [ValidateRange(5, 3600)][int]$WaitSeconds = 600
    )
    $folder = Resolve-GwFullPath -Path $Path
    $log = Join-Path $folder 'kit.log'
    $state = Get-GwKitState -Path $folder
    if ($null -eq $state) {
        Write-GwConsole -Message ('No kit-state.json in {0}: run setup.ps1 for this folder first.' -f $folder) -Status 'FAIL'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    $runtime = Get-GwRuntimeFromState -State $state
    Write-GwLog -Path $log -Message ('start: waiting up to {0} s for the container engine ({1})' -f $WaitSeconds, $runtime.Mode)
    if (-not (Wait-GwContainerEngine -Runtime $runtime -TimeoutSeconds $WaitSeconds)) {
        Write-GwLog -Path $log -Message 'start: the container engine did not answer in time; nothing was started'
        Write-GwConsole -Message 'The container engine did not answer in time; nothing was started.' -Status 'FAIL'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    $started = Start-GwStack -Runtime $runtime -Path $folder -NoRecreate -Confirm:$false
    if (-not $started) {
        Write-GwLog -Path $log -Message 'start: docker compose up -d --no-recreate failed'
        return [pscustomobject]@{ ExitCode = 1 }
    }
    Write-GwLog -Path $log -Message 'start: stack started (a running gateway is left as it is); IBKR will ask for 2FA if a login is needed'
    Write-GwConsole -Message 'The stack is up. If the gateway had to log in, approve the IBKR Mobile prompt on your phone.' -Status 'PASS'
    if ($KeepAlive -and $runtime.Mode -eq 'WslEngine') {
        Write-GwLog -Path $log -Message ('start: holding a session open in {0} so the distribution is not shut down as idle' -f $runtime.Distro)
        $session = Invoke-GwWsl -ArgumentList @('-d', [string]$runtime.Distro, '--exec', 'sleep', 'infinity') -Interactive
        Write-GwLog -Path $log -Message ('start: the keep-alive session ended with exit code {0}' -f $session.ExitCode)
    }
    return [pscustomobject]@{ ExitCode = 0 }
}

function Invoke-GwUninstall {
    <#
    .SYNOPSIS
    Removes the gateway stack and the kit's scheduled tasks (the logic of uninstall.ps1).
    .DESCRIPTION
    Stops the stack ('docker compose stop', then 'down'), deletes the kit's scheduled tasks and,
    only with -RemoveData, also deletes the named volumes (gateway settings and logs) and the
    gateway folder with its secrets. Without -RemoveData the folder, the secrets and the
    volumes stay. Host changes made by harden.ps1 are not reverted here: while the journal
    still lists some, -RemoveData refuses to delete the folder (the journal is what undo
    needs) unless -KeepHostChanges says to leave them in place. ConfirmImpact is High, so
    PowerShell asks before anything is removed unless -Confirm:$false is given; secrets are
    never deleted silently.
    .PARAMETER Path
    Gateway folder.
    .PARAMETER RemoveData
    Also delete the volumes and the folder, including the secret files.
    .PARAMETER KeepHostChanges
    With -RemoveData: delete the folder even though harden changes are still in place.
    .OUTPUTS
    PSCustomObject: ExitCode (0 done, 1 something was left behind).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [string]$Path = 'C:\BrokerSRE\gateway',
        [switch]$RemoveData,
        [switch]$KeepHostChanges
    )
    $folder = Resolve-GwFullPath -Path $Path
    $exitCode = 0
    $state = Get-GwKitState -Path $folder
    $tradingMode = [string](Get-GwPropertyValue -InputObject $state -Name 'TradingMode' -Default 'paper')
    if (@('paper', 'live') -notcontains $tradingMode) { $tradingMode = 'paper' }

    $pendingHostChanges = @()
    if (Test-Path -LiteralPath (Get-GwJournalPath -Path $folder)) {
        $pendingHostChanges = @((Get-GwJournal -Path $folder).Entries | Where-Object { -not $_.Reverted -and $_.Kind -ne 'ScheduledTask' })
    }
    if ($RemoveData -and $pendingHostChanges.Count -gt 0 -and -not $KeepHostChanges) {
        $refusal = ('{0} host change(s) made by harden.ps1 are still in place and the folder holds the journal that can revert them. ' +
            'Run harden.ps1 -Undo first, or add -KeepHostChanges to leave them as they are.') -f $pendingHostChanges.Count
        Write-GwConsole -Status 'FAIL' -Message $refusal
        return [pscustomobject]@{ ExitCode = 1 }
    }

    if (Test-Path -LiteralPath (Join-Path $folder 'compose.yaml')) {
        $preference = 'Auto'
        $distro = ''
        if ($null -ne $state) {
            $recorded = Get-GwRuntimeFromState -State $state
            if ($recorded.Mode -eq 'WslEngine') {
                $preference = 'WslEngine'
                $distro = $recorded.Distro
            }
        }
        $runtime = Get-GwRuntime -Preference $preference -Distro $distro
        if ([string]$runtime.Mode -eq 'None') {
            $exitCode = 1
            Write-GwConsole -Message ('The container engine does not answer ({0}), so the container was not removed. Start Docker and run uninstall.ps1 again.' -f $runtime.Detail) -Status 'WARN'
        }
        elseif ($PSCmdlet.ShouldProcess($folder, 'Stop and remove the gateway container (the gateway logs out)')) {
            Stop-GwStack -Runtime $runtime -Path $folder -Confirm:$false | Out-Null
            if (-not (Remove-GwStack -Runtime $runtime -Path $folder -RemoveVolumes:$RemoveData -Confirm:$false)) {
                $exitCode = 1
                Write-GwConsole -Message 'docker compose down failed.' -Status 'FAIL'
            }
            else {
                Write-GwConsole -Message 'The gateway container was stopped and removed.' -Status 'PASS'
            }
        }
    }

    $taskNames = @(
        (Get-GwTaskName -Kind 'Boot' -TradingMode $tradingMode)
        (Get-GwTaskName -Kind 'SignIn' -TradingMode $tradingMode)
        (Get-GwTaskName -Kind 'ClockFix')
    )
    foreach ($taskName in $taskNames) {
        if (-not (Test-GwKitTask -Name $taskName)) { continue }
        if (-not $PSCmdlet.ShouldProcess($taskName, 'Delete scheduled task')) { continue }
        $delete = Invoke-GwSchTasks -ArgumentList @('/Delete', '/TN', $taskName, '/F')
        if ($delete.ExitCode -ne 0) {
            $exitCode = 1
            Write-GwConsole -Message ('The scheduled task "{0}" could not be deleted; try again from an elevated PowerShell.' -f $taskName) -Status 'FAIL'
        }
        else {
            Write-GwConsole -Message ('Deleted the scheduled task "{0}".' -f $taskName) -Status 'PASS'
        }
    }

    if ($RemoveData) {
        if ((Test-Path -LiteralPath $folder) -and $PSCmdlet.ShouldProcess($folder, 'Delete the gateway folder, including the IBKR secret files')) {
            Remove-Item -LiteralPath $folder -Recurse -Force
            Write-GwConsole -Message ('Deleted {0}, including the secret files.' -f $folder) -Status 'PASS'
        }
    }
    else {
        Write-GwConsole -Message ('Kept {0} with your secret files and the Docker volumes; add -RemoveData to delete them.' -f $folder)
    }
    if ($pendingHostChanges.Count -gt 0) {
        Write-GwConsole -Message 'Host changes made by harden.ps1 are still in place.' -Status 'WARN'
    }
    return [pscustomobject]@{ ExitCode = $exitCode }
}
