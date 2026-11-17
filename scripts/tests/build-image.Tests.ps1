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
        param([string]$Stamp, [string]$Context)
        return @('version: 10.50.1h', 'channel: stable', 'arch: x64', 'pinned_version: 10.50.1g', 'pinned: no',
            'qualified_by_project: no', ('ibkr_build_stamp: {0}' -f $Stamp), ('installer_sha256: {0}' -f ('b' * 64)),
            'source: ibkr', 'cache_hit: no', 'ibkr_reachable: yes', 'run: run-Ab12Cd34', ('context_file: {0}' -f $Context),
            'build_arg: IB_GATEWAY_VERSION=10.50.1h', ('build_arg: IB_GATEWAY_BUILD_STAMP={0}' -f $Stamp),
            'build_arg: IB_GATEWAY_QUALIFIED=no')
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
        $script:plan = Get-TestPlan -Stamp $script:stamp -Context $script:context
        Mock Write-BiMessage { [void]$script:messages.Add($Message) }
        Mock Write-BiUsage {}
        Mock Write-BiResult { [void]$script:results.Add($Line) }
        Mock Test-BiDockerAvailable { return $true }
        Mock Get-BiUserArgument { return @() }
        Mock Invoke-BiDockerCapture {
            [void]$script:calls.Add([string[]]$ArgumentList)
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
        Test-Sequence -Actual $resolve -Expected @('-e', 'BROKERSRE_TEST_IBKR_BASE_URL', 'brokersre-ib-gateway-build-helper:local', 'bash', '/repo/scripts/resolve-installer.sh') | Should -BeTrue
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

    It 'returns the helper''s exit code <code> and builds nothing' -TestCases @(@{ code = 1 }, @{ code = 3 }, @{ code = 4 }) {
        $script:resolveExit = $code
        Invoke-BuildImage -ArgumentList @('-CacheDir', $script:cache) -RepoRoot $script:repo | Should -Be $code
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

    It 'without Docker it returns 1' {
        Mock Test-BiDockerAvailable { return $false }
        Invoke-BuildImage -ArgumentList @() -RepoRoot $script:repo | Should -Be 1
    }
}

Describe 'build-image.ps1 as a process' {
    It 'exits 2 on a usage error under <edition>' -ForEach $script:editions {
        & $exe -NoProfile -ExecutionPolicy Bypass -File $script:scriptPath -Channel 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
        & $exe -NoProfile -ExecutionPolicy Bypass -File $script:scriptPath -Bogus 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 2
    }
}
