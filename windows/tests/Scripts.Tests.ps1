# End-to-end tests of the scripts themselves, run as separate processes the way an operator runs
# them. They use the real wrappers, so they stay read-only for the host: 'setup.ps1 -WhatIf' and
# 'doctor.ps1 -Json'. On a computer without a Linux container runtime (a CI runner) the checks
# report FAIL or SKIP; the tests assert the contract (nothing created, valid JSON, exit code
# equal to "has a FAIL"), not a healthy host.

BeforeDiscovery {
    $script:editions = @()
    if ($null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)) { $script:editions += @{ edition = 'Windows PowerShell 5.1'; exe = 'powershell.exe' } }
    if ($null -ne (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) { $script:editions += @{ edition = 'PowerShell 7'; exe = 'pwsh.exe' } }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:kitRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'setup.ps1 -WhatIf as a process' {
    It 'creates nothing and exits 0 or 1 under <edition>' -ForEach $script:editions {
        $parent = Join-Path $TestDrive ('setup-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $parent | Out-Null
        $target = Join-Path $parent 'gateway'
        $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:kitRoot 'setup.ps1') -WhatIf -Path $target 2>&1
        $text = $output | Out-String
        $LASTEXITCODE | Should -BeIn @(0, 1) -Because $text
        $text | Should -Match 'Step 1 of 8'
        $text | Should -Match '(?m)^(PASS|WARN|FAIL|SKIP)\s+WindowsBuild'
        Test-Path -LiteralPath $target | Should -BeFalse
        @(Get-ChildItem -LiteralPath $parent -Force).Count | Should -Be 0
    }
}

Describe 'doctor.ps1 -Json as a process' {
    It 'prints one JSON document whose exit code says whether a check failed, under <edition>' -ForEach $script:editions {
        $folder = Join-Path $TestDrive ('doctor-' + [guid]::NewGuid().ToString('N'))
        $errorFile = Join-Path $TestDrive ('doctor-' + [guid]::NewGuid().ToString('N') + '.err')
        $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:kitRoot 'doctor.ps1') -Json -Path $folder 2> $errorFile
        $exitCode = $LASTEXITCODE
        $report = ($output | Out-String) | ConvertFrom-Json
        $report.schema | Should -Be 1
        @($report.results).Count | Should -BeGreaterThan 20
        foreach ($result in $report.results) { $result.status | Should -BeIn @('PASS', 'WARN', 'FAIL', 'SKIP') }
        $failed = @($report.results | Where-Object { $_.status -eq 'FAIL' }).Count
        $report.summary.fail | Should -Be $failed
        $expectedExit = 0
        if ($failed -gt 0) { $expectedExit = 1 }
        $exitCode | Should -Be $expectedExit
        $report.exitCode | Should -Be $expectedExit
        Test-Path -LiteralPath $folder | Should -BeFalse -Because 'doctor is read-only'
    }
}

Describe 'harden.ps1 and uninstall.ps1 as processes' {
    It 'harden.ps1 without options changes nothing and exits 1 under <edition>' -ForEach $script:editions {
        $folder = Join-Path $TestDrive ('harden-' + [guid]::NewGuid().ToString('N'))
        $output = & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:kitRoot 'harden.ps1') -Path $folder 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output | Out-String) | Should -Match 'Nothing to do'
        Test-Path -LiteralPath $folder | Should -BeFalse
    }

    It 'uninstall.ps1 -WhatIf on a folder without a stack changes nothing under <edition>' -ForEach $script:editions {
        $folder = Join-Path $TestDrive ('uninstall-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $folder | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $folder 'keep.txt'), 'keep')
        $before = Get-TestTreeSnapshot -Path $folder
        & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:kitRoot 'uninstall.ps1') -Path $folder -RemoveData -WhatIf 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
        Get-TestTreeSnapshot -Path $folder | Should -Be $before
    }
}
