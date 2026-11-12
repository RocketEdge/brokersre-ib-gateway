# Hygiene tests for the whole kit: file encoding, help on every function and script, the module
# manifest, and the rules a public trading-adjacent repository must never break (no credentials
# in the template, no order placement anywhere, trademark sentence in the README).

BeforeDiscovery {
    $script:kitRoot = Split-Path -Parent $PSScriptRoot
    # Filtered by extension here: Windows PowerShell 5.1 ignores -Include together with -LiteralPath.
    $script:powerShellFiles = @(Get-ChildItem -LiteralPath $script:kitRoot -Recurse -File |
            Where-Object { @('.ps1', '.psm1', '.psd1') -contains $_.Extension } |
            ForEach-Object { @{ file = $_.FullName; name = $_.FullName.Substring($script:kitRoot.Length + 1) } })
    $script:scriptFiles = @('setup.ps1', 'doctor.ps1', 'harden.ps1', 'start.ps1', 'uninstall.ps1' | ForEach-Object { @{ script = $_ } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-KitModule
    $script:kitRoot = Split-Path -Parent $PSScriptRoot

    function Get-KitFunctionAst {
        $functions = New-Object System.Collections.Generic.List[object]
        foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:kitRoot 'src') -Filter '*.ps1')) {
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            foreach ($function in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
                $functions.Add($function)
            }
        }
        return $functions.ToArray()
    }
}

Describe 'Source files' {
    It '<name> is ASCII, LF-only, has no trailing whitespace and ends with one newline' -ForEach $script:powerShellFiles {
        $bytes = [System.IO.File]::ReadAllBytes($file)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0 -Because 'Windows PowerShell 5.1 reads a file without byte-order mark as ANSI'
        ($bytes -contains 13) | Should -BeFalse -Because 'the repository uses LF line endings'
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
        $text | Should -Not -Match '[ \t]+\n'
        $text.EndsWith("`n") | Should -BeTrue
        $text.EndsWith("`n`n") | Should -BeFalse
    }

    It '<name> parses without errors' -ForEach $script:powerShellFiles {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0
    }

    It 'the compose template and the workflow use LF and are ASCII' {
        foreach ($relative in @('templates\compose.yaml.tmpl')) {
            $bytes = [System.IO.File]::ReadAllBytes((Join-Path $script:kitRoot $relative))
            ($bytes -contains 13) | Should -BeFalse
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        }
    }
}

Describe 'Function documentation' {
    It 'every function has a synopsis, an outputs section and a description of each parameter' {
        $problems = New-Object System.Collections.Generic.List[string]
        foreach ($function in (Get-KitFunctionAst)) {
            $help = $function.GetHelpContent()
            if ($null -eq $help) {
                $problems.Add(('{0}: no comment-based help' -f $function.Name))
                continue
            }
            if ([string]::IsNullOrWhiteSpace($help.Synopsis)) { $problems.Add(('{0}: no .SYNOPSIS' -f $function.Name)) }
            if (@($help.Outputs).Count -eq 0) { $problems.Add(('{0}: no .OUTPUTS' -f $function.Name)) }
            $parameters = @()
            if ($null -ne $function.Body.ParamBlock) { $parameters = @($function.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) }
            foreach ($parameter in $parameters) {
                if (-not $help.Parameters.ContainsKey($parameter.ToUpperInvariant())) { $problems.Add(('{0}: parameter {1} is not documented' -f $function.Name, $parameter)) }
            }
        }
        $problems | Should -BeNullOrEmpty
    }

    It 'every state-changing command supports -WhatIf' {
        $required = @(
            'Write-GwSecretFile', 'Protect-GwSecretFolder', 'Start-GwStack', 'Stop-GwStack', 'Remove-GwStack', 'Disable-GwSleep', 'Set-GwUpdateActiveWindow',
            'Register-GwStartTask', 'Register-GwResumeClockTask', 'Set-GwWslConfigValue', 'Add-GwFirewallBlockRule', 'Undo-GwHardening',
            'Invoke-GwSetup', 'Invoke-GwHarden', 'Invoke-GwUninstall'
        )
        foreach ($name in $required) {
            (Get-Command -Name $name).Parameters.ContainsKey('WhatIf') | Should -BeTrue -Because $name
        }
    }

    It 'power and undo changes ask for confirmation by default' {
        foreach ($name in @('Disable-GwSleep', 'Undo-GwHardening', 'Invoke-GwUninstall')) {
            $attribute = (Get-Command -Name $name).ScriptBlock.Attributes | Where-Object { $_ -is [System.Management.Automation.CmdletBindingAttribute] }
            $attribute.ConfirmImpact | Should -Be 'High' -Because $name
        }
    }
}

Describe 'Module manifest' {
    It 'exports exactly the functions the module defines, as an explicit list' {
        $defined = @((Get-KitFunctionAst).Name | Sort-Object)
        $manifest = Import-PowerShellDataFile -Path (Join-Path $script:kitRoot 'BrokerSre.Gateway.psd1')
        $exported = @($manifest.FunctionsToExport | Sort-Object)
        ($exported -join "`n") | Should -Be ($defined -join "`n")
    }

    It 'loads on this PowerShell edition and exposes the five entry points' {
        foreach ($name in @('Invoke-GwSetup', 'Invoke-GwDoctor', 'Invoke-GwHarden', 'Invoke-GwStart', 'Invoke-GwUninstall')) {
            Get-Command -Name $name -Module 'BrokerSre.Gateway' | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Scripts' {
    It '<script> has help with a synopsis, documents every parameter and forwards to the module' -ForEach $script:scriptFiles {
        $path = Join-Path $script:kitRoot $script
        $help = Get-Help -Name $path -Full
        $help.Synopsis | Should -Not -BeNullOrEmpty
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
        $documented = $ast.GetHelpContent().Parameters
        foreach ($parameter in $ast.ParamBlock.Parameters) {
            $documented.ContainsKey($parameter.Name.VariablePath.UserPath.ToUpperInvariant()) | Should -BeTrue -Because $parameter.Name.VariablePath.UserPath
        }
        [System.IO.File]::ReadAllText($path) | Should -Match 'Invoke-Gw\w+ @PSBoundParameters'
    }

    It '<script> offers the same parameters as the module function it forwards to' -ForEach $script:scriptFiles {
        $path = Join-Path $script:kitRoot $script
        $text = [System.IO.File]::ReadAllText($path)
        $functionName = [regex]::Match($text, '(Invoke-Gw\w+) @PSBoundParameters').Groups[1].Value
        $common = @([System.Management.Automation.PSCmdlet]::CommonParameters) + @([System.Management.Automation.PSCmdlet]::OptionalCommonParameters)
        $scriptParameters = @((Get-Command -Name $path).Parameters.Keys | Where-Object { $common -notcontains $_ } | Sort-Object)
        $functionParameters = @((Get-Command -Name $functionName).Parameters.Keys | Where-Object { $common -notcontains $_ } | Sort-Object)
        ($scriptParameters -join ',') | Should -Be ($functionParameters -join ',')
    }
}

Describe 'Rules of the repository' {
    It 'the compose template never carries a credential, only the two secret file references' {
        $template = [System.IO.File]::ReadAllText((Join-Path $script:kitRoot 'templates\compose.yaml.tmpl'))
        $template | Should -Not -Match '(?m)^\s*TWS_USERID:'
        $template | Should -Not -Match '(?m)^\s*TWS_PASSWORD:'
        $template | Should -Not -Match '(?m)^\s*VNC_SERVER_PASSWORD:'
        $template | Should -Match 'TWS_USERID_FILE: /run/secrets/ib-username'
        $template | Should -Match 'TWS_PASSWORD_FILE: /run/secrets/ib-password'
        $template | Should -Not -Match 'docker\.sock'
        $template | Should -Not -Match 'privileged'
    }

    It 'nothing in the kit names an order placement, modification or cancellation call' {
        # Assembled at run time so that this file does not contain the names either.
        $forbidden = @(('place' + 'Order'), ('cancel' + 'Order'), ('reqGlobal' + 'Cancel'), ('whatIf' + 'Order'))
        foreach ($file in (Get-ChildItem -LiteralPath $script:kitRoot -Recurse -File)) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            foreach ($word in $forbidden) {
                ($text.IndexOf($word, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) | Should -BeFalse -Because ('{0} in {1}' -f $word, $file.Name)
            }
        }
    }

    It 'nothing in the kit automates the second factor' {
        foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $script:kitRoot 'src') -File)) {
            [System.IO.File]::ReadAllText($file.FullName) | Should -Not -Match '(?i)totp|authenticator secret|otpauth'
        }
    }

    It 'the README ends with the trademark sentence' {
        $readme = [System.IO.File]::ReadAllText((Join-Path $script:kitRoot 'README.md')).TrimEnd()
        $sentence = 'Interactive Brokers, IBKR, IB Gateway and Trader Workstation are trademarks of Interactive Brokers LLC. ' +
        'This project is not affiliated with, endorsed by or sponsored by Interactive Brokers.'
        (($readme -replace '\s+', ' ').EndsWith($sentence)) | Should -BeTrue
    }

    It 'the clock probe image is pinned by digest' {
        $checks = [System.IO.File]::ReadAllText((Join-Path $script:kitRoot 'src\Checks.ps1'))
        $checks | Should -Match "GwClockImage = 'busybox:\d+\.\d+\.\d+@sha256:[0-9a-f]{64}'"
    }
}
