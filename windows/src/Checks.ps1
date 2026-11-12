# Prerequisite and doctor checks of the Windows host kit. Every check is one function that reads
# the host through the wrappers in Native.ps1 and returns one result object
# {Name, Status (PASS|WARN|FAIL|SKIP), Detail, Fix}. Checks never change anything. A check that
# cannot measure returns SKIP with the reason: absence of a measurement is never reported as
# healthy. Parsing is done by position and by regular expression, not by English labels, so the
# checks also work on a localised Windows.

$script:GwApiPorts = @(4001, 4002, 9810)
# The one image reference in the kit: a tiny probe image the HOST runs for two read-only checks
# (the clock inside the container VM, and whether a container can read the restricted secrets
# folder). Tag for readability, digest for immutability (index digest, resolved 2026-11-12).
# Accepted exception to invariant 1 of the repository ("every input is pinned and verified;
# versions.json holds them; no other file carries a version"): versions.json describes what goes
# INTO the gateway image, and this image is never part of it. It is pinned by digest here, in
# this single constant, and a test fails when a second copy appears. Bump it by replacing tag
# and digest together ('docker buildx imagetools inspect <image>:<tag>' prints the digest).
$script:GwProbeImage = 'busybox:1.37.0@sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec'

function Get-GwDefaultWslConfigPath {
    <#
    .SYNOPSIS
    Returns the documented location of the global WSL configuration file.
    .OUTPUTS
    System.String: %UserProfile%\.wslconfig.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-Path $env:USERPROFILE '.wslconfig')
}

function Get-GwDefaultDockerSettingsPath {
    <#
    .SYNOPSIS
    Returns the documented location of Docker Desktop's settings file on Windows.
    .OUTPUTS
    System.String: %APPDATA%\Docker\settings-store.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-Path (Join-Path $env:APPDATA 'Docker') 'settings-store.json')
}

function Get-GwTaskName {
    <#
    .SYNOPSIS
    Returns the full Task Scheduler name of one of the kit's tasks.
    .DESCRIPTION
    The kit's tasks live in the folder \BrokerSRE so they are easy to find and so uninstall
    removes exactly what the kit created. Start tasks carry the trading mode, because a paper
    and a live gateway can coexist; the clock fix is per computer.
    .PARAMETER Kind
    Boot (start at boot, no sign-in), SignIn (start after sign-in) or ClockFix (after resume).
    .PARAMETER TradingMode
    'paper' or 'live'; ignored for ClockFix.
    .OUTPUTS
    System.String, for example '\BrokerSRE\Gateway paper - start at boot'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Boot', 'SignIn', 'ClockFix')][string]$Kind,
        [ValidateSet('paper', 'live')][string]$TradingMode = 'paper'
    )
    switch ($Kind) {
        'Boot' { return ('\BrokerSRE\Gateway {0} - start at boot' -f $TradingMode.ToLowerInvariant()) }
        'SignIn' { return ('\BrokerSRE\Gateway {0} - start after sign-in' -f $TradingMode.ToLowerInvariant()) }
        default { return '\BrokerSRE\Gateway - clock fix after resume' }
    }
}

function Test-GwKitTask {
    <#
    .SYNOPSIS
    Tells whether a scheduled task exists.
    .DESCRIPTION
    Read-only: 'schtasks /Query /TN <name> /XML' exits with 0 only when the task exists.
    .PARAMETER Name
    Full task name from Get-GwTaskName.
    .OUTPUTS
    System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Name)
    $result = Invoke-GwSchTasks -ArgumentList @('/Query', '/TN', $Name, '/XML')
    return ($result.ExitCode -eq 0)
}

function Invoke-GwCheckSafely {
    <#
    .SYNOPSIS
    Runs one check and guarantees a result object.
    .DESCRIPTION
    doctor must finish and must stay truthful even when a probe breaks. Any exception, and an
    empty result, becomes SKIP with the reason; it can never become PASS. This is the one place
    in the kit that catches every exception type, and it does so to report the failure, not to
    hide it.
    .PARAMETER Name
    Check name to use when the check itself produced nothing.
    .PARAMETER Check
    Script block that returns one check result.
    .OUTPUTS
    Check result object.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Check
    )
    try {
        $result = & $Check
        if ($null -eq $result) {
            return (New-GwCheckResult -Name $Name -Status 'SKIP' -Detail 'The check produced no result.')
        }
        return $result
    }
    catch {
        $reason = ('The check could not run: {0}' -f $_.Exception.Message)
        return (New-GwCheckResult -Name $Name -Status 'SKIP' -Detail $reason)
    }
}

function Test-GwWindowsBuild {
    <#
    .SYNOPSIS
    Prerequisite: Windows 10 22H2 (build 19045) or Windows 11.
    .DESCRIPTION
    Reads CurrentBuildNumber from the registry (ProductName still says "Windows 10" on Windows
    11, so the build number decides: 22000 and above is Windows 11). Windows 10 works but gets
    WARN: its support ended on 2025-10-14 and it receives security updates only through the
    Extended Security Updates programme.
    .OUTPUTS
    Check result 'WindowsBuild'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = 'WindowsBuild'
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $buildText = [string](Invoke-GwRegistry -Operation Get -Path $key -Name 'CurrentBuildNumber')
    $display = [string](Invoke-GwRegistry -Operation Get -Path $key -Name 'DisplayVersion')
    if ($buildText -notmatch '^\d+$') {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'The Windows build number could not be read.')
    }
    $build = [int]$buildText
    if ($build -lt 19045) {
        $detail = 'Windows build {0} is older than Windows 10 22H2 (build 19045).' -f $build
        return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail $detail -Fix 'Update Windows to Windows 10 22H2 or Windows 11.')
    }
    if ($build -lt 22000) {
        $detail = 'Windows 10 build {0} ({1}). It works, but Windows 10 support ended on 2025-10-14.' -f $build, $display
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail -Fix 'Plan the move to Windows 11, or enrol in Extended Security Updates.')
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('Windows 11 build {0} ({1}).' -f $build, $display))
}

function Test-GwVirtualization {
    <#
    .SYNOPSIS
    Prerequisite: hardware virtualization is usable (WSL 2 runs in a lightweight VM).
    .DESCRIPTION
    PASS when a hypervisor is already running, or when none runs yet but the firmware switch is
    on; FAIL when both are off; SKIP when CIM gave no answer.
    .OUTPUTS
    Check result 'Virtualization'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = 'Virtualization'
    $info = Get-GwVirtualizationInfo
    if ($null -eq $info.HypervisorPresent -and $null -eq $info.FirmwareEnabled) {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'Windows did not report the virtualization state.')
    }
    if ($info.HypervisorPresent -eq $true) {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'A hypervisor is running, so hardware virtualization works.')
    }
    if ($info.FirmwareEnabled -eq $true) {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'Virtualization is enabled in the firmware; WSL 2 starts the hypervisor when installed.')
    }
    return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail 'Hardware virtualization is switched off.' `
            -Fix 'Enable Intel VT-x / AMD-V (SVM) in the UEFI/BIOS setup of this computer, then run: wsl --install')
}

function Test-GwWslVersion {
    <#
    .SYNOPSIS
    Prerequisite and doctor check: WSL is installed and recent.
    .DESCRIPTION
    'wsl --version' exists only in the Microsoft Store / MSI version of WSL; the old inbox
    version rejects it, which is itself the finding (FAIL). The version number is taken from the
    first line by pattern, because the label is localised. Docker Desktop documents WSL 2.1.5 as
    its minimum; older gets WARN.
    .OUTPUTS
    Check result 'WslVersion'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = 'WslVersion'
    $result = Invoke-GwWsl -ArgumentList @('--version')
    if ($result.ExitCode -ne 0) {
        return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail 'WSL is missing or is the old built-in version (it does not answer "wsl --version").' `
                -Fix 'In an elevated PowerShell run: wsl --install   then: wsl --update   and restart Windows.')
    }
    $versionText = ''
    foreach ($line in $result.Output) {
        $match = [regex]::Match($line, '(\d+)\.(\d+)\.(\d+)(\.\d+)?')
        if ($match.Success) {
            $versionText = $match.Value
            break
        }
    }
    if ($versionText.Length -eq 0) {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'The WSL version could not be read from "wsl --version".')
    }
    $version = [version]$versionText
    if ($version -lt [version]'2.1.5') {
        $detail = 'WSL {0}. Docker Desktop documents 2.1.5 as its minimum.' -f $versionText
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail -Fix 'Run: wsl --update')
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('WSL {0}.' -f $versionText))
}

function Test-GwContainerRuntime {
    <#
    .SYNOPSIS
    Prerequisite and doctor check: a container runtime answers and runs Linux containers.
    .DESCRIPTION
    Judges the object from Get-GwRuntime. The gateway is a Linux image (IB Gateway is a GUI
    application under Xvfb; Windows containers cannot run it), so an engine in Windows-container
    mode is FAIL with the instruction to switch.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .OUTPUTS
    Check result 'ContainerRuntime'; Detail names the detected mode.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][pscustomobject]$Runtime)
    $name = 'ContainerRuntime'
    if ([string]$Runtime.Mode -eq 'None') {
        $detail = 'No container runtime answered: {0}' -f $Runtime.Detail
        return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail $detail `
                -Fix 'Start Docker Desktop and wait for "Engine running", or install Docker Engine inside a WSL 2 distribution (see README).')
    }
    if ([string]$Runtime.OsType -ne 'linux') {
        return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail 'Docker is set to Windows containers; the gateway is a Linux image.' `
                -Fix 'Right-click the Docker Desktop tray icon and choose "Switch to Linux containers...".')
    }
    switch ([string]$Runtime.Mode) {
        'DockerDesktop' { $detail = 'Mode: Docker Desktop, engine {0}, Linux containers.' -f $Runtime.ServerVersion }
        'WslEngine' { $detail = 'Mode: Docker Engine {0} inside the WSL distribution {1}.' -f $Runtime.ServerVersion, $Runtime.Distro }
        default { $detail = 'Mode: docker.exe talking to {0}, engine {1}.' -f $Runtime.EngineName, $Runtime.ServerVersion }
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail $detail)
}

function Test-GwPortAvailable {
    <#
    .SYNOPSIS
    Prerequisite: a TCP port is free, or is held by this kit's own gateway container.
    .DESCRIPTION
    Looks at the Windows listener table. When something listens, 'docker port <container>'
    tells whether it is the kit's gateway (re-running setup is then fine). Anything else is FAIL
    for the port the chosen trading mode needs and WARN for the others.
    .PARAMETER Port
    Port to check (4001 live API, 4002 paper API, 9810 reserved for the sidecar).
    .PARAMETER Runtime
    Object from Get-GwRuntime; with mode None docker is not asked.
    .PARAMETER ContainerName
    The kit's gateway container name.
    .PARAMETER Required
    The stack cannot start without this port.
    .OUTPUTS
    Check result 'Port<number>'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$ContainerName,
        [switch]$Required
    )
    $name = 'Port{0}' -f $Port
    $listeners = @(Get-GwTcpListenerPort)
    if ($listeners -notcontains $Port) {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('Port {0} is free.' -f $Port))
    }
    if ([string]$Runtime.Mode -ne 'None') {
        $mapping = Invoke-GwContainerCli -Runtime $Runtime -ArgumentList @('port', $ContainerName)
        if ($mapping.ExitCode -eq 0 -and @($mapping.Output | Where-Object { $_ -match (':{0}\s*$' -f $Port) }).Count -gt 0) {
            return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('Port {0} is in use by this kit''s gateway container.' -f $Port))
        }
    }
    $status = 'WARN'
    if ($Required) { $status = 'FAIL' }
    $fix = 'Find the program with: Get-NetTCPConnection -LocalPort {0} -State Listen | Select-Object OwningProcess   then stop it (often Trader Workstation or another gateway).' -f $Port
    return (New-GwCheckResult -Name $name -Status $status -Detail ('Another program is listening on port {0}.' -f $Port) -Fix $fix)
}

function Test-GwDiskSpace {
    <#
    .SYNOPSIS
    Prerequisite and doctor check: enough free disk space on a drive.
    .DESCRIPTION
    The image is about 1 GB and the WSL virtual disk and the logs grow on the same drive. FAIL
    below 2 GB, WARN below 10 GB.
    .PARAMETER Path
    Any path on the drive.
    .PARAMETER Name
    Check name, 'DiskSpace' by default.
    .OUTPUTS
    Check result.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Name = 'DiskSpace'
    )
    $free = Get-GwDriveFreeByte -Path $Path
    if ($null -eq $free) {
        return (New-GwCheckResult -Name $Name -Status 'SKIP' -Detail ('Free space could not be measured for {0}.' -f $Path))
    }
    $gigabytes = [Math]::Round(([double]$free / 1073741824), 1)
    $root = [System.IO.Path]::GetPathRoot($Path)
    $detail = ('{0} GB free on {1}.' -f $gigabytes.ToString([System.Globalization.CultureInfo]::InvariantCulture), $root)
    if ($free -lt 2147483648) {
        return (New-GwCheckResult -Name $Name -Status 'FAIL' -Detail $detail -Fix 'Free at least 10 GB: the image is about 1 GB and the container disk and logs grow.')
    }
    if ($free -lt 10737418240) {
        return (New-GwCheckResult -Name $Name -Status 'WARN' -Detail $detail -Fix 'Free some space; below 2 GB the gateway and Docker start failing.')
    }
    return (New-GwCheckResult -Name $Name -Status 'PASS' -Detail $detail)
}

function Get-GwPowerAcSecond {
    <#
    .SYNOPSIS
    Reads the AC value of one sleep setting of the current power scheme, in seconds.
    .DESCRIPTION
    'powercfg /query SCHEME_CURRENT SUB_SLEEP <alias>' prints the setting with localised labels;
    the last two hexadecimal numbers are always the AC and the DC value, so the function takes
    them by position. Returns null when powercfg fails or prints fewer than two numbers.
    .PARAMETER Alias
    STANDBYIDLE (sleep after) or HIBERNATEIDLE (hibernate after).
    .OUTPUTS
    System.Int64 seconds (0 = never), or null when not measured.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param([Parameter(Mandatory = $true)][ValidateSet('STANDBYIDLE', 'HIBERNATEIDLE')][string]$Alias)
    $result = Invoke-GwPowerCfg -ArgumentList @('/query', 'SCHEME_CURRENT', 'SUB_SLEEP', $Alias)
    if ($result.ExitCode -ne 0) { return $null }
    $numbers = [regex]::Matches(($result.Output -join "`n"), '0x[0-9a-fA-F]{8}')
    if ($numbers.Count -lt 2) { return $null }
    return [Convert]::ToInt64($numbers[$numbers.Count - 2].Value.Substring(2), 16)
}

function Test-GwSleepOnAc {
    <#
    .SYNOPSIS
    Doctor check: the computer does not sleep or hibernate while on AC power.
    .DESCRIPTION
    A sleeping host freezes the gateway: the IBKR session drops, and after resume the clock
    inside the container VM can be wrong. FAIL when either timeout is set; PASS only when both
    were measured as "never"; WARN when one is "never" and the other could not be read; SKIP
    when neither could be read.
    .OUTPUTS
    Check result 'SleepOnAc'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = 'SleepOnAc'
    $fix = 'Run: harden.ps1 -DisableSleep   (sets "sleep after" and "hibernate after" to never on AC power; reversible with harden.ps1 -Undo).'
    $standby = Get-GwPowerAcSecond -Alias 'STANDBYIDLE'
    $hibernate = Get-GwPowerAcSecond -Alias 'HIBERNATEIDLE'
    if ($null -eq $standby -and $null -eq $hibernate) {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'powercfg did not report the sleep settings of the current power scheme.')
    }
    $problems = New-Object System.Collections.Generic.List[string]
    if ($null -ne $standby -and $standby -gt 0) { $problems.Add(('sleeps after {0} minutes' -f [int]($standby / 60))) }
    if ($null -ne $hibernate -and $hibernate -gt 0) { $problems.Add(('hibernates after {0} minutes' -f [int]($hibernate / 60))) }
    if ($problems.Count -gt 0) {
        $detail = 'On AC power this computer {0}. A sleeping host freezes the gateway and drops the IBKR session.' -f ($problems.ToArray() -join ' and ')
        return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail $detail -Fix $fix)
    }
    if ($null -eq $standby -or $null -eq $hibernate) {
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail 'One of the two timeouts (sleep, hibernate) is "never"; the other could not be read.' `
                -Fix 'Check Settings > System > Power, or run: powercfg /query SCHEME_CURRENT SUB_SLEEP')
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'On AC power this computer never sleeps and never hibernates.')
}

function Format-GwHourWindow {
    <#
    .SYNOPSIS
    Formats an active-hours window, for example '20:00 to 08:00 (12 hours)'.
    .PARAMETER Start
    Start hour, 0 to 23.
    .PARAMETER End
    End hour, 0 to 23; a window may cross midnight.
    .OUTPUTS
    System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][int]$Start,
        [Parameter(Mandatory = $true)][int]$End
    )
    $length = (($End - $Start) + 24) % 24
    if ($length -eq 0) { $length = 24 }
    return ('{0:00}:00 to {1:00}:00 ({2} hours)' -f $Start, $End, $length)
}

function Test-GwUpdateActiveWindow {
    <#
    .SYNOPSIS
    Doctor check: Windows Update active hours are set on purpose.
    .DESCRIPTION
    Windows restarts for updates outside the active hours (at most 18 hours long). The check
    reads the documented policy values first (SetActiveHours, ActiveHoursStart, ActiveHoursEnd
    under HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate) and otherwise the values the
    Settings app stores. PASS when a window is set explicitly; WARN when Windows adjusts it
    automatically (SmartActiveHoursState = 1; that reading of the value is from community
    documentation, not from Microsoft) or when nothing is stored (default 8:00 to 17:00).
    Active hours only move restarts; they do not prevent them.
    .OUTPUTS
    Check result 'UpdateActiveHours'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = 'UpdateActiveHours'
    $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $settingsKey = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $reminder = 'Windows can still restart for updates outside this window; after a restart the gateway needs a new IBKR login with 2FA.'
    $fix = 'Run: harden.ps1 -SetActiveHours <start>,<end>   (hours 0-23, at most 18 hours apart) so the window covers your trading session.'

    if ((Invoke-GwRegistry -Operation Get -Path $policyKey -Name 'SetActiveHours') -eq 1) {
        $start = Invoke-GwRegistry -Operation Get -Path $policyKey -Name 'ActiveHoursStart'
        $end = Invoke-GwRegistry -Operation Get -Path $policyKey -Name 'ActiveHoursEnd'
        if ($null -ne $start -and $null -ne $end) {
            $detail = 'Active hours set by policy: {0}. {1}' -f (Format-GwHourWindow -Start ([int]$start) -End ([int]$end)), $reminder
            return (New-GwCheckResult -Name $name -Status 'PASS' -Detail $detail)
        }
    }
    $start = Invoke-GwRegistry -Operation Get -Path $settingsKey -Name 'ActiveHoursStart'
    $end = Invoke-GwRegistry -Operation Get -Path $settingsKey -Name 'ActiveHoursEnd'
    if ($null -eq $start -or $null -eq $end) {
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail ('No active hours are stored; the Windows default is 8:00 to 17:00. {0}' -f $reminder) -Fix $fix)
    }
    $window = Format-GwHourWindow -Start ([int]$start) -End ([int]$end)
    if ((Invoke-GwRegistry -Operation Get -Path $settingsKey -Name 'SmartActiveHoursState') -eq 1) {
        $detail = 'Windows adjusts the active hours by itself from observed use (currently {0}); an unattended computer looks unused. {1}' -f $window, $reminder
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail -Fix $fix)
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('Active hours: {0}. {1}' -f $window, $reminder))
}

function Test-GwUpdatePendingReboot {
    <#
    .SYNOPSIS
    Doctor check: no Windows restart is pending.
    .DESCRIPTION
    Looks for the two registry keys Windows creates when an installed update waits for a
    restart (Windows Update's RebootRequired and Component Based Servicing's RebootPending; the
    same keys Microsoft's PendingReboot DSC resource reads). A pending restart will happen
    outside active hours; restarting at a chosen time keeps the login under control.
    .OUTPUTS
    Check result 'UpdatePendingReboot'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = 'UpdatePendingReboot'
    $sources = New-Object System.Collections.Generic.List[string]
    if (Invoke-GwRegistry -Operation Test -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        $sources.Add('Windows Update')
    }
    if (Invoke-GwRegistry -Operation Test -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        $sources.Add('component servicing')
    }
    if ($sources.Count -eq 0) {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'No Windows restart is pending.')
    }
    $detail = 'A restart is pending ({0}). Windows will restart by itself outside active hours.' -f ($sources.ToArray() -join ', ')
    return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail `
            -Fix 'Restart Windows at a time you choose (outside market hours), then approve the IBKR login on your phone.')
}

function Test-GwUpdateAutoRestart {
    <#
    .SYNOPSIS
    Doctor check: does Windows restart by itself after installing updates?
    .DESCRIPTION
    Reads the documented policy values under ...\WindowsUpdate\AU. PASS when updates install
    only on request (AUOptions 2 or 3) or when 'No auto-restart with logged on users' is set
    together with scheduled installation (AUOptions 4), the only combination in which Microsoft
    says it applies. WARN otherwise, including when automatic updates are disabled altogether
    (no surprise restart, but no security patches either). On an unconfigured computer the
    result is WARN: Windows restarts outside active hours.
    .OUTPUTS
    Check result 'UpdateAutoRestart'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = 'UpdateAutoRestart'
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $noAutoUpdate = Invoke-GwRegistry -Operation Get -Path $key -Name 'NoAutoUpdate'
    $options = Invoke-GwRegistry -Operation Get -Path $key -Name 'AUOptions'
    $noReboot = Invoke-GwRegistry -Operation Get -Path $key -Name 'NoAutoRebootWithLoggedOnUsers'
    if ($noAutoUpdate -eq 1) {
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail 'Automatic updates are disabled by policy: no surprise restart, but no security patches unless you install them.' `
                -Fix 'Install Windows updates yourself at least monthly, outside market hours.')
    }
    if ($options -eq 2 -or $options -eq 3) {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('Updates install only when you approve them (AUOptions={0}), so restarts happen when you choose.' -f $options))
    }
    if ($options -eq 4 -and $noReboot -eq 1) {
        return (New-GwCheckResult -Name $name -Status 'PASS' `
                -Detail 'Policy: no automatic restart while a user is signed in. Microsoft notes this can postpone restarts indefinitely, so restart on purpose.')
    }
    return (New-GwCheckResult -Name $name -Status 'WARN' `
            -Detail 'Windows installs updates and restarts by itself outside active hours. Each restart needs a new IBKR login with 2FA.' `
            -Fix 'Set active hours over your trading session (harden.ps1 -SetActiveHours) and restart on purpose at the weekend, before the weekly IBKR login.')
}

function Get-GwDockerDesktopSetting {
    <#
    .SYNOPSIS
    Loads Docker Desktop's settings-store.json.
    .DESCRIPTION
    Read-only. Docker documents the file location but not its key names; the kit reads two keys
    it has seen there (AutoStart, AutoDownloadUpdates) and treats everything else as unknown.
    .PARAMETER DockerSettingsPath
    Path of settings-store.json.
    .OUTPUTS
    PSCustomObject with the settings, or null when the file is missing or not JSON.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$DockerSettingsPath)
    $text = Read-GwTextFile -Path $DockerSettingsPath
    if ([string]::IsNullOrEmpty($text)) { return $null }
    try { return ($text | ConvertFrom-Json) }
    catch [System.ArgumentException] {
        Write-Verbose ('Docker Desktop settings are not valid JSON: {0}' -f $_.Exception.Message)
        return $null
    }
}

function Test-GwStartAtBoot {
    <#
    .SYNOPSIS
    Doctor check: does the stack come back after a Windows restart, and does that need a sign-in?
    .DESCRIPTION
    Reports the detected mode and what happens after a restart.
    Docker Desktop is a per-user desktop application whose documented start option is "Start
    Docker Desktop when you sign in to your computer", so the stack returns only after a
    sign-in: PASS needs that option plus Windows auto-logon; without auto-logon the result is
    WARN (someone has to sign in first). The option is read from settings-store.json (AutoStart)
    or, when the file is missing, from the Run key; if neither can tell the result is SKIP.
    Docker Engine in WSL: PASS with the kit's boot task (no sign-in needed), or with the kit's
    sign-in task plus auto-logon; WARN otherwise.
    Either way IBKR still asks for 2FA after a restart; the kit never automates that.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER Path
    Gateway folder (named in the fix text).
    .PARAMETER TradingMode
    'paper' or 'live'; selects the task names.
    .PARAMETER DockerSettingsPath
    Path of Docker Desktop's settings-store.json.
    .OUTPUTS
    Check result 'StartAtBoot'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('paper', 'live')][string]$TradingMode = 'paper',
        [string]$DockerSettingsPath = (Get-GwDefaultDockerSettingsPath)
    )
    $name = 'StartAtBoot'
    $twoFactor = 'IBKR still asks for 2FA after every restart; approve it on your phone.'
    $autoLogon = ([string](Invoke-GwRegistry -Operation Get -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'AutoAdminLogon') -eq '1')
    $signInTask = Test-GwKitTask -Name (Get-GwTaskName -Kind 'SignIn' -TradingMode $TradingMode)
    $autoLogonFix = 'For an unattended computer enable Windows auto-logon with Sysinternals Autologon (read the security trade-off in the README first).'

    switch ([string]$Runtime.Mode) {
        'DockerDesktop' {
            $autoStart = $null
            $settings = Get-GwDockerDesktopSetting -DockerSettingsPath $DockerSettingsPath
            if ($null -ne $settings) {
                $autoStart = ((Get-GwPropertyValue -InputObject $settings -Name 'AutoStart' -Default $false) -eq $true)
            }
            elseif ($null -ne (Invoke-GwRegistry -Operation Get -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Docker Desktop')) {
                $autoStart = $true
            }
            if ($null -eq $autoStart) {
                return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'Mode: Docker Desktop. Its start-at-sign-in setting could not be read.' `
                        -Fix 'Check Docker Desktop > Settings > General > "Start Docker Desktop when you sign in to your computer".')
            }
            if (-not $autoStart) {
                return (New-GwCheckResult -Name $name -Status 'WARN' -Detail 'Mode: Docker Desktop. Docker Desktop does not start when you sign in, so the gateway stays down after a restart.' `
                        -Fix 'Docker Desktop > Settings > General > tick "Start Docker Desktop when you sign in to your computer"; then run: harden.ps1 -StartAtBoot DockerDesktop')
            }
            $taskNote = 'The kit''s start-after-sign-in task is not installed (harden.ps1 -StartAtBoot DockerDesktop adds it).'
            if ($signInTask) { $taskNote = 'The kit''s start-after-sign-in task is installed.' }
            if ($autoLogon) {
                $detail = 'Mode: Docker Desktop. Windows signs in automatically and Docker Desktop starts at sign-in, so the stack returns after a restart. {0} {1}' -f $taskNote, $twoFactor
                return (New-GwCheckResult -Name $name -Status 'PASS' -Detail $detail)
            }
            $detail = 'Mode: Docker Desktop. Docker Desktop starts at sign-in, but after a restart nothing starts until someone signs in to Windows. {0} {1}' -f $taskNote, $twoFactor
            return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail `
                    -Fix ('{0} Or use Docker Engine inside WSL 2, or a Linux VM, which need no sign-in.' -f $autoLogonFix))
        }
        'WslEngine' {
            $bootTask = Test-GwKitTask -Name (Get-GwTaskName -Kind 'Boot' -TradingMode $TradingMode)
            if ($bootTask) {
                $detail = ('Mode: Docker Engine in WSL ({0}). The kit''s boot task starts the distribution and the stack without a sign-in. ' +
                    'Confirm it once: restart, do not sign in, and check from another device. {1}') -f $Runtime.Distro, $twoFactor
                return (New-GwCheckResult -Name $name -Status 'PASS' -Detail $detail)
            }
            if ($signInTask -and $autoLogon) {
                $detail = 'Mode: Docker Engine in WSL ({0}). Windows signs in automatically and the kit''s sign-in task starts the stack. {1}' -f $Runtime.Distro, $twoFactor
                return (New-GwCheckResult -Name $name -Status 'PASS' -Detail $detail)
            }
            if ($signInTask) {
                $detail = 'Mode: Docker Engine in WSL ({0}). The kit''s sign-in task starts the stack, but only after someone signs in to Windows. {1}' -f $Runtime.Distro, $twoFactor
                return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail -Fix ('Run: harden.ps1 -StartAtBoot WslEngine   (boot task, no sign-in). {0}' -f $autoLogonFix))
            }
            $detail = 'Mode: Docker Engine in WSL ({0}). Nothing starts the distribution after a restart, so the gateway stays down. {1}' -f $Runtime.Distro, $twoFactor
            return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail -Fix ('Run: harden.ps1 -StartAtBoot WslEngine   (gateway folder: {0}).' -f $Path))
        }
        default {
            return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'No supported container runtime was detected, so start-at-boot cannot be judged.')
        }
    }
}

function Test-GwWslNetworking {
    <#
    .SYNOPSIS
    Doctor check: WSL uses NAT networking (the default), not mirrored mode.
    .DESCRIPTION
    Reads [wsl2] networkingMode from .wslconfig (documented values: none, nat, bridged
    (deprecated), mirrored, consomme/virtioproxy; default NAT). Mirrored mode breaks published
    container ports: Microsoft's WSL troubleshooting page lists a known issue with Docker
    Desktop containers that publish ports, and moby/moby#48056 describes localhost ports of
    Docker Engine in WSL not reachable from Windows. Mirrored mode also makes Linux listeners
    reachable from the LAN. WARN for mirrored and for any non-default mode, FAIL for 'none'.
    .PARAMETER WslConfigPath
    Path of .wslconfig.
    .OUTPUTS
    Check result 'WslNetworkingMode'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$WslConfigPath = (Get-GwDefaultWslConfigPath))
    $name = 'WslNetworkingMode'
    $fix = 'Run: harden.ps1 -WslConfig   (sets networkingMode=nat with a backup), then restart WSL in a maintenance window: wsl --shutdown'
    $mode = Get-GwIniValue -Text (Read-GwTextFile -Path $WslConfigPath) -Section 'wsl2' -Key 'networkingMode'
    if ([string]::IsNullOrEmpty($mode)) {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'networkingMode is not set: WSL uses NAT, the default, which published ports rely on.')
    }
    switch ($mode.Trim().ToLowerInvariant()) {
        'nat' { return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'networkingMode=nat (NAT, the default).') }
        'mirrored' {
            return (New-GwCheckResult -Name $name -Status 'WARN' -Fix $fix `
                    -Detail 'networkingMode=mirrored: known to break published ports of containers, and it exposes Linux listeners to the LAN.')
        }
        'none' {
            return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail 'networkingMode=none: the WSL VM has no network, so the gateway cannot reach IBKR.' -Fix $fix)
        }
        default {
            return (New-GwCheckResult -Name $name -Status 'WARN' -Detail ('networkingMode={0}: not the default; the kit is tested with NAT only.' -f $mode.Trim()) -Fix $fix)
        }
    }
}

function Test-GwWslIdle {
    <#
    .SYNOPSIS
    Doctor check: WSL idle shutdown cannot stop the gateway.
    .DESCRIPTION
    Reports [wsl2] vmIdleTimeout (documented default 60000 ms) and [general]
    instanceIdleTimeout (documented default 15000 ms; -1 disables). With Docker Desktop the
    timeouts do not matter: it keeps its own distribution running. With Docker Engine in WSL a
    distribution shuts down once its last wsl.exe session ends, even with dockerd running, so
    the check passes only when instanceIdleTimeout is -1 or one of the kit's start tasks holds
    a session open.
    .PARAMETER WslConfigPath
    Path of .wslconfig.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER TradingMode
    'paper' or 'live'; selects the task names.
    .OUTPUTS
    Check result 'WslIdleShutdown'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string]$WslConfigPath = (Get-GwDefaultWslConfigPath),
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [ValidateSet('paper', 'live')][string]$TradingMode = 'paper'
    )
    $name = 'WslIdleShutdown'
    $text = Read-GwTextFile -Path $WslConfigPath
    $vmIdle = Get-GwIniValue -Text $text -Section 'wsl2' -Key 'vmIdleTimeout'
    $instanceIdle = Get-GwIniValue -Text $text -Section 'general' -Key 'instanceIdleTimeout'
    $vmText = 'vmIdleTimeout=60000 (default)'
    if (-not [string]::IsNullOrEmpty($vmIdle)) { $vmText = 'vmIdleTimeout={0}' -f $vmIdle.Trim() }
    $instanceText = 'instanceIdleTimeout=15000 (default)'
    if (-not [string]::IsNullOrEmpty($instanceIdle)) { $instanceText = 'instanceIdleTimeout={0}' -f $instanceIdle.Trim() }
    $values = '{0}, {1}' -f $vmText, $instanceText

    switch ([string]$Runtime.Mode) {
        'DockerDesktop' {
            return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('Docker Desktop keeps its own WSL distribution running, so idle shutdown does not stop the gateway ({0}).' -f $values))
        }
        'WslEngine' {
            if (-not [string]::IsNullOrEmpty($instanceIdle) -and $instanceIdle.Trim() -eq '-1') {
                return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('Idle shutdown of the distribution is disabled ({0}).' -f $values))
            }
            $bootTask = Test-GwKitTask -Name (Get-GwTaskName -Kind 'Boot' -TradingMode $TradingMode)
            $signInTask = Test-GwKitTask -Name (Get-GwTaskName -Kind 'SignIn' -TradingMode $TradingMode)
            if ($bootTask -or $signInTask) {
                return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('A start task of the kit keeps a session open, which keeps the distribution alive ({0}).' -f $values))
            }
            $detail = 'The distribution shuts down shortly after its last wsl.exe session ends, even with dockerd running, and takes the gateway with it ({0}).' -f $values
            return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail `
                    -Fix 'Run: harden.ps1 -StartAtBoot WslEngine   (keeps a session open) and harden.ps1 -WslConfig   (sets instanceIdleTimeout=-1).')
        }
        default {
            return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail ('No supported container runtime was detected ({0}).' -f $values))
        }
    }
}

function Test-GwWslMemory {
    <#
    .SYNOPSIS
    Doctor check: the WSL VM has enough memory for the gateway.
    .DESCRIPTION
    Reads [wsl2] memory (documented default: 50% of the computer's memory) and reports
    autoMemoryReclaim ([experimental], default dropCache; also looked up under [wsl2]). IB
    Gateway runs a Java heap of 768 MB plus the JVM, Xvfb and the container runtime, so less
    than 2 GB for the whole VM gets WARN, as does a value the kit cannot read.
    .PARAMETER WslConfigPath
    Path of .wslconfig.
    .OUTPUTS
    Check result 'WslMemory'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string]$WslConfigPath = (Get-GwDefaultWslConfigPath))
    $name = 'WslMemory'
    $text = Read-GwTextFile -Path $WslConfigPath
    $memory = Get-GwIniValue -Text $text -Section 'wsl2' -Key 'memory'
    $reclaim = Get-GwIniValue -Text $text -Section 'experimental' -Key 'autoMemoryReclaim'
    if ([string]::IsNullOrEmpty($reclaim)) { $reclaim = Get-GwIniValue -Text $text -Section 'wsl2' -Key 'autoMemoryReclaim' }
    $reclaimText = 'autoMemoryReclaim=dropCache (default)'
    if (-not [string]::IsNullOrEmpty($reclaim)) { $reclaimText = 'autoMemoryReclaim={0}' -f $reclaim.Trim() }
    if ([string]::IsNullOrEmpty($memory)) {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('memory is not set: the WSL VM may use up to 50% of this computer''s memory (default); {0}.' -f $reclaimText))
    }
    $bytes = ConvertTo-GwSizeByte -Text $memory
    if ($null -eq $bytes) {
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail ('memory={0} is not a size the kit can read; {1}.' -f $memory.Trim(), $reclaimText) `
                -Fix 'Use a value such as memory=4GB in the [wsl2] section of .wslconfig.')
    }
    if ($bytes -lt 2147483648) {
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail ('memory={0}: less than 2 GB for the whole container VM; {1}.' -f $memory.Trim(), $reclaimText) `
                -Fix 'Give the WSL VM at least 2 GB, better 4 GB: harden.ps1 -WslConfig -WslMemoryGB 4')
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('memory={0}; {1}.' -f $memory.Trim(), $reclaimText))
}

function Test-GwDockerDesktopVersion {
    <#
    .SYNOPSIS
    Doctor check: reports the Docker Desktop version in use.
    .DESCRIPTION
    Reads 'docker version --format {{.Server.Platform.Name}}', which Docker Desktop answers with
    'Docker Desktop <version> (<build>)'. SKIP when another runtime is in use or docker does not
    answer.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .OUTPUTS
    Check result 'DockerDesktopVersion'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][pscustomobject]$Runtime)
    $name = 'DockerDesktopVersion'
    if ([string]$Runtime.Mode -ne 'DockerDesktop') {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'Docker Desktop is not the runtime in use.')
    }
    $result = Invoke-GwDocker -ArgumentList @('version', '--format', '{{.Server.Platform.Name}}')
    $line = [string]($result.Output | Where-Object { $_ -match 'Docker Desktop' } | Select-Object -First 1)
    if ($result.ExitCode -ne 0 -or $line.Length -eq 0) {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'Docker did not report the Docker Desktop version.')
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('{0}.' -f $line.Trim()))
}

function Test-GwDockerDesktopUpdate {
    <#
    .SYNOPSIS
    Doctor check: does Docker Desktop download updates by itself?
    .DESCRIPTION
    Applying a Docker Desktop update restarts the engine and with it the gateway, which then
    needs a new login. The check reads AutoDownloadUpdates from settings-store.json. Docker does
    not document the key names of that file, so a missing key is SKIP (not measured), never
    PASS; Docker documents the default of "Always download updates" as off.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER DockerSettingsPath
    Path of settings-store.json.
    .OUTPUTS
    Check result 'DockerDesktopAutoUpdate'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [string]$DockerSettingsPath = (Get-GwDefaultDockerSettingsPath)
    )
    $name = 'DockerDesktopAutoUpdate'
    $manual = 'Open Docker Desktop > Settings > Updates ("Software updates" in older versions) and leave "Always download updates" off; update on purpose, outside market hours.'
    if ([string]$Runtime.Mode -ne 'DockerDesktop') {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'Docker Desktop is not the runtime in use.')
    }
    $settings = Get-GwDockerDesktopSetting -DockerSettingsPath $DockerSettingsPath
    if ($null -eq $settings) {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'Docker Desktop''s settings file could not be read.' -Fix $manual)
    }
    $value = Get-GwPropertyValue -InputObject $settings -Name 'AutoDownloadUpdates'
    if ($null -eq $value) {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'The update setting is not recorded in settings-store.json (Docker documents its default as off).' -Fix $manual)
    }
    if ($value -eq $true) {
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail 'Docker Desktop downloads updates by itself; applying one restarts the engine and the gateway (new login with 2FA).' -Fix $manual)
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'Docker Desktop does not download updates by itself.')
}

function Test-GwDockerDesktopLicence {
    <#
    .SYNOPSIS
    Doctor reminder: Docker Desktop's licence terms.
    .DESCRIPTION
    A script cannot know an organisation's size, so with Docker Desktop this is SKIP (not
    measurable) carrying a neutral statement of Docker's published terms, and a pointer to the
    alternative. With another runtime it is PASS.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .OUTPUTS
    Check result 'DockerDesktopLicence'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][pscustomobject]$Runtime)
    $name = 'DockerDesktopLicence'
    if ([string]$Runtime.Mode -ne 'DockerDesktop') {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'Docker Desktop is not the runtime in use.')
    }
    $detail = 'Not measurable by a script. Docker''s terms: Docker Desktop is free for personal use, education, non-commercial open source and ' +
    'small businesses with fewer than 250 employees AND less than USD 10 million annual revenue; other commercial and government use needs a paid subscription.'
    return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail $detail `
            -Fix 'Confirm which case applies to you (docs.docker.com/subscription/desktop-license). The alternative without Docker Desktop is Docker Engine inside WSL 2 (see README).')
}

function Test-GwFirewallExposure {
    <#
    .SYNOPSIS
    Doctor check: nothing lets the network reach the API ports 4001, 4002 or 9810.
    .DESCRIPTION
    The compose file binds the ports to 127.0.0.1, so by itself nothing is exposed. Two host
    settings can change that and are checked here. A 'netsh interface portproxy' entry that
    listens on a non-loopback address for one of the ports forwards the API to the network:
    FAIL. An enabled inbound allow rule that names one of the ports, for any program or for a
    Docker/WSL program, is a hole waiting for a listener: WARN. Rules tied to an unrelated
    program are ignored. SKIP when the firewall cannot be queried and no port proxy was found.
    .OUTPUTS
    Check result 'FirewallExposure'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = 'FirewallExposure'
    $proxyFindings = New-Object System.Collections.Generic.List[string]
    $proxyFix = New-Object System.Collections.Generic.List[string]
    $proxies = Invoke-GwRegistry -Operation GetValues -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'
    foreach ($listen in @($proxies.Keys)) {
        $parts = ([string]$listen).Split('/')
        if ($parts.Count -ne 2 -or $parts[1] -notmatch '^\d+$') { continue }
        if ($script:GwApiPorts -notcontains [int]$parts[1]) { continue }
        if (@('127.0.0.1', 'localhost', '::1') -contains $parts[0]) { continue }
        $proxyFindings.Add(('{0}:{1} -> {2}' -f $parts[0], $parts[1], [string]$proxies[$listen]))
        $proxyFix.Add(('netsh interface portproxy delete v4tov4 listenport={0} listenaddress={1}' -f $parts[1], $parts[0]))
    }
    if ($proxyFindings.Count -gt 0) {
        $detail = 'A port proxy publishes the gateway API to the network: {0}.' -f ($proxyFindings.ToArray() -join '; ')
        return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail $detail -Fix ('In an elevated prompt run: {0}' -f ($proxyFix.ToArray() -join '   and   ')))
    }
    try {
        $rules = @(Invoke-GwFirewall -Operation List -Port $script:GwApiPorts)
    }
    catch {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail ('Windows Firewall could not be queried: {0}' -f $_.Exception.Message))
    }
    $relevant = @($rules | Where-Object { $_.Program -eq 'Any' -or $_.Program -match '(?i)docker|wslrelay|wsl\.exe|vpnkit' })
    if ($relevant.Count -eq 0) {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'No firewall rule and no port proxy opens ports 4001, 4002 or 9810 to the network.')
    }
    $described = @($relevant | ForEach-Object { '"{0}" (ports {1}, from {2}, profile {3})' -f $_.DisplayName, ($_.LocalPort -join ','), ($_.RemoteAddress -join ','), $_.Profile })
    $detail = 'Firewall rules allow inbound traffic to a gateway port: {0}. Nothing listens there beyond loopback today, but the hole exists.' -f ($described -join '; ')
    return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail `
            -Fix 'Remove or narrow those rules, or run: harden.ps1 -FirewallLoopbackOnly   (adds a block rule for the three ports; loopback is not affected).')
}

function Test-GwHostClock {
    <#
    .SYNOPSIS
    Doctor check: the Windows clock agrees with time.windows.com.
    .DESCRIPTION
    Takes one sample with 'w32tm /stripchart /computer:time.windows.com /samples:1 /dataonly'
    and reads the offset by pattern (decimal point or comma). WARN above 1 s, FAIL above 5 s.
    An error line (for example 0x800705B4 when UDP port 123 is blocked) or a failed command is
    SKIP: an unmeasured clock is not a healthy clock.
    .OUTPUTS
    Check result 'HostClock'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    $name = 'HostClock'
    $fix = 'In an elevated prompt run: w32tm /resync   (and check Settings > Time & language > "Set time automatically").'
    $result = Invoke-GwW32tm -ArgumentList @('/stripchart', '/computer:time.windows.com', '/samples:1', '/dataonly')
    $joined = $result.Output -join "`n"
    $match = [regex]::Match($joined, '(?m)([+-]\d+[.,]\d+)s\s*$')
    if ($result.ExitCode -ne 0 -or -not $match.Success) {
        $errorCode = [regex]::Match($joined, '0x[0-9A-Fa-f]{8}')
        $reason = 'w32tm gave no offset'
        if ($errorCode.Success) { $reason = 'time.windows.com did not answer (error {0}); outbound UDP port 123 may be blocked' -f $errorCode.Value }
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail ('The Windows clock could not be compared: {0}.' -f $reason))
    }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $offset = [double]::Parse($match.Groups[1].Value.Replace(',', '.'), $culture)
    $absolute = [Math]::Abs($offset)
    $detail = 'The Windows clock differs from time.windows.com by {0} s.' -f $absolute.ToString('0.00', $culture)
    if ($absolute -gt 5) { return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail $detail -Fix $fix) }
    if ($absolute -gt 1) { return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail -Fix $fix) }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail $detail)
}

function Test-GwVmClock {
    <#
    .SYNOPSIS
    Doctor check: the clock inside the container VM agrees with the Windows clock.
    .DESCRIPTION
    After the host resumes from sleep the WSL VM's clock can lag by the time slept. The check
    runs a tiny pinned image ('docker run --rm ... busybox adjtimex', no network, read-only,
    no capabilities, unprivileged user) that prints the kernel time with sub-second precision,
    and compares it with the Windows time at the moment the line arrived. The comparison is
    biased by the pipe latency (tens of milliseconds), far below the thresholds: WARN above
    1 s, FAIL above 5 s. Containers share the VM's kernel clock, so this is the gateway's clock.
    The first run pulls the image (about 2 MB). SKIP when docker cannot run it.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .OUTPUTS
    Check result 'ContainerClock'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][pscustomobject]$Runtime)
    $name = 'ContainerClock'
    if ([string]$Runtime.Mode -eq 'None') {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'No container runtime was detected, so the container clock was not measured.')
    }
    $containerName = 'winkit-clock-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8)
    $arguments = @(
        'run', '--rm', '--name', $containerName, '--network', 'none', '--read-only', '--cap-drop', 'ALL',
        '--security-opt', 'no-new-privileges:true', '--user', '65534:65534', $script:GwProbeImage, 'adjtimex'
    )
    $result = Invoke-GwContainerCli -Runtime $Runtime -ArgumentList $arguments -TimeoutSeconds 300
    if ($result.ExitCode -ne 0) {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'The clock probe container could not run (the first run needs to pull a 2 MB image).' `
                -Fix 'Check that Docker can pull images, then run doctor.ps1 again.')
    }
    $seconds = $null
    $fraction = $null
    $status = 0
    $received = $null
    for ($index = 0; $index -lt $result.Output.Count; $index++) {
        $line = $result.Output[$index]
        if ($line -match 'status:\s+(\d+)') { $status = [int]$Matches[1] }
        if ($line -match 'time\.tv_sec:\s+(\d+)') { $seconds = [long]$Matches[1] }
        if ($line -match 'time\.tv_usec:\s+(\d+)') {
            $fraction = [long]$Matches[1]
            $received = $result.ReceivedUtc[$index]
        }
    }
    if ($null -eq $seconds -or $null -eq $fraction -or $null -eq $received) {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'The clock probe printed no timestamp.')
    }
    # With the STA_NANO status flag (0x2000) the kernel reports nanoseconds in tv_usec.
    $divisor = [double]1000000
    if (($status -band 0x2000) -ne 0) { $divisor = [double]1000000000 }
    $vmEpoch = [double]$seconds + ([double]$fraction / $divisor)
    $unixEpoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    $hostEpoch = ($received.ToUniversalTime() - $unixEpoch).TotalSeconds
    $offset = $vmEpoch - $hostEpoch
    $absolute = [Math]::Abs($offset)
    $direction = 'behind'
    if ($offset -gt 0) { $direction = 'ahead of' }
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $detail = 'The container clock is {0} s {1} the Windows clock.' -f $absolute.ToString('0.0', $culture), $direction
    $fix = 'Run: harden.ps1 -ResumeClockFix   (re-syncs the VM clock after every resume). To fix it now without restarting the gateway: wsl -u root hwclock -s'
    if ($absolute -gt 5) { return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail $detail -Fix $fix) }
    if ($absolute -gt 1) { return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail -Fix $fix) }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail $detail)
}

function Get-GwComposeConfig {
    <#
    .SYNOPSIS
    Loads the gateway folder's compose file the way Docker understands it.
    .DESCRIPTION
    Runs 'docker compose -f compose.yaml config --format json' (read-only: it only parses and
    normalises) and returns the parsed object, so the compose checks judge the effective
    configuration and need no YAML parser. A missing file, an undetected runtime or a compose
    error returns Config = null with the reason.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER Path
    Gateway folder.
    .OUTPUTS
    PSCustomObject: Config (object or null) and Reason (empty when loaded).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $folder = Resolve-GwFullPath -Path $Path
    if (-not [System.IO.File]::Exists((Join-Path $folder 'compose.yaml'))) {
        return [pscustomobject]@{ Config = $null; Reason = 'compose.yaml not found (setup.ps1 has not run in this folder)' }
    }
    if ([string]$Runtime.Mode -eq 'None') {
        return [pscustomobject]@{ Config = $null; Reason = 'no container runtime was detected, so the compose file could not be parsed' }
    }
    $result = Invoke-GwCompose -Runtime $Runtime -Path $folder -ArgumentList @('config', '--format', 'json')
    if ($result.ExitCode -ne 0) {
        $first = [string]($result.Output | Select-Object -First 1)
        return [pscustomobject]@{ Config = $null; Reason = ('docker compose config failed: {0}' -f $first) }
    }
    try {
        return [pscustomobject]@{ Config = (($result.Output -join "`n") | ConvertFrom-Json); Reason = '' }
    }
    catch [System.ArgumentException] {
        return [pscustomobject]@{ Config = $null; Reason = 'docker compose config did not print JSON' }
    }
}

function Get-GwComposeService {
    <#
    .SYNOPSIS
    Returns the services of a parsed compose configuration as name/definition pairs.
    .PARAMETER Config
    Object from Get-GwComposeConfig.
    .OUTPUTS
    PSCustomObject per service: Name and Definition.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][pscustomobject]$Config)
    $services = Get-GwPropertyValue -InputObject $Config -Name 'services'
    if ($null -eq $services) { return }
    foreach ($property in $services.PSObject.Properties) {
        [pscustomobject]@{ Name = $property.Name; Definition = $property.Value }
    }
}

function Test-GwComposePortBinding {
    <#
    .SYNOPSIS
    Doctor check: every published port of the compose file is bound to loopback.
    .DESCRIPTION
    A port published without a host address, or on 0.0.0.0 or a LAN address, lets other
    computers reach the trading API: FAIL. Only 127.0.0.1 and ::1 pass.
    .PARAMETER Config
    Parsed configuration, or null.
    .PARAMETER Reason
    Why Config is null.
    .OUTPUTS
    Check result 'ComposePortBinding'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][pscustomobject]$Config,
        [AllowEmptyString()][string]$Reason = ''
    )
    $name = 'ComposePortBinding'
    if ($null -eq $Config) { return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail ('Not checked: {0}.' -f $Reason)) }
    $exposed = New-Object System.Collections.Generic.List[string]
    $count = 0
    foreach ($service in @(Get-GwComposeService -Config $Config)) {
        foreach ($port in @(Get-GwPropertyValue -InputObject $service.Definition -Name 'ports' -Default @())) {
            $count++
            $hostIp = [string](Get-GwPropertyValue -InputObject $port -Name 'host_ip' -Default '')
            $published = [string](Get-GwPropertyValue -InputObject $port -Name 'published' -Default '?')
            if (@('127.0.0.1', '::1') -contains $hostIp) { continue }
            $where = 'all addresses'
            if ($hostIp.Length -gt 0) { $where = $hostIp }
            $exposed.Add(('{0}: port {1} on {2}' -f $service.Name, $published, $where))
        }
    }
    if ($exposed.Count -gt 0) {
        return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail ('Ports are published beyond this computer: {0}.' -f ($exposed.ToArray() -join '; ')) `
                -Fix 'Re-run setup.ps1 (add -Force to replace the edited compose.yaml); it binds the API to 127.0.0.1.')
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('{0} published port(s), all bound to loopback.' -f $count))
}

function Test-GwComposeStopGrace {
    <#
    .SYNOPSIS
    Doctor check: the gateway gets at least 60 seconds to shut down.
    .DESCRIPTION
    IB Gateway saves its settings on shutdown and the image waits up to 60 seconds for it;
    Docker's default stop timeout is 10 seconds, after which the process is killed. FAIL when
    stop_grace_period is missing, unreadable or below 60 s.
    .PARAMETER Config
    Parsed configuration, or null.
    .PARAMETER Reason
    Why Config is null.
    .OUTPUTS
    Check result 'ComposeStopGrace'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][pscustomobject]$Config,
        [AllowEmptyString()][string]$Reason = ''
    )
    $name = 'ComposeStopGrace'
    if ($null -eq $Config) { return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail ('Not checked: {0}.' -f $Reason)) }
    $problems = New-Object System.Collections.Generic.List[string]
    $values = New-Object System.Collections.Generic.List[string]
    foreach ($service in @(Get-GwComposeService -Config $Config)) {
        $text = [string](Get-GwPropertyValue -InputObject $service.Definition -Name 'stop_grace_period' -Default '')
        $seconds = ConvertTo-GwDurationSecond -Text $text
        if ($null -eq $seconds) { $problems.Add(('{0}: not set (Docker stops after 10 s)' -f $service.Name)) }
        elseif ($seconds -lt 60) { $problems.Add(('{0}: {1} s' -f $service.Name, $seconds)) }
        else { $values.Add(('{0}: {1} s' -f $service.Name, $seconds)) }
    }
    if ($problems.Count -gt 0) {
        return (New-GwCheckResult -Name $name -Status 'FAIL' -Detail ('The stop grace period is too short: {0}.' -f ($problems.ToArray() -join '; ')) `
                -Fix 'Re-run setup.ps1 (add -Force to replace the edited compose.yaml); it sets stop_grace_period: 90s.')
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail ('Stop grace period: {0}.' -f ($values.ToArray() -join '; ')))
}

function Test-GwComposeReadOnly {
    <#
    .SYNOPSIS
    Doctor check: the container's root file system is read-only.
    .PARAMETER Config
    Parsed configuration, or null.
    .PARAMETER Reason
    Why Config is null.
    .OUTPUTS
    Check result 'ComposeReadOnly': PASS when every service sets read_only, WARN otherwise.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [AllowNull()][pscustomobject]$Config,
        [AllowEmptyString()][string]$Reason = ''
    )
    $name = 'ComposeReadOnly'
    if ($null -eq $Config) { return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail ('Not checked: {0}.' -f $Reason)) }
    $writable = @(Get-GwComposeService -Config $Config | Where-Object { (Get-GwPropertyValue -InputObject $_.Definition -Name 'read_only' -Default $false) -ne $true } |
            ForEach-Object { $_.Name })
    if ($writable.Count -gt 0) {
        return (New-GwCheckResult -Name $name -Status 'WARN' -Detail ('The root file system is writable for: {0}.' -f ($writable -join ', ')) `
                -Fix 'Re-run setup.ps1 (add -Force to replace the edited compose.yaml); it sets read_only: true.')
    }
    return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'The container root file system is read-only.')
}

function Test-GwFolderAccess {
    <#
    .SYNOPSIS
    Doctor check: can only the operator, SYSTEM and Administrators change a folder the kit relies on?
    .DESCRIPTION
    Used for two folders. The gateway folder holds compose.yaml, the record of a rejected
    login and the change journal that 'harden.ps1 -Undo' replays (elevated). The kit's own
    folder holds start.ps1, which the scheduled start task runs as the operator. An account
    that can write to either can therefore change what runs under the operator's name. A
    folder created directly under C:\ inherits write access for every local user, so this is
    the default situation for a kit extracted there. Read-only: looks at the access list of
    the folder itself (Get-GwAclWriterIdentity), not at every file below it.
    .PARAMETER Path
    Folder to inspect.
    .PARAMETER Name
    Check name to report: 'GatewayFolderAccess' or 'KitFolderAccess'.
    .PARAMETER Fix
    What the operator should do when other accounts may write.
    .PARAMETER Risk
    One sentence saying what such an account could do; appended to the detail.
    .OUTPUTS
    Check result object: PASS, WARN (the other accounts are named) or SKIP (folder missing).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Fix,
        [string]$Risk = ''
    )
    $folder = Resolve-GwFullPath -Path $Path
    if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
        return (New-GwCheckResult -Name $Name -Status 'SKIP' -Detail ('{0} does not exist yet.' -f $folder) -Fix 'Run setup.ps1.')
    }
    $writers = @(Get-GwAclWriterIdentity -Path $folder)
    if ($writers.Count -eq 0) {
        return (New-GwCheckResult -Name $Name -Status 'PASS' -Detail ('Only your account, SYSTEM and Administrators can change {0}.' -f $folder))
    }
    $detail = 'Other accounts can change {0}: {1}.' -f $folder, ($writers -join ', ')
    if (-not [string]::IsNullOrEmpty($Risk)) { $detail = '{0} {1}' -f $detail, $Risk }
    return (New-GwCheckResult -Name $Name -Status 'WARN' -Detail $detail -Fix $Fix)
}

function Get-GwPrerequisiteResult {
    <#
    .SYNOPSIS
    Runs the prerequisite checks of setup.ps1.
    .DESCRIPTION
    Windows build, virtualization, WSL, container runtime, the three ports and disk space, in
    that order. Only the API port of the chosen trading mode is required; the other API port
    and 9810 (reserved for the sidecar) are reported as WARN when taken. Read-only.
    .PARAMETER Path
    Gateway folder (its drive is checked for space; it need not exist).
    .PARAMETER TradingMode
    'paper' or 'live'.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .OUTPUTS
    Check result objects.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('paper', 'live')][string]$TradingMode,
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime
    )
    $setting = Get-GwComposeSetting -TradingMode $TradingMode
    $otherPort = 4001
    if ($setting.ApiPort -eq 4001) { $otherPort = 4002 }
    Invoke-GwCheckSafely -Name 'WindowsBuild' -Check { Test-GwWindowsBuild }
    Invoke-GwCheckSafely -Name 'Virtualization' -Check { Test-GwVirtualization }
    Invoke-GwCheckSafely -Name 'WslVersion' -Check { Test-GwWslVersion }
    Invoke-GwCheckSafely -Name 'ContainerRuntime' -Check { Test-GwContainerRuntime -Runtime $Runtime }
    Invoke-GwCheckSafely -Name ('Port{0}' -f $setting.ApiPort) -Check { Test-GwPortAvailable -Port $setting.ApiPort -Runtime $Runtime -ContainerName $setting.ContainerName -Required }
    Invoke-GwCheckSafely -Name ('Port{0}' -f $otherPort) -Check { Test-GwPortAvailable -Port $otherPort -Runtime $Runtime -ContainerName $setting.ContainerName }
    Invoke-GwCheckSafely -Name 'Port9810' -Check { Test-GwPortAvailable -Port 9810 -Runtime $Runtime -ContainerName $setting.ContainerName }
    Invoke-GwCheckSafely -Name 'DiskSpace' -Check { Test-GwDiskSpace -Path $Path }
}

function Get-GwDoctorResult {
    <#
    .SYNOPSIS
    Runs every doctor check and returns the results.
    .DESCRIPTION
    Read-only by construction: the checks call only the read operations of the wrappers. Each
    check runs through Invoke-GwCheckSafely, so a broken probe becomes SKIP and the list is
    always complete. The trading mode comes from kit-state.json in the folder (paper when
    setup has not run there).
    .PARAMETER Path
    Gateway folder.
    .PARAMETER Runtime
    Object from Get-GwRuntime.
    .PARAMETER WslConfigPath
    Path of .wslconfig.
    .PARAMETER DockerSettingsPath
    Path of Docker Desktop's settings-store.json.
    .OUTPUTS
    Check result objects, in a fixed order.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][pscustomobject]$Runtime,
        [string]$WslConfigPath = (Get-GwDefaultWslConfigPath),
        [string]$DockerSettingsPath = (Get-GwDefaultDockerSettingsPath)
    )
    $folder = Resolve-GwFullPath -Path $Path
    $state = Get-GwKitState -Path $folder
    $tradingMode = [string](Get-GwPropertyValue -InputObject $state -Name 'TradingMode' -Default 'paper')
    if (@('paper', 'live') -notcontains $tradingMode) { $tradingMode = 'paper' }
    $secrets = Join-Path $folder 'secrets'

    Invoke-GwCheckSafely -Name 'WindowsBuild' -Check { Test-GwWindowsBuild }
    Invoke-GwCheckSafely -Name 'Virtualization' -Check { Test-GwVirtualization }
    Invoke-GwCheckSafely -Name 'WslVersion' -Check { Test-GwWslVersion }
    Invoke-GwCheckSafely -Name 'ContainerRuntime' -Check { Test-GwContainerRuntime -Runtime $Runtime }
    Invoke-GwCheckSafely -Name 'DockerDesktopVersion' -Check { Test-GwDockerDesktopVersion -Runtime $Runtime }
    Invoke-GwCheckSafely -Name 'DockerDesktopAutoUpdate' -Check { Test-GwDockerDesktopUpdate -Runtime $Runtime -DockerSettingsPath $DockerSettingsPath }
    Invoke-GwCheckSafely -Name 'DockerDesktopLicence' -Check { Test-GwDockerDesktopLicence -Runtime $Runtime }
    Invoke-GwCheckSafely -Name 'SleepOnAc' -Check { Test-GwSleepOnAc }
    Invoke-GwCheckSafely -Name 'UpdateActiveHours' -Check { Test-GwUpdateActiveWindow }
    Invoke-GwCheckSafely -Name 'UpdatePendingReboot' -Check { Test-GwUpdatePendingReboot }
    Invoke-GwCheckSafely -Name 'UpdateAutoRestart' -Check { Test-GwUpdateAutoRestart }
    Invoke-GwCheckSafely -Name 'StartAtBoot' -Check { Test-GwStartAtBoot -Runtime $Runtime -Path $folder -TradingMode $tradingMode -DockerSettingsPath $DockerSettingsPath }
    Invoke-GwCheckSafely -Name 'WslNetworkingMode' -Check { Test-GwWslNetworking -WslConfigPath $WslConfigPath }
    Invoke-GwCheckSafely -Name 'WslIdleShutdown' -Check { Test-GwWslIdle -WslConfigPath $WslConfigPath -Runtime $Runtime -TradingMode $tradingMode }
    Invoke-GwCheckSafely -Name 'WslMemory' -Check { Test-GwWslMemory -WslConfigPath $WslConfigPath }
    Invoke-GwCheckSafely -Name 'FirewallExposure' -Check { Test-GwFirewallExposure }
    Invoke-GwCheckSafely -Name 'HostClock' -Check { Test-GwHostClock }
    Invoke-GwCheckSafely -Name 'ContainerClock' -Check { Test-GwVmClock -Runtime $Runtime }
    Invoke-GwCheckSafely -Name 'DiskSpace' -Check { Test-GwDiskSpace -Path $folder }
    Invoke-GwCheckSafely -Name 'SecretEncodingUsername' -Check { Test-GwSecretEncoding -Path (Join-Path $secrets 'ib-username') -Name 'SecretEncodingUsername' }
    Invoke-GwCheckSafely -Name 'SecretEncodingPassword' -Check { Test-GwSecretEncoding -Path (Join-Path $secrets 'ib-password') -Name 'SecretEncodingPassword' }
    Invoke-GwCheckSafely -Name 'SecretFolderAccess' -Check { Test-GwSecretAcl -Path $secrets }
    Invoke-GwCheckSafely -Name 'GatewayFolderAccess' -Check {
        Test-GwFolderAccess -Path $folder -Name 'GatewayFolderAccess' `
            -Risk 'They could edit compose.yaml, clear the record of a rejected login or alter the change journal that harden.ps1 -Undo replays.' `
            -Fix 'Run setup.ps1 again; it restricts the folder to your account, SYSTEM and Administrators and keeps your secrets.'
    }
    Invoke-GwCheckSafely -Name 'KitFolderAccess' -Check {
        # The icacls line was run on a scratch folder (2026-11-12): it drops the inherited entries
        # and leaves the three named ones; an entry granted explicitly to someone else stays and
        # doctor keeps naming it.
        $kitFix = ('Keep the kit in a folder only you can change, for example under your user profile, or switch inheritance off for this one: ' +
            'icacls "{0}" /inheritance:r /grant:r "*{1}:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" ' +
            '(then run doctor.ps1 again and remove any account it still names with icacls /remove). ' +
            'If you move the kit, run harden.ps1 -StartAtBoot again: the start task refers to its path.') -f $script:GwModuleRoot, (Get-GwCurrentUser).Sid
        Test-GwFolderAccess -Path $script:GwModuleRoot -Name 'KitFolderAccess' -Fix $kitFix `
            -Risk 'The scheduled start task runs start.ps1 from this folder under your account, so they could run code as you.'
    }
    $compose = Get-GwComposeConfig -Runtime $Runtime -Path $folder
    Invoke-GwCheckSafely -Name 'ComposePortBinding' -Check { Test-GwComposePortBinding -Config $compose.Config -Reason $compose.Reason }
    Invoke-GwCheckSafely -Name 'ComposeStopGrace' -Check { Test-GwComposeStopGrace -Config $compose.Config -Reason $compose.Reason }
    Invoke-GwCheckSafely -Name 'ComposeReadOnly' -Check { Test-GwComposeReadOnly -Config $compose.Config -Reason $compose.Reason }
}
