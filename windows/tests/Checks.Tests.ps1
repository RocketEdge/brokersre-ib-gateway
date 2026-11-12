# Tests for src/Checks.ps1: every prerequisite and doctor check, on its PASS, WARN, FAIL and SKIP
# paths. Each external dependency is mocked once for the whole file; the mock reads a handler or
# a table from script scope, which BeforeEach resets, so a test only states what the host "says".

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-KitModule

    $script:desktop = [pscustomobject]@{ Mode = 'DockerDesktop'; Distro = ''; EngineName = 'Docker Desktop'; OsType = 'linux'; ServerVersion = '29.9.3'; Detail = '' }
    $script:engine = [pscustomobject]@{ Mode = 'WslEngine'; Distro = 'Ubuntu-24.04'; EngineName = 'Ubuntu 24.04 LTS'; OsType = 'linux'; ServerVersion = '29.0.0'; Detail = '' }
    $script:noRuntime = [pscustomobject]@{ Mode = 'None'; Distro = ''; EngineName = ''; OsType = ''; ServerVersion = ''; Detail = 'docker.exe cannot reach a running engine.' }

    $script:winVersionKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $script:uxKey = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
    $script:wuPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $script:auPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
    $script:winlogonKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $script:runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $script:portProxyKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'
    $script:rebootKeyUpdate = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $script:rebootKeyServicing = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'

    function Get-PowerCfgOutput {
        param([string]$Ac, [string]$Dc)
        return @(
            'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)'
            '  Subgroup GUID: 238c9fa8-0aad-41ed-83f4-97be242c8f20  (Sleep)'
            '    Power Setting GUID: 29f6c1db-86da-48c5-9fdb-f2b67b1f44da  (Sleep after)'
            '      Minimum Possible Setting: 0x00000000'
            '      Maximum Possible Setting: 0xffffffff'
            '      Possible Settings increment: 0x00000001'
            '      Possible Settings units: Seconds'
            ('    Current AC Power Setting Index: {0}' -f $Ac)
            ('    Current DC Power Setting Index: {0}' -f $Dc)
        )
    }

    Mock -ModuleName BrokerSre.Gateway Invoke-GwRegistry {
        switch ($Operation) {
            'Get' { return $script:registry[('{0}|{1}' -f $Path, $Name)] }
            'Test' { return ($script:registryKeys -contains $Path) }
            'GetValues' {
                if ($script:registryValues.ContainsKey($Path)) { return $script:registryValues[$Path] }
                return @{}
            }
            default { throw ('a check must never write the registry: ' + $Operation) }
        }
    }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwPowerCfg { & $script:powerCfgHandler $ArgumentList }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwDocker { & $script:dockerHandler $ArgumentList }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwWsl { & $script:wslHandler $ArgumentList }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwSchTasks { & $script:schTasksHandler $ArgumentList }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwW32tm { & $script:w32tmHandler $ArgumentList }
    Mock -ModuleName BrokerSre.Gateway Invoke-GwFirewall {
        if ($Operation -ne 'List') { throw ('a check must never change the firewall: ' + $Operation) }
        if ($script:firewallThrows) { throw 'The firewall service is not running.' }
        return $script:firewallRules
    }
    Mock -ModuleName BrokerSre.Gateway Get-GwTcpListenerPort { return [int[]]$script:listeners }
    Mock -ModuleName BrokerSre.Gateway Get-GwDriveFreeByte { return $script:freeBytes }
    Mock -ModuleName BrokerSre.Gateway Get-GwVirtualizationInfo { return $script:virtualization }
}

Describe 'Host checks' {
    BeforeEach {
        $script:registry = @{}
        $script:registryKeys = @()
        $script:registryValues = @{}
        $script:powerCfgHandler = { Get-TestNativeResult -ExitCode 1 -Output @('unexpected powercfg call') }
        $script:dockerHandler = { param($a) Get-TestNativeResult -ExitCode 1 -Output @('unexpected docker call: ' + ($a -join ' ')) }
        $script:wslHandler = { param($a) Get-TestNativeResult -ExitCode 1 -Output @('unexpected wsl call: ' + ($a -join ' ')) }
        $script:schTasksHandler = { Get-TestNativeResult -ExitCode 1 -Output @('ERROR: The system cannot find the file specified.') }
        $script:w32tmHandler = { Get-TestNativeResult -ExitCode 1 -Output @('unexpected w32tm call') }
        $script:firewallRules = @()
        $script:firewallThrows = $false
        $script:listeners = @(135, 445)
        $script:freeBytes = [long]200GB
        $script:virtualization = [pscustomobject]@{ HypervisorPresent = $true; FirmwareEnabled = $false }
    }

    Describe 'Test-GwWindowsBuild' {
        It 'passes on Windows 11' {
            $script:registry["$script:winVersionKey|CurrentBuildNumber"] = '26100'
            $script:registry["$script:winVersionKey|DisplayVersion"] = '24H2'
            $result = Test-GwWindowsBuild
            $result.Name | Should -Be 'WindowsBuild'
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match 'Windows 11.*26100.*24H2'
        }

        It 'warns on Windows 10 22H2, which is past its end of support' {
            $script:registry["$script:winVersionKey|CurrentBuildNumber"] = '19045'
            $script:registry["$script:winVersionKey|DisplayVersion"] = '22H2'
            $result = Test-GwWindowsBuild
            $result.Status | Should -Be 'WARN'
            $result.Detail | Should -Match 'Windows 10'
        }

        It 'fails below Windows 10 22H2' {
            $script:registry["$script:winVersionKey|CurrentBuildNumber"] = '19044'
            (Test-GwWindowsBuild).Status | Should -Be 'FAIL'
        }

        It 'skips when the build number cannot be read' {
            (Test-GwWindowsBuild).Status | Should -Be 'SKIP'
        }
    }

    Describe 'Test-GwVirtualization' {
        It 'passes when a hypervisor is running' {
            (Test-GwVirtualization).Status | Should -Be 'PASS'
        }

        It 'passes when no hypervisor runs yet but the firmware switch is on' {
            $script:virtualization = [pscustomobject]@{ HypervisorPresent = $false; FirmwareEnabled = $true }
            (Test-GwVirtualization).Status | Should -Be 'PASS'
        }

        It 'fails when virtualization is off in the firmware' {
            $script:virtualization = [pscustomobject]@{ HypervisorPresent = $false; FirmwareEnabled = $false }
            $result = Test-GwVirtualization
            $result.Status | Should -Be 'FAIL'
            $result.Fix | Should -Match 'UEFI'
        }

        It 'skips when CIM gives no answer' {
            $script:virtualization = [pscustomobject]@{ HypervisorPresent = $null; FirmwareEnabled = $null }
            (Test-GwVirtualization).Status | Should -Be 'SKIP'
        }
    }

    Describe 'Test-GwWslVersion' {
        It 'passes for a current WSL and reports the version' {
            $script:wslHandler = { Get-TestNativeResult -Output @('WSL version: 2.6.1.0', 'Kernel version: 6.6.87.2-1') }
            $result = Test-GwWslVersion
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match '2\.6\.1\.0'
        }

        It 'parses a localised label' {
            $script:wslHandler = { Get-TestNativeResult -Output @('WSL-Version: 2.3.26.0', 'Kernelversion: 5.15.167.4-1') }
            (Test-GwWslVersion).Detail | Should -Match '2\.3\.26\.0'
        }

        It 'warns below 2.1.5, the minimum Docker Desktop documents' {
            $script:wslHandler = { Get-TestNativeResult -Output @('WSL version: 2.0.9.0') }
            $result = Test-GwWslVersion
            $result.Status | Should -Be 'WARN'
            $result.Fix | Should -Match 'wsl --update'
        }

        It 'fails when wsl --version is not supported (inbox WSL) or WSL is missing' {
            $script:wslHandler = { Get-TestNativeResult -ExitCode -1 -Output @('Invalid command line option: --version') }
            $result = Test-GwWslVersion
            $result.Status | Should -Be 'FAIL'
            $result.Fix | Should -Match 'wsl --install'
        }

        It 'skips when the output carries no version number' {
            $script:wslHandler = { Get-TestNativeResult -Output @('something unexpected') }
            (Test-GwWslVersion).Status | Should -Be 'SKIP'
        }

        It 'asks exactly wsl --version' {
            $script:seen = ''
            $script:wslHandler = { param($a) $script:seen = ($a -join ' '); Get-TestNativeResult -Output @('WSL version: 2.6.1.0') }
            Test-GwWslVersion | Out-Null
            $script:seen | Should -Be '--version'
        }
    }

    Describe 'Test-GwContainerRuntime' {
        It 'passes for Docker Desktop with Linux containers and names the mode' {
            $result = Test-GwContainerRuntime -Runtime $script:desktop
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match 'Docker Desktop'
            $result.Detail | Should -Match '29\.9\.3'
        }

        It 'passes for Docker Engine in WSL and names the distribution' {
            $result = Test-GwContainerRuntime -Runtime $script:engine
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match 'Ubuntu-24\.04'
        }

        It 'fails for Windows containers: the gateway is a Linux image' {
            $windows = [pscustomobject]@{ Mode = 'DockerDesktop'; Distro = ''; EngineName = 'Docker Desktop'; OsType = 'windows'; ServerVersion = '29.9.3'; Detail = '' }
            $result = Test-GwContainerRuntime -Runtime $windows
            $result.Status | Should -Be 'FAIL'
            $result.Fix | Should -Match 'Switch to Linux containers'
        }

        It 'fails when no runtime answers and passes the reason on' {
            $result = Test-GwContainerRuntime -Runtime $script:noRuntime
            $result.Status | Should -Be 'FAIL'
            $result.Detail | Should -Match 'cannot reach a running engine'
        }
    }

    Describe 'Test-GwPortAvailable' {
        It 'passes when nothing listens on the port' {
            $result = Test-GwPortAvailable -Port 4002 -Runtime $script:desktop -ContainerName 'ctr' -Required
            $result.Name | Should -Be 'Port4002'
            $result.Status | Should -Be 'PASS'
        }

        It 'passes when the listener is this kit''s own gateway container' {
            $script:listeners = @(4002)
            $script:dockerHandler = { Get-TestNativeResult -Output @('4004/tcp -> 127.0.0.1:4002') }
            $result = Test-GwPortAvailable -Port 4002 -Runtime $script:desktop -ContainerName 'ctr' -Required
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match 'this kit'
        }

        It 'fails for a required port taken by something else' {
            $script:listeners = @(4002)
            $script:dockerHandler = { Get-TestNativeResult -ExitCode 1 -Output @('Error: No such container: ctr') }
            $result = Test-GwPortAvailable -Port 4002 -Runtime $script:desktop -ContainerName 'ctr' -Required
            $result.Status | Should -Be 'FAIL'
            $result.Fix | Should -Match 'Get-NetTCPConnection -LocalPort 4002'
        }

        It 'warns for an optional port taken by something else' {
            $script:listeners = @(9810)
            $script:dockerHandler = { Get-TestNativeResult -ExitCode 1 -Output @('Error: No such container: ctr') }
            (Test-GwPortAvailable -Port 9810 -Runtime $script:desktop -ContainerName 'ctr').Status | Should -Be 'WARN'
        }

        It 'does not ask docker when no runtime was detected' {
            $script:listeners = @(4002)
            $script:dockerHandler = { throw 'docker must not be called' }
            (Test-GwPortAvailable -Port 4002 -Runtime $script:noRuntime -ContainerName 'ctr' -Required).Status | Should -Be 'FAIL'
        }
    }

    Describe 'Test-GwDiskSpace' {
        It 'passes with plenty of space' {
            $result = Test-GwDiskSpace -Path 'C:\BrokerSRE\gateway' -Name 'DiskSpace'
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match '200'
        }

        It 'warns below 10 GB' {
            $script:freeBytes = [long]6GB
            (Test-GwDiskSpace -Path 'C:\x' -Name 'DiskSpace').Status | Should -Be 'WARN'
        }

        It 'fails below 2 GB' {
            $script:freeBytes = [long]1GB
            (Test-GwDiskSpace -Path 'C:\x' -Name 'DiskSpace').Status | Should -Be 'FAIL'
        }

        It 'skips when the drive cannot be measured' {
            $script:freeBytes = $null
            (Test-GwDiskSpace -Path 'Q:\x' -Name 'DiskSpace').Status | Should -Be 'SKIP'
        }
    }

    Describe 'Test-GwSleepOnAc' {
        It 'passes when standby and hibernate are both off on AC power' {
            $script:powerCfgHandler = { Get-TestNativeResult -Output (Get-PowerCfgOutput -Ac '0x00000000' -Dc '0x00000384') }
            $result = Test-GwSleepOnAc
            $result.Name | Should -Be 'SleepOnAc'
            $result.Status | Should -Be 'PASS'
        }

        It 'fails when the computer sleeps on AC power and gives the minutes' {
            $script:powerCfgHandler = {
                param($a)
                if ($a -contains 'STANDBYIDLE') { return (Get-TestNativeResult -Output (Get-PowerCfgOutput -Ac '0x00000708' -Dc '0x00000384')) }
                Get-TestNativeResult -Output (Get-PowerCfgOutput -Ac '0x00000000' -Dc '0x00000000')
            }
            $result = Test-GwSleepOnAc
            $result.Status | Should -Be 'FAIL'
            $result.Detail | Should -Match 'sleeps after 30 minutes'
            $result.Fix | Should -Match 'harden\.ps1 -DisableSleep'
        }

        It 'fails when the computer hibernates on AC power' {
            $script:powerCfgHandler = {
                param($a)
                if ($a -contains 'HIBERNATEIDLE') { return (Get-TestNativeResult -Output (Get-PowerCfgOutput -Ac '0x00002a30' -Dc '0x00000000')) }
                Get-TestNativeResult -Output (Get-PowerCfgOutput -Ac '0x00000000' -Dc '0x00000000')
            }
            $result = Test-GwSleepOnAc
            $result.Status | Should -Be 'FAIL'
            $result.Detail | Should -Match 'hibernates after 180 minutes'
        }

        It 'reads the values from localised output by position, not by label' {
            $script:powerCfgHandler = {
                Get-TestNativeResult -Output @(
                    'GUID des Energieschemas: 381b4222-f694-41f0-9685-ff5bb260df2e  (Ausbalanciert)'
                    '      Minimale Einstellung: 0x00000000'
                    '      Maximale Einstellung: 0xffffffff'
                    '      Schrittweite: 0x00000001'
                    '    Index der aktuellen Wechselstromeinstellung: 0x00000e10'
                    '    Index der aktuellen Gleichstromeinstellung: 0x00000000'
                )
            }
            (Test-GwSleepOnAc).Detail | Should -Match 'sleeps after 60 minutes'
        }

        It 'skips when powercfg fails for both settings' {
            (Test-GwSleepOnAc).Status | Should -Be 'SKIP'
        }

        It 'warns, never passes, when standby is off but hibernate cannot be read' {
            $script:powerCfgHandler = {
                param($a)
                if ($a -contains 'STANDBYIDLE') { return (Get-TestNativeResult -Output (Get-PowerCfgOutput -Ac '0x00000000' -Dc '0x00000000')) }
                Get-TestNativeResult -ExitCode 1 -Output @('The power scheme, subgroup or setting specified does not exist.')
            }
            (Test-GwSleepOnAc).Status | Should -Be 'WARN'
        }

        It 'queries the current scheme with the documented aliases' {
            $script:calls = New-Object System.Collections.Generic.List[string]
            $script:powerCfgHandler = { param($a) $script:calls.Add(($a -join ' ')); Get-TestNativeResult -Output (Get-PowerCfgOutput -Ac '0x00000000' -Dc '0x00000000') }
            Test-GwSleepOnAc | Out-Null
            $script:calls | Should -Be @('/query SCHEME_CURRENT SUB_SLEEP STANDBYIDLE', '/query SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE')
        }
    }

    Describe 'Test-GwUpdateActiveWindow' {
        It 'passes for manual active hours and shows the window' {
            $script:registry["$script:uxKey|ActiveHoursStart"] = 6
            $script:registry["$script:uxKey|ActiveHoursEnd"] = 23
            $script:registry["$script:uxKey|SmartActiveHoursState"] = 0
            $result = Test-GwUpdateActiveWindow
            $result.Name | Should -Be 'UpdateActiveHours'
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match '06:00 to 23:00'
            $result.Detail | Should -Match '17 hours'
        }

        It 'computes a window that crosses midnight' {
            $script:registry["$script:uxKey|ActiveHoursStart"] = 20
            $script:registry["$script:uxKey|ActiveHoursEnd"] = 8
            (Test-GwUpdateActiveWindow).Detail | Should -Match '20:00 to 08:00 \(12 hours\)'
        }

        It 'prefers the policy values when the policy is on' {
            $script:registry["$script:wuPolicyKey|SetActiveHours"] = 1
            $script:registry["$script:wuPolicyKey|ActiveHoursStart"] = 3
            $script:registry["$script:wuPolicyKey|ActiveHoursEnd"] = 21
            $script:registry["$script:uxKey|ActiveHoursStart"] = 8
            $script:registry["$script:uxKey|ActiveHoursEnd"] = 17
            $result = Test-GwUpdateActiveWindow
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match 'policy'
            $result.Detail | Should -Match '03:00 to 21:00'
        }

        It 'warns when Windows adjusts the hours automatically' {
            $script:registry["$script:uxKey|ActiveHoursStart"] = 8
            $script:registry["$script:uxKey|ActiveHoursEnd"] = 17
            $script:registry["$script:uxKey|SmartActiveHoursState"] = 1
            $result = Test-GwUpdateActiveWindow
            $result.Status | Should -Be 'WARN'
            $result.Fix | Should -Match 'harden\.ps1 -SetActiveHours'
        }

        It 'warns when no active hours are stored' {
            $result = Test-GwUpdateActiveWindow
            $result.Status | Should -Be 'WARN'
            $result.Detail | Should -Match '8'
        }
    }

    Describe 'Test-GwUpdatePendingReboot' {
        It 'passes when no restart is pending' {
            $result = Test-GwUpdatePendingReboot
            $result.Name | Should -Be 'UpdatePendingReboot'
            $result.Status | Should -Be 'PASS'
        }

        It 'warns when Windows Update wants a restart' {
            $script:registryKeys = @($script:rebootKeyUpdate)
            $result = Test-GwUpdatePendingReboot
            $result.Status | Should -Be 'WARN'
            $result.Detail | Should -Match 'Windows Update'
        }

        It 'warns when component servicing wants a restart' {
            $script:registryKeys = @($script:rebootKeyServicing)
            (Test-GwUpdatePendingReboot).Status | Should -Be 'WARN'
        }
    }

    Describe 'Test-GwUpdateAutoRestart' {
        It 'warns on a default computer: Windows restarts by itself outside active hours' {
            $result = Test-GwUpdateAutoRestart
            $result.Name | Should -Be 'UpdateAutoRestart'
            $result.Status | Should -Be 'WARN'
            $result.Detail | Should -Match '2FA'
        }

        It 'passes when the no-auto-restart-with-logged-on-users policy is effective' {
            $script:registry["$script:auPolicyKey|AUOptions"] = 4
            $script:registry["$script:auPolicyKey|NoAutoRebootWithLoggedOnUsers"] = 1
            (Test-GwUpdateAutoRestart).Status | Should -Be 'PASS'
        }

        It 'still warns when that policy is set without scheduled installation, where Microsoft says it does not apply' {
            $script:registry["$script:auPolicyKey|NoAutoRebootWithLoggedOnUsers"] = 1
            (Test-GwUpdateAutoRestart).Status | Should -Be 'WARN'
        }

        It 'passes when updates only install on request' {
            $script:registry["$script:auPolicyKey|AUOptions"] = 2
            (Test-GwUpdateAutoRestart).Status | Should -Be 'PASS'
        }

        It 'warns when automatic updates are disabled altogether' {
            $script:registry["$script:auPolicyKey|NoAutoUpdate"] = 1
            $result = Test-GwUpdateAutoRestart
            $result.Status | Should -Be 'WARN'
            $result.Detail | Should -Match 'security'
        }
    }

    Describe 'Test-GwStartAtBoot' {
        BeforeEach {
            $script:settingsPath = Join-Path $TestDrive ('settings-' + [guid]::NewGuid().ToString('N') + '.json')
            $script:gatewayPath = Join-Path $TestDrive 'gw'
            function Write-DockerSetting {
                param([string]$Json)
                [System.IO.File]::WriteAllText($script:settingsPath, $Json)
            }
            function Use-KitTask {
                param([string[]]$Present)
                $script:presentTasks = $Present
                $script:schTasksHandler = {
                    param($a)
                    $taskName = $a[2]
                    if ($script:presentTasks -contains $taskName) { return (Get-TestNativeResult -Output @('<Task/>')) }
                    Get-TestNativeResult -ExitCode 1 -Output @('ERROR: The system cannot find the file specified.')
                }
            }
            Use-KitTask -Present @()
        }

        It 'warns for Docker Desktop that starts at sign-in when nobody signs in automatically' {
            Write-DockerSetting -Json '{"AutoStart": true}'
            $script:registry["$script:winlogonKey|AutoAdminLogon"] = '0'
            $result = Test-GwStartAtBoot -Runtime $script:desktop -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath
            $result.Name | Should -Be 'StartAtBoot'
            $result.Status | Should -Be 'WARN'
            $result.Detail | Should -Match 'Mode: Docker Desktop'
            $result.Detail | Should -Match 'until someone signs in'
        }

        It 'passes for Docker Desktop with start at sign-in and Windows auto-logon' {
            Write-DockerSetting -Json '{"AutoStart": true}'
            $script:registry["$script:winlogonKey|AutoAdminLogon"] = '1'
            $result = Test-GwStartAtBoot -Runtime $script:desktop -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match '2FA'
        }

        It 'warns when Docker Desktop does not start at sign-in' {
            Write-DockerSetting -Json '{"AutoStart": false}'
            $script:registry["$script:winlogonKey|AutoAdminLogon"] = '1'
            $result = Test-GwStartAtBoot -Runtime $script:desktop -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath
            $result.Status | Should -Be 'WARN'
            $result.Fix | Should -Match 'Start Docker Desktop when you sign in'
        }

        It 'treats a settings file without the key as the documented default: off' {
            Write-DockerSetting -Json '{"SettingsVersion": 48}'
            (Test-GwStartAtBoot -Runtime $script:desktop -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath).Status | Should -Be 'WARN'
        }

        It 'falls back to the Run key when the settings file is missing' {
            $script:registry["$script:runKey|Docker Desktop"] = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
            $script:registry["$script:winlogonKey|AutoAdminLogon"] = '1'
            (Test-GwStartAtBoot -Runtime $script:desktop -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath).Status | Should -Be 'PASS'
        }

        It 'skips for Docker Desktop when neither the settings file nor the Run key can tell' {
            (Test-GwStartAtBoot -Runtime $script:desktop -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath).Status | Should -Be 'SKIP'
        }

        It 'passes for Docker Engine in WSL with the boot task and reports the mode' {
            Use-KitTask -Present @('\BrokerSRE\Gateway paper - start at boot')
            $result = Test-GwStartAtBoot -Runtime $script:engine -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match 'Mode: Docker Engine in WSL'
        }

        It 'passes for Docker Engine in WSL with the sign-in task and auto-logon' {
            Use-KitTask -Present @('\BrokerSRE\Gateway paper - start after sign-in')
            $script:registry["$script:winlogonKey|AutoAdminLogon"] = '1'
            (Test-GwStartAtBoot -Runtime $script:engine -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath).Status | Should -Be 'PASS'
        }

        It 'warns for Docker Engine in WSL with the sign-in task but no auto-logon' {
            Use-KitTask -Present @('\BrokerSRE\Gateway paper - start after sign-in')
            (Test-GwStartAtBoot -Runtime $script:engine -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath).Status | Should -Be 'WARN'
        }

        It 'warns for Docker Engine in WSL without any start task' {
            $result = Test-GwStartAtBoot -Runtime $script:engine -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath
            $result.Status | Should -Be 'WARN'
            $result.Fix | Should -Match 'harden\.ps1 -StartAtBoot WslEngine'
        }

        It 'skips when no runtime was detected' {
            (Test-GwStartAtBoot -Runtime $script:noRuntime -Path $script:gatewayPath -TradingMode 'paper' -DockerSettingsPath $script:settingsPath).Status | Should -Be 'SKIP'
        }

        It 'queries the task by its full name with schtasks /Query /TN' {
            $script:queries = New-Object System.Collections.Generic.List[string]
            $script:schTasksHandler = { param($a) $script:queries.Add(($a -join '|')); Get-TestNativeResult -ExitCode 1 -Output @('ERROR') }
            Test-GwStartAtBoot -Runtime $script:engine -Path $script:gatewayPath -TradingMode 'live' -DockerSettingsPath $script:settingsPath | Out-Null
            $script:queries | Should -Contain '/Query|/TN|\BrokerSRE\Gateway live - start at boot|/XML'
            $script:queries | Should -Contain '/Query|/TN|\BrokerSRE\Gateway live - start after sign-in|/XML'
        }
    }

    Describe '.wslconfig checks' {
        BeforeEach {
            $script:wslConfigPath = Join-Path $TestDrive ('wslconfig-' + [guid]::NewGuid().ToString('N'))
            function Write-WslConfig {
                param([string]$Text)
                [System.IO.File]::WriteAllText($script:wslConfigPath, $Text)
            }
        }

        Context 'Test-GwWslNetworking' {
            It 'passes when no file exists: NAT is the default' {
                $result = Test-GwWslNetworking -WslConfigPath $script:wslConfigPath
                $result.Name | Should -Be 'WslNetworkingMode'
                $result.Status | Should -Be 'PASS'
                $result.Detail | Should -Match 'NAT'
            }

            It 'passes for networkingMode=nat in any casing' {
                Write-WslConfig -Text "[wsl2]`nnetworkingMode=NAT`n"
                (Test-GwWslNetworking -WslConfigPath $script:wslConfigPath).Status | Should -Be 'PASS'
            }

            It 'warns for mirrored networking, which breaks published ports' {
                Write-WslConfig -Text "[wsl2]`nnetworkingMode = Mirrored`n"
                $result = Test-GwWslNetworking -WslConfigPath $script:wslConfigPath
                $result.Status | Should -Be 'WARN'
                $result.Detail | Should -Match 'published ports'
                $result.Fix | Should -Match 'harden\.ps1 -WslConfig'
            }

            It 'fails for networkingMode=none: the VM has no network' {
                Write-WslConfig -Text "[wsl2]`nnetworkingMode=none`n"
                (Test-GwWslNetworking -WslConfigPath $script:wslConfigPath).Status | Should -Be 'FAIL'
            }

            It 'warns for any other mode' {
                Write-WslConfig -Text "[wsl2]`nnetworkingMode=bridged`n"
                (Test-GwWslNetworking -WslConfigPath $script:wslConfigPath).Status | Should -Be 'WARN'
            }
        }

        Context 'Test-GwWslIdle' {
            It 'passes for Docker Desktop, which keeps its distribution running, and reports vmIdleTimeout' {
                Write-WslConfig -Text "[wsl2]`nvmIdleTimeout=120000`n"
                $result = Test-GwWslIdle -WslConfigPath $script:wslConfigPath -Runtime $script:desktop -TradingMode 'paper'
                $result.Name | Should -Be 'WslIdleShutdown'
                $result.Status | Should -Be 'PASS'
                $result.Detail | Should -Match 'vmIdleTimeout=120000'
            }

            It 'reports the documented defaults when nothing is set' {
                $result = Test-GwWslIdle -WslConfigPath $script:wslConfigPath -Runtime $script:desktop -TradingMode 'paper'
                $result.Detail | Should -Match 'vmIdleTimeout=60000 \(default\)'
                $result.Detail | Should -Match 'instanceIdleTimeout=15000 \(default\)'
            }

            It 'warns for Docker Engine in WSL when nothing keeps the distribution alive' {
                $result = Test-GwWslIdle -WslConfigPath $script:wslConfigPath -Runtime $script:engine -TradingMode 'paper'
                $result.Status | Should -Be 'WARN'
                $result.Detail | Should -Match 'shuts down'
            }

            It 'passes for Docker Engine in WSL when instanceIdleTimeout is -1' {
                Write-WslConfig -Text "[general]`ninstanceIdleTimeout=-1`n"
                (Test-GwWslIdle -WslConfigPath $script:wslConfigPath -Runtime $script:engine -TradingMode 'paper').Status | Should -Be 'PASS'
            }

            It 'passes for Docker Engine in WSL when a kit start task keeps a session open' {
                $script:schTasksHandler = {
                    param($a)
                    if ($a[2] -eq '\BrokerSRE\Gateway paper - start at boot') { return (Get-TestNativeResult -Output @('<Task/>')) }
                    Get-TestNativeResult -ExitCode 1 -Output @('ERROR')
                }
                (Test-GwWslIdle -WslConfigPath $script:wslConfigPath -Runtime $script:engine -TradingMode 'paper').Status | Should -Be 'PASS'
            }

            It 'skips when no runtime was detected' {
                (Test-GwWslIdle -WslConfigPath $script:wslConfigPath -Runtime $script:noRuntime -TradingMode 'paper').Status | Should -Be 'SKIP'
            }
        }

        Context 'Test-GwWslMemory' {
            It 'passes with the default and names it' {
                $result = Test-GwWslMemory -WslConfigPath $script:wslConfigPath
                $result.Name | Should -Be 'WslMemory'
                $result.Status | Should -Be 'PASS'
                $result.Detail | Should -Match '50%'
                $result.Detail | Should -Match 'autoMemoryReclaim=dropCache \(default\)'
            }

            It 'passes for 4GB and reports autoMemoryReclaim from the experimental section' {
                Write-WslConfig -Text "[wsl2]`nmemory=4GB`n[experimental]`nautoMemoryReclaim=gradual`n"
                $result = Test-GwWslMemory -WslConfigPath $script:wslConfigPath
                $result.Status | Should -Be 'PASS'
                $result.Detail | Should -Match 'memory=4GB'
                $result.Detail | Should -Match 'autoMemoryReclaim=gradual'
            }

            It 'warns below 2 GB' {
                Write-WslConfig -Text "[wsl2]`nmemory=1GB`n"
                (Test-GwWslMemory -WslConfigPath $script:wslConfigPath).Status | Should -Be 'WARN'
            }

            It 'warns for a memory value it cannot read' {
                Write-WslConfig -Text "[wsl2]`nmemory=plenty`n"
                (Test-GwWslMemory -WslConfigPath $script:wslConfigPath).Status | Should -Be 'WARN'
            }
        }
    }

    Describe 'Docker Desktop checks' {
        BeforeEach {
            $script:settingsPath = Join-Path $TestDrive ('dd-' + [guid]::NewGuid().ToString('N') + '.json')
        }

        It 'reports the Docker Desktop version' {
            $script:dockerHandler = { Get-TestNativeResult -Output @('Docker Desktop 4.99.0 (245822)') }
            $result = Test-GwDockerDesktopVersion -Runtime $script:desktop
            $result.Name | Should -Be 'DockerDesktopVersion'
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match '4\.99\.0'
        }

        It 'skips the version when docker does not answer' {
            (Test-GwDockerDesktopVersion -Runtime $script:desktop).Status | Should -Be 'SKIP'
        }

        It 'skips the version when Docker Desktop is not the runtime' {
            (Test-GwDockerDesktopVersion -Runtime $script:engine).Status | Should -Be 'SKIP'
        }

        It 'warns when Docker Desktop downloads updates automatically' {
            [System.IO.File]::WriteAllText($script:settingsPath, '{"AutoDownloadUpdates": true}')
            $result = Test-GwDockerDesktopUpdate -Runtime $script:desktop -DockerSettingsPath $script:settingsPath
            $result.Name | Should -Be 'DockerDesktopAutoUpdate'
            $result.Status | Should -Be 'WARN'
        }

        It 'passes when automatic download is off' {
            [System.IO.File]::WriteAllText($script:settingsPath, '{"AutoDownloadUpdates": false}')
            (Test-GwDockerDesktopUpdate -Runtime $script:desktop -DockerSettingsPath $script:settingsPath).Status | Should -Be 'PASS'
        }

        It 'skips, never passes, when the setting is not recorded' {
            [System.IO.File]::WriteAllText($script:settingsPath, '{"AutoStart": true}')
            $result = Test-GwDockerDesktopUpdate -Runtime $script:desktop -DockerSettingsPath $script:settingsPath
            $result.Status | Should -Be 'SKIP'
            $result.Fix | Should -Match 'Software updates'
        }

        It 'skips when the settings file is missing or Docker Desktop is not in use' {
            (Test-GwDockerDesktopUpdate -Runtime $script:desktop -DockerSettingsPath $script:settingsPath).Status | Should -Be 'SKIP'
            (Test-GwDockerDesktopUpdate -Runtime $script:engine -DockerSettingsPath $script:settingsPath).Status | Should -Be 'SKIP'
        }

        It 'states the licence terms neutrally and cannot measure them: SKIP for Docker Desktop' {
            $result = Test-GwDockerDesktopLicence -Runtime $script:desktop
            $result.Name | Should -Be 'DockerDesktopLicence'
            $result.Status | Should -Be 'SKIP'
            $result.Detail | Should -Match 'fewer than 250 employees'
            $result.Detail | Should -Match 'USD 10 million'
            $result.Fix | Should -Match 'Docker Engine inside WSL'
        }

        It 'passes the licence check when Docker Desktop is not the runtime' {
            (Test-GwDockerDesktopLicence -Runtime $script:engine).Status | Should -Be 'PASS'
        }
    }

    Describe 'Test-GwFirewallExposure' {
        It 'passes when no rule and no port proxy names the ports' {
            $result = Test-GwFirewallExposure
            $result.Name | Should -Be 'FirewallExposure'
            $result.Status | Should -Be 'PASS'
        }

        It 'warns for an allow rule that names an API port for any program' {
            $script:firewallRules = @([pscustomobject]@{
                    Name = 'r1'; DisplayName = 'IB API'; Profile = 'Any'; LocalPort = [string[]]@('4001-4002'); RemoteAddress = [string[]]@('Any'); Program = 'Any'
                })
            $result = Test-GwFirewallExposure
            $result.Status | Should -Be 'WARN'
            $result.Detail | Should -Match 'IB API'
            $result.Fix | Should -Match 'harden\.ps1 -FirewallLoopbackOnly'
        }

        It 'ignores a rule that is tied to an unrelated program' {
            $script:firewallRules = @([pscustomobject]@{
                    Name = 'r2'; DisplayName = 'Video app'; Profile = 'Any'; LocalPort = [string[]]@('7200-17210'); RemoteAddress = [string[]]@('Any')
                    Program = 'C:\Program Files\Video\app.exe'
                })
            (Test-GwFirewallExposure).Status | Should -Be 'PASS'
        }

        It 'warns for a rule tied to the Docker backend' {
            $script:firewallRules = @([pscustomobject]@{
                    Name = 'r3'; DisplayName = 'Docker Desktop Backend'; Profile = 'Private'; LocalPort = [string[]]@('4002'); RemoteAddress = [string[]]@('LocalSubnet')
                    Program = 'C:\Program Files\Docker\Docker\resources\com.docker.backend.exe'
                })
            (Test-GwFirewallExposure).Status | Should -Be 'WARN'
        }

        It 'fails for a port proxy that publishes an API port on all addresses' {
            $script:registryValues[$script:portProxyKey] = @{ '0.0.0.0/4002' = '172.20.1.2/4002' }
            $result = Test-GwFirewallExposure
            $result.Status | Should -Be 'FAIL'
            $result.Detail | Should -Match 'port proxy'
            $result.Fix | Should -Match 'netsh interface portproxy delete'
        }

        It 'accepts a port proxy that listens on loopback only or on another port' {
            $script:registryValues[$script:portProxyKey] = @{ '127.0.0.1/4002' = '172.20.1.2/4002'; '0.0.0.0/8080' = '172.20.1.2/80' }
            (Test-GwFirewallExposure).Status | Should -Be 'PASS'
        }

        It 'skips when the firewall cannot be queried' {
            $script:firewallThrows = $true
            (Test-GwFirewallExposure).Status | Should -Be 'SKIP'
        }
    }

    Describe 'Test-GwHostClock' {
        It 'passes for a small offset' {
            $script:w32tmHandler = {
                Get-TestNativeResult -Output @(
                    'Tracking time.windows.com [20.1.2.3:123].', 'Collecting 1 samples.', 'The current time is 11/12/2026 7:37:58 AM.', '07:37:58, +00.0370085s'
                )
            }
            $result = Test-GwHostClock
            $result.Name | Should -Be 'HostClock'
            $result.Status | Should -Be 'PASS'
            $result.Detail | Should -Match '0\.04'
        }

        It 'warns above one second' {
            $script:w32tmHandler = { Get-TestNativeResult -Output @('07:37:58, -01.5000000s') }
            $result = Test-GwHostClock
            $result.Status | Should -Be 'WARN'
            $result.Fix | Should -Match 'w32tm /resync'
        }

        It 'fails above five seconds' {
            $script:w32tmHandler = { Get-TestNativeResult -Output @('07:37:58, +07.2500000s') }
            (Test-GwHostClock).Status | Should -Be 'FAIL'
        }

        It 'treats exactly one second as a pass and exactly five as a warning' {
            $script:w32tmHandler = { Get-TestNativeResult -Output @('07:37:58, +01.0000000s') }
            (Test-GwHostClock).Status | Should -Be 'PASS'
            $script:w32tmHandler = { Get-TestNativeResult -Output @('07:37:58, +05.0000000s') }
            (Test-GwHostClock).Status | Should -Be 'WARN'
        }

        It 'reads a decimal comma' {
            $script:w32tmHandler = { Get-TestNativeResult -Output @('07:37:58, +02,5000000s') }
            (Test-GwHostClock).Status | Should -Be 'WARN'
        }

        It 'skips, with the error code, when the time server does not answer' {
            $script:w32tmHandler = { Get-TestNativeResult -Output @('Tracking time.windows.com [20.1.2.3:123].', '07:37:58, error: 0x800705B4') }
            $result = Test-GwHostClock
            $result.Status | Should -Be 'SKIP'
            $result.Detail | Should -Match '0x800705B4'
        }

        It 'skips when w32tm fails' {
            (Test-GwHostClock).Status | Should -Be 'SKIP'
        }

        It 'takes one sample from time.windows.com' {
            $script:seen = ''
            $script:w32tmHandler = { param($a) $script:seen = ($a -join ' '); Get-TestNativeResult -Output @('07:37:58, +00.0100000s') }
            Test-GwHostClock | Out-Null
            $script:seen | Should -Be '/stripchart /computer:time.windows.com /samples:1 /dataonly'
        }
    }

    Describe 'Test-GwVmClock' {
        BeforeAll {
            function Get-AdjtimexResult {
                param([double]$VmEpoch, [datetime]$ReceivedUtc, [int]$Status = 0, [switch]$Nano)
                $seconds = [long][Math]::Floor($VmEpoch)
                $fraction = $VmEpoch - $seconds
                $sub = [long][Math]::Round($fraction * 1000000)
                if ($Nano) { $sub = [long][Math]::Round($fraction * 1000000000) }
                $lines = @(
                    '    mode:         0'
                    ('    status:       {0} ()' -f $Status)
                    ('    time.tv_sec:  {0}' -f $seconds)
                    ('    time.tv_usec: {0}' -f $sub)
                    '    return value: 0 (clock synchronized)'
                )
                return (Get-TestNativeResult -Output $lines -ReceivedUtc ([datetime[]]@($lines | ForEach-Object { $ReceivedUtc })))
            }
            $script:epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            $script:received = New-Object DateTime(2026, 11, 12, 1, 0, 0, [DateTimeKind]::Utc)
            $script:receivedEpoch = ($script:received - $script:epoch).TotalSeconds
        }

        It 'passes when the container clock matches the host clock' {
            $script:dockerHandler = { Get-AdjtimexResult -VmEpoch ($script:receivedEpoch - 0.03) -ReceivedUtc $script:received }
            $result = Test-GwVmClock -Runtime $script:desktop
            $result.Name | Should -Be 'ContainerClock'
            $result.Status | Should -Be 'PASS'
        }

        It 'warns when the container clock is more than one second off' {
            $script:dockerHandler = { Get-AdjtimexResult -VmEpoch ($script:receivedEpoch - 2.5) -ReceivedUtc $script:received }
            $result = Test-GwVmClock -Runtime $script:desktop
            $result.Status | Should -Be 'WARN'
            $result.Detail | Should -Match '2\.5'
            $result.Detail | Should -Match 'behind'
        }

        It 'fails when the container clock is more than five seconds off, as after a resume from sleep' {
            $script:dockerHandler = { Get-AdjtimexResult -VmEpoch ($script:receivedEpoch - 3600) -ReceivedUtc $script:received }
            $result = Test-GwVmClock -Runtime $script:desktop
            $result.Status | Should -Be 'FAIL'
            $result.Fix | Should -Match 'harden\.ps1 -ResumeClockFix'
        }

        It 'reports a clock that runs ahead' {
            $script:dockerHandler = { Get-AdjtimexResult -VmEpoch ($script:receivedEpoch + 8) -ReceivedUtc $script:received }
            $result = Test-GwVmClock -Runtime $script:desktop
            $result.Status | Should -Be 'FAIL'
            $result.Detail | Should -Match 'ahead'
        }

        It 'reads nanoseconds when the kernel reports the NANO status flag' {
            $script:dockerHandler = { Get-AdjtimexResult -VmEpoch ($script:receivedEpoch - 0.5) -ReceivedUtc $script:received -Status 8193 -Nano }
            (Test-GwVmClock -Runtime $script:desktop).Status | Should -Be 'PASS'
        }

        It 'skips when docker cannot run the probe' {
            $script:dockerHandler = { Get-TestNativeResult -ExitCode 125 -Output @('docker: Error response from daemon: pull access denied') }
            $result = Test-GwVmClock -Runtime $script:desktop
            $result.Status | Should -Be 'SKIP'
        }

        It 'skips when the output has no timestamp' {
            $script:dockerHandler = { Get-TestNativeResult -Output @('something else') }
            (Test-GwVmClock -Runtime $script:desktop).Status | Should -Be 'SKIP'
        }

        It 'skips when no runtime was detected' {
            (Test-GwVmClock -Runtime $script:noRuntime).Status | Should -Be 'SKIP'
        }

        It 'runs a pinned, unprivileged, network-less, read-only container named winkit-clock-*' {
            $script:seen = @()
            $script:dockerHandler = { param($a) $script:seen = $a; Get-AdjtimexResult -VmEpoch $script:receivedEpoch -ReceivedUtc $script:received }
            Test-GwVmClock -Runtime $script:desktop | Out-Null
            $joined = $script:seen -join ' '
            $expected = '^run --rm --name winkit-clock-[0-9a-f]{8} --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true ' +
            '--user 65534:65534 busybox:1\.37\.0@sha256:[0-9a-f]{64} adjtimex$'
            $joined | Should -Match $expected
        }
    }

    Describe 'Compose file checks' {
        BeforeAll {
            function Get-ComposeJson {
                param([string]$HostIp = '127.0.0.1', [string]$Grace = '1m30s', [string]$ReadOnly = 'true', [switch]$NoHostIp)
                $port = '{"mode":"ingress","host_ip":"' + $HostIp + '","target":4004,"published":"4002","protocol":"tcp"}'
                if ($NoHostIp) { $port = '{"mode":"ingress","target":4004,"published":"4002","protocol":"tcp"}' }
                # PowerShell variable names are case-insensitive: do not reuse the parameter name.
                $graceJson = ''
                if ($Grace.Length -gt 0) { $graceJson = '"stop_grace_period":"' + $Grace + '",' }
                return ('{"name":"brokersre-gateway-paper","services":{"ib-gateway":{' + $graceJson + '"read_only":' + $ReadOnly + ',"ports":[' + $port + ']}}}')
            }
        }

        BeforeEach {
            $script:composeFolder = Join-Path $TestDrive ('compose-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:composeFolder | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $script:composeFolder 'compose.yaml'), "services: {}`n")
        }

        It 'Get-GwComposeConfig parses docker compose config --format json' {
            $script:seen = ''
            $script:dockerHandler = { param($a) $script:seen = ($a -join '|'); Get-TestNativeResult -Output @((Get-ComposeJson)) }
            $loaded = Get-GwComposeConfig -Runtime $script:desktop -Path $script:composeFolder
            $loaded.Config.name | Should -Be 'brokersre-gateway-paper'
            $loaded.Reason | Should -Be ''
            $script:seen | Should -Be ('compose|-f|' + (Join-Path $script:composeFolder 'compose.yaml') + '|config|--format|json')
        }

        It 'Get-GwComposeConfig reports a missing compose file without calling docker' {
            $script:dockerHandler = { throw 'docker must not be called' }
            $loaded = Get-GwComposeConfig -Runtime $script:desktop -Path (Join-Path $TestDrive 'no-folder')
            $loaded.Config | Should -BeNullOrEmpty
            $loaded.Reason | Should -Match 'compose\.yaml'
        }

        It 'Get-GwComposeConfig reports a compose error' {
            $script:dockerHandler = { Get-TestNativeResult -ExitCode 15 -Output @('validating compose.yaml: services.ib-gateway Additional property x is not allowed') }
            $loaded = Get-GwComposeConfig -Runtime $script:desktop -Path $script:composeFolder
            $loaded.Config | Should -BeNullOrEmpty
            $loaded.Reason | Should -Match 'not allowed'
        }

        It 'port binding passes for loopback' {
            $config = (Get-ComposeJson) | ConvertFrom-Json
            $result = Test-GwComposePortBinding -Config $config -Reason ''
            $result.Name | Should -Be 'ComposePortBinding'
            $result.Status | Should -Be 'PASS'
        }

        It 'port binding fails for <case>' -ForEach @(
            @{ case = '0.0.0.0'; json = { Get-ComposeJson -HostIp '0.0.0.0' } }
            @{ case = 'a LAN address'; json = { Get-ComposeJson -HostIp '192.168.1.10' } }
            @{ case = 'no host address at all'; json = { Get-ComposeJson -NoHostIp } }
        ) {
            $config = (& $json) | ConvertFrom-Json
            $result = Test-GwComposePortBinding -Config $config -Reason ''
            $result.Status | Should -Be 'FAIL'
            $result.Detail | Should -Match '4002'
        }

        It 'stop grace passes at 90 s and at exactly 60 s' {
            (Test-GwComposeStopGrace -Config ((Get-ComposeJson) | ConvertFrom-Json) -Reason '').Status | Should -Be 'PASS'
            (Test-GwComposeStopGrace -Config ((Get-ComposeJson -Grace '1m0s') | ConvertFrom-Json) -Reason '').Status | Should -Be 'PASS'
        }

        It 'stop grace fails below 60 s and when it is not set' {
            $short = Test-GwComposeStopGrace -Config ((Get-ComposeJson -Grace '30s') | ConvertFrom-Json) -Reason ''
            $short.Name | Should -Be 'ComposeStopGrace'
            $short.Status | Should -Be 'FAIL'
            (Test-GwComposeStopGrace -Config ((Get-ComposeJson -Grace '') | ConvertFrom-Json) -Reason '').Status | Should -Be 'FAIL'
        }

        It 'read-only passes when set and warns when not' {
            $pass = Test-GwComposeReadOnly -Config ((Get-ComposeJson) | ConvertFrom-Json) -Reason ''
            $pass.Name | Should -Be 'ComposeReadOnly'
            $pass.Status | Should -Be 'PASS'
            (Test-GwComposeReadOnly -Config ((Get-ComposeJson -ReadOnly 'false') | ConvertFrom-Json) -Reason '').Status | Should -Be 'WARN'
        }

        It 'every compose check skips with the reason when the file could not be loaded' {
            foreach ($result in @(
                    (Test-GwComposePortBinding -Config $null -Reason 'compose.yaml not found')
                    (Test-GwComposeStopGrace -Config $null -Reason 'compose.yaml not found')
                    (Test-GwComposeReadOnly -Config $null -Reason 'compose.yaml not found')
                )) {
                $result.Status | Should -Be 'SKIP'
                $result.Detail | Should -Match 'compose\.yaml not found'
            }
        }
    }

    Describe 'Test-GwFolderAccess' {
        It 'passes for a folder only the operator, SYSTEM and Administrators can write' {
            $folder = Join-Path $TestDrive ('access-pass-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $folder | Out-Null
            Protect-GwSecretFolder -Path $folder -IncludeSystem -Confirm:$false
            $result = Test-GwFolderAccess -Path $folder -Name 'GatewayFolderAccess' -Fix 'fix text'
            $result.Name | Should -Be 'GatewayFolderAccess'
            $result.Status | Should -Be 'PASS'
        }

        It 'warns, naming the account, when another principal may write there' {
            $folder = Join-Path $TestDrive ('access-warn-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $folder | Out-Null
            Add-TestAccessRule -Path $folder -Sid 'S-1-5-11' -Rights 'Modify'
            $result = Test-GwFolderAccess -Path $folder -Name 'KitFolderAccess' -Fix 'fix text' -Risk 'They could run code as you.'
            $result.Status | Should -Be 'WARN'
            $result.Detail | Should -Match 'Authenticated Users'
            $result.Detail | Should -Match 'They could run code as you\.$'
            $result.Fix | Should -Be 'fix text'
        }

        It 'does not count read-only access as a problem' {
            $folder = Join-Path $TestDrive ('access-read-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $folder | Out-Null
            Protect-GwSecretFolder -Path $folder -IncludeSystem -Confirm:$false
            Add-TestAccessRule -Path $folder -Sid 'S-1-5-32-545' -Rights 'ReadAndExecute'
            (Test-GwFolderAccess -Path $folder -Name 'KitFolderAccess' -Fix 'x').Status | Should -Be 'PASS'
        }

        It 'skips when the folder does not exist' {
            (Test-GwFolderAccess -Path (Join-Path $TestDrive 'access-none') -Name 'GatewayFolderAccess' -Fix 'x').Status | Should -Be 'SKIP'
        }
    }

    Describe 'Invoke-GwCheckSafely' {
        It 'returns the check result unchanged' {
            $result = Invoke-GwCheckSafely -Name 'Demo' -Check { New-GwCheckResult -Name 'Demo' -Status 'PASS' -Detail 'fine' }
            $result.Status | Should -Be 'PASS'
        }

        It 'turns an exception into SKIP with the reason, never into PASS' {
            $result = Invoke-GwCheckSafely -Name 'Demo' -Check { throw 'the probe exploded' }
            $result.Name | Should -Be 'Demo'
            $result.Status | Should -Be 'SKIP'
            $result.Detail | Should -Match 'the probe exploded'
        }

        It 'turns an empty result into SKIP' {
            (Invoke-GwCheckSafely -Name 'Demo' -Check { }).Status | Should -Be 'SKIP'
        }
    }

    Describe 'Get-GwDoctorResult' {
        BeforeEach {
            $script:folder = Join-Path $TestDrive ('doctor-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:folder | Out-Null
            $script:dockerHandler = { Get-TestNativeResult -ExitCode 1 -Output @('error during connect') }
        }

        It 'returns one result per check, each with a valid status, and no duplicates' {
            $results = @(Get-GwDoctorResult -Path $script:folder -Runtime $script:noRuntime -WslConfigPath (Join-Path $TestDrive 'none') -DockerSettingsPath (Join-Path $TestDrive 'none.json'))
            $results.Count | Should -BeGreaterThan 20
            foreach ($result in $results) { $result.Status | Should -BeIn @('PASS', 'WARN', 'FAIL', 'SKIP') }
            @($results.Name | Sort-Object -Unique).Count | Should -Be $results.Count
        }

        It 'covers every area the kit promises to check' {
            $names = @(Get-GwDoctorResult -Path $script:folder -Runtime $script:noRuntime -WslConfigPath (Join-Path $TestDrive 'none') -DockerSettingsPath (Join-Path $TestDrive 'none.json')).Name
            foreach ($expected in @(
                    'WindowsBuild', 'ContainerRuntime', 'SleepOnAc', 'UpdateActiveHours', 'UpdatePendingReboot', 'UpdateAutoRestart', 'StartAtBoot',
                    'WslVersion', 'WslNetworkingMode', 'WslIdleShutdown', 'WslMemory', 'DockerDesktopVersion', 'DockerDesktopAutoUpdate',
                    'DockerDesktopLicence', 'FirewallExposure', 'HostClock', 'ContainerClock', 'DiskSpace', 'SecretEncodingUsername',
                    'SecretEncodingPassword', 'SecretFolderAccess', 'ComposePortBinding', 'ComposeStopGrace', 'ComposeReadOnly', 'GatewayFolderAccess', 'KitFolderAccess'
                )) {
                $names | Should -Contain $expected
            }
        }

        It 'never changes the host: no registry write, no firewall change, no task change' {
            Get-GwDoctorResult -Path $script:folder -Runtime $script:noRuntime -WslConfigPath (Join-Path $TestDrive 'none') -DockerSettingsPath (Join-Path $TestDrive 'none.json') | Out-Null
            Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwRegistry -Times 0 -Exactly -ParameterFilter { $Operation -eq 'Set' -or $Operation -eq 'Remove' }
            Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwFirewall -Times 0 -Exactly -ParameterFilter { $Operation -ne 'List' }
            Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwSchTasks -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -ne '/Query' }
            Should -Invoke -ModuleName BrokerSre.Gateway Invoke-GwPowerCfg -Times 0 -Exactly -ParameterFilter { $ArgumentList[0] -ne '/query' }
        }

        It 'reports secrets written by the kit as clean and never shows their content' {
            $secrets = Join-Path $script:folder 'secrets'
            New-Item -ItemType Directory -Path $secrets | Out-Null
            $canary = 'CANARY_' + 'doctor'
            Write-GwSecretFile -Path (Join-Path $secrets 'ib-username') -SecureValue (ConvertTo-TestSecureString -Text $canary) -Confirm:$false
            Write-GwSecretFile -Path (Join-Path $secrets 'ib-password') -SecureValue (ConvertTo-TestSecureString -Text $canary) -Confirm:$false
            $results = @(Get-GwDoctorResult -Path $script:folder -Runtime $script:noRuntime -WslConfigPath (Join-Path $TestDrive 'none') -DockerSettingsPath (Join-Path $TestDrive 'none.json'))
            ($results | Where-Object { $_.Name -eq 'SecretEncodingPassword' }).Status | Should -Be 'PASS'
            ($results | ConvertTo-Json -Depth 4) | Should -Not -Match 'CANARY'
        }
    }

    Describe 'Get-GwPrerequisiteResult' {
        It 'checks build, virtualization, WSL, runtime, the three ports and disk space' {
            $script:wslHandler = { Get-TestNativeResult -Output @('WSL version: 2.6.1.0') }
            $script:registry["$script:winVersionKey|CurrentBuildNumber"] = '26100'
            $results = @(Get-GwPrerequisiteResult -Path 'C:\BrokerSRE\gateway' -TradingMode 'paper' -Runtime $script:desktop)
            $results.Name | Should -Be @('WindowsBuild', 'Virtualization', 'WslVersion', 'ContainerRuntime', 'Port4002', 'Port4001', 'Port9810', 'DiskSpace')
        }

        It 'requires only the port of the chosen trading mode' {
            $script:wslHandler = { Get-TestNativeResult -Output @('WSL version: 2.6.1.0') }
            $script:registry["$script:winVersionKey|CurrentBuildNumber"] = '26100'
            $script:listeners = @(4001, 4002, 9810)
            $results = @(Get-GwPrerequisiteResult -Path 'C:\BrokerSRE\gateway' -TradingMode 'live' -Runtime $script:desktop)
            ($results | Where-Object { $_.Name -eq 'Port4001' }).Status | Should -Be 'FAIL'
            ($results | Where-Object { $_.Name -eq 'Port4002' }).Status | Should -Be 'WARN'
            ($results | Where-Object { $_.Name -eq 'Port9810' }).Status | Should -Be 'WARN'
        }
    }
}
