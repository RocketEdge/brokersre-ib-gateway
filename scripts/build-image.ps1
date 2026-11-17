<#
.SYNOPSIS
Builds the IB Gateway image from this repository, robust against IBKR replacing its installers.

.DESCRIPTION
The PowerShell twin of scripts/build-image.sh, with the same behaviour, options, output and
exit codes (interface: docs/specs/2026-11-17-private-image-public-recipe.md; decision: ADR 0018).
Runs under Windows PowerShell 5.1 and PowerShell 7. The only other requirement is Docker with
buildx (Docker Desktop, or Docker Engine 23 or later).

Parameters (names are case-insensitive):
  -Channel stable|latest   IBKR channel (default stable; with -Installer, the installer's own)
  -Strict                  build only the version pinned in versions.json (exit 4 otherwise)
  -Installer FILE          build from this installer file; its version comes from its build stamp
  -Platform linux/amd64|linux/arm64   image platform (default: the Docker host's architecture)
  -Tag NAME                image name, repeatable; replaces brokersre-ib-gateway:<channel> and
                           brokersre-ib-gateway:<version>
  -NoSmoke                 skip the offline IBC smoke test
  -CacheDir DIR            installer cache (default %LOCALAPPDATA%\brokersre-ib-gateway)
  -PrintPlan               print what would be built (version, pinned or not, cache hit);
                           download nothing, build nothing

Steps: build the helper image scripts/build-helper; run scripts/resolve-installer.sh in it (it
decides, downloads or takes from the cache, verifies, and puts the installer into the build
context's downloads/); 'docker buildx build --load' with the resolved build arguments; the IBC
smoke test (tests/container/run.sh --only ibc-smoke), run inside the helper container through
the Docker socket because this host may have no bash; record the installer in the cache and
print the summary.

Output: progress and warnings on standard error; on success the last seven lines on standard
output are version, channel, qualified_by_project, installer_sha256, ibkr_build_stamp, image,
image_id as 'key: value' (with -PrintPlan: the plan's 'key: value' lines).

qualified_by_project: yes means the version and the installer's SHA-256 equal the pin in
versions.json, which passed the project's offline CI; a paper login is a separate
qualification (scripts/qualify-paper.sh). A stable pin can move without a person
(STABLE_AUTOMERGE, ADR 0018).

Exit codes: 0 built (and smoke-tested unless -NoSmoke); 1 download, verification, build or
smoke test failed; 2 usage; 3 IBKR unreachable and no usable cached installer; 4 -Strict and
IBKR serves (or the installer is) a version other than the pin.

The arguments are parsed by this script, not by PowerShell's parameter binder: the binder
refuses a parameter without its value with exit 1 before the script runs, and the contract
says 2. Environment: BROKERSRE_TEST_IBKR_BASE_URL (tests only) is passed to the helper;
SMOKE_TIMEOUT to the smoke test.

.EXAMPLE
pwsh -NoProfile -File scripts/build-image.ps1

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\build-image.ps1 -Channel latest -Strict
#>

Set-StrictMode -Version Latest

$script:HelperImage = 'brokersre-ib-gateway-build-helper:local'
$script:DefaultRepository = 'brokersre-ib-gateway'
$script:UsageText = @'
usage: scripts/build-image.ps1 [-Channel stable|latest] [-Strict] [-Installer FILE]
                               [-Platform linux/amd64|linux/arm64] [-Tag NAME] [-NoSmoke]
                               [-CacheDir DIR] [-PrintPlan]
Exit codes: 0 built, 1 download/verification/build/smoke test failed, 2 usage,
3 IBKR unreachable and no usable cached installer, 4 -Strict and IBKR serves another version.
qualified_by_project: yes means the version and the installer's SHA-256 equal the pin in
versions.json, which passed the project's offline CI; a paper login is a separate
qualification (scripts/qualify-paper.sh).
'@

function Write-BiMessage {
    <#
    .SYNOPSIS
    Writes one progress or error line to standard error, prefixed 'build-image: '.
    .DESCRIPTION
    Standard error, not the host or the success stream: under 'pwsh -File' the host stream is
    the process's standard output, and the last lines of standard output are the contract.
    .PARAMETER Message
    The text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message)
    [Console]::Error.WriteLine('build-image: ' + $Message)
}

function Write-BiUsage {
    <#
    .SYNOPSIS
    Writes the usage text to standard error (after a usage error).
    #>
    [CmdletBinding()]
    param()
    [Console]::Error.WriteLine($script:UsageText)
}

function Write-BiResult {
    <#
    .SYNOPSIS
    Writes one machine-readable 'key: value' line to standard output.
    .DESCRIPTION
    Written to the console's standard output directly, so that Invoke-BuildImage's pipeline
    output stays its exit code alone.
    .PARAMETER Line
    The line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Line)
    [Console]::Out.WriteLine($Line)
}

function Test-BiDockerAvailable {
    <#
    .SYNOPSIS
    True when a 'docker' command can be found.
    .OUTPUTS
    System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ($null -ne (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue))
}

function Invoke-BiDockerCapture {
    <#
    .SYNOPSIS
    Runs docker with the given arguments and captures its standard output.
    .DESCRIPTION
    The one place that runs docker and keeps its output; Pester mocks it. Standard error goes
    to the console, or nowhere with -Quiet. Arguments with spaces are quoted by PowerShell;
    none may contain a double quote (Windows PowerShell 5.1 and PowerShell 7 pass embedded
    quotes differently).
    .PARAMETER ArgumentList
    The docker arguments.
    .PARAMETER Quiet
    Discard docker's standard error (a probe whose failure this script explains itself). The
    error preference is lowered in this function only: Windows PowerShell 5.1 turns a
    redirected native standard error line into an error, terminating under 'Stop'.
    .OUTPUTS
    An object with ExitCode (int) and Lines (string[]).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList, [switch]$Quiet)
    if ($Quiet) {
        $ErrorActionPreference = 'Continue'
        $lines = @(& docker @ArgumentList 2>$null)
    }
    else {
        $lines = @(& docker @ArgumentList)
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Lines = [string[]]@($lines | ForEach-Object { [string]$_ }) }
}

function Invoke-BiDockerStream {
    <#
    .SYNOPSIS
    Runs docker with the given arguments, showing its output on standard error.
    .DESCRIPTION
    The one place that runs docker for long steps (the image build, the smoke test); Pester
    mocks it. Docker's standard output is copied to standard error line by line, so that
    standard output carries only the result lines.
    .PARAMETER ArgumentList
    The docker arguments.
    .OUTPUTS
    System.Int32, docker's exit code.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)
    & docker @ArgumentList | ForEach-Object { [Console]::Error.WriteLine([string]$_) }
    return [int]$LASTEXITCODE
}

function Get-BiUserArgument {
    <#
    .SYNOPSIS
    The '--user uid:gid' arguments for the helper container on Linux, nothing elsewhere.
    .DESCRIPTION
    On Linux a bind mount keeps host ownership, so the helper runs as the calling user and the
    cache and downloads/ stay the user's. Docker Desktop (Windows, macOS) maps ownership itself.
    .OUTPUTS
    System.String[] (empty or two elements).
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    if ((Test-Path -Path 'variable:IsLinux') -and $IsLinux) {
        return [string[]]@('--user', ('{0}:{1}' -f (& id -u), (& id -g)))
    }
    return [string[]]@()
}

function Get-BiProxyName {
    <#
    .SYNOPSIS
    The names of the proxy variables set in this process's environment.
    .DESCRIPTION
    HTTPS_PROXY, HTTP_PROXY, NO_PROXY and their lower-case forms, as the caller's shell set
    them. Only the names are passed on ('-e NAME', '--build-arg NAME'); docker reads the values
    from its environment, so a value, which may hold a password, is never in an argument list
    or in the output. On Windows the names are case-insensitive, so a set HTTPS_PROXY also
    answers for https_proxy; both are passed, with the same value.
    .OUTPUTS
    System.String[].
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    $names = @()
    foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'no_proxy')) {
        if ([Environment]::GetEnvironmentVariable($name)) { $names += $name }
    }
    return [string[]]$names
}

function Get-BiRevision {
    <#
    .SYNOPSIS
    The commit of the checkout at RepoRoot, or 'unknown'.
    .DESCRIPTION
    Labels the image (org.opencontainers.image.revision). 'unknown' when git is not installed or
    RepoRoot is not a git work tree (a downloaded archive). The error preference is lowered in
    this function only: Windows PowerShell 5.1 turns git's redirected standard error into an
    error, terminating under 'Stop'.
    .PARAMETER RepoRoot
    The repository root.
    .OUTPUTS
    System.String: lower-case hex, or 'unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return 'unknown' }
    $ErrorActionPreference = 'Continue'
    $revision = (@(& git -C $RepoRoot rev-parse HEAD 2>$null) -join '').Trim()
    if ($LASTEXITCODE -eq 0 -and $revision -match '^[0-9a-f]+$') { return $revision }
    return 'unknown'
}

function Get-BiPlanValue {
    <#
    .SYNOPSIS
    The value of the line 'KEY: value' in the helper's plan, or an empty string.
    .PARAMETER Plan
    The plan lines.
    .PARAMETER Key
    The key.
    .OUTPUTS
    System.String.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Plan, [Parameter(Mandatory = $true)][string]$Key)
    foreach ($line in $Plan) {
        if ($line.StartsWith($Key + ': ')) { return $line.Substring($Key.Length + 2) }
    }
    return ''
}

function ConvertFrom-BiArgument {
    <#
    .SYNOPSIS
    Parses the script's arguments into a settings object, or returns an error message.
    .DESCRIPTION
    Accepts -Channel, -Strict, -Installer, -Platform, -Tag (repeatable, also a comma-separated
    or array value), -NoSmoke, -CacheDir and -PrintPlan, case-insensitively. A value parameter
    must be followed by a value that is not itself a parameter name.
    .PARAMETER ArgumentList
    The arguments as the script received them ($args).
    .OUTPUTS
    An object with Error (string, empty when valid) and the settings Channel, Strict, Installer,
    Platform, Tags, Smoke, CacheDir, PrintPlan.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$ArgumentList = @())
    $settings = [pscustomobject]@{
        Error = ''; Channel = ''; Strict = $false; Installer = ''; Platform = ''
        Tags = @(); Smoke = $true; CacheDir = ''; PrintPlan = $false
    }
    # Not flattened: '-Tag a,b' typed in a PowerShell session arrives as one array element.
    $tokens = @($ArgumentList)
    $index = 0
    while ($index -lt $tokens.Count) {
        $name = [string]$tokens[$index]
        $index++
        switch -Regex ($name) {
            '^-(Channel|Installer|Platform|Tag|CacheDir)$' {
                $value = ''
                if ($index -lt $tokens.Count) { $value = @($tokens[$index]) -join ',' }
                if ($value -eq '' -or $value.StartsWith('-')) {
                    $settings.Error = '{0} needs a value' -f $name
                    return $settings
                }
                $index++
                if ($name -eq '-Channel') { $settings.Channel = $value }
                elseif ($name -eq '-Installer') { $settings.Installer = $value }
                elseif ($name -eq '-Platform') { $settings.Platform = $value }
                elseif ($name -eq '-CacheDir') { $settings.CacheDir = $value }
                else { $settings.Tags += @($value -split ',' | Where-Object { $_ -ne '' }) }
                continue
            }
            '^-Strict$' { $settings.Strict = $true; continue }
            '^-NoSmoke$' { $settings.Smoke = $false; continue }
            '^-PrintPlan$' { $settings.PrintPlan = $true; continue }
            default {
                $settings.Error = "unknown argument '{0}'" -f $name
                return $settings
            }
        }
    }
    if (@('', 'stable', 'latest') -notcontains $settings.Channel) { $settings.Error = '-Channel must be stable or latest' }
    elseif (@('', 'linux/amd64', 'linux/arm64') -notcontains $settings.Platform) { $settings.Error = '-Platform must be linux/amd64 or linux/arm64' }
    elseif ($settings.Installer -ne '' -and -not (Test-Path -LiteralPath $settings.Installer -PathType Leaf)) {
        $settings.Error = "-Installer: cannot read '{0}'" -f $settings.Installer
    }
    return $settings
}

function Invoke-BuildImage {
    <#
    .SYNOPSIS
    Does the whole build and returns the exit code of the contract.
    .DESCRIPTION
    See the script's help. Every docker call goes through Invoke-BiDockerCapture or
    Invoke-BiDockerStream, every message through Write-BiMessage and every result line through
    Write-BiResult, so that Pester can run this function without Docker.
    .PARAMETER ArgumentList
    The script's arguments.
    .PARAMETER RepoRoot
    The repository root (default: the parent of this script's folder).
    .OUTPUTS
    System.Int32: 0, 1, 2, 3 or 4.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([AllowEmptyCollection()][object[]]$ArgumentList = @(), [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot))
    $settings = ConvertFrom-BiArgument -ArgumentList $ArgumentList
    if ($settings.Error -ne '') {
        Write-BiMessage -Message $settings.Error
        Write-BiUsage
        return 2
    }
    if (-not (Test-BiDockerAvailable)) {
        Write-BiMessage -Message 'Docker is required (Docker Desktop, or Docker Engine 23 or later with buildx)'
        return 1
    }
    if ((Invoke-BiDockerCapture -ArgumentList @('buildx', 'version')).ExitCode -ne 0) {
        Write-BiMessage -Message 'docker buildx is required (Docker Desktop, or Docker Engine 23 or later with the buildx plugin)'
        return 1
    }
    # The daemon, before anything asks it a question: without this check a stopped Docker
    # Desktop surfaced as an empty architecture, or (with -Platform) as a failed helper build.
    # Docker's own error is not repeated: it can name DOCKER_HOST, which may hold a user name.
    $server = Invoke-BiDockerCapture -ArgumentList @('version', '--format', '{{.Server.Version}}') -Quiet
    if ($server.ExitCode -ne 0 -or (@($server.Lines) -join '').Trim() -eq '') {
        $context = (@((Invoke-BiDockerCapture -ArgumentList @('context', 'show') -Quiet).Lines) -join '').Trim()
        if ($context -eq '') { $context = 'unknown' }
        $hostNote = ''
        if ($env:DOCKER_HOST) { $hostNote = ', DOCKER_HOST is set' }
        $advice = 'start Docker Desktop and wait until its engine runs (Windows, macOS), or start the daemon ' +
        '(Linux: sudo systemctl start docker); check the Docker context and DOCKER_HOST'
        Write-BiMessage -Message ("the Docker daemon is not reachable (Docker context '{0}'{1}): {2}" -f $context, $hostNote, $advice)
        return 1
    }
    $platform = $settings.Platform
    if ($platform -eq '') {
        $info = Invoke-BiDockerCapture -ArgumentList @('info', '--format', '{{.Architecture}}')
        $hostArch = (@($info.Lines) -join '').Trim()
        if (@('x86_64', 'amd64') -contains $hostArch) { $platform = 'linux/amd64' }
        elseif (@('aarch64', 'arm64') -contains $hostArch) { $platform = 'linux/arm64' }
        else {
            Write-BiMessage -Message ("the Docker host's architecture '{0}' is not supported; pass -Platform" -f $hostArch)
            return 1
        }
    }
    $arch = 'x64'
    if ($platform -eq 'linux/arm64') { $arch = 'arm' }
    $cacheDir = $settings.CacheDir
    if ($cacheDir -eq '') {
        if ($env:LOCALAPPDATA) { $cacheDir = Join-Path $env:LOCALAPPDATA 'brokersre-ib-gateway' }
        else {
            $base = $env:XDG_CACHE_HOME
            if (-not $base) { $base = Join-Path $HOME '.cache' }
            $cacheDir = Join-Path $base 'brokersre-ib-gateway'
        }
    }
    $downloads = Join-Path $RepoRoot 'downloads'
    foreach ($directory in @($cacheDir, $downloads)) {
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    }
    $cacheDir = (Resolve-Path -LiteralPath $cacheDir).ProviderPath

    # 'buildx build --load', not 'docker build': with a docker-container default builder a plain
    # build leaves the image in the build cache only, and 'docker run' would not find it.
    $built = Invoke-BiDockerCapture -ArgumentList @('buildx', 'build', '--load', '-q', '-t', $script:HelperImage, (Join-Path (Join-Path $RepoRoot 'scripts') 'build-helper'))
    if ($built.ExitCode -ne 0) {
        Write-BiMessage -Message 'could not build the helper image from scripts/build-helper'
        return 1
    }
    $helperPrefix = @('run', '--rm') + @(Get-BiUserArgument)
    if ($settings.Installer -ne '') {
        $installerPath = (Resolve-Path -LiteralPath $settings.Installer).ProviderPath
        $helperPrefix += @('-v', ('{0}:/installer:ro' -f (Split-Path -Parent $installerPath)),
            '-e', ('BROKERSRE_HOST_INSTALLER={0}' -f $settings.Installer))
    }
    # The helper's messages name the cache as this host does, not by its mount /cache.
    $helperPrefix += @('-e', ('BROKERSRE_HOST_CACHE={0}' -f $cacheDir))
    # The shell's proxy variables, by name only (Get-BiProxyName); also passed to the build.
    $proxyNames = @(Get-BiProxyName)
    foreach ($name in $proxyNames) { $helperPrefix += @('-e', $name) }
    # BROKERSRE_HOST_SHELL and BROKERSRE_HOST_DOWNLOADS let the helper's advice name PowerShell's
    # command, -Installer and the Windows path of downloads\ (it sees only its mount /downloads).
    $helperPrefix += @('-v', ('{0}:/cache' -f $cacheDir), '-v', ('{0}:/repo:ro' -f $RepoRoot), '-v', ('{0}:/downloads' -f $downloads),
        '-e', 'BROKERSRE_TEST_IBKR_BASE_URL', '-e', 'BROKERSRE_HOST_SHELL=powershell', '-e', ('BROKERSRE_HOST_DOWNLOADS={0}' -f $downloads),
        $script:HelperImage, 'bash', '/repo/scripts/resolve-installer.sh')

    $resolve = @('resolve', '--arch', $arch, '--versions', '/repo/versions.json', '--cache', '/cache', '--downloads', '/downloads')
    if ($settings.Channel -ne '') { $resolve += @('--channel', $settings.Channel) }
    if ($settings.Strict) { $resolve += '--strict' }
    if ($settings.Installer -ne '') { $resolve += @('--installer', ('/installer/' + (Split-Path -Leaf $installerPath))) }
    if ($settings.PrintPlan) { $resolve += '--print-plan' }
    $resolved = Invoke-BiDockerCapture -ArgumentList ($helperPrefix + $resolve)
    if (@(1, 2, 3, 4) -contains $resolved.ExitCode) { return [int]$resolved.ExitCode }
    if ($resolved.ExitCode -ne 0) {
        # Not the helper's answer: docker itself failed (125 daemon or mount error, 126/127 the
        # command could not run). The contract has no such code; it is a failed build.
        Write-BiMessage -Message ('the helper container did not run (docker exit {0})' -f $resolved.ExitCode)
        return 1
    }
    $plan = @($resolved.Lines)

    $version = Get-BiPlanValue -Plan $plan -Key 'version'
    $channel = Get-BiPlanValue -Plan $plan -Key 'channel'
    $runId = Get-BiPlanValue -Plan $plan -Key 'run'
    $contextFile = Get-BiPlanValue -Plan $plan -Key 'context_file'
    $tags = @($settings.Tags)
    if ($tags.Count -eq 0) { $tags = @(('{0}:{1}' -f $script:DefaultRepository, $channel), ('{0}:{1}' -f $script:DefaultRepository, $version)) }
    $image = $tags[0]

    if ($settings.PrintPlan) {
        foreach ($line in $plan) { Write-BiResult -Line $line }
        Write-BiResult -Line ('platform: {0}' -f $platform)
        Write-BiResult -Line ('image: {0}' -f $image)
        return 0
    }

    $discard = $helperPrefix + @('discard', '--cache', '/cache', '--run', $runId)
    $contextPath = Join-Path $RepoRoot ($contextFile -replace '/', [IO.Path]::DirectorySeparatorChar)
    try {
        $build = @('buildx', 'build', '--platform', $platform, '--load')
        foreach ($tag in $tags) { $build += @('-t', $tag) }
        foreach ($line in $plan) {
            if ($line.StartsWith('build_arg: ')) { $build += @('--build-arg', $line.Substring(11)) }
        }
        # Predefined build arguments: usable in RUN, kept out of docker history and the image.
        foreach ($name in $proxyNames) { $build += @('--build-arg', $name) }
        # The build's own OCI labels, as build-image.sh and the bake path set them: the build
        # time in UTC, to the second, and the commit of this checkout (Get-BiRevision).
        $created = [DateTime]::UtcNow.ToString("yyyy'-'MM'-'dd'T'HH':'mm':'ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $build += @('--label', ('org.opencontainers.image.created={0}' -f $created),
            '--label', ('org.opencontainers.image.revision={0}' -f (Get-BiRevision -RepoRoot $RepoRoot)))
        $build += @('-f', (Join-Path $RepoRoot 'Dockerfile'), $RepoRoot)
        Write-BiMessage -Message ('building {0}: IB Gateway {1} ({2}) for {3}' -f $image, $version, $channel, $platform)
        if ((Invoke-BiDockerStream -ArgumentList $build) -ne 0) {
            [void](Invoke-BiDockerCapture -ArgumentList $discard)
            Write-BiMessage -Message 'the image build failed; nothing was cached'
            return 1
        }
    }
    finally {
        # Only the installer this run put into downloads/; a file that was there before (the
        # user's, context_owned: no) is never removed.
        $owned = (Get-BiPlanValue -Plan $plan -Key 'context_owned') -eq 'yes'
        if ($owned -and $contextFile -ne '' -and (Test-Path -LiteralPath $contextPath)) { Remove-Item -LiteralPath $contextPath -Force }
    }

    if ($settings.Smoke) {
        # The smoke test is bash; this host may have none, so it runs in the helper container,
        # which reaches the daemon through its socket (the test mounts no host path).
        Write-BiMessage -Message ('smoke test: tests/container/run.sh --only ibc-smoke on {0} (offline)' -f $image)
        $smoke = @('run', '--rm', '-v', '/var/run/docker.sock:/var/run/docker.sock', '-v', ('{0}:/repo:ro' -f $RepoRoot),
            '-w', '/repo', '-e', ('IMAGE={0}' -f $image), '-e', 'SMOKE_TIMEOUT', $script:HelperImage,
            'bash', 'tests/container/run.sh', '--only', 'ibc-smoke')
        if ((Invoke-BiDockerStream -ArgumentList $smoke) -ne 0) {
            [void](Invoke-BiDockerCapture -ArgumentList $discard)
            Write-BiMessage -Message ('the IBC smoke test failed for {0}; nothing was cached' -f $image)
            return 1
        }
    }

    $accepted = Invoke-BiDockerCapture -ArgumentList ($helperPrefix + @('accept', '--cache', '/cache', '--run', $runId, '--image', $image))
    if ($accepted.ExitCode -ne 0) {
        Write-BiMessage -Message ('the image was built, but the helper could not record it (exit {0})' -f $accepted.ExitCode)
        return 1
    }
    $inspected = Invoke-BiDockerCapture -ArgumentList @('image', 'inspect', '--format', '{{.Id}}', $image)
    foreach ($line in @($accepted.Lines)) { Write-BiResult -Line $line }
    Write-BiResult -Line ('image: {0}' -f $image)
    Write-BiResult -Line ('image_id: {0}' -f ((@($inspected.Lines) -join '').Trim()))
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Invoke-BuildImage -ArgumentList $args)
}
