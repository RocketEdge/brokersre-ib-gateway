# Tests for src/Core.ps1: result objects, atomic UTF-8 writes, INI editing, small converters.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-KitModule
}

Describe 'New-GwCheckResult' {
    It 'returns an object with exactly Name, Status, Detail and Fix' {
        $result = New-GwCheckResult -Name 'Demo' -Status 'WARN' -Detail 'detail text' -Fix 'fix text'
        ($result.PSObject.Properties.Name -join ',') | Should -Be 'Name,Status,Detail,Fix'
        $result.Name | Should -Be 'Demo'
        $result.Status | Should -Be 'WARN'
        $result.Detail | Should -Be 'detail text'
        $result.Fix | Should -Be 'fix text'
    }

    It 'rejects a status outside PASS, WARN, FAIL and SKIP' {
        { New-GwCheckResult -Name 'Demo' -Status 'OK' -Detail 'x' } | Should -Throw
    }

    It 'defaults Fix to an empty string' {
        (New-GwCheckResult -Name 'Demo' -Status 'PASS' -Detail 'x').Fix | Should -Be ''
    }
}

Describe 'Write-GwFileAtomic' {
    It 'writes UTF-8 without a byte-order mark and without adding a newline' {
        $path = Join-Path $TestDrive 'atomic.txt'
        Write-GwFileAtomic -Path $path -Text ('caf' + [char]0xE9)
        $bytes = [System.IO.File]::ReadAllBytes($path)
        ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' ' | Should -Be '63 61 66 C3 A9'
    }

    It 'replaces an existing file and leaves no temporary file behind' {
        $directory = Join-Path $TestDrive 'replace'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $path = Join-Path $directory 'file.txt'
        Write-GwFileAtomic -Path $path -Text 'one'
        Write-GwFileAtomic -Path $path -Text 'two'
        [System.IO.File]::ReadAllText($path) | Should -Be 'two'
        @(Get-ChildItem -LiteralPath $directory -Force).Count | Should -Be 1
    }

    It 'keeps LF line endings exactly as given' {
        $path = Join-Path $TestDrive 'lf.txt'
        Write-GwFileAtomic -Path $path -Text "a`nb`n"
        ([System.IO.File]::ReadAllBytes($path) -contains 13) | Should -BeFalse
    }
}

Describe 'Read-GwTextFile' {
    It 'returns null for a missing file' {
        Read-GwTextFile -Path (Join-Path $TestDrive 'missing.txt') | Should -BeNullOrEmpty
    }

    It 'reads UTF-8 and drops a byte-order mark' {
        $path = Join-Path $TestDrive 'bom.txt'
        [System.IO.File]::WriteAllBytes($path, [byte[]](0xEF, 0xBB, 0xBF, 0x61, 0xC3, 0xA9))
        Read-GwTextFile -Path $path | Should -Be ('a' + [char]0xE9)
    }
}

Describe 'INI helpers' {
    BeforeAll {
        $script:iniText = "# comment`n[wsl2]`nmemory = 4GB`nNetworkingMode=mirrored`n`n[experimental]`nautoMemoryReclaim=gradual`n"
    }

    It 'reads a value regardless of the case of section and key' {
        Get-GwIniValue -Text $script:iniText -Section 'WSL2' -Key 'networkingmode' | Should -Be 'mirrored'
        Get-GwIniValue -Text $script:iniText -Section 'wsl2' -Key 'memory' | Should -Be '4GB'
    }

    It 'returns null when the key or the section is absent' {
        Get-GwIniValue -Text $script:iniText -Section 'wsl2' -Key 'vmIdleTimeout' | Should -BeNullOrEmpty
        Get-GwIniValue -Text $script:iniText -Section 'general' -Key 'memory' | Should -BeNullOrEmpty
        Get-GwIniValue -Text '' -Section 'wsl2' -Key 'memory' | Should -BeNullOrEmpty
    }

    It 'does not read a key from another section' {
        Get-GwIniValue -Text $script:iniText -Section 'wsl2' -Key 'autoMemoryReclaim' | Should -BeNullOrEmpty
    }

    It 'ignores commented-out keys' {
        Get-GwIniValue -Text "[wsl2]`n# memory=1GB`n;memory=2GB`n" -Section 'wsl2' -Key 'memory' | Should -BeNullOrEmpty
    }

    It 'replaces an existing value in place and keeps every other line' {
        $updated = Set-GwIniValue -Text $script:iniText -Section 'wsl2' -Key 'networkingMode' -Value 'nat'
        $updated | Should -Be "# comment`n[wsl2]`nmemory = 4GB`nnetworkingMode=nat`n`n[experimental]`nautoMemoryReclaim=gradual`n"
    }

    It 'appends a key to the end of an existing section' {
        $updated = Set-GwIniValue -Text $script:iniText -Section 'wsl2' -Key 'vmIdleTimeout' -Value '-1'
        $updated | Should -Be "# comment`n[wsl2]`nmemory = 4GB`nNetworkingMode=mirrored`nvmIdleTimeout=-1`n`n[experimental]`nautoMemoryReclaim=gradual`n"
    }

    It 'creates the section when it does not exist' {
        $updated = Set-GwIniValue -Text $script:iniText -Section 'general' -Key 'instanceIdleTimeout' -Value '-1'
        $updated | Should -Be ($script:iniText + "`n[general]`ninstanceIdleTimeout=-1`n")
    }

    It 'creates the file content from nothing' {
        Set-GwIniValue -Text '' -Section 'wsl2' -Key 'memory' -Value '4GB' | Should -Be "[wsl2]`nmemory=4GB`n"
    }

    It 'normalises CRLF input to LF' {
        $updated = Set-GwIniValue -Text "[wsl2]`r`nmemory=1GB`r`n" -Section 'wsl2' -Key 'memory' -Value '2GB'
        $updated | Should -Be "[wsl2]`nmemory=2GB`n"
    }

    It 'removes a key and keeps the rest' {
        $updated = Remove-GwIniValue -Text $script:iniText -Section 'wsl2' -Key 'memory'
        $updated | Should -Be "# comment`n[wsl2]`nNetworkingMode=mirrored`n`n[experimental]`nautoMemoryReclaim=gradual`n"
    }

    It 'leaves the text unchanged when the key to remove is absent' {
        Remove-GwIniValue -Text $script:iniText -Section 'wsl2' -Key 'swap' | Should -Be $script:iniText
    }
}

Describe 'ConvertTo-GwDurationSecond' {
    It 'converts <text> to <expected> seconds' -ForEach @(
        @{ text = '90s'; expected = 90 }
        @{ text = '1m30s'; expected = 90 }
        @{ text = '2m'; expected = 120 }
        @{ text = '1h0m5s'; expected = 3605 }
        @{ text = '1.5s'; expected = 1.5 }
        @{ text = '500ms'; expected = 0.5 }
    ) {
        ConvertTo-GwDurationSecond -Text $text | Should -Be $expected
    }

    It 'returns null for text that is not a duration' {
        ConvertTo-GwDurationSecond -Text 'soon' | Should -BeNullOrEmpty
        ConvertTo-GwDurationSecond -Text '' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-GwSizeByte' {
    It 'converts <text> to <expected> bytes' -ForEach @(
        @{ text = '4GB'; expected = 4294967296 }
        @{ text = '512MB'; expected = 536870912 }
        @{ text = '1024'; expected = 1024 }
        @{ text = '8gb'; expected = 8589934592 }
        @{ text = '2KB'; expected = 2048 }
        @{ text = '1TB'; expected = 1099511627776 }
    ) {
        ConvertTo-GwSizeByte -Text $text | Should -Be $expected
    }

    It 'returns null for text that is not a size' {
        ConvertTo-GwSizeByte -Text 'lots' | Should -BeNullOrEmpty
    }
}

Describe 'ConvertTo-GwTimestampText' {
    It 'formats a DateTime as UTC ISO 8601 with a Z suffix' {
        $value = New-Object DateTime(2026, 11, 12, 1, 2, 3, [DateTimeKind]::Utc)
        ConvertTo-GwTimestampText -Value $value | Should -Be '2026-11-12T01:02:03Z'
    }

    It 'converts a local DateTime to UTC' {
        $utc = New-Object DateTime(2026, 11, 12, 1, 2, 3, [DateTimeKind]::Utc)
        ConvertTo-GwTimestampText -Value $utc.ToLocalTime() | Should -Be '2026-11-12T01:02:03Z'
    }

    It 'passes a string through unchanged' {
        ConvertTo-GwTimestampText -Value '2026-11-12T01:02:03Z' | Should -Be '2026-11-12T01:02:03Z'
    }
}

Describe 'Kit state file' {
    It 'round-trips the state through JSON' {
        $directory = Join-Path $TestDrive 'state'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $state = [pscustomobject]@{
            Runtime = 'DockerDesktop'; Distro = ''; TradingMode = 'paper'; ContainerName = 'brokersre-ib-gateway-paper'
            ProjectName = 'brokersre-gateway-paper'; ApiPort = 4002; ImageRef = 'example/image:tag'
        }
        Save-GwKitState -Path $directory -State $state
        $loaded = Get-GwKitState -Path $directory
        $loaded.Runtime | Should -Be 'DockerDesktop'
        $loaded.ApiPort | Should -Be 4002
        $loaded.ContainerName | Should -Be 'brokersre-ib-gateway-paper'
        $loaded.Schema | Should -Be 1
    }

    It 'returns null when no state file exists' {
        Get-GwKitState -Path (Join-Path $TestDrive 'nostate') | Should -BeNullOrEmpty
    }

    It 'returns null for a state file that is not JSON instead of throwing' {
        $directory = Join-Path $TestDrive 'badstate'
        New-Item -ItemType Directory -Path $directory | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $directory 'kit-state.json'), 'not json {')
        Get-GwKitState -Path $directory | Should -BeNullOrEmpty
    }
}

Describe 'Write-GwLog' {
    It 'appends timestamped lines' {
        $path = Join-Path $TestDrive 'kit.log'
        Write-GwLog -Path $path -Message 'first'
        Write-GwLog -Path $path -Message 'second'
        $lines = [System.IO.File]::ReadAllLines($path)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z first$'
        $lines[1] | Should -Match ' second$'
    }

    It 'rotates to a single .1 file once the size limit is exceeded' {
        $path = Join-Path $TestDrive 'rotate.log'
        Write-GwLog -Path $path -Message ('x' * 200) -MaxBytes 256
        Write-GwLog -Path $path -Message ('y' * 200) -MaxBytes 256
        Write-GwLog -Path $path -Message 'z' -MaxBytes 256
        Test-Path -LiteralPath ($path + '.1') | Should -BeTrue
        [System.IO.File]::ReadAllText($path) | Should -Match ' z'
        [System.IO.File]::ReadAllText($path) | Should -Not -Match 'xxxx'
    }
}

Describe 'Get-GwPropertyValue' {
    It 'returns the value of an existing property' {
        Get-GwPropertyValue -InputObject ([pscustomobject]@{ A = 5 }) -Name 'A' | Should -Be 5
    }

    It 'returns the default for a missing property or a null object' {
        Get-GwPropertyValue -InputObject ([pscustomobject]@{ A = 5 }) -Name 'B' -Default 'none' | Should -Be 'none'
        Get-GwPropertyValue -InputObject $null -Name 'B' | Should -BeNullOrEmpty
    }
}
