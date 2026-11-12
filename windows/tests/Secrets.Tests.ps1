# Tests for src/Secrets.ps1: byte-exact secret files, the BSTR lifetime, the owner-only ACL and
# the encoding inspection used by doctor. All fake secrets are obviously fake and are assembled
# from parts so that a secret scanner sees no credential assignment.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-KitModule
    $script:fakePassword = 'hunter2' + 'hunter2'
    $script:canary = 'CANARY_' + 'secret_file'
    $script:helper = Join-Path (Join-Path $PSScriptRoot 'helpers') 'Write-SecretProbe.ps1'

    function Get-HexByte {
        param([string]$Path)
        return (([System.IO.File]::ReadAllBytes($Path) | ForEach-Object { $_.ToString('X2') }) -join ' ')
    }
}

Describe 'Write-GwSecretFile' {
    It 'writes the exact UTF-8 bytes: no byte-order mark and no trailing newline' {
        $path = Join-Path $TestDrive 'plain'
        Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text $script:fakePassword) -Confirm:$false
        Get-HexByte -Path $path | Should -Be '68 75 6E 74 65 72 32 68 75 6E 74 65 72 32'
    }

    It 'preserves dollar, backtick, quotes, percent, backslash and spaces' {
        $text = 'a$b`c"d' + "'" + 'e%f\g h'
        $path = Join-Path $TestDrive 'special'
        Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text $text) -Confirm:$false
        Get-HexByte -Path $path | Should -Be '61 24 62 60 63 22 64 27 65 25 66 5C 67 20 68'
    }

    It 'encodes non-ASCII characters as UTF-8, including a character outside the basic plane' {
        $text = 'p' + [char]0xE9 + [char]0x20AC + [char]::ConvertFromUtf32(0x1F511)
        $path = Join-Path $TestDrive 'unicode'
        Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text $text) -Confirm:$false
        Get-HexByte -Path $path | Should -Be '70 C3 A9 E2 82 AC F0 9F 94 91'
    }

    It 'replaces an existing secret and leaves no temporary file in the folder' {
        $directory = Join-Path $TestDrive 'replace'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $path = Join-Path $directory 'ib-password'
        Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text 'old-fake-value') -Confirm:$false
        Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text $script:fakePassword) -Confirm:$false
        [System.IO.File]::ReadAllText($path) | Should -Be $script:fakePassword
        @(Get-ChildItem -LiteralPath $directory -Force).Count | Should -Be 1
    }

    It 'frees the BSTR exactly once after a successful write' {
        Mock -ModuleName BrokerSre.Gateway Clear-GwBstr { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer) }
        Write-GwSecretFile -Path (Join-Path $TestDrive 'freed') -SecureValue (ConvertTo-TestSecureString -Text $script:fakePassword) -Confirm:$false
        Should -Invoke -ModuleName BrokerSre.Gateway Clear-GwBstr -Times 1 -Exactly
    }

    It 'frees the BSTR exactly once when the write fails' {
        Mock -ModuleName BrokerSre.Gateway Clear-GwBstr { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer) }
        $missingDirectory = Join-Path (Join-Path $TestDrive 'no-such-directory') 'secret'
        { Write-GwSecretFile -Path $missingDirectory -SecureValue (ConvertTo-TestSecureString -Text $script:fakePassword) -Confirm:$false } | Should -Throw
        Should -Invoke -ModuleName BrokerSre.Gateway Clear-GwBstr -Times 1 -Exactly
    }

    It 'frees the pointer it obtained, not another one' {
        $script:obtained = [IntPtr]::Zero
        $script:freed = [IntPtr]::Zero
        Mock -ModuleName BrokerSre.Gateway Get-GwBstr {
            $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
            $script:obtained = $pointer
            return $pointer
        }
        Mock -ModuleName BrokerSre.Gateway Clear-GwBstr {
            $script:freed = $Pointer
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
        }
        Write-GwSecretFile -Path (Join-Path $TestDrive 'pointer') -SecureValue (ConvertTo-TestSecureString -Text $script:fakePassword) -Confirm:$false
        $script:obtained | Should -Not -Be ([IntPtr]::Zero)
        $script:freed | Should -Be $script:obtained
    }

    It 'rejects an empty value without creating a file' {
        $path = Join-Path $TestDrive 'empty'
        { Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text '') -Confirm:$false } | Should -Throw -ExpectedMessage '*empty*'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'rejects a value containing a line break and does not echo the value in the error' {
        $path = Join-Path $TestDrive 'linebreak'
        $value = $script:canary + "`n" + 'second'
        $message = ''
        try { Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text $value) -Confirm:$false }
        catch { $message = $_.Exception.Message }
        $message | Should -Match 'line break'
        $message | Should -Not -Match 'CANARY'
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'never writes the value to the success, verbose, debug, warning or information stream' {
        $path = Join-Path $TestDrive 'streams'
        $everything = Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text $script:canary) -Confirm:$false -Verbose -Debug *>&1
        (($everything | Out-String) -match 'CANARY') | Should -BeFalse
        [System.IO.File]::ReadAllText($path) | Should -Be $script:canary
    }

    It 'changes nothing under -WhatIf' {
        $path = Join-Path $TestDrive 'whatif'
        Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text $script:fakePassword) -WhatIf
        Test-Path -LiteralPath $path | Should -BeFalse
    }
}

Describe 'Write-GwSecretFile under each PowerShell edition' {
    # P $ ` " ' e-acute euro-sign key-emoji space z
    BeforeAll {
        $script:codePoints = '80,36,96,34,39,233,8364,128273,32,122'
        $script:expectedHex = '50 24 60 22 27 C3 A9 E2 82 AC F0 9F 94 91 20 7A'
    }

    It 'is byte-exact when run by Windows PowerShell 5.1 (powershell.exe)' -Skip:($null -eq (Get-Command powershell.exe -ErrorAction SilentlyContinue)) {
        $path = Join-Path $TestDrive 'edition-desktop'
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:helper -Path $path -CodePoint $script:codePoints 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        Get-HexByte -Path $path | Should -Be $script:expectedHex
    }

    It 'is byte-exact when run by PowerShell 7 (pwsh.exe)' -Skip:($null -eq (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
        $path = Join-Path $TestDrive 'edition-core'
        $output = & pwsh.exe -NoProfile -File $script:helper -Path $path -CodePoint $script:codePoints 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output | Out-String)
        Get-HexByte -Path $path | Should -Be $script:expectedHex
    }
}

Describe 'Protect-GwSecretFolder' {
    BeforeAll {
        $script:currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

        function Get-AccessSummary {
            param([string]$Path)
            $acl = Get-Acl -LiteralPath $Path
            return @($acl.Access | ForEach-Object {
                    '{0}|{1}|{2}' -f $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value, $_.FileSystemRights, $_.AccessControlType
                })
        }
    }

    It 'leaves exactly one access rule: full control for the current user, inheritance off' {
        $directory = Join-Path $TestDrive 'acl-secrets'
        New-Item -ItemType Directory -Path $directory | Out-Null
        Protect-GwSecretFolder -Path $directory -Confirm:$false
        (Get-Acl -LiteralPath $directory).AreAccessRulesProtected | Should -BeTrue
        Get-AccessSummary -Path $directory | Should -Be @(('{0}|FullControl|Allow' -f $script:currentSid))
    }

    It 'makes files created afterwards inherit only that rule' {
        $directory = Join-Path $TestDrive 'acl-inherit'
        New-Item -ItemType Directory -Path $directory | Out-Null
        Protect-GwSecretFolder -Path $directory -Confirm:$false
        $file = Join-Path $directory 'ib-password'
        Write-GwSecretFile -Path $file -SecureValue (ConvertTo-TestSecureString -Text $script:fakePassword) -Confirm:$false
        Get-AccessSummary -Path $file | Should -Be @(('{0}|FullControl|Allow' -f $script:currentSid))
    }

    It 'keeps the file readable by the current user' {
        $directory = Join-Path $TestDrive 'acl-read'
        New-Item -ItemType Directory -Path $directory | Out-Null
        Protect-GwSecretFolder -Path $directory -Confirm:$false
        $file = Join-Path $directory 'dummy'
        [System.IO.File]::WriteAllText($file, 'dummy')
        [System.IO.File]::ReadAllText($file) | Should -Be 'dummy'
    }

    It 'changes nothing under -WhatIf' {
        $directory = Join-Path $TestDrive 'acl-whatif'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $before = Get-AccessSummary -Path $directory
        Protect-GwSecretFolder -Path $directory -WhatIf
        Get-AccessSummary -Path $directory | Should -Be $before
        (Get-Acl -LiteralPath $directory).AreAccessRulesProtected | Should -BeFalse
    }
}

Describe 'Get-GwAclOtherIdentity' {
    It 'lists identities other than the current user on an inherited folder' {
        $directory = Join-Path $TestDrive 'acl-others'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $others = @(Get-GwAclOtherIdentity -Path $directory)
        $others.Count | Should -BeGreaterThan 0
    }

    It 'returns nothing once the folder is protected' {
        $directory = Join-Path $TestDrive 'acl-none'
        New-Item -ItemType Directory -Path $directory | Out-Null
        Protect-GwSecretFolder -Path $directory -Confirm:$false
        @(Get-GwAclOtherIdentity -Path $directory).Count | Should -Be 0
    }
}

Describe 'Get-GwSecretFileFinding' {
    BeforeAll {
        function Save-ByteFile {
            param([string]$Name, [byte[]]$Byte)
            $path = Join-Path $TestDrive $Name
            [System.IO.File]::WriteAllBytes($path, $Byte)
            return $path
        }
    }

    It 'reports nothing for a clean UTF-8 secret' {
        $path = Save-ByteFile -Name 'clean' -Byte ([byte[]](0x61, 0xC3, 0xA9, 0x24))
        @(Get-GwSecretFileFinding -Path $path).Count | Should -Be 0
    }

    It 'reports Missing for a file that does not exist' {
        Get-GwSecretFileFinding -Path (Join-Path $TestDrive 'nope') | Should -Be @('Missing')
    }

    It 'reports Empty for a zero-length file' {
        $path = Save-ByteFile -Name 'empty' -Byte ([byte[]]@())
        Get-GwSecretFileFinding -Path $path | Should -Be @('Empty')
    }

    It 'reports Utf8Bom' {
        $path = Save-ByteFile -Name 'bom' -Byte ([byte[]](0xEF, 0xBB, 0xBF, 0x61))
        Get-GwSecretFileFinding -Path $path | Should -Be @('Utf8Bom')
    }

    It 'reports Utf16 for a little-endian mark, a big-endian mark and for markless UTF-16' {
        Get-GwSecretFileFinding -Path (Save-ByteFile -Name 'u16le' -Byte ([byte[]](0xFF, 0xFE, 0x61, 0x00))) | Should -Be @('Utf16')
        Get-GwSecretFileFinding -Path (Save-ByteFile -Name 'u16be' -Byte ([byte[]](0xFE, 0xFF, 0x00, 0x61))) | Should -Be @('Utf16')
        Get-GwSecretFileFinding -Path (Save-ByteFile -Name 'u16raw' -Byte ([byte[]](0x61, 0x00, 0x62, 0x00))) | Should -Be @('Utf16')
    }

    It 'reports CarriageReturn for CRLF, which the container does not strip' {
        $path = Save-ByteFile -Name 'crlf' -Byte ([byte[]](0x61, 0x0D, 0x0A))
        Get-GwSecretFileFinding -Path $path | Should -Be @('CarriageReturn', 'TrailingLineFeed')
    }

    It 'reports TrailingLineFeed alone for a single final LF' {
        $path = Save-ByteFile -Name 'lf' -Byte ([byte[]](0x61, 0x0A))
        Get-GwSecretFileFinding -Path $path | Should -Be @('TrailingLineFeed')
    }

    It 'reports EmbeddedLineFeed for a line break inside the value' {
        $path = Save-ByteFile -Name 'multi' -Byte ([byte[]](0x61, 0x0A, 0x62))
        Get-GwSecretFileFinding -Path $path | Should -Be @('EmbeddedLineFeed')
    }

    It 'reports InvalidUtf8 for ANSI-encoded accented characters' {
        $path = Save-ByteFile -Name 'ansi' -Byte ([byte[]](0x70, 0xE9, 0x71))
        Get-GwSecretFileFinding -Path $path | Should -Be @('InvalidUtf8')
    }
}

Describe 'Test-GwSecretEncoding' {
    It 'passes for a file written by the kit and never shows the content' {
        $path = Join-Path $TestDrive 'check-clean'
        Write-GwSecretFile -Path $path -SecureValue (ConvertTo-TestSecureString -Text $script:canary) -Confirm:$false
        $result = Test-GwSecretEncoding -Path $path -Name 'SecretEncodingPassword'
        $result.Status | Should -Be 'PASS'
        ($result | Out-String) | Should -Not -Match 'CANARY'
    }

    It 'fails for a byte-order mark and names the fix' {
        $path = Join-Path $TestDrive 'check-bom'
        [System.IO.File]::WriteAllBytes($path, [byte[]](0xEF, 0xBB, 0xBF, 0x61))
        $result = Test-GwSecretEncoding -Path $path -Name 'SecretEncodingPassword'
        $result.Status | Should -Be 'FAIL'
        $result.Detail | Should -Match 'byte-order mark'
        $result.Fix | Should -Match 'ResetSecrets'
    }

    It 'fails for UTF-16, for a carriage return, for an embedded line break and for an empty file' {
        $cases = @{
            utf16    = [byte[]](0xFF, 0xFE, 0x61, 0x00)
            carriage = [byte[]](0x61, 0x0D, 0x0A)
            embedded = [byte[]](0x61, 0x0A, 0x62)
            empty    = [byte[]]@()
        }
        foreach ($name in $cases.Keys) {
            $path = Join-Path $TestDrive ('check-' + $name)
            [System.IO.File]::WriteAllBytes($path, [byte[]]$cases[$name])
            (Test-GwSecretEncoding -Path $path -Name 'SecretEncodingPassword').Status | Should -Be 'FAIL' -Because $name
        }
    }

    It 'passes with a note for a single trailing line feed, which the image strips' {
        $path = Join-Path $TestDrive 'check-lf'
        [System.IO.File]::WriteAllBytes($path, [byte[]](0x61, 0x0A))
        $result = Test-GwSecretEncoding -Path $path -Name 'SecretEncodingPassword'
        $result.Status | Should -Be 'PASS'
        $result.Detail | Should -Match 'line feed'
    }

    It 'warns for bytes that are not valid UTF-8' {
        $path = Join-Path $TestDrive 'check-ansi'
        [System.IO.File]::WriteAllBytes($path, [byte[]](0x70, 0xE9, 0x71))
        (Test-GwSecretEncoding -Path $path -Name 'SecretEncodingPassword').Status | Should -Be 'WARN'
    }

    It 'skips, never passes, when the file does not exist' {
        $result = Test-GwSecretEncoding -Path (Join-Path $TestDrive 'check-missing') -Name 'SecretEncodingPassword'
        $result.Status | Should -Be 'SKIP'
        $result.Name | Should -Be 'SecretEncodingPassword'
    }
}

Describe 'Test-GwSecretAcl' {
    It 'passes for a protected folder' {
        $directory = Join-Path $TestDrive 'aclcheck-pass'
        New-Item -ItemType Directory -Path $directory | Out-Null
        Protect-GwSecretFolder -Path $directory -Confirm:$false
        (Test-GwSecretAcl -Path $directory).Status | Should -Be 'PASS'
    }

    It 'warns for a folder other accounts can read and lists them' {
        $directory = Join-Path $TestDrive 'aclcheck-warn'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $result = Test-GwSecretAcl -Path $directory
        $result.Status | Should -Be 'WARN'
        $result.Detail | Should -Match '\\'
    }

    It 'skips when the folder does not exist' {
        (Test-GwSecretAcl -Path (Join-Path $TestDrive 'aclcheck-missing')).Status | Should -Be 'SKIP'
    }
}
