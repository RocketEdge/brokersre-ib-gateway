# Tests for src/Commands.ps1: the five entry points behind setup.ps1, doctor.ps1, harden.ps1,
# start.ps1 and uninstall.ps1. docker, wsl, schtasks, powercfg, the registry, the firewall and the
# credential prompt are mocked; the file system work (folder, secrets, ACL, compose file, state)
# is real and happens under TestDrive.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-KitModule

    $script:fakeUser = 'CANARY_' + 'username'
    $script:fakePassword = 'CANARY_' + 'pass$word`"quoted'
    $script:desktop = [pscustomobject]@{ Mode = 'DockerDesktop'; Distro = ''; EngineName = 'Docker Desktop'; OsType = 'linux'; ServerVersion = '29.9.3'; Detail = '' }
    $script:engine = [pscustomobject]@{ Mode = 'WslEngine'; Distro = 'Ubuntu-24.04'; EngineName = 'Ubuntu 24.04 LTS'; OsType = 'linux'; ServerVersion = '29.0.0'; Detail = '' }

    function Get-PassResult {
        param([string]$Name)
        return (New-GwCheckResult -Name $Name -Status 'PASS' -Detail 'ok')
    }

    Mock -ModuleName BrokerSre.Gateway Get-GwRuntime { return $script:runtime }
    Mock -ModuleName BrokerSre.Gateway Get-GwPrerequisiteResult { return $script:prerequisites }
    Mock -ModuleName BrokerSre.Gateway Read-GwSecureInput {
        $script:prompts.Add($Prompt)
        if ($Prompt -match 'username') { return (ConvertTo-TestSecureString -Text $script:fakeUser) }
        return (ConvertTo-TestSecureString -Text $script:fakePassword)
    }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker {
        $joined = $ArgumentList -join ' '
        $script:dockerCalls.Add($joined)
        if ($ArgumentList[0] -eq 'run') { return (& $script:probeHandler $ArgumentList) }
        if ($joined -match ' up -d') { return (Get-TestNativeResult -ExitCode $script:upExitCode -Output @('started')) }
        if ($joined -match ' stop$') { return (Get-TestNativeResult -ExitCode $script:stopExitCode) }
        if ($joined -match ' down') { return (Get-TestNativeResult -ExitCode $script:downExitCode) }
        if ($joined -match 'State\.StartedAt') {
            if ($script:startedAt -eq '') { return (Get-TestNativeResult -ExitCode 1 -Output @('Error: No such object')) }
            return (Get-TestNativeResult -Output @($script:startedAt))
        }
        if ($ArgumentList[0] -eq 'info') { return (& $script:infoHandler) }
        return (Get-TestNativeResult)
    }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwWsl {
        $script:wslCalls.Add(($ArgumentList -join ' '))
        return (Get-TestNativeResult)
    }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwSchTasks {
        $script:taskCalls.Add(($ArgumentList -join '|'))
        $taskName = $ArgumentList[2]
        switch ($ArgumentList[0]) {
            '/Query' {
                if ($script:tasks -contains $taskName) { return (Get-TestNativeResult -Output @('<Task/>')) }
                return (Get-TestNativeResult -ExitCode 1 -Output @('ERROR'))
            }
            '/Delete' {
                $script:tasks = @($script:tasks | Where-Object { $_ -ne $taskName })
                return (Get-TestNativeResult)
            }
            default { return (Get-TestNativeResult) }
        }
    }
    Mock -ModuleName BrokerSre.Gateway Wait-GwGatewayLogin {
        $script:waitCalls++
        $script:waitSince = $Since
        return [pscustomobject]@{ Outcome = $script:loginOutcome; Phase = 'login'; ElapsedSeconds = 5; Message = 'message' }
    }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwRegistry { return $null }
    Mock -ModuleName BrokerSre.Gateway Write-GwConsole { $script:console.Add($Message) }
    Mock -ModuleName BrokerSre.Gateway Get-GwUtcNow { return $script:now }
    Mock -ModuleName BrokerSre.Gateway Wait-GwDelay { $script:now = $script:now.AddSeconds($Seconds) }
}

Describe 'Commands' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ('gw-' + [guid]::NewGuid().ToString('N'))
        $script:runtime = $script:desktop
        $script:prerequisites = @((Get-PassResult -Name 'WindowsBuild'), (Get-PassResult -Name 'ContainerRuntime'))
        $script:prompts = New-Object System.Collections.Generic.List[string]
        $script:dockerCalls = New-Object System.Collections.Generic.List[string]
        $script:wslCalls = New-Object System.Collections.Generic.List[string]
        $script:taskCalls = New-Object System.Collections.Generic.List[string]
        $script:tasks = @()
        $script:console = New-Object System.Collections.Generic.List[string]
        $script:probeHandler = { Get-TestNativeResult -Output @('winkit-probe') }
        $script:infoHandler = { Get-TestNativeResult -Output @('29.9.3') }
        $script:upExitCode = 0
        $script:stopExitCode = 0
        $script:downExitCode = 0
        $script:startedAt = ''
        $script:waitSince = ''
        $script:loginOutcome = 'LoggedIn'
        $script:waitCalls = 0
        $script:now = New-Object DateTime(2026, 11, 12, 1, 0, 0, [DateTimeKind]::Utc)
        $script:secureUser = ConvertTo-TestSecureString -Text $script:fakeUser
        $script:securePassword = ConvertTo-TestSecureString -Text $script:fakePassword
    }

    Context 'Invoke-GwSetup -NoStart' {
        It 'creates the folder, both secret files byte-exact, compose.yaml and the state file, and starts nothing' {
            $result = Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 0
            [System.IO.File]::ReadAllBytes((Join-Path $script:folder 'secrets\ib-username')) | Should -Be ([System.Text.Encoding]::UTF8.GetBytes($script:fakeUser))
            [System.IO.File]::ReadAllBytes((Join-Path $script:folder 'secrets\ib-password')) | Should -Be ([System.Text.Encoding]::UTF8.GetBytes($script:fakePassword))
            $compose = [System.IO.File]::ReadAllText((Join-Path $script:folder 'compose.yaml'))
            $compose | Should -Match '- "127\.0\.0\.1:4002:4004"'
            $compose | Should -Match 'image: ghcr\.io/rocketedge/brokersre-ib-gateway:stable'
            $state = Get-GwKitState -Path $script:folder
            $state.Runtime | Should -Be 'DockerDesktop'
            $state.TradingMode | Should -Be 'paper'
            $state.ApiPort | Should -Be 4002
            $state.ContainerName | Should -Be 'brokersre-ib-gateway-paper'
            @($script:dockerCalls | Where-Object { $_ -match ' up ' }).Count | Should -Be 0
            $script:waitCalls | Should -Be 0
        }

        It 'does not prompt when both values are supplied through the SecureString parameters' {
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $script:prompts.Count | Should -Be 0
        }

        It 'prompts for username and password with the secure prompt when nothing is supplied' {
            Invoke-GwSetup -Path $script:folder -NoStart -Confirm:$false | Out-Null
            $script:prompts.Count | Should -Be 2
            $script:prompts[0] | Should -Match 'username'
            $script:prompts[1] | Should -Match 'password'
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'secrets\ib-password')) | Should -Be $script:fakePassword
        }

        It 'restricts the secrets folder to the current account' {
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            @(Get-GwAclOtherIdentity -Path (Join-Path $script:folder 'secrets')).Count | Should -Be 0
        }

        It 'checks with a dummy file that the container can still read the protected folder, and removes the dummy' {
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $probe = @($script:dockerCalls | Where-Object { $_ -like 'run *' })
            $probe.Count | Should -Be 1
            $probe[0] | Should -Match '^run --rm --name winkit-acl-[0-9a-f]{8} --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true --user 1000:1000 -v '
            $probe[0] | Should -Match 'winkit-probe:/run/secrets/winkit-probe:ro busybox:1\.37\.0@sha256:[0-9a-f]{64} cat /run/secrets/winkit-probe$'
            @(Get-ChildItem -LiteralPath (Join-Path $script:folder 'secrets') -Force).Name | Sort-Object | Should -Be @('ib-password', 'ib-username')
        }

        It 'falls back to an access list that includes SYSTEM and Administrators when the container cannot read, and says so' {
            $script:probeAttempt = 0
            $script:probeHandler = {
                $script:probeAttempt++
                if ($script:probeAttempt -eq 1) { return (Get-TestNativeResult -ExitCode 1 -Output @('cat: can''t open ''/run/secrets/winkit-probe'': Permission denied')) }
                Get-TestNativeResult -Output @('winkit-probe')
            }
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $others = @(Get-GwAclOtherIdentity -Path (Join-Path $script:folder 'secrets'))
            $others.Count | Should -Be 2
            ($script:console -join "`n") | Should -Match 'SYSTEM and Administrators'
        }

        It 'never shows the username or password on any stream and writes them to no other file' {
            $everything = Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false -Verbose -Debug *>&1
            (($everything | Out-String) -match 'CANARY') | Should -BeFalse
            (($script:console -join "`n") -match 'CANARY') | Should -BeFalse
            (($script:dockerCalls -join "`n") -match 'CANARY') | Should -BeFalse
            foreach ($file in @(Get-ChildItem -LiteralPath $script:folder -Recurse -File -Force)) {
                if ($file.FullName -like '*\secrets\ib-*') { continue }
                ([System.IO.File]::ReadAllText($file.FullName) -match 'CANARY') | Should -BeFalse -Because $file.Name
            }
        }

        It 'restricts the secrets folder before the first secret is written into it' {
            $script:othersAtWrite = -1
            Mock -ModuleName BrokerSre.Gateway Write-GwSecretFile { $script:othersAtWrite = @(Get-GwAclOtherIdentity -Path (Split-Path -Parent $Path)).Count }
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $script:othersAtWrite | Should -Be 0
        }

        It 'removes a temporary secret file left behind by an interrupted run' {
            New-Item -ItemType Directory -Path (Join-Path $script:folder 'secrets') -Force | Out-Null
            $stale = Join-Path $script:folder 'secrets\.ib-password.0123456789abcdef0123456789abcdef.tmp'
            [System.IO.File]::WriteAllText($stale, 'stale-fake-value')
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            Test-Path -LiteralPath $stale | Should -BeFalse
        }

        It 'renders live mode with -Live' {
            Invoke-GwSetup -Path $script:folder -Live -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'compose.yaml')) | Should -Match '- "127\.0\.0\.1:4001:4003"'
            (Get-GwKitState -Path $script:folder).TradingMode | Should -Be 'live'
        }

        It 'recommends pinning a digest when the image is a tag, and not when it is pinned' {
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            ($script:console -join "`n") | Should -Match 'sha256'
            $script:console.Clear()
            $other = Join-Path $TestDrive ('gw-' + [guid]::NewGuid().ToString('N'))
            $pinned = 'ghcr.io/rocketedge/brokersre-ib-gateway@sha256:' + ('cd' * 32)
            Invoke-GwSetup -Path $other -ImageRef $pinned -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            ($script:console -join "`n") | Should -Not -Match 'Recommendation'
        }
    }

    Context 'Invoke-GwSetup is idempotent' {
        BeforeEach {
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $script:prompts.Clear()
            $script:firstWrite = (Get-Item -LiteralPath (Join-Path $script:folder 'secrets\ib-password')).LastWriteTimeUtc
        }

        It 'keeps existing secrets on a second run and does not prompt' {
            $result = Invoke-GwSetup -Path $script:folder -NoStart -Confirm:$false
            $result.ExitCode | Should -Be 0
            $script:prompts.Count | Should -Be 0
            (Get-Item -LiteralPath (Join-Path $script:folder 'secrets\ib-password')).LastWriteTimeUtc | Should -Be $script:firstWrite
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'secrets\ib-password')) | Should -Be $script:fakePassword
        }

        It 'validates both values before writing either: a refused password leaves the stored username as it was' {
            $newUser = ConvertTo-TestSecureString -Text ('CANARY_' + 'other_user')
            $empty = ConvertTo-TestSecureString -Text ''
            $result = Invoke-GwSetup -Path $script:folder -NoStart -ResetSecrets -UserNameSecure $newUser -PasswordSecure $empty -Confirm:$false
            $result.ExitCode | Should -Be 1
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'secrets\ib-username')) | Should -Be $script:fakeUser
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'secrets\ib-password')) | Should -Be $script:fakePassword
        }

        It 'treats a compose file that differs only in letter case as different' {
            $other = Join-Path $TestDrive ('gw-' + [guid]::NewGuid().ToString('N'))
            Invoke-GwSetup -Path $other -TimeZone 'america/new_york' -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            (Invoke-GwSetup -Path $other -TimeZone 'America/New_York' -NoStart -Confirm:$false).ExitCode | Should -Be 1
            (Invoke-GwSetup -Path $other -TimeZone 'America/New_York' -NoStart -Force -Confirm:$false).ExitCode | Should -Be 0
            [System.IO.File]::ReadAllText((Join-Path $other 'compose.yaml')) | Should -MatchExactly 'TIME_ZONE: America/New_York'
        }

        It 'asks again and rewrites with -ResetSecrets' {
            Invoke-GwSetup -Path $script:folder -NoStart -ResetSecrets -Confirm:$false | Out-Null
            $script:prompts.Count | Should -Be 2
        }

        It 'leaves an identical compose file untouched' {
            $composePath = Join-Path $script:folder 'compose.yaml'
            $before = (Get-Item -LiteralPath $composePath).LastWriteTimeUtc
            Invoke-GwSetup -Path $script:folder -NoStart -Confirm:$false | Out-Null
            (Get-Item -LiteralPath $composePath).LastWriteTimeUtc | Should -Be $before
            @(Get-ChildItem -LiteralPath $script:folder -Filter 'compose.yaml.bak-*').Count | Should -Be 0
        }

        It 'refuses to replace a differing compose file without -Force, so a mode is never switched by accident' {
            $composePath = Join-Path $script:folder 'compose.yaml'
            $before = [System.IO.File]::ReadAllText($composePath)
            $result = Invoke-GwSetup -Path $script:folder -Live -NoStart -Confirm:$false
            $result.ExitCode | Should -Be 1
            [System.IO.File]::ReadAllText($composePath) | Should -Be $before
            ($script:console -join "`n") | Should -Match '-Force'
        }

        It 'replaces a differing compose file with -Force and keeps a backup' {
            $composePath = Join-Path $script:folder 'compose.yaml'
            $before = [System.IO.File]::ReadAllText($composePath)
            $result = Invoke-GwSetup -Path $script:folder -Live -NoStart -Force -Confirm:$false
            $result.ExitCode | Should -Be 0
            [System.IO.File]::ReadAllText($composePath) | Should -Match 'TRADING_MODE: live'
            $backups = @(Get-ChildItem -LiteralPath $script:folder -Filter 'compose.yaml.bak-*')
            $backups.Count | Should -Be 1
            [System.IO.File]::ReadAllText($backups[0].FullName) | Should -Be $before
        }
    }

    Context 'Invoke-GwSetup -WhatIf' {
        It 'creates nothing when the folder does not exist' {
            $parent = Join-Path $TestDrive ('whatif-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $parent | Out-Null
            $target = Join-Path $parent 'gateway'
            $before = Get-TestTreeSnapshot -Path $parent
            $result = Invoke-GwSetup -Path $target -WhatIf
            $result.ExitCode | Should -Be 0
            Get-TestTreeSnapshot -Path $parent | Should -Be $before
            Test-Path -LiteralPath $target | Should -BeFalse
            ($script:console -join "`n") | Should -Match 'Preview only'
        }

        It 'changes nothing in an existing gateway folder, even with -ResetSecrets and -Force' {
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $before = Get-TestTreeSnapshot -Path $script:folder
            $script:dockerCalls.Clear()
            $script:prompts.Clear()
            Invoke-GwSetup -Path $script:folder -Live -ResetSecrets -Force -WhatIf | Out-Null
            Get-TestTreeSnapshot -Path $script:folder | Should -Be $before
            $script:prompts.Count | Should -Be 0
            @($script:dockerCalls | Where-Object { $_ -match '^run | up | stop| down' }).Count | Should -Be 0
            $script:waitCalls | Should -Be 0
        }
    }

    Context 'Invoke-GwSetup prerequisites' {
        It 'stops before creating anything when a prerequisite fails, and shows the fix' {
            $script:prerequisites = @(
                (Get-PassResult -Name 'WindowsBuild')
                (New-GwCheckResult -Name 'ContainerRuntime' -Status 'FAIL' -Detail 'No container runtime answered.' -Fix 'Start Docker Desktop.')
            )
            $result = Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 1
            Test-Path -LiteralPath $script:folder | Should -BeFalse
            ($script:console -join "`n") | Should -Match 'FAIL'
            ($script:console -join "`n") | Should -Match 'Start Docker Desktop\.'
            $script:prompts.Count | Should -Be 0
        }

        It 'continues past warnings' {
            $script:prerequisites = @((New-GwCheckResult -Name 'Port9810' -Status 'WARN' -Detail 'Another program is listening on port 9810.' -Fix 'x'))
            (Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false).ExitCode | Should -Be 0
        }

        It 'explains and returns 1, without starting anything, when Windows denies access to the folder' {
            Mock -ModuleName BrokerSre.Gateway Protect-GwSecretFolder { throw (New-Object System.UnauthorizedAccessException('Attempted to perform an unauthorized operation.')) }
            $result = Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 1
            ($script:console -join "`n") | Should -Match 'Windows denied access'
            @($script:dockerCalls | Where-Object { $_ -match ' up ' }).Count | Should -Be 0
        }

        It 'rejects an image reference that is not one, before creating anything' {
            $result = Invoke-GwSetup -Path $script:folder -ImageRef 'not an image' -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 1
            Test-Path -LiteralPath $script:folder | Should -BeFalse
        }
    }

    Context 'Invoke-GwSetup start and follow' {
        It 'starts the stack once, follows the login and prints both connection snippets on success' {
            $result = Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 0
            $result.Outcome | Should -Be 'LoggedIn'
            @($script:dockerCalls | Where-Object { $_ -match ' up -d( --force-recreate)?$' }).Count | Should -Be 1
            $script:waitCalls | Should -Be 1
            ($script:console -join "`n") | Should -Match 'from ib_async import IB'
            ($script:console -join "`n") | Should -Match 'eConnect\("127\.0\.0\.1", 4002, 1\)'
        }

        It 'stops the stack exactly once after a rejected login and never starts it again' {
            $script:loginOutcome = 'LoginFailed'
            $result = Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 2
            $result.Outcome | Should -Be 'LoginFailed'
            @($script:dockerCalls | Where-Object { $_ -match ' up -d( --force-recreate)?$' }).Count | Should -Be 1
            @($script:dockerCalls | Where-Object { $_ -match ' stop$' }).Count | Should -Be 1
            @($script:dockerCalls | Where-Object { $_ -match ' restart' }).Count | Should -Be 0
            $script:waitCalls | Should -Be 1
            $script:dockerCalls[$script:dockerCalls.Count - 1] | Should -Match ' stop$'
        }

        It 'records a rejected login, and neither start.ps1 nor a plain re-run sends the same credentials again' {
            $script:loginOutcome = 'LoginFailed'
            Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            (Get-GwKitState -Path $script:folder).LoginRejectedUtc | Should -Not -BeNullOrEmpty
            $script:dockerCalls.Clear()

            (Invoke-GwStart -Path $script:folder).ExitCode | Should -Be 1
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'kit.log')) | Should -Match 'rejected'

            $script:loginOutcome = 'LoggedIn'
            $again = Invoke-GwSetup -Path $script:folder -Confirm:$false
            $again.ExitCode | Should -Be 1
            ($script:console -join "`n") | Should -Match '-ResetSecrets'
            @($script:dockerCalls | Where-Object { $_ -match ' up ' }).Count | Should -Be 0
        }

        It 'starts again after the credentials were entered again, and clears the record' {
            $script:loginOutcome = 'LoginFailed'
            Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $script:loginOutcome = 'LoggedIn'
            $result = Invoke-GwSetup -Path $script:folder -ResetSecrets -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 0
            [string](Get-GwPropertyValue -InputObject (Get-GwKitState -Path $script:folder) -Name 'LoginRejectedUtc' -Default '') | Should -Be ''
        }

        It 'says so, with the command to run, when the stack could not be stopped after a rejected login' {
            $script:loginOutcome = 'LoginFailed'
            $script:stopExitCode = 1
            Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            ($script:console -join "`n") | Should -Match 'could not be stopped'
            ($script:console -join "`n") | Should -Match 'docker compose -f .* stop'
            ($script:console -join "`n") | Should -Not -Match 'The gateway was stopped so'
        }

        It 'starts the login-failure window at the container''s own start time, so a rejection before this run is seen' {
            $script:startedAt = '2026-11-11T22:15:00.123456789Z'
            Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $script:waitSince | Should -Be '2026-11-11T22:15:00.123456789Z'
        }

        It 'falls back to the engine clock, then to the Windows clock, when the start time is not available' {
            $script:infoHandler = { Get-TestNativeResult -Output @('2026-11-12T00:00:00.500000000Z') }
            Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $script:waitSince | Should -Be '2026-11-12T00:00:00.500000000Z'
            $other = Join-Path $TestDrive ('gw-' + [guid]::NewGuid().ToString('N'))
            $script:infoHandler = { Get-TestNativeResult -Output @('29.9.3') }
            Invoke-GwSetup -Path $other -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $script:waitSince | Should -Be '2026-11-12T01:00:00Z'
        }

        It 'recreates the container after new credentials were written: compose would otherwise keep the old ones' {
            Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            @($script:dockerCalls | Where-Object { $_ -match ' up -d --force-recreate$' }).Count | Should -Be 1
            $script:dockerCalls.Clear()
            Invoke-GwSetup -Path $script:folder -Confirm:$false | Out-Null
            @($script:dockerCalls | Where-Object { $_ -match ' up -d$' }).Count | Should -Be 1
            @($script:dockerCalls | Where-Object { $_ -match 'force-recreate' }).Count | Should -Be 0
        }

        It 'records and stops when the gateway reports needs-human: a person must act before anything is sent again' {
            $script:loginOutcome = 'NeedsHuman'
            $result = Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 2
            (Get-GwLoginRejection -Path $script:folder) | Should -Be '2026-11-12T01:00:00Z'
            @($script:dockerCalls | Where-Object { $_ -match ' stop$' }).Count | Should -Be 1
        }

        It 'still stops the stack when recording the rejection fails' {
            $script:loginOutcome = 'LoginFailed'
            Mock -ModuleName BrokerSre.Gateway Save-GwLoginRejection { throw (New-Object System.IO.IOException('disk full')) }
            { Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false } | Should -Throw
            @($script:dockerCalls | Where-Object { $_ -match ' stop$' }).Count | Should -Be 1
        }

        It 'keeps the recorded time as the same text under both PowerShell editions' {
            $script:loginOutcome = 'LoginFailed'
            Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            Invoke-GwSetup -Path $script:folder -NoStart -Confirm:$false | Out-Null
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'kit-state.json')) | Should -Match '"LoginRejectedUtc":\s*"2026-11-12T01:00:00Z"'
            Invoke-GwStart -Path $script:folder | Out-Null
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'kit.log')) | Should -Match 'rejected the stored credentials at 2026-11-12T01:00:00Z'
            $script:console.Clear()
            Invoke-GwSetup -Path $script:folder -Confirm:$false | Out-Null
            ($script:console -join "`n") | Should -Match 'at 2026-11-12T01:00:00Z'
        }

        It 'leaves the gateway running and returns 2 when the wait times out' {
            $script:loginOutcome = 'Timeout'
            $result = Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 2
            @($script:dockerCalls | Where-Object { $_ -match ' stop$| down' }).Count | Should -Be 0
        }

        It 'returns 1 and does not follow when compose up fails' {
            $script:upExitCode = 1
            $result = Invoke-GwSetup -Path $script:folder -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false
            $result.ExitCode | Should -Be 1
            $script:waitCalls | Should -Be 0
        }
    }

    Context 'Invoke-GwDoctor' {
        BeforeAll {
            Mock -ModuleName BrokerSre.Gateway Get-GwDoctorResult { return $script:doctorResults }
        }

        It 'returns exit code 0 when nothing failed, even with warnings and skips' {
            $script:doctorResults = @(
                (New-GwCheckResult -Name 'A' -Status 'PASS' -Detail 'a')
                (New-GwCheckResult -Name 'B' -Status 'WARN' -Detail 'b' -Fix 'fix b')
                (New-GwCheckResult -Name 'C' -Status 'SKIP' -Detail 'c')
            )
            $report = Invoke-GwDoctor -Path $script:folder
            $report.ExitCode | Should -Be 0
            $report.Summary.Pass | Should -Be 1
            $report.Summary.Warn | Should -Be 1
            $report.Summary.Skip | Should -Be 1
            $report.Summary.Fail | Should -Be 0
        }

        It 'returns exit code 1 when at least one check failed' {
            $script:doctorResults = @((New-GwCheckResult -Name 'A' -Status 'PASS' -Detail 'a'), (New-GwCheckResult -Name 'D' -Status 'FAIL' -Detail 'd' -Fix 'fix d'))
            (Invoke-GwDoctor -Path $script:folder).ExitCode | Should -Be 1
        }

        It 'prints a table with status, name, detail and fix' {
            $script:doctorResults = @((New-GwCheckResult -Name 'SleepOnAc' -Status 'FAIL' -Detail 'sleeps after 30 minutes' -Fix 'harden.ps1 -DisableSleep'))
            Invoke-GwDoctor -Path $script:folder | Out-Null
            $text = $script:console -join "`n"
            $text | Should -Match 'FAIL\s+SleepOnAc\s+sleeps after 30 minutes'
            $text | Should -Match 'Fix: harden\.ps1 -DisableSleep'
            $text | Should -Match '1 FAIL'
        }

        It 'produces JSON with a stable shape and prints no table with -Json' {
            $script:doctorResults = @(
                (New-GwCheckResult -Name 'A' -Status 'PASS' -Detail 'a')
                (New-GwCheckResult -Name 'D' -Status 'FAIL' -Detail 'd "quoted"' -Fix 'fix d')
            )
            $report = Invoke-GwDoctor -Path $script:folder -Json
            $script:console.Count | Should -Be 0
            $parsed = $report.Json | ConvertFrom-Json
            $parsed.schema | Should -Be 1
            $parsed.mode | Should -Be 'DockerDesktop'
            $parsed.exitCode | Should -Be 1
            $parsed.summary.fail | Should -Be 1
            $parsed.summary.pass | Should -Be 1
            @($parsed.results).Count | Should -Be 2
            ($parsed.results[1].PSObject.Properties.Name -join ',') | Should -Be 'name,status,detail,fix'
            $parsed.results[1].detail | Should -Be 'd "quoted"'
            $report.Json | Should -Match '"generatedUtc":\s*"2026-11-12T01:00:00Z"'
        }

        It 'keeps a single result as a JSON array' {
            $script:doctorResults = @((New-GwCheckResult -Name 'A' -Status 'PASS' -Detail 'a'))
            $report = Invoke-GwDoctor -Path $script:folder -Json
            $report.Json | Should -Match '"results":\s*\['
        }
    }

    Context 'Invoke-GwHarden' {
        BeforeAll {
            Mock -ModuleName BrokerSre.Gateway Disable-GwSleep { $script:hardenCalls.Add('DisableSleep') }
            Mock -ModuleName BrokerSre.Gateway Set-GwUpdateActiveWindow { $script:hardenCalls.Add(('ActiveHours {0}-{1}' -f $Start, $End)) }
            Mock -ModuleName BrokerSre.Gateway Register-GwStartTask { $script:hardenCalls.Add(('StartTask {0} afterSignIn={1} logon={2}' -f $Mode, [bool]$AfterSignIn, $LogonType)) }
            Mock -ModuleName BrokerSre.Gateway Register-GwResumeClockTask { $script:hardenCalls.Add(('ClockTask {0}' -f $LogonType)) }
            Mock -ModuleName BrokerSre.Gateway Set-GwWslConfigValue { $script:hardenCalls.Add(('Wsl [{0}] {1}={2}' -f $Section, $Key, $Value)) }
            Mock -ModuleName BrokerSre.Gateway Add-GwFirewallBlockRule { $script:hardenCalls.Add('Firewall') }
            Mock -ModuleName BrokerSre.Gateway Undo-GwHardening { $script:hardenCalls.Add('Undo') }
        }

        BeforeEach {
            $script:hardenCalls = New-Object System.Collections.Generic.List[string]
            $script:wslConfig = Join-Path $TestDrive ('wslconfig-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:folder | Out-Null
            Save-GwKitState -Path $script:folder -State ([pscustomobject]@{
                    Runtime = 'DockerDesktop'; Distro = ''; TradingMode = 'paper'; ContainerName = 'c'; ProjectName = 'p'; ApiPort = 4002; ImageRef = 'i'
                })
        }

        It 'does nothing and returns 1 when no option is given' {
            (Invoke-GwHarden -Path $script:folder -Confirm:$false).ExitCode | Should -Be 1
            $script:hardenCalls.Count | Should -Be 0
        }

        It 'changes nothing and points to setup when the gateway folder does not exist: the journal lives there' {
            $missing = Join-Path $TestDrive ('missing-' + [guid]::NewGuid().ToString('N'))
            $result = Invoke-GwHarden -Path $missing -DisableSleep -FirewallLoopbackOnly -Confirm:$false
            $result.ExitCode | Should -Be 1
            $script:hardenCalls.Count | Should -Be 0
            ($script:console -join "`n") | Should -Match 'setup\.ps1'
            Test-Path -LiteralPath $missing | Should -BeFalse
        }

        It 'applies only the options that were asked for' {
            (Invoke-GwHarden -Path $script:folder -DisableSleep -Confirm:$false).ExitCode | Should -Be 0
            $script:hardenCalls | Should -Be @('DisableSleep')
        }

        It 'passes the active hours on' {
            Invoke-GwHarden -Path $script:folder -SetActiveHours 6, 23 -Confirm:$false | Out-Null
            $script:hardenCalls | Should -Be @('ActiveHours 6-23')
        }

        It 'registers the sign-in task for Docker Desktop and explains auto-logon without configuring it' {
            Invoke-GwHarden -Path $script:folder -StartAtBoot DockerDesktop -Confirm:$false | Out-Null
            $script:hardenCalls | Should -Be @('StartTask DockerDesktop afterSignIn=False logon=Password')
            ($script:console -join "`n") | Should -Match 'Autologon'
            Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwRegistry -Times 0 -Exactly
        }

        It 'registers the boot task for Docker Engine in WSL with the chosen logon type' {
            Invoke-GwHarden -Path $script:folder -StartAtBoot WslEngine -TaskLogonType S4U -Confirm:$false | Out-Null
            $script:hardenCalls | Should -Be @('StartTask WslEngine afterSignIn=False logon=S4U')
        }

        It 'registers the clock task interactively by default and with the given logon type otherwise' {
            Invoke-GwHarden -Path $script:folder -ResumeClockFix -Confirm:$false | Out-Null
            Invoke-GwHarden -Path $script:folder -ResumeClockFix -TaskLogonType S4U -Confirm:$false | Out-Null
            $script:hardenCalls | Should -Be @('ClockTask Interactive', 'ClockTask S4U')
        }

        It 'sets networkingMode=nat only when .wslconfig asks for another mode' {
            [System.IO.File]::WriteAllText($script:wslConfig, "[wsl2]`nnetworkingMode=mirrored`n")
            Invoke-GwHarden -Path $script:folder -WslConfig -WslConfigPath $script:wslConfig -Confirm:$false | Out-Null
            $script:hardenCalls | Should -Be @('Wsl [wsl2] networkingMode=nat')
        }

        It 'leaves .wslconfig alone when there is nothing to change' {
            Invoke-GwHarden -Path $script:folder -WslConfig -WslConfigPath $script:wslConfig -Confirm:$false | Out-Null
            $script:hardenCalls.Count | Should -Be 0
        }

        It 'disables the distribution idle shutdown for Docker Engine in WSL and sets memory on request' {
            Save-GwKitState -Path $script:folder -State ([pscustomobject]@{
                    Runtime = 'WslEngine'; Distro = 'Ubuntu-24.04'; TradingMode = 'paper'; ContainerName = 'c'; ProjectName = 'p'; ApiPort = 4002; ImageRef = 'i'
                })
            Invoke-GwHarden -Path $script:folder -WslConfig -WslMemoryGB 4 -WslConfigPath $script:wslConfig -Confirm:$false | Out-Null
            $script:hardenCalls | Should -Be @('Wsl [general] instanceIdleTimeout=-1', 'Wsl [wsl2] memory=4GB')
        }

        It 'runs undo alone' {
            Invoke-GwHarden -Path $script:folder -Undo -Confirm:$false | Out-Null
            $script:hardenCalls | Should -Be @('Undo')
        }

        It 'says where changes are recorded after applying, but not in a -WhatIf preview, which records nothing' {
            Invoke-GwHarden -Path $script:folder -DisableSleep -Confirm:$false | Out-Null
            ($script:console -join "`n") | Should -Match 'harden-journal\.json'
            $script:console.Clear()
            Invoke-GwHarden -Path $script:folder -DisableSleep -WhatIf | Out-Null
            ($script:console -join "`n") | Should -Not -Match 'harden-journal\.json'
            ($script:console -join "`n") | Should -Match 'Preview only'
        }

        It 'reports a failed option, continues with the others and returns 1' {
            Mock -ModuleName BrokerSre.Gateway Disable-GwSleep { throw 'powercfg could not change it' }
            $result = Invoke-GwHarden -Path $script:folder -DisableSleep -FirewallLoopbackOnly -Confirm:$false
            $result.ExitCode | Should -Be 1
            $script:hardenCalls | Should -Be @('Firewall')
            ($script:console -join "`n") | Should -Match 'powercfg could not change it'
        }
    }

    Context 'Invoke-GwStart' {
        BeforeEach {
            New-Item -ItemType Directory -Path $script:folder | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $script:folder 'compose.yaml'), "services: {}`n")
            Save-GwKitState -Path $script:folder -State ([pscustomobject]@{
                    Runtime = 'DockerDesktop'; Distro = ''; TradingMode = 'paper'; ContainerName = 'c'; ProjectName = 'p'; ApiPort = 4002; ImageRef = 'i'
                })
        }

        It 'waits for the engine, then runs compose up -d --no-recreate and logs the result' {
            $script:infoAttempt = 0
            $script:infoHandler = {
                $script:infoAttempt++
                if ($script:infoAttempt -lt 3) { return (Get-TestNativeResult -ExitCode 1 -Output @('not yet')) }
                Get-TestNativeResult -Output @('29.9.3')
            }
            $result = Invoke-GwStart -Path $script:folder
            $result.ExitCode | Should -Be 0
            $script:dockerCalls | Should -Contain ('compose -f {0} up -d --no-recreate' -f (Join-Path $script:folder 'compose.yaml'))
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'kit.log')) | Should -Match 'stack started'
        }

        It 'follows the login from the container''s start time, so a rejection that nobody watched is found' {
            $script:startedAt = '2026-11-11T22:15:00Z'
            Invoke-GwStart -Path $script:folder | Out-Null
            $script:waitCalls | Should -Be 1
            $script:waitSince | Should -Be '2026-11-11T22:15:00Z'
        }

        It 'records a rejected login found after an unattended start, stops the stack and returns 1' {
            $script:startedAt = '2026-11-11T22:15:00Z'
            $script:loginOutcome = 'LoginFailed'
            $result = Invoke-GwStart -Path $script:folder
            $result.ExitCode | Should -Be 1
            (Get-GwLoginRejection -Path $script:folder) | Should -Be '2026-11-12T01:00:00Z'
            $script:dockerCalls[$script:dockerCalls.Count - 1] | Should -Match ' stop$'
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'kit.log')) | Should -Match 'setup\.ps1 -ResetSecrets'
            $script:dockerCalls.Clear()
            (Invoke-GwStart -Path $script:folder).ExitCode | Should -Be 1
            @($script:dockerCalls | Where-Object { $_ -match ' up ' }).Count | Should -Be 0
        }

        It 'does the same for needs-human, and leaves the gateway alone while 2FA is merely pending' {
            $script:loginOutcome = 'NeedsHuman'
            (Invoke-GwStart -Path $script:folder).ExitCode | Should -Be 1
            @($script:dockerCalls | Where-Object { $_ -match ' stop$' }).Count | Should -Be 1
            $other = Join-Path $TestDrive ('gw-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $other | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $other 'compose.yaml'), "services: {}`n")
            Save-GwKitState -Path $other -State ([pscustomobject]@{
                    Runtime = 'DockerDesktop'; Distro = ''; TradingMode = 'paper'; ContainerName = 'c'; ProjectName = 'p'; ApiPort = 4002; ImageRef = 'i'
                })
            $script:dockerCalls.Clear()
            $script:loginOutcome = 'Timeout'
            (Invoke-GwStart -Path $other).ExitCode | Should -Be 0
            @($script:dockerCalls | Where-Object { $_ -match ' stop$' }).Count | Should -Be 0
        }

        It 'does not follow when asked not to' {
            Invoke-GwStart -Path $script:folder -FollowSeconds 0 | Out-Null
            $script:waitCalls | Should -Be 0
        }

        It 'gives up after the deadline without starting anything and returns 1' {
            $script:infoHandler = { Get-TestNativeResult -ExitCode 1 -Output @('not yet') }
            $result = Invoke-GwStart -Path $script:folder -WaitSeconds 30
            $result.ExitCode | Should -Be 1
            @($script:dockerCalls | Where-Object { $_ -match ' up ' }).Count | Should -Be 0
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'kit.log')) | Should -Match 'did not answer'
        }

        It 'returns 1 when setup has not run in the folder' {
            $empty = Join-Path $TestDrive ('empty-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $empty | Out-Null
            (Invoke-GwStart -Path $empty).ExitCode | Should -Be 1
        }

        It 'keeps one WSL session open after starting the stack with -KeepAlive' {
            Save-GwKitState -Path $script:folder -State ([pscustomobject]@{
                    Runtime = 'WslEngine'; Distro = 'Ubuntu-24.04'; TradingMode = 'paper'; ContainerName = 'c'; ProjectName = 'p'; ApiPort = 4002; ImageRef = 'i'
                })
            Invoke-GwStart -Path $script:folder -KeepAlive | Out-Null
            $script:wslCalls | Should -Contain ('-d Ubuntu-24.04 --cd {0} --exec docker compose -f compose.yaml up -d --no-recreate' -f $script:folder)
            $script:wslCalls[$script:wslCalls.Count - 1] | Should -Be '-d Ubuntu-24.04 --exec sleep infinity'
        }

        It 'ignores -KeepAlive for Docker Desktop, which keeps its own distribution running' {
            Invoke-GwStart -Path $script:folder -KeepAlive | Out-Null
            $script:wslCalls.Count | Should -Be 0
        }
    }

    Context 'Invoke-GwUninstall' {
        BeforeEach {
            Invoke-GwSetup -Path $script:folder -NoStart -UserNameSecure $script:secureUser -PasswordSecure $script:securePassword -Confirm:$false | Out-Null
            $script:dockerCalls.Clear()
            $script:tasks = @('\BrokerSRE\Gateway paper - start after sign-in', '\BrokerSRE\Gateway - clock fix after resume')
        }

        It 'stops and removes the container, removes the kit tasks and keeps the folder, the secrets and the volumes' {
            Add-GwJournalEntry -Path $script:folder -Action 'ResumeClockFix' -Kind 'ScheduledTask' -Description 'clock task' `
                -Data @{ TaskName = '\BrokerSRE\Gateway - clock fix after resume'; ExistedBefore = $false } | Out-Null
            $result = Invoke-GwUninstall -Path $script:folder -Confirm:$false
            $result.ExitCode | Should -Be 0
            $composePath = Join-Path $script:folder 'compose.yaml'
            $script:dockerCalls | Should -Be @(('compose -f {0} stop' -f $composePath), ('compose -f {0} down' -f $composePath))
            $script:tasks.Count | Should -Be 0
            @($script:taskCalls | Where-Object { $_ -like '/Delete|*' }).Count | Should -Be 2
            Test-Path -LiteralPath (Join-Path $script:folder 'secrets\ib-password') | Should -BeTrue
        }

        It 'removes volumes and the folder with -RemoveData' {
            $result = Invoke-GwUninstall -Path $script:folder -RemoveData -Confirm:$false
            $result.ExitCode | Should -Be 0
            ($script:dockerCalls -join "`n") | Should -Match 'down --volumes'
            Test-Path -LiteralPath $script:folder | Should -BeFalse
        }

        It 'leaves the per-computer clock task alone when this gateway did not register it' {
            Invoke-GwUninstall -Path $script:folder -Confirm:$false | Out-Null
            $script:tasks | Should -Be @('\BrokerSRE\Gateway - clock fix after resume')
        }

        It 'deletes only the files the kit wrote: other content and the folder stay, also with -RemoveData' {
            New-Item -ItemType Directory -Path (Join-Path $script:folder 'my-strategies') | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $script:folder 'my-strategies\notes.txt'), 'keep me')
            [System.IO.File]::WriteAllText((Join-Path $script:folder 'secrets\other-key'), 'not ours')
            $result = Invoke-GwUninstall -Path $script:folder -RemoveData -Confirm:$false
            $result.ExitCode | Should -Be 0
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'my-strategies\notes.txt')) | Should -Be 'keep me'
            [System.IO.File]::ReadAllText((Join-Path $script:folder 'secrets\other-key')) | Should -Be 'not ours'
            foreach ($gone in @('compose.yaml', 'kit-state.json', 'secrets\ib-username', 'secrets\ib-password')) {
                Test-Path -LiteralPath (Join-Path $script:folder $gone) | Should -BeFalse -Because $gone
            }
            ($script:console -join "`n") | Should -Match 'other files'
        }

        It 'does not touch a folder that only holds someone else''s compose.yaml' {
            $foreign = Join-Path $TestDrive ('foreign-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $foreign | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $foreign 'compose.yaml'), "services: {}`n")
            $result = Invoke-GwUninstall -Path $foreign -RemoveData -Confirm:$false
            $result.ExitCode | Should -Be 1
            $script:dockerCalls.Count | Should -Be 0
            $script:tasks.Count | Should -Be 2
            Test-Path -LiteralPath (Join-Path $foreign 'compose.yaml') | Should -BeTrue
        }

        It 'refuses to delete the folder while host changes are still journaled, unless told to keep them' {
            Add-GwJournalEntry -Path $script:folder -Action 'DisableSleep' -Kind 'PowerAcValue' -Description 'sleep' -Data @{ Scheme = 's'; Setting = 'STANDBYIDLE'; PreviousSeconds = 1800 } | Out-Null
            $result = Invoke-GwUninstall -Path $script:folder -RemoveData -Confirm:$false
            $result.ExitCode | Should -Be 1
            Test-Path -LiteralPath $script:folder | Should -BeTrue
            ($script:console -join "`n") | Should -Match 'harden\.ps1 -Undo'
            (Invoke-GwUninstall -Path $script:folder -RemoveData -KeepHostChanges -Confirm:$false).ExitCode | Should -Be 0
            Test-Path -LiteralPath $script:folder | Should -BeFalse
        }

        It 'changes nothing under -WhatIf, not even with -RemoveData' {
            $before = Get-TestTreeSnapshot -Path $script:folder
            Invoke-GwUninstall -Path $script:folder -RemoveData -WhatIf | Out-Null
            Get-TestTreeSnapshot -Path $script:folder | Should -Be $before
            $script:dockerCalls.Count | Should -Be 0
            $script:tasks.Count | Should -Be 2
        }

        It 'declares a high confirm impact, so secrets are never deleted silently' {
            $attribute = (Get-Command Invoke-GwUninstall).ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $attribute.ConfirmImpact | Should -Be 'High'
        }

        It 'refuses to delete a folder that setup did not create, even with -RemoveData and -Confirm:$false' {
            $other = Join-Path $TestDrive ('not-a-gateway-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $other 'documents') -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $other 'documents\important.txt'), 'keep me')
            $before = Get-TestTreeSnapshot -Path $other
            $result = Invoke-GwUninstall -Path $other -RemoveData -Confirm:$false
            $result.ExitCode | Should -Be 1
            Get-TestTreeSnapshot -Path $other | Should -Be $before
            ($script:console -join "`n") | Should -Match 'kit-state\.json'
        }

        It 'still removes tasks and reports when no container runtime answers' {
            $script:runtime = [pscustomobject]@{ Mode = 'None'; Distro = ''; EngineName = ''; OsType = ''; ServerVersion = ''; Detail = 'nothing' }
            $result = Invoke-GwUninstall -Path $script:folder -Confirm:$false
            $result.ExitCode | Should -Be 1
            $script:tasks | Should -Be @('\BrokerSRE\Gateway - clock fix after resume')
            $script:dockerCalls.Count | Should -Be 0
        }
    }
}
