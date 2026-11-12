# Module manifest of the BrokerSRE Windows host kit. FunctionsToExport is an explicit list (no
# wildcard) so command discovery stays fast; tests/Kit.Tests.ps1 fails when it drifts from the
# functions the module defines.
@{
    RootModule           = 'BrokerSre.Gateway.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6c3f3f0e-6a52-4a83-9d0f-2f1b7a4c9e11'
    Author               = 'RocketEdge'
    CompanyName          = 'RocketEdge'
    Copyright            = '(c) RocketEdge. MIT License.'
    Description          = 'Windows host kit for the brokersre-ib-gateway container: guided setup, read-only doctor, reversible hardening.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = '*'
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags       = @('IBGateway', 'Docker', 'WSL2', 'Windows')
            LicenseUri = 'https://github.com/RocketEdge/brokersre-ib-gateway/blob/main/LICENSE'
            ProjectUri = 'https://github.com/RocketEdge/brokersre-ib-gateway'
        }
    }
}
