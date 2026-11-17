# Pester tests for scripts/build-image.ps1 (Pester 6.2.0, under Windows PowerShell 5.1 and
# PowerShell 7):
#   pwsh -NoProfile -Command "Invoke-Pester scripts/tests" ; powershell -NoProfile -Command "Invoke-Pester scripts/tests"
#
# The wrapper's own logic is tested with docker mocked: Invoke-BiDockerCapture and
# Invoke-BiDockerStream are the only places that run docker, Write-BiMessage and Write-BiResult
# the only places that print. What runs inside the helper container (scripts/resolve-installer.sh)
# is tested by tests/bats/ci/build-image.bats; here the helper's answers are canned. Contract under
# test: argument mapping, the docker command lines (helper, build, smoke test), the seven last
# lines, and the exit codes 0, 1, 2, 3, 4 of docs/specs/2026-11-17-private-image-public-recipe.md.

BeforeDiscovery {
    $script:editions = @()
    if ($null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)) { $script:editions += @{ edition = 'Windows PowerShell 5.1'; exe = 'powershell.exe' } }
    if ($null -ne (Get-Command pwsh -ErrorAction SilentlyContinue)) { $script:editions += @{ edition = 'PowerShell 7'; exe = 'pwsh' } }
}

BeforeAll {
    $script:scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'build-image.ps1'
    . $script:scriptPath
    $script:stamp = '(.1h) 20261116 16:02:08'
    $script:context = 'downloads/ibgateway-10.50.1h-standalone-linux-x64.sh'

    # Helper functions take everything as parameters: inside a function defined in BeforeAll,
    # $script: does not reach the variables the mocks and the tests share.
    function Get-TestPlan {
        <#
        .SYNOPSIS
        A plan as the helper's 'resolve' prints it for IBKR's 10.50.1h on stable.
        #>
        param([string]$Stamp, [string]$Context, [string]$Owned = 'yes')
        return @('version: 10.50.1h', 'channel: stable', 'arch: x64', 'pinned_version: 10.50.1g', 'pinned: no',
            'qualified_by_project: no', ('ibkr_build_stamp: {0}' -f $Stamp), ('installer_sha256: {0}' -f ('b' * 64)),
            'source: ibkr', 'installer_source: ibkr', 'cache_hit: no', 'ibkr_reachable: yes', 'run: run-Ab12Cd34',
            ('context_file: {0}' -f $Context), ('context_owned: {0}' -f $Owned),
            'build_arg: IB_GATEWAY_VERSION=10.50.1h', ('build_arg: IB_GATEWAY_BUILD_STAMP={0}' -f $Stamp),
            'build_arg: IB_GATEWAY_QUALIFIED=no', 'build_arg: IB_GATEWAY_INSTALLER_SOURCE=ibkr')
    }

    function Get-TestCall {
        <#
        .SYNOPSIS
        The recorded docker calls (Calls) whose arguments contain Marker.
        #>
        param([System.Collections.ArrayList]$Calls, [string]$Marker)
        $found = New-Object System.Collections.ArrayList
        foreach ($call in $Calls) { if ($call -contains $Marker) { [void]$found.Add($call) } }
        # The comma keeps the array of calls one object: a bare return would unroll it, and [0]
        # would be the first argument of the first call instead of the first call.
        return , $found.ToArray()
    }

    function Test-Sequence {
        <#
        .SYNOPSIS
        True when Expected appears in Actual as consecutive elements.
        #>
        param([string[]]$Actual, [string[]]$Expected)
        for ($i = 0; $i -le $Actual.Count - $Expected.Count; $i++) {
            $match = $true
            for ($j = 0; $j -lt $Expected.Count; $j++) {
                if ($Actual[$i + $j] -cne $Expected[$j]) { $match = $false; break }
            }
            if ($match) { return $true }
        }
        return $false
    }
}

Describe 'Invoke-BuildImage' {
    BeforeEach {
        $script:repo = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:repo 'downloads') -Force | Out-Null
        $script:cache = Join-Path $TestDrive ('cache-' + [guid]::NewGuid().ToString('N'))
        $script:calls = New-Object System.Collections.ArrayList
        $script:results = New-Object System.Collections.ArrayList
        $script:messages = New-Object System.Collections.ArrayList
        $script:resolveExit = 0
        $script:buildExit = 0
        $script:smokeExit = 0
        $script:hostArch = 'x86_64'
        $script:daemonDown = $false
        $script:plan = Get-TestPlan -Stamp $script:stamp -Context $script:context
        Mock Write-BiMessage { [void]$script:messages.Add($Message) }
        Mock Write-BiUsage {}
        Mock Write-BiResult { [void]$script:results.Add($Line) }
        Mock Test-BiDockerAvailable { return $true }
        Mock Get-BiUserArgument { return @() }
        Mock Invoke-BiDockerCapture {
            [void]$script:calls.Add([string[]]$ArgumentList)
            # Like buildx: a build asked for a metadata file writes one that names its record.
            $at = [array]::IndexOf([string[]]$ArgumentList, '--metadata-file')
            if ($at -ge 0) { Set-Content -LiteralPath $ArgumentList[$at + 1] -Value '{ "buildx.build.ref": "desktop-linux/desktop-linux/stubhelperref" }' }
            if ($script:daemonDown -and @('info', 'version') -contains $ArgumentList[0]) { return [pscustomobject]@{ ExitCode = 1; Lines = [string[]]@() } }
            if ($ArgumentList[0] -eq 'version') { return [pscustomobject]@{ ExitCode = 0; Lines = [string[]]@('29.9.3') } }
            if ($ArgumentList[0] -eq 'context') { return [pscustomobject]@{ ExitCode = 0; Lines = [string[]]@('desktop-linux') } }
            if ($ArgumentList[0] -eq 'info') { return [pscustomobject]@{ ExitCode = 0; Lines = [string[]]@($script:hostArch) } }
            if ($ArgumentList[0] -eq 'image') { return [pscustomobject]@{ ExitCode = 0; Lines = [string[]]@('sha256:' + ('a' * 64)) } }
            if ($ArgumentList -contains 'resolve') { return [pscustomobject]@{ ExitCode = $script:resolveExit; Lines = [string[]]$script:plan } }
            if ($ArgumentList -contains 'accept') {
                return [pscustomobject]@{ ExitCode = 0; Lines = [string[]]@('version: 10.50.1h', 'channel: stable', 'qualified_by_project: no',
                        ('installer_sha256: {0}' -f ('b' * 64)), ('ibkr_build_stamp: {0}' -f $script:stamp)) }
            }
            return [pscustomobject]@{ ExitCode = 0; Lines = [string[]]@() }
        }
        Mock Invoke-BiDockerStream {
            [void]$script:calls.Add([string[]]$ArgumentList)
            $at = [array]::IndexOf([string[]]$ArgumentList, '--metadata-file')
            if ($at -ge 0) { Set-Content -LiteralPath $ArgumentList[$at + 1] -Value '{ "buildx.build.ref": "desktop-linux/desktop-linux/stubimageref" }' }
            if ($ArgumentList[0] -eq 'buildx') { return $script:buildExit }
            return $script:smokeExit
        }
    }

    It 'maps -Channel, -Strict, -Installer and -PrintPlan to the helper''s resolve arguments' {
        $installer = Join-Path $TestDrive 'my-installer.sh'
        Set-Content -LiteralPath $installer -Value 'x'
        $code = Invoke-BuildImage -ArgumentList @('-Channel', 'latest', '-Strict', '-Installer', $installer, '-PrintPlan', '-CacheDir', $script:cache) -RepoRoot $script:repo
        $code | Should -Be 0
        $resolve = (Get-TestCall -Calls $script:calls -Marker 'resolve')[0]
        Test-Sequence -Actual $resolve -Expected @('resolve', '--arch', 'x64', '--versions', '/repo/versions.json', '--cache', '/cache', '--downloads', '/downloads') | Should -BeTrue
        Test-Sequence -Actual $resolve -Expected @('--channel', 'latest', '--strict', '--installer', '/installer/my-installer.sh', '--print-plan') | Should -BeTrue
        Test-Sequence -Actual $resolve -Expected @('-v', ('{0}:/installer:ro' -f $TestDrive)) | Should -BeTrue
        Test-Sequence -Actual $resolve -Expected @('-e', 'BROKERSRE_TEST_IBKR_BASE_URL') | Should -BeTrue
        Test-Sequence -Actual $resolve -Expected @('brokersre-ib-gateway-build-helper:local', 'bash', '/repo/scripts/resolve-installer.sh') | Should -BeTrue
    }

    It 'tells the helper that the caller is PowerShell and where downloads\ is on this host' {
        $code = Invoke-BuildImage -ArgumentList @('-PrintPlan', '-CacheDir', $script:cache) -RepoRoot $script:repo
        $code | Should -Be 0
        $resolve = (Get-TestCall -Calls $script:calls -Marker 'resolve')[0]
        Test-Sequence -Actual $resolve -Expected @('-e', 'BROKERSRE_HOST_SHELL=powershell') | Should -BeTrue
        Test-Sequence -Actual $resolve -Expected @('-e', ('BROKERSRE_HOST_DOWNLOADS={0}' -f (Join-Path $script:repo 'downloads'))) | Should -BeTrue
    }

    It '-PrintPlan prints the plan, the platform and the image, and builds nothing' {
        $code = Invoke-BuildImage -ArgumentList @('-PrintPlan', '-CacheDir', $script:cache) -RepoRoot $script:repo
        $code | Should -Be 0
        $script:results | Should -Contain 'version: 10.50.1h'
        $script:results | Should -Contain 'pinned: no'
        $script:results | Should -Contain 'cache_hit: no'
        $script:results[-2] | Should -Be 'platform: linux/amd64'
        $script:results[-1] | Should -Be 'image: brokersre-ib-gateway:stable'
        (Get-TestCall -Calls $script:calls -Marker '--platform').Count | Should -Be 0
        (Get-TestCall -Calls $script:calls -Marker 'resolve').Count | Should -Be 1
    }

    It 'builds with the resolved build arguments, the host''s platform and the default tags' {
        $code = Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo
        $code | Should -Be 0
        $build = (Get-TestCall -Calls $script:calls -Marker '--platform')[0]
        Test-Sequence -Actual $build -Expected @('buildx', 'build', '--platform', 'linux/amd64', '--load', '-t', 'brokersre-ib-gateway:stable', '-t', 'brokersre-ib-gateway:10.50.1h') | Should -BeTrue
        Test-Sequence -Actual $build -Expected @('--build-arg', ('IB_GATEWAY_BUILD_STAMP={0}' -f $script:stamp)) | Should -BeTrue
        Test-Sequence -Actual $build -Expected @('--build-arg', 'IB_GATEWAY_QUALIFIED=no') | Should -BeTrue
        $build[-1] | Should -Be $script:repo
        $build[-2] | Should -Be (Join-Path $script:repo 'Dockerfile')
        $helperBuild = (Get-TestCall -Calls $script:calls -Marker 'brokersre-ib-gateway-build-helper:local')[0]
        Test-Sequence -Actual $helperBuild -Expected @('buildx', 'build', '--load', '-q', '-t', 'brokersre-ib-gateway-build-helper:local') | Should -BeTrue
    }

    It 'prints the seven result lines last, in the order of the contract' {
        $code = Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo
        $code | Should -Be 0
        @($script:results) | Should -Be @('version: 10.50.1h', 'channel: stable', 'qualified_by_project: no', ('installer_sha256: {0}' -f ('b' * 64)),
            ('ibkr_build_stamp: {0}' -f $script:stamp), 'image: brokersre-ib-gateway:stable', ('image_id: sha256:{0}' -f ('a' * 64)))
        $accept = (Get-TestCall -Calls $script:calls -Marker 'accept')[0]
        Test-Sequence -Actual $accept -Expected @('accept', '--cache', '/cache', '--run', 'run-Ab12Cd34', '--image', 'brokersre-ib-gateway:stable') | Should -BeTrue
    }

    It 'an arm64 Docker host builds linux/arm64 and asks the helper for the arm installer' {
        $script:hostArch = 'aarch64'
        $code = Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo
        $code | Should -Be 0
        Test-Sequence -Actual (Get-TestCall -Calls $script:calls -Marker 'resolve')[0] -Expected @('--arch', 'arm') | Should -BeTrue
        Test-Sequence -Actual (Get-TestCall -Calls $script:calls -Marker '--platform')[0] -Expected @('--platform', 'linux/arm64') | Should -BeTrue
    }

    It '-Platform overrides the host and -Tag (repeated, or comma-separated) replaces the default tags' {
        $arguments = @('-Platform', 'linux/arm64', '-Tag', 'example.test/gw:a', '-Tag', 'example.test/gw:b,example.test/gw:c', '-NoSmoke', '-CacheDir', $script:cache)
        $code = Invoke-BuildImage -ArgumentList $arguments -RepoRoot $script:repo
        $code | Should -Be 0
        (Get-TestCall -Calls $script:calls -Marker 'info').Count | Should -Be 0
        $build = (Get-TestCall -Calls $script:calls -Marker '--platform')[0]
        Test-Sequence -Actual $build -Expected @('--platform', 'linux/arm64', '--load', '-t', 'example.test/gw:a', '-t', 'example.test/gw:b', '-t', 'example.test/gw:c', '--build-arg') | Should -BeTrue
        $script:results[-2] | Should -Be 'image: example.test/gw:a'
    }

    It 'maps the helper''s exit code <code> to <expected> and builds nothing' -TestCases @(
        @{ code = 1; expected = 1 }, @{ code = 2; expected = 2 }, @{ code = 3; expected = 3 }, @{ code = 4; expected = 4 },
        @{ code = 125; expected = 1 }, @{ code = 126; expected = 1 }
    ) {
        $script:resolveExit = $code
        Invoke-BuildImage -ArgumentList @('-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be $expected
        (Get-TestCall -Calls $script:calls -Marker '--platform').Count | Should -Be 0
        $script:results.Count | Should -Be 0
    }

    It 'a failed image build returns 1, discards the run and removes the installer from downloads/' {
        $script:buildExit = 1
        $contextPath = Join-Path $script:repo ($script:context -replace '/', [IO.Path]::DirectorySeparatorChar)
        Set-Content -LiteralPath $contextPath -Value 'installer'
        Invoke-BuildImage -ArgumentList @('-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be 1
        Test-Sequence -Actual (Get-TestCall -Calls $script:calls -Marker 'discard')[0] -Expected @('discard', '--cache', '/cache', '--run', 'run-Ab12Cd34') | Should -BeTrue
        (Get-TestCall -Calls $script:calls -Marker 'accept').Count | Should -Be 0
        (Get-TestCall -Calls $script:calls -Marker 'ibc-smoke').Count | Should -Be 0
        Test-Path -LiteralPath $contextPath | Should -BeFalse
    }

    It 'an installer the user put in downloads/ (context_owned: no) stays after a <outcome> build' -TestCases @(
        @{ outcome = 'successful'; buildExit = 0; code = 0 }, @{ outcome = 'failed'; buildExit = 1; code = 1 }
    ) {
        $script:buildExit = $buildExit
        $script:plan = Get-TestPlan -Stamp $script:stamp -Context $script:context -Owned 'no'
        $contextPath = Join-Path $script:repo ($script:context -replace '/', [IO.Path]::DirectorySeparatorChar)
        Set-Content -LiteralPath $contextPath -Value 'the user''s installer'
        Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be $code
        Test-Path -LiteralPath $contextPath | Should -BeTrue
    }

    It 'the smoke test runs in the helper container through the Docker socket, offline' {
        Invoke-BuildImage -ArgumentList @('-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be 0
        $smoke = (Get-TestCall -Calls $script:calls -Marker 'ibc-smoke')[0]
        Test-Sequence -Actual $smoke -Expected @('run', '--rm', '-v', '/var/run/docker.sock:/var/run/docker.sock', '-v', ('{0}:/repo:ro' -f $script:repo), '-w', '/repo') | Should -BeTrue
        $expected = @('-e', 'IMAGE=brokersre-ib-gateway:stable', '-e', 'SMOKE_TIMEOUT', 'brokersre-ib-gateway-build-helper:local',
            'bash', 'tests/container/run.sh', '--only', 'ibc-smoke')
        Test-Sequence -Actual $smoke -Expected $expected | Should -BeTrue
    }

    It 'a failed smoke test returns 1 and discards the run' {
        $script:smokeExit = 1
        Invoke-BuildImage -ArgumentList @('-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be 1
        (Get-TestCall -Calls $script:calls -Marker 'discard').Count | Should -Be 1
        (Get-TestCall -Calls $script:calls -Marker 'accept').Count | Should -Be 0
    }

    It '-NoSmoke skips the smoke test' {
        Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be 0
        (Get-TestCall -Calls $script:calls -Marker 'ibc-smoke').Count | Should -Be 0
    }

    It 'usage error <arguments> returns 2 before any docker call' -TestCases @(
        @{ arguments = @('-Bogus') }, @{ arguments = @('-Channel', 'beta') }, @{ arguments = @('-Channel') },
        @{ arguments = @('-Channel', '-Strict') }, @{ arguments = @('-Platform', 'linux/386') }, @{ arguments = @('-Tag') },
        @{ arguments = @('-Installer', 'no-such-installer.sh') }, @{ arguments = @('stable') }
    ) {
        Invoke-BuildImage -ArgumentList $arguments -RepoRoot $script:repo | Should -Be 2
        $script:calls.Count | Should -Be 0
    }

    It 'the default cache is %LOCALAPPDATA%\brokersre-ib-gateway' {
        $saved = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = Join-Path $TestDrive 'localappdata'
            Invoke-BuildImage -ArgumentList @('-PrintPlan') -RepoRoot $script:repo | Should -Be 0
            $expected = '{0}:/cache' -f (Join-Path $env:LOCALAPPDATA 'brokersre-ib-gateway')
            Test-Sequence -Actual (Get-TestCall -Calls $script:calls -Marker 'resolve')[0] -Expected @('-v', $expected) | Should -BeTrue
        }
        finally { $env:LOCALAPPDATA = $saved }
    }

    It 'an unreachable Docker daemon is named as such and returns 1, with or without -Platform: <arguments>' -TestCases @(
        @{ arguments = @() }, @{ arguments = @('-Platform', 'linux/amd64') }
    ) {
        $script:daemonDown = $true
        Invoke-BuildImage -ArgumentList (@($arguments) + @('-NoSmoke', '-CacheDir', $script:cache)) -RepoRoot $script:repo | Should -Be 1
        ($script:messages -join "`n") | Should -Match 'the Docker daemon is not reachable'
        ($script:messages -join "`n") | Should -Match 'desktop-linux'
        ($script:messages -join "`n") | Should -Not -Match 'architecture'
        (Get-TestCall -Calls $script:calls -Marker 'run').Count | Should -Be 0
    }

    It 'proxy variables reach the helper (-e NAME) and the build (--build-arg NAME) by name, never by value' {
        $secret = 'pw-' + ('SYN{0}' -f 'THETIC')
        $saved = @{}
        foreach ($name in @('HTTPS_PROXY', 'NO_PROXY')) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', ('http://synthetic:{0}@proxy.invalid:3128' -f $secret))
            [Environment]::SetEnvironmentVariable('NO_PROXY', '127.0.0.1,localhost')
            Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be 0
            Test-Sequence -Actual (Get-TestCall -Calls $script:calls -Marker 'resolve')[0] -Expected @('-e', 'HTTPS_PROXY') | Should -BeTrue
            Test-Sequence -Actual (Get-TestCall -Calls $script:calls -Marker 'resolve')[0] -Expected @('-e', 'NO_PROXY') | Should -BeTrue
            $build = (Get-TestCall -Calls $script:calls -Marker '--platform')[0]
            Test-Sequence -Actual $build -Expected @('--build-arg', 'HTTPS_PROXY') | Should -BeTrue
            Test-Sequence -Actual $build -Expected @('--build-arg', 'NO_PROXY') | Should -BeTrue
            # The helper image's build (apk add) needs the proxy as well (review of #43).
            $helperBuild = (Get-TestCall -Calls $script:calls -Marker 'brokersre-ib-gateway-build-helper:local')[0]
            Test-Sequence -Actual $helperBuild -Expected @('buildx', 'build', '--load', '-q', '-t', 'brokersre-ib-gateway-build-helper:local') | Should -BeTrue
            Test-Sequence -Actual $helperBuild -Expected @('--build-arg', 'HTTPS_PROXY') | Should -BeTrue
            Test-Sequence -Actual $helperBuild -Expected @('--build-arg', 'NO_PROXY') | Should -BeTrue
            foreach ($call in $script:calls) { ($call -join ' ') | Should -Not -Match $secret }
            ($script:messages -join "`n") | Should -Not -Match $secret
            ($script:results -join "`n") | Should -Not -Match $secret
        }
        finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }

    It 'without proxy variables no proxy name is passed' {
        $saved = @{}
        $names = @('HTTPS_PROXY', 'HTTP_PROXY', 'NO_PROXY', 'https_proxy', 'http_proxy', 'no_proxy')
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
        try {
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $null) }
            Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be 0
            foreach ($call in $script:calls) { ($call -join ' ') | Should -Not -Match '(?i)proxy' }
        }
        finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }

    It 'labels the build with its time (UTC) and the revision Get-BiRevision gives (<revision>)' -TestCases @(
        @{ revision = ('c' * 40) }, @{ revision = 'unknown' }
    ) {
        Mock Get-BiRevision { return $revision }
        Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be 0
        $build = (Get-TestCall -Calls $script:calls -Marker '--platform')[0]
        Test-Sequence -Actual $build -Expected @('--label', ('org.opencontainers.image.revision={0}' -f $revision)) | Should -BeTrue
        $created = @($build | Where-Object { $_ -like 'org.opencontainers.image.created=*' })
        $created.Count | Should -Be 1
        $created[0] | Should -Match '^org\.opencontainers\.image\.created=\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
    }

    It 'Get-BiRevision names the commit of a git work tree and unknown elsewhere' {
        Get-BiRevision -RepoRoot $script:repo | Should -Be 'unknown'
        if ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
            Get-BiRevision -RepoRoot (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) | Should -Match '^[0-9a-f]{40}$'
        }
    }

    It 'passes the host''s cache directory and installer path, so the helper''s messages name them' {
        $installer = Join-Path $TestDrive 'mine.sh'
        Set-Content -LiteralPath $installer -Value 'x'
        Invoke-BuildImage -ArgumentList @('-Installer', $installer, '-PrintPlan', '-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be 0
        $resolve = (Get-TestCall -Calls $script:calls -Marker 'resolve')[0]
        Test-Sequence -Actual $resolve -Expected @('-e', ('BROKERSRE_HOST_CACHE={0}' -f $script:cache)) | Should -BeTrue
        Test-Sequence -Actual $resolve -Expected @('-e', ('BROKERSRE_HOST_INSTALLER={0}' -f $installer)) | Should -BeTrue
    }

    It 'drops a trailing separator from -CacheDir: Windows PowerShell 5.1 turns "\ + quote" into an escaped quote' {
        # "...\ps cache dir\" (a space and a trailing backslash): 5.1 quoted the argument
        # BROKERSRE_HOST_CACHE=...\ps cache dir\ as "...dir\" and docker read a garbled command
        # ("Unable to find image 'cache:latest'"; review of #43).
        $dir = Join-Path $TestDrive 'ps cache dir'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Invoke-BuildImage -ArgumentList @('-PrintPlan', '-CacheDir', ($dir + [IO.Path]::DirectorySeparatorChar)) -RepoRoot $script:repo | Should -Be 0
        $resolve = (Get-TestCall -Calls $script:calls -Marker 'resolve')[0]
        Test-Sequence -Actual $resolve -Expected @('-e', ('BROKERSRE_HOST_CACHE={0}' -f $dir)) | Should -BeTrue
        Test-Sequence -Actual $resolve -Expected @('-v', ('{0}:/cache' -f $dir)) | Should -BeTrue
        foreach ($argument in $resolve) { $argument.EndsWith('\') | Should -BeFalse -Because $argument }
    }

    It 'a proxy URL with credentials ends the build (<outcome>) with the records to remove; the value stays hidden' -TestCases @(
        @{ outcome = 'built'; buildExit = 0; code = 0 }, @{ outcome = 'failed'; buildExit = 1; code = 1 }
    ) {
        $secret = 'pw-' + ('SYN{0}' -f 'THETIC')
        $saved = [Environment]::GetEnvironmentVariable('HTTPS_PROXY')
        try {
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', ('http://synthetic:{0}@proxy.invalid:3128' -f $secret))
            $script:buildExit = $buildExit
            Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be $code
            $text = $script:messages -join "`n"
            $text | Should -Match 'build records'
            $text | Should -Match 'docker buildx history rm stubhelperref stubimageref'
            $text | Should -Not -Match $secret
            foreach ($call in $script:calls) {
                $at = [array]::IndexOf([string[]]$call, '--metadata-file')
                if ($at -ge 0) { Test-Path -LiteralPath $call[$at + 1] | Should -BeFalse }
            }
        }
        finally { [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $saved) }
    }

    It 'a proxy URL without credentials asks for no metadata and prints no reminder' {
        $saved = [Environment]::GetEnvironmentVariable('HTTPS_PROXY')
        try {
            [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://proxy.invalid:3128')
            Invoke-BuildImage -ArgumentList @('-NoSmoke', '-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be 0
            ($script:messages -join "`n") | Should -Not -Match 'build records'
            foreach ($call in $script:calls) { $call | Should -Not -Contain '--metadata-file' }
        }
        finally { [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $saved) }
    }

    It 'without Docker it returns 1' {
        Mock Test-BiDockerAvailable { return $false }
        Invoke-BuildImage -ArgumentList @() -RepoRoot $script:repo | Should -Be 1
    }
}

Describe 'build-image.ps1 as a process' {
    # Start-Process with files, not '& exe 2>$null': in a Windows PowerShell 5.1 host with
    # $ErrorActionPreference = 'Stop' (as in CI) a redirected native standard error line is a
    # terminating error, and the test would fail on the usage message it expects.
    It 'exits 2 on a usage error under <edition>' -ForEach $script:editions {
        foreach ($usage in @('-Channel', '-Bogus')) {
            $out = Join-Path $TestDrive ('out-' + [guid]::NewGuid().ToString('N'))
            $err = Join-Path $TestDrive ('err-' + [guid]::NewGuid().ToString('N'))
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $script:scriptPath), $usage)
            $process = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError $err
            $process.ExitCode | Should -Be 2 -Because $usage
            (Get-Content -LiteralPath $err -Raw) | Should -Match 'build-image: '
        }
    }
}

Describe 'The help of build-image.ps1' {
    # A stable bump can become the pin without a person (ADR 0009, 0018): 'yes' means "equals
    # the pin, which passed the offline CI", never "logged in with".
    It 'says what qualified_by_project: yes means, and that a paper login is separate (<source>)' -TestCases @(
        @{ source = 'Get-Help' }
        @{ source = 'usage text' }
    ) {
        param($source)
        if ($source -eq 'Get-Help') {
            $text = Get-Help -Name $script:scriptPath -Full | Out-String
        }
        else {
            $text = $script:UsageText
        }
        $text = $text -replace '\s+', ' '
        $text | Should -BeLike "*qualified_by_project: yes means the version and the installer's SHA-256 equal the pin in versions.json, which passed the project's offline CI*"
        $text | Should -BeLike '*a paper login is a separate qualification (scripts/qualify-paper.sh)*'
    }
}
