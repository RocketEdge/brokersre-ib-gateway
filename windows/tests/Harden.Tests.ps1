# Tests for src/Harden.ps1: the change journal, each opt-in host change and the undo round trip.
# Every wrapper is mocked by a small fake that keeps state (a fake power scheme, registry, task
# list, firewall rule list), so a test can apply a change, undo it and compare the fake host with
# its initial state. Nothing here touches the real host.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-KitModule

    $script:scheme = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $script:policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

    function Get-FakePowerQuery {
        param([long]$Ac)
        return @(
            ('Power Scheme GUID: {0}  (Balanced)' -f $script:scheme)
            '      Minimum Possible Setting: 0x00000000'
            '      Maximum Possible Setting: 0xffffffff'
            '      Possible Settings increment: 0x00000001'
            ('    Current AC Power Setting Index: 0x{0:x8}' -f $Ac)
            '    Current DC Power Setting Index: 0x00000000'
        )
    }

    Mock -ModuleName BrokerSre.Gateway Invoke-GwPowerCfg {
        $script:powerCalls.Add(($ArgumentList -join ' '))
        switch ($ArgumentList[0]) {
            '/getactivescheme' { return (Get-TestNativeResult -Output @(('Power Scheme GUID: {0}  (Balanced)' -f $script:activeScheme))) }
            '/query' { return (Get-TestNativeResult -Output (Get-FakePowerQuery -Ac $script:power[$ArgumentList[3]])) }
            '/setacvalueindex' {
                if ($script:powerFails) { return (Get-TestNativeResult -ExitCode 1 -Output @('Access is denied.')) }
                $script:power[$ArgumentList[3]] = [long]$ArgumentList[4]
                return (Get-TestNativeResult)
            }
            '/setactive' { return (Get-TestNativeResult) }
            default { throw ('unexpected powercfg call: ' + ($ArgumentList -join ' ')) }
        }
    }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwRegistry {
        $key = '{0}|{1}' -f $Path, $Name
        switch ($Operation) {
            'Get' { return $script:registry[$key] }
            'Test' { return $false }
            'GetValues' { return @{} }
            'Set' {
                if ($script:registrySetThrows) { throw 'Requested registry access is not allowed.' }
                $script:registry[$key] = $Value
            }
            'Remove' { $script:registry.Remove($key) }
        }
    }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwSchTasks {
        $script:taskCalls.Add(($ArgumentList -join '|'))
        $taskName = $ArgumentList[2]
        switch ($ArgumentList[0]) {
            '/Query' {
                if ($script:tasks.ContainsKey($taskName)) { return (Get-TestNativeResult -Output @($script:tasks[$taskName])) }
                return (Get-TestNativeResult -ExitCode 1 -Output @('ERROR: The system cannot find the file specified.'))
            }
            '/Create' {
                if ($script:taskCreateFails) { return (Get-TestNativeResult -ExitCode 1 -Output @('ERROR: Access is denied.')) }
                $xmlFile = $ArgumentList[4]
                $script:tasks[$taskName] = [System.IO.File]::ReadAllText($xmlFile)
                $script:taskXmlBytes[$taskName] = [System.IO.File]::ReadAllBytes($xmlFile)
                return (Get-TestNativeResult -Output @('SUCCESS'))
            }
            '/Delete' {
                $script:tasks.Remove($taskName)
                return (Get-TestNativeResult -Output @('SUCCESS'))
            }
            default { throw ('unexpected schtasks call: ' + ($ArgumentList -join ' ')) }
        }
    }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwFirewall {
        switch ($Operation) {
            'Exists' { return ($script:firewall -contains $Name) }
            'Add' {
                if ($script:firewallAddThrows) { throw 'Access is denied.' }
                $script:firewall += $Name
                $script:firewallAdd = [pscustomobject]@{ Name = $Name; DisplayName = $DisplayName; Port = $Port }
            }
            'Remove' {
                if ($script:firewallRemoveThrows) { throw 'The firewall service is not running.' }
                $script:firewall = @($script:firewall | Where-Object { $_ -ne $Name })
            }
            'List' { return @() }
        }
    }
    Mock -ModuleName BrokerSre.Gateway Test-GwIsAdministrator { return $script:isAdmin }
    Mock -ModuleName BrokerSre.Gateway Get-GwCurrentUser { return [pscustomobject]@{ Name = 'TESTPC\trader'; Sid = 'S-1-5-21-1111111111-2222222222-3333333333-1001' } }
    Mock -ModuleName BrokerSre.Gateway Get-GwUtcNow { return $script:now }
    Mock -ModuleName BrokerSre.Gateway Write-GwConsole { }
}

Describe 'Hardening' {
    BeforeEach {
        $script:folder = Join-Path $TestDrive ('gw-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:folder | Out-Null
        $script:wslConfig = Join-Path $script:folder 'fake.wslconfig'
        $script:now = New-Object DateTime(2026, 11, 12, 1, 2, 3, [DateTimeKind]::Utc)
        $script:activeScheme = $script:scheme
        $script:power = @{ STANDBYIDLE = [long]1800; HIBERNATEIDLE = [long]10800 }
        $script:powerFails = $false
        $script:powerCalls = New-Object System.Collections.Generic.List[string]
        $script:registry = @{}
        $script:tasks = @{}
        $script:taskXmlBytes = @{}
        $script:taskCalls = New-Object System.Collections.Generic.List[string]
        $script:taskCreateFails = $false
        $script:firewall = @()
        $script:firewallAdd = $null
        $script:firewallAddThrows = $false
        $script:firewallRemoveThrows = $false
        $script:registrySetThrows = $false
        $script:isAdmin = $true
        Save-GwKitState -Path $script:folder -State ([pscustomobject]@{
                Runtime = 'DockerDesktop'; Distro = ''; TradingMode = 'paper'; ContainerName = 'brokersre-ib-gateway-paper'
                ProjectName = 'brokersre-gateway-paper'; ApiPort = 4002; ImageRef = 'example/image:tag'
            })
    }

    Context 'Change journal' {
        It 'starts empty when no journal file exists' {
            $journal = Get-GwJournal -Path $script:folder
            @($journal.Entries).Count | Should -Be 0
        }

        It 'appends entries with id, time, action, kind, data and Reverted = false' {
            $entry = Add-GwJournalEntry -Path $script:folder -Action 'Demo' -Kind 'RegistryValue' -Description 'demo change' -Data ([pscustomobject]@{ Name = 'X'; PreviousValue = 5 })
            $entry.Id | Should -Match '^[0-9a-f]{32}$'
            $journal = Get-GwJournal -Path $script:folder
            @($journal.Entries).Count | Should -Be 1
            $journal.Entries[0].Action | Should -Be 'Demo'
            $journal.Entries[0].Kind | Should -Be 'RegistryValue'
            $journal.Entries[0].Time | Should -Be '2026-11-12T01:02:03Z'
            $journal.Entries[0].Reverted | Should -BeFalse
            $journal.Entries[0].Data.PreviousValue | Should -Be 5
        }

        It 'keeps the timestamp as text when the journal is read and written again' {
            Add-GwJournalEntry -Path $script:folder -Action 'One' -Kind 'RegistryValue' -Description 'd' -Data ([pscustomobject]@{ A = 1 }) | Out-Null
            Add-GwJournalEntry -Path $script:folder -Action 'Two' -Kind 'RegistryValue' -Description 'd' -Data ([pscustomobject]@{ A = 2 }) | Out-Null
            $raw = [System.IO.File]::ReadAllText((Join-Path $script:folder 'harden-journal.json'))
            ([regex]::Matches($raw, '"Time":\s*"2026-11-12T01:02:03Z"')).Count | Should -Be 2
            $raw | Should -Not -Match 'Date\('
        }

        It 'writes the journal as UTF-8 without byte-order mark and with LF line endings' {
            Add-GwJournalEntry -Path $script:folder -Action 'One' -Kind 'RegistryValue' -Description 'd' -Data ([pscustomobject]@{ A = 1 }) | Out-Null
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:folder 'harden-journal.json'))
            $bytes[0] | Should -Be 0x7B
            ($bytes -contains 13) | Should -BeFalse
        }

        It 'treats a damaged journal as an error instead of silently starting a new one' {
            [System.IO.File]::WriteAllText((Join-Path $script:folder 'harden-journal.json'), 'not json {')
            { Get-GwJournal -Path $script:folder } | Should -Throw -ExpectedMessage '*harden-journal.json*'
        }
    }

    Context 'Disable-GwSleep' {
        It 'sets both AC timeouts of the active scheme to never and journals the previous values' {
            Disable-GwSleep -Path $script:folder -Confirm:$false
            $script:power.STANDBYIDLE | Should -Be 0
            $script:power.HIBERNATEIDLE | Should -Be 0
            $script:powerCalls | Should -Contain ('/setacvalueindex {0} SUB_SLEEP STANDBYIDLE 0' -f $script:scheme)
            $script:powerCalls | Should -Contain ('/setacvalueindex {0} SUB_SLEEP HIBERNATEIDLE 0' -f $script:scheme)
            $script:powerCalls | Should -Contain ('/setactive {0}' -f $script:scheme)
            $entries = @((Get-GwJournal -Path $script:folder).Entries)
            $entries.Count | Should -Be 2
            ($entries | Where-Object { $_.Data.Setting -eq 'STANDBYIDLE' }).Data.PreviousSeconds | Should -Be 1800
            ($entries | Where-Object { $_.Data.Setting -eq 'HIBERNATEIDLE' }).Data.PreviousSeconds | Should -Be 10800
            $entries[0].Kind | Should -Be 'PowerAcValue'
            $entries[0].Data.Scheme | Should -Be $script:scheme
        }

        It 'does nothing and journals nothing when both are already never' {
            $script:power = @{ STANDBYIDLE = [long]0; HIBERNATEIDLE = [long]0 }
            Disable-GwSleep -Path $script:folder -Confirm:$false
            @((Get-GwJournal -Path $script:folder).Entries).Count | Should -Be 0
            @($script:powerCalls | Where-Object { $_ -like '/setacvalueindex*' }).Count | Should -Be 0
        }

        It 'changes nothing under -WhatIf' {
            Disable-GwSleep -Path $script:folder -WhatIf
            $script:power.STANDBYIDLE | Should -Be 1800
            Test-Path -LiteralPath (Join-Path $script:folder 'harden-journal.json') | Should -BeFalse
            @($script:powerCalls | Where-Object { $_ -like '/set*' }).Count | Should -Be 0
        }

        It 'marks the journal entry as not applied when powercfg refuses, and reports the failure' {
            $script:powerFails = $true
            { Disable-GwSleep -Path $script:folder -Confirm:$false } | Should -Throw -ExpectedMessage '*powercfg*'
            $entries = @((Get-GwJournal -Path $script:folder).Entries)
            $entries.Count | Should -Be 1
            $entries[0].Reverted | Should -BeTrue
            $entries[0].Note | Should -Match 'not applied'
        }

        It 'declares a high confirm impact, so PowerShell asks before changing power settings' {
            $attribute = (Get-Command Disable-GwSleep).ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $attribute.ConfirmImpact | Should -Be 'High'
            $attribute.SupportsShouldProcess | Should -BeTrue
        }
    }

    Context 'Set-GwUpdateActiveWindow' {
        It 'writes the three documented policy values and journals that they did not exist' {
            Set-GwUpdateActiveWindow -Path $script:folder -Start 6 -End 23 -Confirm:$false
            $script:registry["$script:policyKey|SetActiveHours"] | Should -Be 1
            $script:registry["$script:policyKey|ActiveHoursStart"] | Should -Be 6
            $script:registry["$script:policyKey|ActiveHoursEnd"] | Should -Be 23
            $entries = @((Get-GwJournal -Path $script:folder).Entries)
            $entries.Count | Should -Be 3
            foreach ($entry in $entries) {
                $entry.Kind | Should -Be 'RegistryValue'
                $entry.Data.Existed | Should -BeFalse
            }
        }

        It 'journals the previous values when the policy existed' {
            $script:registry["$script:policyKey|SetActiveHours"] = 1
            $script:registry["$script:policyKey|ActiveHoursStart"] = 8
            $script:registry["$script:policyKey|ActiveHoursEnd"] = 17
            Set-GwUpdateActiveWindow -Path $script:folder -Start 6 -End 23 -Confirm:$false
            $entries = @((Get-GwJournal -Path $script:folder).Entries)
            ($entries | Where-Object { $_.Data.Name -eq 'ActiveHoursStart' }).Data.PreviousValue | Should -Be 8
            ($entries | Where-Object { $_.Data.Name -eq 'ActiveHoursStart' }).Data.Existed | Should -BeTrue
            @($entries | Where-Object { $_.Data.Name -eq 'SetActiveHours' }).Count | Should -Be 0
        }

        It 'rejects a window longer than 18 hours, an empty window and hours outside 0-23' {
            { Set-GwUpdateActiveWindow -Path $script:folder -Start 3 -End 22 -Confirm:$false } | Should -Throw -ExpectedMessage '*18*'
            { Set-GwUpdateActiveWindow -Path $script:folder -Start 5 -End 5 -Confirm:$false } | Should -Throw
            { Set-GwUpdateActiveWindow -Path $script:folder -Start 24 -End 5 -Confirm:$false } | Should -Throw
            $script:registry.Count | Should -Be 0
        }

        It 'accepts a window that crosses midnight' {
            Set-GwUpdateActiveWindow -Path $script:folder -Start 20 -End 8 -Confirm:$false
            $script:registry["$script:policyKey|ActiveHoursEnd"] | Should -Be 8
        }

        It 'refuses without elevation and changes nothing' {
            $script:isAdmin = $false
            { Set-GwUpdateActiveWindow -Path $script:folder -Start 6 -End 23 -Confirm:$false } | Should -Throw -ExpectedMessage '*administrator*'
            $script:registry.Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $script:folder 'harden-journal.json') | Should -BeFalse
        }

        It 'changes nothing under -WhatIf, even without elevation' {
            $script:isAdmin = $false
            Set-GwUpdateActiveWindow -Path $script:folder -Start 6 -End 23 -WhatIf
            $script:registry.Count | Should -Be 0
        }
    }

    Context 'New-GwTaskXml' {
        It 'builds a boot task that runs as the user without an interactive session' {
            $xml = New-GwTaskXml -Description 'demo' -UserSid 'S-1-5-21-1-2-3-1001' -UserName 'TESTPC\trader' -LogonType 'S4U' -Trigger 'Boot' `
                -Action @(@{ Command = 'powershell.exe'; Arguments = '-File "C:\kit\start.ps1" -Path "C:\gw" -KeepAlive' })
            $document = [xml]$xml
            $document.Task.Triggers.BootTrigger.Enabled | Should -Be 'true'
            $document.Task.Principals.Principal.UserId | Should -Be 'S-1-5-21-1-2-3-1001'
            $document.Task.Principals.Principal.LogonType | Should -Be 'S4U'
            $document.Task.Principals.Principal.RunLevel | Should -Be 'LeastPrivilege'
            $document.Task.Actions.Exec.Command | Should -Be 'powershell.exe'
            $document.Task.Actions.Exec.Arguments | Should -Be '-File "C:\kit\start.ps1" -Path "C:\gw" -KeepAlive'
            $document.Task.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
            $document.Task.Settings.MultipleInstancesPolicy | Should -Be 'IgnoreNew'
            $document.Task.Settings.DisallowStartIfOnBatteries | Should -Be 'false'
        }

        It 'builds a sign-in task for one user with an interactive token' {
            $xml = New-GwTaskXml -Description 'demo' -UserSid 'S-1-5-21-1-2-3-1001' -UserName 'TESTPC\trader' -LogonType 'InteractiveToken' -Trigger 'Logon' `
                -Action @(@{ Command = 'powershell.exe'; Arguments = '-File x' })
            $document = [xml]$xml
            $document.Task.Triggers.LogonTrigger.UserId | Should -Be 'TESTPC\trader'
            $document.Task.Principals.Principal.LogonType | Should -Be 'InteractiveToken'
        }

        It 'builds a resume task that listens for the three resume events in the System log' {
            $xml = New-GwTaskXml -Description 'demo' -UserSid 'S-1-5-21-1-2-3-1001' -UserName 'TESTPC\trader' -LogonType 'InteractiveToken' -Trigger 'Resume' `
                -Action @(@{ Command = 'wsl.exe'; Arguments = '-d docker-desktop -u root -- hwclock -s' })
            $subscription = ([xml]$xml).Task.Triggers.EventTrigger.Subscription
            $subscription | Should -Match "Provider\[@Name='Microsoft-Windows-Power-Troubleshooter'\] and EventID=1"
            $subscription | Should -Match "Provider\[@Name='Microsoft-Windows-Kernel-Power'\] and \(EventID=107 or EventID=507\)"
            ([xml]$subscription).QueryList.Query.Path | Should -Be 'System'
        }

        It 'escapes XML special characters in descriptions, names and arguments' {
            $xml = New-GwTaskXml -Description 'a & b < c' -UserSid 'S-1-5-21-1-2-3-1001' -UserName 'PC\o''brien & co' -LogonType 'InteractiveToken' -Trigger 'Logon' `
                -Action @(@{ Command = 'x.exe'; Arguments = '-a "1 < 2" && echo' })
            $document = [xml]$xml
            $document.Task.RegistrationInfo.Description | Should -Be 'a & b < c'
            $document.Task.Triggers.LogonTrigger.UserId | Should -Be 'PC\o''brien & co'
            $document.Task.Actions.Exec.Arguments | Should -Be '-a "1 < 2" && echo'
        }

        It 'supports several actions in sequence' {
            $xml = New-GwTaskXml -Description 'demo' -UserSid 'S-1-5-21-1-2-3-1001' -UserName 'TESTPC\trader' -LogonType 'InteractiveToken' -Trigger 'Resume' `
                -Action @(@{ Command = 'a.exe'; Arguments = '1' }, @{ Command = 'a.exe'; Arguments = '2' })
            @(([xml]$xml).Task.Actions.Exec).Count | Should -Be 2
        }

        It 'is accepted by the real Task Scheduler schema without registering anything' -Skip:(-not (Test-Path 'HKLM:\SOFTWARE\Classes\Schedule.Service')) {
            $service = New-Object -ComObject Schedule.Service
            $service.Connect()
            foreach ($trigger in @('Boot', 'Logon', 'Resume')) {
                foreach ($logonType in @('InteractiveToken', 'S4U', 'Password')) {
                    $xml = New-GwTaskXml -Description 'schema check' -UserSid ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value) `
                        -UserName ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType $logonType -Trigger $trigger `
                        -Action @(@{ Command = 'wsl.exe'; Arguments = '-d docker-desktop -u root -- hwclock -s' })
                    $definition = $service.NewTask(0)
                    { $definition.XmlText = $xml } | Should -Not -Throw -Because ('{0}/{1}' -f $trigger, $logonType)
                    $definition.Actions.Count | Should -Be 1
                }
            }
        }
    }

    Context 'Register-GwStartTask' {
        It 'registers the start-after-sign-in task for Docker Desktop and journals it' {
            Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false
            $name = '\BrokerSRE\Gateway paper - start after sign-in'
            $script:tasks.ContainsKey($name) | Should -BeTrue
            $document = [xml]$script:tasks[$name]
            $document.Task.Triggers.LogonTrigger.UserId | Should -Be 'TESTPC\trader'
            $document.Task.Principals.Principal.LogonType | Should -Be 'InteractiveToken'
            $document.Task.Actions.Exec.Command | Should -Match 'powershell\.exe$'
            $expected = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\kit\windows\start.ps1 -Path ' + (ConvertTo-GwNativeArgument -Argument $script:folder)
            $document.Task.Actions.Exec.Arguments | Should -Be $expected
            $entry = @((Get-GwJournal -Path $script:folder).Entries)[0]
            $entry.Kind | Should -Be 'ScheduledTask'
            $entry.Data.TaskName | Should -Be $name
            $entry.Data.ExistedBefore | Should -BeFalse
        }

        It 'quotes a folder with a space and a trailing backslash so the task still receives -Path and -KeepAlive' {
            $spaced = Join-Path $TestDrive ('my gw ' + [guid]::NewGuid().ToString('N').Substring(0, 6))
            New-Item -ItemType Directory -Path $spaced | Out-Null
            Save-GwKitState -Path $spaced -State ([pscustomobject]@{
                    Runtime = 'WslEngine'; Distro = 'Ubuntu-24.04'; TradingMode = 'paper'; ContainerName = 'c'; ProjectName = 'p'; ApiPort = 4002; ImageRef = 'i'
                })
            Register-GwStartTask -Path ($spaced + '\') -Mode 'WslEngine' -AfterSignIn -KitRoot 'C:\my kit\windows' -Confirm:$false
            $arguments = ([xml]$script:tasks['\BrokerSRE\Gateway paper - start after sign-in']).Task.Actions.Exec.Arguments
            $arguments | Should -Be ('-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\my kit\windows\start.ps1" -Path "{0}" -KeepAlive' -f $spaced)
            $arguments | Should -Not -Match '\\" -KeepAlive'
        }

        It 'passes the task definition to schtasks as a UTF-16 XML file and deletes the file afterwards' {
            Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false
            $create = @($script:taskCalls | Where-Object { $_ -like '/Create|*' })[0]
            $parts = $create.Split('|')
            $parts[0..2] -join '|' | Should -Be '/Create|/TN|\BrokerSRE\Gateway paper - start after sign-in'
            $parts[3] | Should -Be '/XML'
            $parts[5] | Should -Be '/F'
            Test-Path -LiteralPath $parts[4] | Should -BeFalse
            $bytes = $script:taskXmlBytes['\BrokerSRE\Gateway paper - start after sign-in']
            $bytes[0] | Should -Be 0xFF
            $bytes[1] | Should -Be 0xFE
        }

        It 'registers a boot task for Docker Engine in WSL that keeps the distribution alive' {
            Register-GwStartTask -Path $script:folder -Mode 'WslEngine' -KitRoot 'C:\kit\windows' -LogonType 'S4U' -Confirm:$false
            $name = '\BrokerSRE\Gateway paper - start at boot'
            $document = [xml]$script:tasks[$name]
            $document.Task.Triggers.BootTrigger.Enabled | Should -Be 'true'
            $document.Task.Principals.Principal.LogonType | Should -Be 'S4U'
            $document.Task.Actions.Exec.Arguments | Should -Match '-KeepAlive$'
            $document.Task.Settings.ExecutionTimeLimit | Should -Be 'PT0S'
        }

        It 'lets Windows ask for the account password itself for a stored-password boot task' {
            Register-GwStartTask -Path $script:folder -Mode 'WslEngine' -KitRoot 'C:\kit\windows' -LogonType 'Password' -Confirm:$false
            $create = @($script:taskCalls | Where-Object { $_ -like '/Create|*' })[0]
            $create | Should -Match '\|/RU\|TESTPC\\trader\|/RP\|\*\|/F$'
            Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwSchTasks -Times 1 -Exactly -ParameterFilter { $ArgumentList[0] -eq '/Create' -and $Interactive }
        }

        It 'registers the sign-in variant for Docker Engine in WSL with -AfterSignIn' {
            Register-GwStartTask -Path $script:folder -Mode 'WslEngine' -AfterSignIn -KitRoot 'C:\kit\windows' -Confirm:$false
            $document = [xml]$script:tasks['\BrokerSRE\Gateway paper - start after sign-in']
            $document.Task.Principals.Principal.LogonType | Should -Be 'InteractiveToken'
            $document.Task.Actions.Exec.Arguments | Should -Match '-KeepAlive$'
        }

        It 'records that the task existed before when it replaces its own earlier version' {
            Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false
            Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false
            $entries = @((Get-GwJournal -Path $script:folder).Entries)
            $entries.Count | Should -Be 2
            $entries[1].Data.ExistedBefore | Should -BeTrue
        }

        It 'needs elevation for the boot task but not for the sign-in task' {
            $script:isAdmin = $false
            { Register-GwStartTask -Path $script:folder -Mode 'WslEngine' -KitRoot 'C:\kit\windows' -LogonType 'S4U' -Confirm:$false } | Should -Throw -ExpectedMessage '*administrator*'
            { Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false } | Should -Not -Throw
        }

        It 'marks the journal entry as not applied when schtasks refuses' {
            $script:taskCreateFails = $true
            { Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false } | Should -Throw -ExpectedMessage '*schtasks*'
            $entry = @((Get-GwJournal -Path $script:folder).Entries)[0]
            $entry.Reverted | Should -BeTrue
        }

        It 'changes nothing under -WhatIf' {
            Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -WhatIf
            $script:tasks.Count | Should -Be 0
            @($script:taskCalls | Where-Object { $_ -notlike '/Query|*' }).Count | Should -Be 0
            Test-Path -LiteralPath (Join-Path $script:folder 'harden-journal.json') | Should -BeFalse
            @(Get-ChildItem -LiteralPath $script:folder -Filter '*.xml').Count | Should -Be 0
        }

        It 'refuses when setup has not run in the folder' {
            $empty = Join-Path $TestDrive ('empty-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $empty | Out-Null
            { Register-GwStartTask -Path $empty -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false } | Should -Throw -ExpectedMessage '*setup.ps1*'
        }
    }

    Context 'Register-GwResumeClockTask' {
        It 'runs hwclock -s as root in Docker Desktop''s distribution on resume, twice for a retry' {
            Register-GwResumeClockTask -Path $script:folder -Confirm:$false
            $name = '\BrokerSRE\Gateway - clock fix after resume'
            $document = [xml]$script:tasks[$name]
            $actions = @($document.Task.Actions.Exec)
            $actions.Count | Should -Be 2
            $actions[0].Command | Should -Match 'wsl\.exe$'
            $actions[0].Arguments | Should -Be '-d docker-desktop -u root -- hwclock -s'
            $actions[1].Arguments | Should -Be '-d docker-desktop -u root -- hwclock -s'
            $document.Task.Triggers.EventTrigger.Subscription | Should -Match 'Power-Troubleshooter'
            @((Get-GwJournal -Path $script:folder).Entries)[0].Data.TaskName | Should -Be $name
        }

        It 'targets the distribution that runs Docker Engine in WSL mode' {
            Save-GwKitState -Path $script:folder -State ([pscustomobject]@{
                    Runtime = 'WslEngine'; Distro = 'Ubuntu-24.04'; TradingMode = 'paper'; ContainerName = 'c'; ProjectName = 'p'; ApiPort = 4002; ImageRef = 'i'
                })
            Register-GwResumeClockTask -Path $script:folder -Confirm:$false
            ([xml]$script:tasks['\BrokerSRE\Gateway - clock fix after resume']).Task.Actions.Exec[0].Arguments | Should -Be '-d Ubuntu-24.04 -u root -- hwclock -s'
        }

        It 'changes nothing under -WhatIf' {
            Register-GwResumeClockTask -Path $script:folder -WhatIf
            $script:tasks.Count | Should -Be 0
        }
    }

    Context 'Set-GwWslConfigValue' {
        It 'creates the file with the key and journals that the key was absent' {
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'general' -Key 'instanceIdleTimeout' -Value '-1' -Confirm:$false
            [System.IO.File]::ReadAllText($script:wslConfig) | Should -Be "[general]`ninstanceIdleTimeout=-1`n"
            $entry = @((Get-GwJournal -Path $script:folder).Entries)[0]
            $entry.Kind | Should -Be 'IniValue'
            $entry.Data.Existed | Should -BeFalse
            $entry.Data.BackupPath | Should -Be ''
        }

        It 'merges into an existing file, keeps other lines and writes a timestamped backup' {
            [System.IO.File]::WriteAllText($script:wslConfig, "# mine`n[wsl2]`nmemory=8GB`nnetworkingMode=mirrored`n")
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'networkingMode' -Value 'nat' -Confirm:$false
            [System.IO.File]::ReadAllText($script:wslConfig) | Should -Be "# mine`n[wsl2]`nmemory=8GB`nnetworkingMode=nat`n"
            $entry = @((Get-GwJournal -Path $script:folder).Entries)[0]
            $entry.Data.Existed | Should -BeTrue
            $entry.Data.PreviousValue | Should -Be 'mirrored'
            $entry.Data.BackupPath | Should -Be ($script:wslConfig + '.brokersre-backup-20261112T010203Z')
            [System.IO.File]::ReadAllText($entry.Data.BackupPath) | Should -Be "# mine`n[wsl2]`nmemory=8GB`nnetworkingMode=mirrored`n"
        }

        It 'does nothing when the value is already set' {
            [System.IO.File]::WriteAllText($script:wslConfig, "[wsl2]`nnetworkingMode=NAT`n")
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'networkingMode' -Value 'nat' -Confirm:$false
            @((Get-GwJournal -Path $script:folder).Entries).Count | Should -Be 0
            @(Get-ChildItem -LiteralPath $script:folder -Filter '*.brokersre-backup-*').Count | Should -Be 0
        }

        It 'changes nothing under -WhatIf' {
            [System.IO.File]::WriteAllText($script:wslConfig, "[wsl2]`nnetworkingMode=mirrored`n")
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'networkingMode' -Value 'nat' -WhatIf
            [System.IO.File]::ReadAllText($script:wslConfig) | Should -Be "[wsl2]`nnetworkingMode=mirrored`n"
            @(Get-ChildItem -LiteralPath $script:folder -Filter '*.brokersre-backup-*').Count | Should -Be 0
        }
    }

    Context 'Add-GwFirewallBlockRule' {
        It 'adds one inbound block rule for the three ports and journals it' {
            Add-GwFirewallBlockRule -Path $script:folder -Confirm:$false
            $script:firewall | Should -Be @('BrokerSRE-Gateway-Block-Api-Ports')
            $script:firewallAdd.Port | Should -Be @(4001, 4002, 9810)
            $entry = @((Get-GwJournal -Path $script:folder).Entries)[0]
            $entry.Kind | Should -Be 'FirewallRule'
            $entry.Data.RuleName | Should -Be 'BrokerSRE-Gateway-Block-Api-Ports'
        }

        It 'does nothing when the rule already exists' {
            $script:firewall = @('BrokerSRE-Gateway-Block-Api-Ports')
            Add-GwFirewallBlockRule -Path $script:folder -Confirm:$false
            @((Get-GwJournal -Path $script:folder).Entries).Count | Should -Be 0
        }

        It 'refuses without elevation' {
            $script:isAdmin = $false
            { Add-GwFirewallBlockRule -Path $script:folder -Confirm:$false } | Should -Throw -ExpectedMessage '*administrator*'
            $script:firewall.Count | Should -Be 0
        }

        It 'changes nothing under -WhatIf' {
            Add-GwFirewallBlockRule -Path $script:folder -WhatIf
            $script:firewall.Count | Should -Be 0
        }
    }

    Context 'A change that fails is recorded as not applied, so undo never reverts what did not happen' {
        It 'marks a refused registry write' {
            $script:registry["$script:policyKey|ActiveHoursStart"] = 8
            $script:registrySetThrows = $true
            { Set-GwUpdateActiveWindow -Path $script:folder -Start 6 -End 23 -Confirm:$false } | Should -Throw
            $entries = @((Get-GwJournal -Path $script:folder).Entries)
            $entries.Count | Should -Be 1
            $entries[0].Reverted | Should -BeTrue
            $entries[0].Note | Should -Match 'not applied'
            $script:registrySetThrows = $false
            @(Undo-GwHardening -Path $script:folder -Confirm:$false).Count | Should -Be 0
            $script:registry["$script:policyKey|ActiveHoursStart"] | Should -Be 8
        }

        It 'marks a refused firewall rule' {
            $script:firewallAddThrows = $true
            { Add-GwFirewallBlockRule -Path $script:folder -Confirm:$false } | Should -Throw
            $entry = @((Get-GwJournal -Path $script:folder).Entries)[0]
            $entry.Reverted | Should -BeTrue
            $entry.Note | Should -Match 'not applied'
        }

        It 'marks a .wslconfig that could not be written' {
            [System.IO.File]::WriteAllText($script:wslConfig, "[wsl2]`nmemory=8GB`n")
            (Get-Item -LiteralPath $script:wslConfig).IsReadOnly = $true
            try {
                { Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'memory' -Value '4GB' -Confirm:$false } | Should -Throw
            }
            finally {
                (Get-Item -LiteralPath $script:wslConfig).IsReadOnly = $false
            }
            $entry = @((Get-GwJournal -Path $script:folder).Entries)[0]
            $entry.Reverted | Should -BeTrue
            [System.IO.File]::ReadAllText($script:wslConfig) | Should -Be "[wsl2]`nmemory=8GB`n"
        }
    }

    Context 'Undo-GwHardening: round trip' {
        It 'restores the fake host exactly after every kind of change' {
            [System.IO.File]::WriteAllText($script:wslConfig, "# mine`n[wsl2]`nnetworkingMode=mirrored`n")
            $script:registry["$script:policyKey|ActiveHoursStart"] = 8

            Disable-GwSleep -Path $script:folder -Confirm:$false
            Set-GwUpdateActiveWindow -Path $script:folder -Start 6 -End 23 -Confirm:$false
            Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false
            Register-GwResumeClockTask -Path $script:folder -Confirm:$false
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'networkingMode' -Value 'nat' -Confirm:$false
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'general' -Key 'instanceIdleTimeout' -Value '-1' -Confirm:$false
            Add-GwFirewallBlockRule -Path $script:folder -Confirm:$false

            $script:power.STANDBYIDLE | Should -Be 0
            $script:tasks.Count | Should -Be 2
            $script:firewall.Count | Should -Be 1

            $summary = @(Undo-GwHardening -Path $script:folder -Confirm:$false)

            $script:power.STANDBYIDLE | Should -Be 1800
            $script:power.HIBERNATEIDLE | Should -Be 10800
            $script:registry.Count | Should -Be 1
            $script:registry["$script:policyKey|ActiveHoursStart"] | Should -Be 8
            $script:tasks.Count | Should -Be 0
            $script:firewall.Count | Should -Be 0
            [System.IO.File]::ReadAllText($script:wslConfig) | Should -Be "# mine`n[wsl2]`nnetworkingMode=mirrored`n"
            $summary.Count | Should -Be 10
            @($summary | Where-Object { $_.Result -ne 'Reverted' }).Count | Should -Be 0
            @((Get-GwJournal -Path $script:folder).Entries | Where-Object { -not $_.Reverted }).Count | Should -Be 0
        }

        It 'reports an entry that cannot be reverted as Failed, keeps it for later and still reverts the others' {
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'memory' -Value '4GB' -Confirm:$false
            Add-GwFirewallBlockRule -Path $script:folder -Confirm:$false
            Disable-GwSleep -Path $script:folder -Confirm:$false
            $script:firewallRemoveThrows = $true
            $summary = @(Undo-GwHardening -Path $script:folder -Confirm:$false)
            @($summary | Where-Object { $_.Result -eq 'Failed' }).Count | Should -Be 1
            @($summary | Where-Object { $_.Result -eq 'Reverted' }).Count | Should -Be 3
            $script:power.STANDBYIDLE | Should -Be 1800
            Test-Path -LiteralPath $script:wslConfig | Should -BeFalse
            $pending = @((Get-GwJournal -Path $script:folder).Entries | Where-Object { -not $_.Reverted })
            $pending.Count | Should -Be 1
            $pending[0].Kind | Should -Be 'FirewallRule'
            $script:firewallRemoveThrows = $false
            @(Undo-GwHardening -Path $script:folder -Confirm:$false | Where-Object { $_.Result -eq 'Reverted' }).Count | Should -Be 1
            $script:firewall.Count | Should -Be 0
        }

        It 'reverts in reverse order and removes the file the kit created once it is empty again' {
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'memory' -Value '4GB' -Confirm:$false
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'memory' -Value '8GB' -Confirm:$false
            [System.IO.File]::ReadAllText($script:wslConfig) | Should -Be "[wsl2]`nmemory=8GB`n"
            Undo-GwHardening -Path $script:folder -Confirm:$false | Out-Null
            Test-Path -LiteralPath $script:wslConfig | Should -BeFalse
        }

        It 'keeps a file that existed before, even when undo leaves it empty' {
            [System.IO.File]::WriteAllText($script:wslConfig, '')
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'memory' -Value '4GB' -Confirm:$false
            Undo-GwHardening -Path $script:folder -Confirm:$false | Out-Null
            Test-Path -LiteralPath $script:wslConfig | Should -BeTrue
            [System.IO.File]::ReadAllText($script:wslConfig) | Should -Be ''
        }

        It 'keeps edits the operator made to .wslconfig after hardening' {
            Set-GwWslConfigValue -Path $script:folder -WslConfigPath $script:wslConfig -Section 'wsl2' -Key 'networkingMode' -Value 'nat' -Confirm:$false
            [System.IO.File]::AppendAllText($script:wslConfig, "processors=4`n")
            Undo-GwHardening -Path $script:folder -Confirm:$false | Out-Null
            $text = [System.IO.File]::ReadAllText($script:wslConfig)
            Get-GwIniValue -Text $text -Section 'wsl2' -Key 'processors' | Should -Be '4'
            Get-GwIniValue -Text $text -Section 'wsl2' -Key 'networkingMode' | Should -BeNullOrEmpty
        }

        It 'does not revert the same entry twice' {
            Disable-GwSleep -Path $script:folder -Confirm:$false
            Undo-GwHardening -Path $script:folder -Confirm:$false | Out-Null
            $script:power.STANDBYIDLE = 600
            @(Undo-GwHardening -Path $script:folder -Confirm:$false).Count | Should -Be 0
            $script:power.STANDBYIDLE | Should -Be 600
        }

        It 'leaves a task in place when an earlier journal entry created it, then removes it with that entry' {
            Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false
            Register-GwStartTask -Path $script:folder -Mode 'DockerDesktop' -KitRoot 'C:\kit\windows' -Confirm:$false
            Undo-GwHardening -Path $script:folder -Confirm:$false | Out-Null
            $script:tasks.Count | Should -Be 0
            @($script:taskCalls | Where-Object { $_ -like '/Delete|*' }).Count | Should -Be 1
        }

        It 'changes nothing under -WhatIf' {
            Disable-GwSleep -Path $script:folder -Confirm:$false
            Undo-GwHardening -Path $script:folder -WhatIf | Out-Null
            $script:power.STANDBYIDLE | Should -Be 0
            @((Get-GwJournal -Path $script:folder).Entries | Where-Object { -not $_.Reverted }).Count | Should -Be 2
        }

        It 'stops at entries that need elevation, reports them and keeps them for a later run' {
            Set-GwUpdateActiveWindow -Path $script:folder -Start 6 -End 23 -Confirm:$false
            $script:isAdmin = $false
            $summary = @(Undo-GwHardening -Path $script:folder -Confirm:$false)
            @($summary | Where-Object { $_.Result -eq 'NeedsElevation' }).Count | Should -Be 3
            $script:registry.Count | Should -Be 3
            @((Get-GwJournal -Path $script:folder).Entries | Where-Object { -not $_.Reverted }).Count | Should -Be 3
        }

        It 'does not switch the active power scheme when the operator changed it since' {
            Disable-GwSleep -Path $script:folder -Confirm:$false
            $script:activeScheme = 'a1841308-3541-4fab-bc81-f71556f20b4a'
            $script:powerCalls.Clear()
            Undo-GwHardening -Path $script:folder -Confirm:$false | Out-Null
            @($script:powerCalls | Where-Object { $_ -like '/setactive*' }).Count | Should -Be 0
            $script:power.STANDBYIDLE | Should -Be 1800
        }
    }
}
