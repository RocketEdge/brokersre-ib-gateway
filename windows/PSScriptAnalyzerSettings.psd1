# PSScriptAnalyzer settings for the Windows host kit (run from the repository root):
#   Invoke-ScriptAnalyzer -Path windows -Recurse -Settings windows/PSScriptAnalyzerSettings.psd1
#
# Strict on purpose: every default rule at every severity, plus the opt-in rules below. Nothing
# is excluded here. The few suppressions that exist are attributes next to the code they cover,
# each with a Justification, so a reviewer sees the reason where it applies.
@{
    Severity            = @('Error', 'Warning', 'Information')
    IncludeDefaultRules = $true
    Rules               = @{
        # The kit must run on Windows PowerShell 5.1 and PowerShell 7: this rule rejects the
        # ternary operator, '&&' / '||' pipeline chains, '??' and other syntax 5.1 cannot parse.
        PSUseCompatibleSyntax                     = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.2')
        }
        PSAvoidLongLines                          = @{
            Enable            = $true
            MaximumLineLength = 200
        }
        # Check functions hand their parameters to Invoke-GwCheckSafely inside script blocks; tell the
        # unused-parameter rule to look there instead of suppressing it.
        PSReviewUnusedParameter                   = @{ CommandsToTraverse = @('Invoke-GwCheckSafely') }
        PSAvoidSemicolonsAsLineTerminators        = @{ Enable = $true }
        PSAvoidUsingDoubleQuotesForConstantString = @{ Enable = $true }
        PSAvoidExclaimOperator                    = @{ Enable = $true }
        # PSUseCorrectCasing stays off: in PSScriptAnalyzer 1.25.0 it intermittently throws a
        # NullReferenceException from UseCorrectCasing.AnalyzeScript (CommandInfo.get_Parameters,
        # observed on both PowerShell editions, 2026-11-12), which makes the gate nondeterministic.
        PSPlaceOpenBrace                          = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSUseConsistentIndentation                = @{
            Enable              = $true
            Kind                = 'space'
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
        }
        PSUseConsistentWhitespace                 = @{
            Enable                          = $true
            CheckInnerBrace                 = $true
            CheckOpenBrace                  = $true
            CheckOpenParen                  = $true
            CheckOperator                   = $true
            CheckPipe                       = $true
            CheckSeparator                  = $true
            # Hashtables in this kit align their '=' signs; the operator check would flag that.
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
    }
}
