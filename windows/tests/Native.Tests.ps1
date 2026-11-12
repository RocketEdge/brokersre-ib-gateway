# Smoke tests for src/Native.ps1, the thin wrappers around external commands. These run the real
# wrapper against harmless, read-only targets (cmd.exe echo, a well-known registry value, the
# listener table); every other test file mocks the wrappers instead.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-KitModule
}

Describe 'Invoke-GwNative' {
    It 'returns the exit code and the output lines of a command' {
        $result = Invoke-GwNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo one& echo two& exit 3')
        $result.ExitCode | Should -Be 3
        $result.Output | Should -Be @('one', 'two')
        $result.NotFound | Should -BeFalse
    }

    It 'records one receipt time per output line' {
        $before = [DateTime]::UtcNow
        $result = Invoke-GwNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo one& echo two')
        $after = [DateTime]::UtcNow
        $result.ReceivedUtc.Count | Should -Be 2
        $result.ReceivedUtc[0] | Should -BeGreaterOrEqual $before
        $result.ReceivedUtc[1] | Should -BeLessOrEqual $after
    }

    It 'captures standard error as text even when the caller stops on errors' {
        $ErrorActionPreference = 'Stop'
        $result = Invoke-GwNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo problem 1>&2& exit 1')
        $result.ExitCode | Should -Be 1
        ($result.Output -join '|') | Should -Match 'problem'
    }

    It 'reports a missing executable as NotFound with exit code -1 instead of throwing' {
        $result = Invoke-GwNative -FilePath 'winkit-no-such-command.exe' -ArgumentList @('x')
        $result.NotFound | Should -BeTrue
        $result.ExitCode | Should -Be -1
    }

    It 'passes arguments with spaces, quotes and dollar signs through unchanged' {
        $result = Invoke-GwNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo', 'a b', '$HOME', 'x`y')
        ($result.Output -join '') | Should -Match '\$HOME'
        ($result.Output -join '') | Should -Match 'x`y'
    }

    It 'returns an empty output array, not null, for a silent command' {
        $result = Invoke-GwNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'exit 0')
        $result.ExitCode | Should -Be 0
        @($result.Output).Count | Should -Be 0
        $null -eq $result.Output | Should -BeFalse
    }

    It 'kills a command that exceeds its timeout and reports TimedOut instead of hanging' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-GwNative -FilePath 'waitfor.exe' -ArgumentList @('/T', '60', 'WinkitSignalNobodySends') -TimeoutSeconds 2
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 20
        $result.TimedOut | Should -BeTrue
        $result.ExitCode | Should -Be -2
        ($result.Output -join ' ') | Should -Match 'timed out after 2 s'
    }

    It 'does not report TimedOut for a command that finishes in time' {
        (Invoke-GwNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'echo ok') -TimeoutSeconds 30).TimedOut | Should -BeFalse
    }

    It 'never leaves a command waiting for keyboard input: standard input is closed' {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-GwNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'set /p answer=type something') -TimeoutSeconds 30
        $watch.Elapsed.TotalSeconds | Should -BeLessThan 20
        $result.TimedOut | Should -BeFalse
    }

    It 'decodes UTF-8 output when asked to' {
        $shell = (Get-Process -Id $PID).Path
        $script = '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); [Console]::Out.WriteLine([string][char]0xE9 + [char]0x20AC)'
        $result = Invoke-GwNative -FilePath $shell -ArgumentList @('-NoProfile', '-Command', $script) -Utf8Output
        $result.ExitCode | Should -Be 0
        $result.Output[0] | Should -Be ([string][char]0xE9 + [char]0x20AC)
    }

    It 'delivers arguments with spaces, quotes and trailing backslashes exactly, under this edition' {
        $shell = (Get-Process -Id $PID).Path
        $helper = Join-Path (Join-Path $PSScriptRoot 'helpers') 'Show-Argument.ps1'
        $sent = @('plain', 'two words', 'say "hi"', 'C:\dir with space\', 'back\slash', 'a\"b', 'x=$y`z', 'tab' + [char]9 + 'bed')
        $result = Invoke-GwNative -FilePath $shell -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper) + $sent)
        $result.ExitCode | Should -Be 0
        $expected = @($sent | ForEach-Object { (([string]$_).ToCharArray() | ForEach-Object { ([int]$_).ToString('X4') }) -join ' ' })
        $result.Output | Should -Be $expected
    }

    It 'returns the exit code and no output in interactive mode' {
        $result = Invoke-GwNative -FilePath 'cmd.exe' -ArgumentList @('/c', 'exit 5') -Interactive
        $result.ExitCode | Should -Be 5
        @($result.Output).Count | Should -Be 0
    }
}

Describe 'ConvertTo-GwNativeArgument' {
    It 'quotes <text> as <expected>' -ForEach @(
        @{ text = 'plain'; expected = 'plain' }
        @{ text = 'two words'; expected = '"two words"' }
        @{ text = ''; expected = '""' }
        @{ text = 'say "hi"'; expected = '"say \"hi\""' }
        @{ text = 'C:\dir with space\'; expected = '"C:\dir with space\\"' }
        @{ text = 'back\slash'; expected = 'back\slash' }
        @{ text = 'a\"b'; expected = '"a\\\"b"' }
        @{ text = 'C:\plain\path\'; expected = 'C:\plain\path\' }
        @{ text = '{{.OSType}}|{{.ServerVersion}}'; expected = '{{.OSType}}|{{.ServerVersion}}' }
    ) {
        ConvertTo-GwNativeArgument -Argument $text | Should -Be $expected
    }
}

Describe 'Invoke-GwRegistry (read operations)' {
    It 'reads an existing value' {
        $build = Invoke-GwRegistry -Operation Get -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'CurrentBuildNumber'
        $build | Should -Match '^\d+$'
    }

    It 'returns null for a missing value and for a missing key' {
        Invoke-GwRegistry -Operation Get -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name 'WinkitNoSuchValue' | Should -BeNullOrEmpty
        Invoke-GwRegistry -Operation Get -Path 'HKCU:\Software\WinkitNoSuchKey' -Name 'X' | Should -BeNullOrEmpty
    }

    It 'tests key existence' {
        Invoke-GwRegistry -Operation Test -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' | Should -BeTrue
        Invoke-GwRegistry -Operation Test -Path 'HKCU:\Software\WinkitNoSuchKey' | Should -BeFalse
    }

    It 'lists the values of a key as a hashtable and returns an empty one for a missing key' {
        $values = Invoke-GwRegistry -Operation GetValues -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $values | Should -BeOfType [hashtable]
        $values.ContainsKey('CurrentBuildNumber') | Should -BeTrue
        $values.ContainsKey('PSPath') | Should -BeFalse
        (Invoke-GwRegistry -Operation GetValues -Path 'HKCU:\Software\WinkitNoSuchKey').Count | Should -Be 0
    }
}

Describe 'Host fact wrappers' {
    It 'Get-GwTcpListenerPort returns port numbers' {
        $ports = @(Get-GwTcpListenerPort)
        $ports.Count | Should -BeGreaterThan 0
        $ports[0] | Should -BeOfType [int]
    }

    It 'Get-GwDriveFreeByte returns a positive number for the system drive' {
        Get-GwDriveFreeByte -Path $env:SystemRoot | Should -BeGreaterThan 0
    }

    It 'Get-GwDriveFreeByte returns null for a drive that does not exist' {
        Get-GwDriveFreeByte -Path 'B:\nothing\here' | Should -BeNullOrEmpty
    }

    It 'Test-GwIsAdministrator returns a boolean' {
        Test-GwIsAdministrator | Should -BeOfType [bool]
    }

    It 'Get-GwCurrentUser returns the account name and its SID' {
        $user = Get-GwCurrentUser
        $user.Name | Should -Match '\\'
        $user.Sid | Should -Match '^S-1-'
    }

    It 'Get-GwUtcNow returns the current UTC time' {
        $now = Get-GwUtcNow
        $now.Kind | Should -Be ([DateTimeKind]::Utc)
        [Math]::Abs(($now - [DateTime]::UtcNow).TotalSeconds) | Should -BeLessThan 5
    }

    It 'Get-GwVirtualizationInfo returns the two facts or null for each' {
        $info = Get-GwVirtualizationInfo
        ($info.PSObject.Properties.Name -join ',') | Should -Be 'HypervisorPresent,FirmwareEnabled'
    }
}

Describe 'BSTR helpers' {
    It 'Get-GwBstr yields a pointer whose text equals the SecureString content, and Clear-GwBstr frees it' {
        $secure = ConvertTo-TestSecureString -Text 'CANARY_bstr_value'
        $pointer = Get-GwBstr -SecureValue $secure
        try {
            [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) | Should -Be 'CANARY_bstr_value'
        }
        finally {
            Clear-GwBstr -Pointer $pointer
        }
    }

    It 'Clear-GwBstr accepts a zero pointer' {
        { Clear-GwBstr -Pointer ([IntPtr]::Zero) } | Should -Not -Throw
    }
}

Describe 'Test-GwPortSpecMatch' {
    It 'matches <spec> against port <port>: <expected>' -ForEach @(
        @{ spec = '4002'; port = 4002; expected = $true }
        @{ spec = '4001'; port = 4002; expected = $false }
        @{ spec = '4000-4010'; port = 4002; expected = $true }
        @{ spec = '4003-4010'; port = 4002; expected = $false }
        @{ spec = 'Any'; port = 4002; expected = $false }
        @{ spec = 'RPC'; port = 4002; expected = $false }
        @{ spec = ' 4002 '; port = 4002; expected = $true }
    ) {
        Test-GwPortSpecMatch -Spec $spec -Port $port | Should -Be $expected
    }
}

Describe 'Invoke-GwFirewall -Operation List (real, read-only)' {
    It 'returns rule records with the documented properties, or nothing' {
        $rules = @(Invoke-GwFirewall -Operation List -Port @(4001, 4002, 9810))
        foreach ($rule in $rules) {
            ($rule.PSObject.Properties.Name -join ',') | Should -Be 'Name,DisplayName,Profile,LocalPort,RemoteAddress,Program'
        }
        $rules.Count | Should -BeGreaterOrEqual 0
    }
}
