# Tests for src/Stack.ps1: runtime detection, compose rendering, the docker/compose dispatch,
# the phase follower and the connection snippets. docker and wsl are mocked at the wrapper,
# except for one read-only 'docker compose config' call that validates the rendered file.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-KitModule
    $script:templatePath = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'templates') 'compose.yaml.tmpl'
    $script:templateText = [System.IO.File]::ReadAllText($script:templatePath)
    $script:desktop = [pscustomobject]@{ Mode = 'DockerDesktop'; Distro = ''; EngineName = 'Docker Desktop'; OsType = 'linux'; ServerVersion = '29.0.0'; Detail = '' }
    $script:engine = [pscustomobject]@{ Mode = 'WslEngine'; Distro = 'Ubuntu-24.04'; EngineName = 'Ubuntu 24.04 LTS'; OsType = 'linux'; ServerVersion = '29.0.0'; Detail = '' }
}

Describe 'Get-GwComposeSetting' {
    It 'derives paper names and ports' {
        $setting = Get-GwComposeSetting -TradingMode 'paper'
        $setting.ProjectName | Should -Be 'brokersre-gateway-paper'
        $setting.ContainerName | Should -Be 'brokersre-ib-gateway-paper'
        $setting.ApiPort | Should -Be 4002
        $setting.RelayPort | Should -Be 4004
    }

    It 'derives live names and ports' {
        $setting = Get-GwComposeSetting -TradingMode 'live'
        $setting.ProjectName | Should -Be 'brokersre-gateway-live'
        $setting.ContainerName | Should -Be 'brokersre-ib-gateway-live'
        $setting.ApiPort | Should -Be 4001
        $setting.RelayPort | Should -Be 4003
    }
}

Describe 'ConvertTo-GwComposeText' {
    BeforeAll {
        $script:rendered = ConvertTo-GwComposeText -TemplateText $script:templateText -ImageRef 'ghcr.io/rocketedge/brokersre-ib-gateway:stable' `
            -TradingMode 'paper' -TimeZone 'America/New_York' -AutoRestartTime '11:45 PM'
    }

    It 'replaces every placeholder' {
        $script:rendered | Should -Not -Match '__[A-Z_]+__'
    }

    It 'binds the paper API to loopback only' {
        $script:rendered | Should -Match '- "127\.0\.0\.1:4002:4004"'
        $script:rendered | Should -Not -Match '0\.0\.0\.0'
        ([regex]::Matches($script:rendered, '(?m)^\s+- "[^"]*:\d+:\d+"')).Count | Should -Be 1
    }

    It 'binds the live API to loopback when rendering live' {
        $live = ConvertTo-GwComposeText -TemplateText $script:templateText -ImageRef 'example/image:tag' -TradingMode 'live' -TimeZone 'Etc/UTC' -AutoRestartTime '11:45 PM'
        $live | Should -Match '- "127\.0\.0\.1:4001:4003"'
        $live | Should -Match 'TRADING_MODE: live'
        $live | Should -Match 'name: brokersre-gateway-live'
    }

    It 'contains the hardening settings' {
        $script:rendered | Should -Match '(?m)^\s+read_only: true$'
        $script:rendered | Should -Match '(?m)^\s+cap_drop:\s*\n\s+- ALL$'
        $script:rendered | Should -Match 'no-new-privileges:true'
        $script:rendered | Should -Match '(?m)^\s+stop_grace_period: 90s$'
        $script:rendered | Should -Match '(?m)^\s+restart: unless-stopped$'
        $script:rendered | Should -Match 'uid=1000,gid=1000'
        $script:rendered | Should -Match '(?m)^\s+soft: 65536$'
        $script:rendered | Should -Match '(?m)^\s+hard: 65536$'
        $script:rendered | Should -Match 'driver: json-file'
        $script:rendered | Should -Match 'max-size: "10m"'
        $script:rendered | Should -Match 'max-file: "5"'
    }

    It 'reads the credentials from secret files and never embeds them' {
        $script:rendered | Should -Match 'TWS_USERID_FILE: /run/secrets/ib-username'
        $script:rendered | Should -Match 'TWS_PASSWORD_FILE: /run/secrets/ib-password'
        $script:rendered | Should -Match 'file: \./secrets/ib-username'
        $script:rendered | Should -Match 'file: \./secrets/ib-password'
        $script:rendered | Should -Not -Match '(?m)^\s+TWS_USERID:'
        $script:rendered | Should -Not -Match '(?m)^\s+TWS_PASSWORD:'
    }

    It 'keeps the API read-only unless orders are allowed explicitly' {
        $script:rendered | Should -Match 'READ_ONLY_API: "yes"'
        $orders = ConvertTo-GwComposeText -TemplateText $script:templateText -ImageRef 'example/image:tag' -TradingMode 'paper' -TimeZone 'Etc/UTC' `
            -AutoRestartTime '11:45 PM' -AllowApiOrders
        $orders | Should -Match 'READ_ONLY_API: "no"'
    }

    It 'uses LF line endings and ends with a newline' {
        $script:rendered.Contains("`r") | Should -BeFalse
        $script:rendered.EndsWith("`n") | Should -BeTrue
    }

    It 'accepts an image pinned by digest' {
        $digest = 'ghcr.io/rocketedge/brokersre-ib-gateway@sha256:' + ('ab' * 32)
        $text = ConvertTo-GwComposeText -TemplateText $script:templateText -ImageRef $digest -TradingMode 'paper' -TimeZone 'Etc/UTC' -AutoRestartTime '11:45 PM'
        $text | Should -Match ([regex]::Escape($digest))
    }

    It 'rejects an image reference that could inject YAML: <value>' -ForEach @(
        @{ value = "image:tag`n    privileged: true" }
        @{ value = 'image tag' }
        @{ value = 'image:tag # comment' }
        @{ value = '"image"' }
        @{ value = 'image@sha256:short' }
        @{ value = "a/b:c`n" }
        @{ value = '' }
    ) {
        { ConvertTo-GwComposeText -TemplateText $script:templateText -ImageRef $value -TradingMode 'paper' -TimeZone 'Etc/UTC' -AutoRestartTime '11:45 PM' } | Should -Throw
    }

    It 'rejects a time zone or restart time that is not in the expected form' {
        { ConvertTo-GwComposeText -TemplateText $script:templateText -ImageRef 'a/b:c' -TradingMode 'paper' -TimeZone 'New York' -AutoRestartTime '11:45 PM' } | Should -Throw
        { ConvertTo-GwComposeText -TemplateText $script:templateText -ImageRef 'a/b:c' -TradingMode 'paper' -TimeZone 'Etc/UTC' -AutoRestartTime '23:45' } | Should -Throw
    }

    It 'fails loudly when the template still contains an unknown placeholder' {
        $broken = $script:templateText + "x: __NEW_TOKEN__`n"
        { ConvertTo-GwComposeText -TemplateText $broken -ImageRef 'a/b:c' -TradingMode 'paper' -TimeZone 'Etc/UTC' -AutoRestartTime '11:45 PM' } |
            Should -Throw -ExpectedMessage '*__NEW_TOKEN__*'
    }
}

Describe 'Rendered compose file against the real docker compose (read-only)' {
    BeforeDiscovery {
        $script:composeAvailable = $false
        if ($null -ne (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
            & docker.exe compose version *> $null
            $script:composeAvailable = ($LASTEXITCODE -eq 0)
        }
    }

    It 'passes docker compose config and resolves to a loopback port, read-only root and 90 s grace' -Skip:(-not $script:composeAvailable) {
        $directory = Join-Path $TestDrive 'compose-real'
        New-Item -ItemType Directory -Path (Join-Path $directory 'secrets') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $directory 'secrets\ib-username'), 'fake-user')
        [System.IO.File]::WriteAllText((Join-Path $directory 'secrets\ib-password'), 'fake-pass')
        $text = ConvertTo-GwComposeText -TemplateText $script:templateText -ImageRef 'ghcr.io/rocketedge/brokersre-ib-gateway:stable' `
            -TradingMode 'paper' -TimeZone 'America/New_York' -AutoRestartTime '11:45 PM'
        $file = Join-Path $directory 'compose.yaml'
        [System.IO.File]::WriteAllText($file, $text, (New-Object System.Text.UTF8Encoding($false)))
        $output = & docker.exe compose -f $file config --format json 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        $config = ($output | Out-String) | ConvertFrom-Json
        $service = $config.services.'ib-gateway'
        $service.ports.Count | Should -Be 1
        $service.ports[0].host_ip | Should -Be '127.0.0.1'
        [string]$service.ports[0].published | Should -Be '4002'
        [string]$service.ports[0].target | Should -Be '4004'
        $service.read_only | Should -BeTrue
        $service.cap_drop | Should -Be @('ALL')
        $service.security_opt | Should -Be @('no-new-privileges:true')
        ConvertTo-GwDurationSecond -Text ([string]$service.stop_grace_period) | Should -Be 90
        $service.restart | Should -Be 'unless-stopped'
        $service.ulimits.nofile.soft | Should -Be 65536
        $service.logging.options.'max-size' | Should -Be '10m'
        $config.name | Should -Be 'brokersre-gateway-paper'
    }
}

Describe 'Get-GwRuntime' {
    It 'detects Docker Desktop through docker.exe' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('linux|Docker Desktop|29.9.3') }
        Mock -ModuleName BrokerSre.Gateway Invoke-GwWsl { throw 'wsl must not be called' }
        $runtime = Get-GwRuntime
        $runtime.Mode | Should -Be 'DockerDesktop'
        $runtime.OsType | Should -Be 'linux'
        $runtime.ServerVersion | Should -Be '29.9.3'
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwDocker -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'info --format {{.OSType}}|{{.OperatingSystem}}|{{.ServerVersion}}'
        }
    }

    It 'reports WindowsCli when docker.exe reaches an engine that is not Docker Desktop' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('linux|Ubuntu 24.04.1 LTS|29.0.0') }
        (Get-GwRuntime).Mode | Should -Be 'WindowsCli'
    }

    It 'falls back to Docker Engine inside the first WSL distribution that answers' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -ExitCode -1 -Output @('docker.exe was not found on this computer.') -NotFound }
        Mock -ModuleName BrokerSre.Gateway Invoke-GwWsl {
            $joined = $ArgumentList -join ' '
            if ($joined -eq '--list --quiet') { return (Get-TestNativeResult -Output @('docker-desktop', 'Debian', 'Ubuntu-24.04')) }
            if ($joined -like '-d Debian *') { return (Get-TestNativeResult -ExitCode 127 -Output @('docker: command not found')) }
            if ($joined -like '-d Ubuntu-24.04 *') { return (Get-TestNativeResult -Output @('linux|Ubuntu 24.04.1 LTS|29.0.0')) }
            throw ('unexpected wsl call: ' + $joined)
        }
        $runtime = Get-GwRuntime
        $runtime.Mode | Should -Be 'WslEngine'
        $runtime.Distro | Should -Be 'Ubuntu-24.04'
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwWsl -Times 0 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -like '-d docker-desktop*' }
    }

    It 'honours an explicit distribution and does not probe docker.exe' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { throw 'docker.exe must not be called' }
        Mock -ModuleName BrokerSre.Gateway Invoke-GwWsl { Get-TestNativeResult -Output @('linux|Debian GNU/Linux 13|29.0.0') }
        $runtime = Get-GwRuntime -Preference 'WslEngine' -Distro 'Debian'
        $runtime.Mode | Should -Be 'WslEngine'
        $runtime.Distro | Should -Be 'Debian'
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwWsl -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq '-d Debian --exec docker info --format {{.OSType}}|{{.OperatingSystem}}|{{.ServerVersion}}'
        }
    }

    It 'returns None with the reason when nothing answers' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -ExitCode 1 -Output @('error during connect: the docker daemon is not running') }
        Mock -ModuleName BrokerSre.Gateway Invoke-GwWsl { Get-TestNativeResult -ExitCode 1 -Output @('no distributions') }
        $runtime = Get-GwRuntime
        $runtime.Mode | Should -Be 'None'
        $runtime.Detail | Should -Match 'docker'
    }

    It 'reports Windows containers through OsType' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('windows|Docker Desktop|29.9.3') }
        (Get-GwRuntime).OsType | Should -Be 'windows'
    }
}

Describe 'Invoke-GwContainerCli and Invoke-GwCompose' {
    It 'calls docker.exe directly for Docker Desktop' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('ok') }
        $result = Invoke-GwContainerCli -Runtime $script:desktop -ArgumentList @('version')
        $result.Output | Should -Be @('ok')
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwDocker -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'version' }
    }

    It 'goes through wsl.exe for Docker Engine in a distribution' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwWsl { Get-TestNativeResult -Output @('ok') }
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { throw 'docker.exe must not be called' }
        Invoke-GwContainerCli -Runtime $script:engine -ArgumentList @('version') | Out-Null
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwWsl -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq '-d Ubuntu-24.04 --exec docker version' }
    }

    It 'runs compose with the full compose file path for Docker Desktop' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult }
        Invoke-GwCompose -Runtime $script:desktop -Path 'C:\BrokerSRE\gateway' -ArgumentList @('up', '-d') | Out-Null
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwDocker -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join '|') -eq 'compose|-f|C:\BrokerSRE\gateway\compose.yaml|up|-d'
        }
    }

    It 'runs compose from the gateway folder inside the distribution for Docker Engine in WSL' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwWsl { Get-TestNativeResult }
        Invoke-GwCompose -Runtime $script:engine -Path 'C:\BrokerSRE\gateway' -ArgumentList @('up', '-d') | Out-Null
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwWsl -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join '|') -eq '-d|Ubuntu-24.04|--cd|C:\BrokerSRE\gateway|--exec|docker|compose|-f|compose.yaml|up|-d'
        }
    }

    It 'refuses to run without a detected runtime' {
        $none = [pscustomobject]@{ Mode = 'None'; Distro = ''; EngineName = ''; OsType = ''; ServerVersion = ''; Detail = 'nothing' }
        { Invoke-GwContainerCli -Runtime $none -ArgumentList @('version') } | Should -Throw
    }
}

Describe 'Get-GwGatewayPhase' {
    It 'reads the phase token with docker exec' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('2fa-pending') }
        Get-GwGatewayPhase -Runtime $script:desktop -ContainerName 'ctr' | Should -Be '2fa-pending'
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwDocker -Times 1 -Exactly -ParameterFilter {
            ($ArgumentList -join ' ') -eq 'exec ctr cat /var/log/ibgateway/state/phase'
        }
    }

    It 'returns null when the file cannot be read' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -ExitCode 1 -Output @('Error response from daemon: No such container: ctr') }
        Get-GwGatewayPhase -Runtime $script:desktop -ContainerName 'ctr' | Should -BeNullOrEmpty
    }

    It 'returns unknown, never the raw text, for content that is not a phase token' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('Some Raw Line with user=someone') }
        Get-GwGatewayPhase -Runtime $script:desktop -ContainerName 'ctr' | Should -Be 'unknown'
    }
}

Describe 'Get-GwPhaseMessage' {
    It 'maps <phase> to kind <kind>' -ForEach @(
        @{ phase = 'starting'; kind = 'Progress'; text = 'Starting' }
        @{ phase = 'login'; kind = 'Progress'; text = 'Logging in\.\.\.' }
        @{ phase = '2fa-pending'; kind = 'Progress'; text = 'Approve the IBKR Mobile prompt on your phone now' }
        @{ phase = 'logged-in'; kind = 'Success'; text = 'Logged in\. API ready on 127\.0\.0\.1:4002' }
        @{ phase = 'restarting'; kind = 'Progress'; text = 'restart' }
        @{ phase = 'existing-session'; kind = 'Progress'; text = 'taking it over' }
        @{ phase = 'needs-human'; kind = 'Stop'; text = 'person' }
        @{ phase = 'stopping'; kind = 'Stop'; text = 'stop' }
        @{ phase = 'stopped'; kind = 'Stop'; text = 'stop' }
        @{ phase = 'exited'; kind = 'Stop'; text = 'exited' }
        @{ phase = 'test-mode'; kind = 'Stop'; text = 'test mode' }
        @{ phase = 'something-new'; kind = 'Progress'; text = 'Unknown state' }
        @{ phase = 'unknown'; kind = 'Progress'; text = 'Unknown state' }
    ) {
        $message = Get-GwPhaseMessage -Phase $phase -ApiPort 4002 -ContainerName 'ctr'
        $message.Kind | Should -Be $kind
        $message.Text | Should -Match $text
    }

    It 'never treats an unknown token as success' {
        (Get-GwPhaseMessage -Phase 'logged-in-maybe' -ApiPort 4002 -ContainerName 'ctr').Kind | Should -Not -Be 'Success'
    }
}

Describe 'Wait-GwGatewayLogin' {
    BeforeEach {
        $script:now = New-Object DateTime(2026, 11, 12, 1, 0, 0, [DateTimeKind]::Utc)
        $script:phases = New-Object System.Collections.Generic.Queue[object]
        $script:lastPhase = $null
        $script:logLines = @()
        $script:containerState = 'running'
        $script:dockerCalls = New-Object System.Collections.Generic.List[string]
    }

    # Mocks are created once per block (creating a mock costs 0.1 to 0.4 s); the state they read
    # is reset before each test above, and Should -Invoke counts per test.
    BeforeAll {
        Mock -ModuleName BrokerSre.Gateway Get-GwUtcNow { $script:now }
        Mock -ModuleName BrokerSre.Gateway Wait-GwDelay { $script:now = $script:now.AddSeconds($Seconds) }
        Mock -ModuleName BrokerSre.Gateway Write-GwConsole { }
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker {
            $script:dockerCalls.Add(($ArgumentList -join ' '))
            switch ($ArgumentList[0]) {
                'exec' {
                    if ($script:phases.Count -gt 0) { $script:lastPhase = $script:phases.Dequeue() }
                    if ($null -eq $script:lastPhase) { return (Get-TestNativeResult -ExitCode 1 -Output @('cat: can''t open')) }
                    return (Get-TestNativeResult -Output @([string]$script:lastPhase))
                }
                'logs' { return (Get-TestNativeResult -Output $script:logLines) }
                'inspect' {
                    if ($null -eq $script:containerState) { return (Get-TestNativeResult -ExitCode 1 -Output @('Error: No such object')) }
                    return (Get-TestNativeResult -Output @($script:containerState))
                }
                default { throw ('unexpected docker call: ' + ($ArgumentList -join ' ')) }
            }
        }
    }

    It 'follows starting, login, 2fa-pending to logged-in and reports success' {
        foreach ($phase in @('starting', 'login', '2fa-pending', '2fa-pending', 'logged-in')) { $script:phases.Enqueue($phase) }
        $result = Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2
        $result.Outcome | Should -Be 'LoggedIn'
        $result.Phase | Should -Be 'logged-in'
        Should -Invoke -ModuleName BrokerSre.Gateway Write-GwConsole -Times 1 -Exactly -ParameterFilter { $Message -match 'Approve the IBKR Mobile prompt on your phone now' }
        Should -Invoke -ModuleName BrokerSre.Gateway Write-GwConsole -Times 1 -Exactly -ParameterFilter { $Message -match 'Logged in\. API ready on 127\.0\.0\.1:4002' }
    }

    It 'does not trust a single logged-in reading: a token left by the previous run is replaced by starting' {
        foreach ($phase in @('logged-in', 'starting', 'login', 'needs-human')) { $script:phases.Enqueue($phase) }
        $result = Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2
        $result.Outcome | Should -Be 'NeedsHuman'
        Should -Invoke -ModuleName BrokerSre.Gateway Write-GwConsole -Times 0 -Exactly -ParameterFilter { $Message -match 'Logged in' }
    }

    It 'reports success once logged-in was read on two consecutive polls' {
        $script:phases.Enqueue('logged-in')
        $result = Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2
        $result.Outcome | Should -Be 'LoggedIn'
        Should -Invoke -ModuleName BrokerSre.Gateway Wait-GwDelay -Times 1 -Exactly
    }

    It 'prints each phase once, not on every poll' {
        foreach ($phase in @('login', 'login', 'login', 'logged-in')) { $script:phases.Enqueue($phase) }
        Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2 | Out-Null
        Should -Invoke -ModuleName BrokerSre.Gateway Write-GwConsole -Times 1 -Exactly -ParameterFilter { $Message -match 'Logging in' }
    }

    It 'stops at once on needs-human and tells the operator what to do' {
        foreach ($phase in @('login', 'needs-human')) { $script:phases.Enqueue($phase) }
        $result = Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2
        $result.Outcome | Should -Be 'NeedsHuman'
        $result.Message | Should -Match 'docker logs ctr'
    }

    It 'keeps following through existing-session: with the template''s "primary" action IBC takes the session over itself' {
        foreach ($phase in @('login', 'existing-session', 'existing-session', 'login', 'logged-in')) { $script:phases.Enqueue($phase) }
        $result = Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2
        $result.Outcome | Should -Be 'LoggedIn'
        Should -Invoke -ModuleName BrokerSre.Gateway Write-GwConsole -Times 1 -Exactly -ParameterFilter { $Message -match 'taking it over' }
    }

    It 'ends with Timeout, not with a terminal state, when the existing session never clears' {
        $script:phases.Enqueue('existing-session')
        (Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 20 -PollSeconds 5).Outcome | Should -Be 'Timeout'
    }

    It 'does not trust a single <stale> reading: a token left by the previous run is replaced by starting' -ForEach @(
        @{ stale = 'stopped' }, @{ stale = 'stopping' }, @{ stale = 'exited' }
    ) {
        foreach ($phase in @($stale, 'starting', 'login', 'needs-human')) { $script:phases.Enqueue($phase) }
        (Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2).Outcome | Should -Be 'NeedsHuman'
    }

    It 'treats the image''s login_rejected_latched event as a rejected login' {
        $script:phases.Enqueue('needs-human')
        $script:logLines = @('{"ts":"2026-11-12T01:00:02.000Z","src":"entrypoint","level":"error","event":"login_rejected_latched","msg":"login_rejected_latched"}')
        (Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2).Outcome | Should -Be 'LoginFailed'
    }
    It 'stops on <phase> with outcome <outcome>' -ForEach @(
        @{ phase = 'stopping'; outcome = 'Stopped' }
        @{ phase = 'stopped'; outcome = 'Stopped' }
        @{ phase = 'exited'; outcome = 'Stopped' }
        @{ phase = 'test-mode'; outcome = 'TestMode' }
    ) {
        $script:phases.Enqueue($phase)
        (Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2).Outcome | Should -Be $outcome
    }

    It 'keeps waiting on an unknown token and then times out: unknown is never healthy' {
        $script:phases.Enqueue('brand-new-token')
        $result = Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 20 -PollSeconds 5
        $result.Outcome | Should -Be 'Timeout'
        $result.Phase | Should -Be 'brand-new-token'
    }

    It 'times out while 2FA is pending and says the gateway keeps prompting' {
        $script:phases.Enqueue('2fa-pending')
        $result = Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 30 -PollSeconds 5
        $result.Outcome | Should -Be 'Timeout'
        $result.Phase | Should -Be '2fa-pending'
        $result.Message | Should -Match 'phone'
        $result.ElapsedSeconds | Should -BeGreaterOrEqual 30
    }

    It 'returns LoginFailed on the first login_failed event and polls no further' {
        foreach ($phase in @('login', 'login', 'login', 'login', 'login', 'login')) { $script:phases.Enqueue($phase) }
        $script:logLines = @(
            '{"ts":"2026-11-12T01:00:01.000Z","src":"ibc","level":"info","event":"login_dialog","msg":"login_dialog"}'
            '{"ts":"2026-11-12T01:00:05.000Z","src":"ibc","level":"error","event":"login_failed","msg":"login_failed"}'
        )
        $result = Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2
        $result.Outcome | Should -Be 'LoginFailed'
        $result.Message | Should -Match 'ResetSecrets'
        @($script:dockerCalls | Where-Object { $_ -like 'exec *' }).Count | Should -Be 1
        Should -Invoke -ModuleName BrokerSre.Gateway Wait-GwDelay -Times 0 -Exactly
    }

    It 'reports a rejected login even when the gateway process has already exited, so the caller can stop the stack' {
        $script:phases.Enqueue('exited')
        $script:logLines = @('{"ts":"2026-11-12T01:00:05.000Z","src":"ibc","level":"error","event":"login_failed","msg":"login_failed"}')
        (Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2).Outcome | Should -Be 'LoginFailed'
    }

    It 'reports a rejected login even when the container is no longer running' {
        $script:containerState = 'exited'
        $script:logLines = @('{"ts":"2026-11-12T01:00:05.000Z","src":"ibc","level":"error","event":"login_failed_dialog","msg":"login_failed_dialog"}')
        (Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2).Outcome | Should -Be 'LoginFailed'
    }

    It 'refuses a since value that is not a timestamp' {
        { Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -Since '10m; rm -rf /' } | Should -Throw
    }

    It 'also treats the login_failed_dialog event as a failed login' {
        $script:phases.Enqueue('login')
        $script:logLines = @('{"ts":"2026-11-12T01:00:05.000Z","src":"ibc","level":"error","event":"login_failed_dialog","msg":"login_failed_dialog"}')
        (Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2).Outcome | Should -Be 'LoginFailed'
    }

    It 'asks docker logs only for events since the follow started' {
        foreach ($phase in @('login', 'logged-in')) { $script:phases.Enqueue($phase) }
        Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2 -Since '2026-11-12T01:00:00Z' | Out-Null
        @($script:dockerCalls | Where-Object { $_ -eq 'logs --since 2026-11-12T01:00:00Z --tail 400 ctr' }).Count | Should -Be 1
    }

    It 'never restarts, starts or recreates anything while following' {
        foreach ($phase in @('login', '2fa-pending', 'needs-human')) { $script:phases.Enqueue($phase) }
        Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2 | Out-Null
        @($script:dockerCalls | Where-Object { $_ -notmatch '^(exec|logs|inspect) ' }).Count | Should -Be 0
    }

    It 'reports ContainerNotRunning when the phase is unreadable and the container has exited' {
        $script:containerState = 'exited'
        $result = Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2
        $result.Outcome | Should -Be 'ContainerNotRunning'
        $result.Message | Should -Match 'docker logs ctr'
    }

    It 'reports ContainerNotRunning when the container does not exist' {
        $script:containerState = $null
        (Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2).Outcome | Should -Be 'ContainerNotRunning'
    }

    It 'waits while the container is running but the phase file is not there yet' {
        $script:phases.Enqueue($null)
        $script:phases.Enqueue($null)
        $script:phases.Enqueue('starting')
        $script:phases.Enqueue('logged-in')
        (Wait-GwGatewayLogin -Runtime $script:desktop -ContainerName 'ctr' -ApiPort 4002 -TimeoutSeconds 600 -PollSeconds 2).Outcome | Should -Be 'LoggedIn'
    }
}

Describe 'Get-GwContainerStartTime' {
    It 'returns the time the container was last started, as the engine wrote it' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('2026-11-12T05:01:02.44782648Z') }
        Get-GwContainerStartTime -Runtime $script:desktop -ContainerName 'ctr' | Should -Be '2026-11-12T05:01:02.44782648Z'
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwDocker -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'inspect --format {{.State.StartedAt}} ctr' }
    }

    It 'returns null for a missing container and for the zero time of a container that never started' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -ExitCode 1 -Output @('Error: No such object: ctr') }
        Get-GwContainerStartTime -Runtime $script:desktop -ContainerName 'ctr' | Should -BeNullOrEmpty
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('0001-01-01T00:00:00Z') }
        Get-GwContainerStartTime -Runtime $script:desktop -ContainerName 'ctr' | Should -BeNullOrEmpty
    }
}

Describe 'Get-GwEngineTime' {
    It 'returns the engine clock as text' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('2026-11-12T00:59:58.123456789Z') }
        Get-GwEngineTime -Runtime $script:desktop | Should -Be '2026-11-12T00:59:58.123456789Z'
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwDocker -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq 'info --format {{.SystemTime}}' }
    }

    It 'returns null when the engine does not answer or prints something else' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -ExitCode 1 -Output @('error') }
        Get-GwEngineTime -Runtime $script:desktop | Should -BeNullOrEmpty
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -Output @('not a time') }
        Get-GwEngineTime -Runtime $script:desktop | Should -BeNullOrEmpty
    }
}

Describe 'Get-GwConnectionSnippet' {
    It 'prints a five-line read-only ib_async example for the port' {
        $snippet = Get-GwConnectionSnippet -ApiPort 4002
        $python = @($snippet.Python -split "`n")
        $python.Count | Should -Be 5
        $snippet.Python | Should -Match 'from ib_async import IB'
        $snippet.Python | Should -Match 'ib\.connect\("127\.0\.0\.1", 4002, clientId=1, readonly=True\)'
    }

    It 'prints a C# example for the port' {
        $snippet = Get-GwConnectionSnippet -ApiPort 4001
        $snippet.CSharp | Should -Match 'eConnect\("127\.0\.0\.1", 4001, 1\)'
        $snippet.CSharp | Should -Match 'reqCurrentTime'
    }

    It 'contains no order placement or cancellation call' {
        $snippet = Get-GwConnectionSnippet -ApiPort 4002
        ($snippet.Python + $snippet.CSharp) | Should -Not -Match '(?i)place.?order|cancel.?order|globalcancel|whatif'
    }
}

Describe 'Start-GwStack, Stop-GwStack and Remove-GwStack' {
    BeforeEach {
        $script:composeCalls = New-Object System.Collections.Generic.List[string]
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker {
            $script:composeCalls.Add(($ArgumentList -join ' '))
            Get-TestNativeResult
        }
    }

    It 'starts with compose up -d' {
        Start-GwStack -Runtime $script:desktop -Path 'C:\gw' -Confirm:$false | Should -BeTrue
        $script:composeCalls | Should -Be @('compose -f C:\gw\compose.yaml up -d')
    }

    It 'adds --force-recreate when asked: compose does not recreate a container when only a secret file changed' {
        Start-GwStack -Runtime $script:desktop -Path 'C:\gw' -ForceRecreate -Confirm:$false | Out-Null
        $script:composeCalls | Should -Be @('compose -f C:\gw\compose.yaml up -d --force-recreate')
    }

    It 'gives a captured compose up a long deadline, because it may have to pull the image' {
        Start-GwStack -Runtime $script:desktop -Path 'C:\gw' -NoRecreate -Confirm:$false | Out-Null
        Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwDocker -Times 1 -Exactly -ParameterFilter { $TimeoutSeconds -ge 900 }
    }

    It 'adds --no-recreate when asked, so a running gateway is never replaced' {
        Start-GwStack -Runtime $script:desktop -Path 'C:\gw' -NoRecreate -Confirm:$false | Out-Null
        $script:composeCalls | Should -Be @('compose -f C:\gw\compose.yaml up -d --no-recreate')
    }

    It 'returns false when compose fails' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -ExitCode 1 -Output @('boom') }
        Start-GwStack -Runtime $script:desktop -Path 'C:\gw' -Confirm:$false | Should -BeFalse
    }

    It 'stops with compose stop' {
        Stop-GwStack -Runtime $script:desktop -Path 'C:\gw' -Confirm:$false | Out-Null
        $script:composeCalls | Should -Be @('compose -f C:\gw\compose.yaml stop')
    }

    It 'removes with compose down, and with volumes only on request' {
        Remove-GwStack -Runtime $script:desktop -Path 'C:\gw' -Confirm:$false | Out-Null
        Remove-GwStack -Runtime $script:desktop -Path 'C:\gw' -RemoveVolumes -Confirm:$false | Out-Null
        $script:composeCalls | Should -Be @('compose -f C:\gw\compose.yaml down', 'compose -f C:\gw\compose.yaml down --volumes')
    }

    It 'does nothing under -WhatIf' {
        Start-GwStack -Runtime $script:desktop -Path 'C:\gw' -WhatIf | Out-Null
        Stop-GwStack -Runtime $script:desktop -Path 'C:\gw' -WhatIf | Out-Null
        Remove-GwStack -Runtime $script:desktop -Path 'C:\gw' -RemoveVolumes -WhatIf | Out-Null
        $script:composeCalls.Count | Should -Be 0
    }
}

Describe 'Wait-GwContainerEngine' {
    BeforeEach {
        $script:now = New-Object DateTime(2026, 11, 12, 1, 0, 0, [DateTimeKind]::Utc)
        Mock -ModuleName BrokerSre.Gateway Get-GwUtcNow { $script:now }
        Mock -ModuleName BrokerSre.Gateway Wait-GwDelay { $script:now = $script:now.AddSeconds($Seconds) }
    }

    It 'returns true as soon as docker info succeeds' {
        $script:attempt = 0
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker {
            $script:attempt++
            if ($script:attempt -lt 3) { return (Get-TestNativeResult -ExitCode 1 -Output @('not yet')) }
            Get-TestNativeResult -Output @('29.9.3')
        }
        Wait-GwContainerEngine -Runtime $script:desktop -TimeoutSeconds 120 -PollSeconds 5 | Should -BeTrue
        $script:attempt | Should -Be 3
    }

    It 'gives up after the timeout and returns false' {
        Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { Get-TestNativeResult -ExitCode 1 -Output @('not yet') }
        Wait-GwContainerEngine -Runtime $script:desktop -TimeoutSeconds 20 -PollSeconds 5 | Should -BeFalse
    }
}
