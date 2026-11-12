# Opt-in host changes of the Windows host kit ("harden") and their undo.
#
# Every function here changes the host, so every one supports -WhatIf / -Confirm
# (SupportsShouldProcess; power changes declare ConfirmImpact High) and records what it is about
# to change, with the previous value, in a small JSON change journal in the gateway folder BEFORE
# it changes anything. 'harden.ps1 -Undo' replays the journal backwards. A change that fails is
# marked "not applied" in the journal, so undo never reverts something that never happened.
# Nothing here handles a credential: the one password involved (the Windows account password of
# a "run whether logged on or not" task) is asked for by schtasks itself on the console.

$script:GwFirewallRuleName = 'BrokerSRE-Gateway-Block-Api-Ports'

function Get-GwJournalPath {
    <#
    .SYNOPSIS
    Returns the path of the change journal inside a gateway folder.
    .PARAMETER Path
    Gateway folder.
    .OUTPUTS
    System.String: <Path>\harden-journal.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$Path)
    return (Join-Path (Resolve-GwFullPath -Path $Path) 'harden-journal.json')
}

function Get-GwJournal {
    <#
    .SYNOPSIS
    Loads the change journal.
    .DESCRIPTION
    A missing file is an empty journal. A file that is not valid JSON is an error, not an empty
    journal: starting over would throw away the information undo needs. Timestamps are
    normalised to text, because PowerShell 7 parses ISO strings into DateTime and Windows
    PowerShell 5.1 would write those back as '\/Date(...)\/'.
    .PARAMETER Path
    Gateway folder.
    .OUTPUTS
    PSCustomObject: Schema (1) and Entries (array of entries, oldest first). Each entry has Id,
    Time, Action, Kind, Description, Data, Reverted, RevertedTime and Note.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $file = Get-GwJournalPath -Path $Path
    $text = Read-GwTextFile -Path $file
    $entries = New-Object System.Collections.Generic.List[object]
    if (-not [string]::IsNullOrEmpty($text)) {
        try { $document = $text | ConvertFrom-Json }
        catch [System.ArgumentException] {
            throw (New-Object System.InvalidOperationException(
                    ('The change journal {0} is not valid JSON. Repair or move it before hardening again; it holds what undo needs.' -f $file)))
        }
        foreach ($entry in @(Get-GwPropertyValue -InputObject $document -Name 'Entries' -Default @())) {
            if ($null -eq $entry) { continue }
            $entries.Add([pscustomobject][ordered]@{
                    Id           = [string](Get-GwPropertyValue -InputObject $entry -Name 'Id' -Default '')
                    Time         = ConvertTo-GwTimestampText -Value (Get-GwPropertyValue -InputObject $entry -Name 'Time' -Default '')
                    Action       = [string](Get-GwPropertyValue -InputObject $entry -Name 'Action' -Default '')
                    Kind         = [string](Get-GwPropertyValue -InputObject $entry -Name 'Kind' -Default '')
                    Description  = [string](Get-GwPropertyValue -InputObject $entry -Name 'Description' -Default '')
                    Data         = Get-GwPropertyValue -InputObject $entry -Name 'Data'
                    Reverted     = ((Get-GwPropertyValue -InputObject $entry -Name 'Reverted' -Default $false) -eq $true)
                    RevertedTime = ConvertTo-GwTimestampText -Value (Get-GwPropertyValue -InputObject $entry -Name 'RevertedTime' -Default '')
                    Note         = [string](Get-GwPropertyValue -InputObject $entry -Name 'Note' -Default '')
                })
        }
    }
    return [pscustomobject]@{ Schema = 1; Entries = $entries.ToArray() }
}

function Save-GwJournal {
    <#
    .SYNOPSIS
    Writes the change journal atomically (UTF-8 without byte-order mark, LF).
    .PARAMETER Path
    Gateway folder (must exist).
    .PARAMETER Journal
    Object from Get-GwJournal.
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][pscustomobject]$Journal
    )
    $document = [pscustomobject][ordered]@{ Schema = 1; Entries = @($Journal.Entries) }
    $json = ($document | ConvertTo-Json -Depth 6).Replace("`r`n", "`n")
    Write-GwFileAtomic -Path (Get-GwJournalPath -Path $Path) -Text ($json + "`n")
}

function Add-GwJournalEntry {
    <#
    .SYNOPSIS
    Records a change that is about to be made.
    .DESCRIPTION
    Called before the change, so an interrupted run still leaves what undo needs. Data carries
    the previous value in a shape the matching undo branch understands (see Undo-GwHardening).
    .PARAMETER Path
    Gateway folder.
    .PARAMETER Action
    The harden option that caused the change, for example 'DisableSleep'.
    .PARAMETER Kind
    PowerAcValue, RegistryValue, ScheduledTask, IniValue or FirewallRule.
    .PARAMETER Description
    One plain sentence for the operator.
    .PARAMETER Data
    Previous value and coordinates of the change (hashtable or object).
    .OUTPUTS
    The new entry (PSCustomObject).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][ValidateSet('PowerAcValue', 'RegistryValue', 'ScheduledTask', 'IniValue', 'FirewallRule')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)]$Data
    )
    $journal = Get-GwJournal -Path $Path
    $dataObject = $Data
    if ($Data -is [System.Collections.IDictionary]) { $dataObject = [pscustomobject]$Data }
    $entry = [pscustomobject][ordered]@{
        Id           = [guid]::NewGuid().ToString('N')
        Time         = ConvertTo-GwTimestampText -Value (Get-GwUtcNow)
        Action       = $Action
        Kind         = $Kind
        Description  = $Description
        Data         = $dataObject
        Reverted     = $false
        RevertedTime = ''
        Note         = ''
    }
    $journal.Entries = @($journal.Entries) + @($entry)
    Save-GwJournal -Path $Path -Journal $journal
    return $entry
}

function Set-GwJournalEntryState {
    <#
    .SYNOPSIS
    Marks a journal entry as reverted, or as never applied.
    .DESCRIPTION
    In-file bookkeeping only (the host is not touched), which is why it carries no ShouldProcess
    of its own: the caller that reverts the host change owns that decision.
    .PARAMETER Path
    Gateway folder.
    .PARAMETER Id
    Entry id.
    .PARAMETER Note
    Why, for example 'not applied: powercfg exit code 1'.
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Updates the kit''s own journal file; the host change it describes is guarded by the caller''s ShouldProcess.')]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Note = ''
    )
    $journal = Get-GwJournal -Path $Path
    foreach ($entry in $journal.Entries) {
        if ($entry.Id -eq $Id) {
            $entry.Reverted = $true
            $entry.RevertedTime = ConvertTo-GwTimestampText -Value (Get-GwUtcNow)
            $entry.Note = $Note
        }
    }
    Save-GwJournal -Path $Path -Journal $journal
}

function Assert-GwElevated {
    <#
    .SYNOPSIS
    Stops with a plain instruction when the session is not elevated.
    .PARAMETER Operation
    What needs elevation, used in the message.
    .OUTPUTS
    None; throws System.UnauthorizedAccessException when not elevated.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Operation)
    if (-not (Test-GwIsAdministrator)) {
        throw (New-Object System.UnauthorizedAccessException(
                ('{0} needs an elevated PowerShell: right-click PowerShell, choose "Run as administrator" and run the command again.' -f $Operation)))
    }
}

function Get-GwActivePowerScheme {
    <#
    .SYNOPSIS
    Returns the GUID of the active power scheme.
    .DESCRIPTION
    'powercfg /getactivescheme' prints a localised label and the GUID; the GUID is taken by
    pattern. The harden functions address the scheme by GUID, so undo restores the scheme that
    was changed even if the operator switches schemes later.
    .OUTPUTS
    System.String GUID; throws when powercfg does not report one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $result = Invoke-GwPowerCfg -ArgumentList @('/getactivescheme')
    $match = [regex]::Match(($result.Output -join ' '), '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}')
    if ($result.ExitCode -ne 0 -or -not $match.Success) {
        throw (New-Object System.InvalidOperationException('powercfg did not report the active power scheme.'))
    }
    return $match.Value.ToLowerInvariant()
}

function Disable-GwSleep {
    <#
    .SYNOPSIS
    Sets "sleep after" and "hibernate after" to never on AC power.
    .DESCRIPTION
    A sleeping host freezes the gateway. For each of the two settings of the active power
    scheme the previous AC value (seconds) is journaled, then
    'powercfg /setacvalueindex <scheme> SUB_SLEEP <setting> 0' is applied and the scheme is
    re-activated. A setting that is already 0, or that cannot be read, is left alone and not
    journaled. Battery (DC) values are not touched. ConfirmImpact is High: PowerShell asks
    before changing power settings unless -Confirm:$false is given.
    .PARAMETER Path
    Gateway folder (holds the journal).
    .OUTPUTS
    None. Side effects: power scheme values, journal.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true)][string]$Path)
    $scheme = Get-GwActivePowerScheme
    $labels = @{ STANDBYIDLE = 'sleep after'; HIBERNATEIDLE = 'hibernate after' }
    $changed = $false
    foreach ($setting in @('STANDBYIDLE', 'HIBERNATEIDLE')) {
        $previous = Get-GwPowerAcSecond -Alias $setting
        if ($null -eq $previous) {
            Write-GwConsole -Message ('The "{0}" setting could not be read; it was left unchanged.' -f $labels[$setting]) -Status 'WARN'
            continue
        }
        if ($previous -eq 0) { continue }
        $description = 'Power: "{0}" on AC changed from {1} minutes to never' -f $labels[$setting], [int]($previous / 60)
        if (-not $PSCmdlet.ShouldProcess(('power scheme {0}' -f $scheme), $description)) { continue }
        $entry = Add-GwJournalEntry -Path $Path -Action 'DisableSleep' -Kind 'PowerAcValue' -Description $description `
            -Data @{ Scheme = $scheme; Setting = $setting; PreviousSeconds = [long]$previous }
        $result = Invoke-GwPowerCfg -ArgumentList @('/setacvalueindex', $scheme, 'SUB_SLEEP', $setting, '0')
        if ($result.ExitCode -ne 0) {
            Set-GwJournalEntryState -Path $Path -Id $entry.Id -Note ('not applied: powercfg exit code {0}' -f $result.ExitCode)
            throw (New-Object System.InvalidOperationException(
                    ('powercfg could not change "{0}" (exit code {1}). Try again from an elevated PowerShell.' -f $labels[$setting], $result.ExitCode)))
        }
        $changed = $true
        Write-GwConsole -Message $description -Status 'PASS'
    }
    if ($changed) { Invoke-GwPowerCfg -ArgumentList @('/setactive', $scheme) | Out-Null }
}

function Set-GwUpdateActiveWindow {
    <#
    .SYNOPSIS
    Sets the Windows Update active hours through the documented policy values.
    .DESCRIPTION
    Writes SetActiveHours = 1, ActiveHoursStart and ActiveHoursEnd under
    HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate (the registry form Microsoft documents
    in "Manage device restarts after updates"). Windows then does not restart for updates inside
    the window; it still restarts outside it. Each value is journaled with its previous state
    (existed or not, previous number) before it is written; a value that already matches is
    left alone. Needs elevation. Settings will show that active hours are managed by policy;
    'harden.ps1 -Undo' removes the values again. Whether Windows Home honours these policy
    values is not verified.
    .PARAMETER Path
    Gateway folder (holds the journal).
    .PARAMETER Start
    Start hour, 0 to 23.
    .PARAMETER End
    End hour, 0 to 23; the window may cross midnight and is at most 18 hours long.
    .OUTPUTS
    None. Side effects: three registry values, journal.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateRange(0, 23)][int]$Start,
        [Parameter(Mandatory = $true)][ValidateRange(0, 23)][int]$End
    )
    $length = (($End - $Start) + 24) % 24
    if ($length -eq 0) { throw (New-Object System.ArgumentException('Start and End must differ.')) }
    if ($length -gt 18) { throw (New-Object System.ArgumentException(('The window is {0} hours long; Windows accepts at most 18 hours.' -f $length))) }
    $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $window = Format-GwHourWindow -Start $Start -End $End
    if (-not $PSCmdlet.ShouldProcess($key, ('Set Windows Update active hours to {0}' -f $window))) { return }
    Assert-GwElevated -Operation 'Setting Windows Update active hours'
    $desired = [ordered]@{ SetActiveHours = 1; ActiveHoursStart = $Start; ActiveHoursEnd = $End }
    foreach ($name in $desired.Keys) {
        $previous = Invoke-GwRegistry -Operation Get -Path $key -Name $name
        if ($null -ne $previous -and [int]$previous -eq [int]$desired[$name]) { continue }
        $existed = ($null -ne $previous)
        $previousValue = 0
        if ($existed) { $previousValue = [int]$previous }
        $description = 'Windows Update policy value {0} set to {1}' -f $name, $desired[$name]
        Add-GwJournalEntry -Path $Path -Action 'SetActiveHours' -Kind 'RegistryValue' -Description $description `
            -Data @{ Path = $key; Name = $name; Existed = $existed; PreviousValue = $previousValue; ValueKind = 'DWord' } | Out-Null
        Invoke-GwRegistry -Operation Set -Path $key -Name $name -Value ([int]$desired[$name]) -Kind 'DWord'
    }
    Write-GwConsole -Message ('Windows Update active hours: {0}. Windows can still restart outside this window.' -f $window) -Status 'PASS'
}

function New-GwTaskXml {
    <#
    .SYNOPSIS
    Builds a Task Scheduler definition (XML, schema version 1.2).
    .DESCRIPTION
    Pure text: nothing is registered. XML is used because only it can express the event trigger
    of the clock fix, and because the same builder serves all three kit tasks. Every value is
    XML-escaped. Triggers: Boot (at startup, 30 s delay), Logon (when the given user signs in,
    15 s delay) and Resume (System event log: Power-Troubleshooter event 1, Kernel-Power events
    107 and 507, logged when Windows returns from sleep or modern standby). The task runs with
    least privilege, also on battery, never in parallel with itself.
    .PARAMETER Description
    Text shown in Task Scheduler.
    .PARAMETER UserSid
    SID the task runs as.
    .PARAMETER UserName
    Account name, used for the logon trigger.
    .PARAMETER LogonType
    InteractiveToken (only while the user is signed in), S4U (no sign-in needed, no stored
    password, local resources only) or Password (no sign-in needed, Windows stores the password).
    .PARAMETER Trigger
    Boot, Logon or Resume.
    .PARAMETER Action
    One or more hashtables with Command and Arguments; they run in order.
    .PARAMETER ExecutionTimeLimit
    ISO 8601 duration; PT0S means no limit (needed by the keep-alive start task).
    .OUTPUTS
    System.String, the XML document (declared UTF-16; write the file as UTF-16).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Builds text; registering the task is done, behind ShouldProcess, by the Register functions.')]
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$UserName,
        [Parameter(Mandatory = $true)][ValidateSet('InteractiveToken', 'S4U', 'Password')][string]$LogonType,
        [Parameter(Mandatory = $true)][ValidateSet('Boot', 'Logon', 'Resume')][string]$Trigger,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary[]]$Action,
        [ValidatePattern('^PT\d+[HMS]$')][string]$ExecutionTimeLimit = 'PT0S'
    )
    $escape = { param($value) [System.Security.SecurityElement]::Escape([string]$value) }
    switch ($Trigger) {
        'Boot' { $triggerXml = '    <BootTrigger>' + "`n" + '      <Enabled>true</Enabled>' + "`n" + '      <Delay>PT30S</Delay>' + "`n" + '    </BootTrigger>' }
        'Logon' {
            $triggerXml = '    <LogonTrigger>' + "`n" + '      <Enabled>true</Enabled>' + "`n" + ('      <UserId>{0}</UserId>' -f (& $escape $UserName)) + "`n" +
            '      <Delay>PT15S</Delay>' + "`n" + '    </LogonTrigger>'
        }
        default {
            $query = '<QueryList><Query Id="0" Path="System">' +
            "<Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]</Select>" +
            "<Select Path=`"System`">*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and (EventID=107 or EventID=507)]]</Select>" +
            '</Query></QueryList>'
            $triggerXml = '    <EventTrigger>' + "`n" + '      <Enabled>true</Enabled>' + "`n" + ('      <Subscription>{0}</Subscription>' -f (& $escape $query)) + "`n" +
            '    </EventTrigger>'
        }
    }
    $actionLines = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Action) {
        $actionLines.Add('    <Exec>')
        $actionLines.Add(('      <Command>{0}</Command>' -f (& $escape $item['Command'])))
        $actionLines.Add(('      <Arguments>{0}</Arguments>' -f (& $escape $item['Arguments'])))
        $actionLines.Add('    </Exec>')
    }
    $lines = @(
        '<?xml version="1.0" encoding="UTF-16"?>'
        '<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">'
        '  <RegistrationInfo>'
        '    <Author>BrokerSRE Windows host kit</Author>'
        ('    <Description>{0}</Description>' -f (& $escape $Description))
        '  </RegistrationInfo>'
        '  <Triggers>'
        $triggerXml
        '  </Triggers>'
        '  <Principals>'
        '    <Principal id="Author">'
        ('      <UserId>{0}</UserId>' -f (& $escape $UserSid))
        ('      <LogonType>{0}</LogonType>' -f $LogonType)
        '      <RunLevel>LeastPrivilege</RunLevel>'
        '    </Principal>'
        '  </Principals>'
        '  <Settings>'
        '    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>'
        '    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>'
        '    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>'
        '    <AllowHardTerminate>true</AllowHardTerminate>'
        '    <StartWhenAvailable>true</StartWhenAvailable>'
        '    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>'
        '    <IdleSettings>'
        '      <StopOnIdleEnd>false</StopOnIdleEnd>'
        '      <RestartOnIdle>false</RestartOnIdle>'
        '    </IdleSettings>'
        '    <AllowStartOnDemand>true</AllowStartOnDemand>'
        '    <Enabled>true</Enabled>'
        '    <Hidden>false</Hidden>'
        '    <RunOnlyIfIdle>false</RunOnlyIfIdle>'
        '    <WakeToRun>false</WakeToRun>'
        ('    <ExecutionTimeLimit>{0}</ExecutionTimeLimit>' -f $ExecutionTimeLimit)
        '    <Priority>7</Priority>'
        '  </Settings>'
        '  <Actions Context="Author">'
        ($actionLines.ToArray() -join "`n")
        '  </Actions>'
        '</Task>'
    )
    return (($lines -join "`n") + "`n")
}

function Register-GwKitTask {
    <#
    .SYNOPSIS
    Registers one kit task from XML and journals it.
    .DESCRIPTION
    Shared tail of the Register functions; the caller has already asked ShouldProcess. Writes
    the XML to a temporary UTF-16 file in the gateway folder, journals the task (with whether
    it existed before), runs 'schtasks /Create /TN <name> /XML <file> /F' and deletes the file.
    For LogonType Password it adds '/RU <user> /RP *' and lets schtasks ask for the Windows
    password on the console; the kit never sees it. A refused registration is marked "not
    applied" in the journal and reported as an error.
    .PARAMETER Path
    Gateway folder.
    .PARAMETER TaskName
    Full task name.
    .PARAMETER Xml
    Task definition from New-GwTaskXml.
    .PARAMETER Action
    Harden option name for the journal.
    .PARAMETER Description
    Sentence for the journal and the console.
    .PARAMETER RunAsAccount
    Account name; when given, schtasks stores that account's password (asked on the console).
    .OUTPUTS
    None.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TaskName,
        [Parameter(Mandatory = $true)][string]$Xml,
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$Description,
        [string]$RunAsAccount = ''
    )
    $folder = Resolve-GwFullPath -Path $Path
    $existedBefore = Test-GwKitTask -Name $TaskName
    $xmlFile = Join-Path $folder ('.task-{0}.xml' -f [guid]::NewGuid().ToString('N'))
    $entry = Add-GwJournalEntry -Path $folder -Action $Action -Kind 'ScheduledTask' -Description $Description `
        -Data @{ TaskName = $TaskName; ExistedBefore = $existedBefore }
    try {
        [System.IO.File]::WriteAllText($xmlFile, $Xml, [System.Text.Encoding]::Unicode)
        $arguments = New-Object System.Collections.Generic.List[string]
        foreach ($argument in @('/Create', '/TN', $TaskName, '/XML', $xmlFile)) { $arguments.Add($argument) }
        $interactive = $false
        if (-not [string]::IsNullOrEmpty($RunAsAccount)) {
            foreach ($argument in @('/RU', $RunAsAccount, '/RP', '*')) { $arguments.Add($argument) }
            $interactive = $true
            Write-GwConsole -Message ('Windows now asks for the password of {0} (typing is hidden). It is stored by Task Scheduler, not by this kit.' -f $RunAsAccount)
        }
        $arguments.Add('/F')
        $result = Invoke-GwSchTasks -ArgumentList $arguments.ToArray() -Interactive:$interactive
    }
    finally {
        if ([System.IO.File]::Exists($xmlFile)) { [System.IO.File]::Delete($xmlFile) }
    }
    if ($result.ExitCode -ne 0) {
        Set-GwJournalEntryState -Path $folder -Id $entry.Id -Note ('not applied: schtasks exit code {0}' -f $result.ExitCode)
        throw (New-Object System.InvalidOperationException(
                ('schtasks could not register "{0}" (exit code {1}): {2}' -f $TaskName, $result.ExitCode, ($result.Output -join ' '))))
    }
    Write-GwConsole -Message $Description -Status 'PASS'
}

function Register-GwStartTask {
    <#
    .SYNOPSIS
    Registers the scheduled task that starts the gateway stack after a Windows restart.
    .DESCRIPTION
    The task runs the kit's start.ps1, which waits for the container engine and runs
    'docker compose up -d --no-recreate': it starts a stopped stack and never replaces a
    running one.
    Mode DockerDesktop: a task at sign-in of the current user (interactive token). Docker
    Desktop only runs in a signed-in session, so an unattended computer additionally needs
    Windows auto-logon, which this kit documents but never configures.
    Mode WslEngine: a task at system startup running as the current user "whether logged on or
    not", with -KeepAlive so that one wsl.exe session stays open and the distribution is not
    shut down as idle. LogonType Password lets Windows store the account password (schtasks
    asks for it); S4U stores none. With -AfterSignIn the sign-in variant is registered instead.
    Whether WSL starts in a session without sign-in depends on the WSL version (Microsoft
    tracks "Store WSL isn't accessible from Session 0" as microsoft/WSL#9231), so the boot task
    must be validated on the computer by restarting it.
    The boot task needs elevation; the sign-in task is attempted without.
    .PARAMETER Path
    Gateway folder (setup.ps1 must have run there).
    .PARAMETER Mode
    DockerDesktop or WslEngine.
    .PARAMETER AfterSignIn
    WslEngine only: register the sign-in task instead of the boot task.
    .PARAMETER LogonType
    WslEngine boot task: Password (default) or S4U.
    .PARAMETER KitRoot
    Folder that holds start.ps1; defaults to the kit's own folder. The task refers to it, so
    the kit must stay where it is.
    .OUTPUTS
    None. Side effects: one scheduled task, journal.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet('DockerDesktop', 'WslEngine')][string]$Mode,
        [switch]$AfterSignIn,
        [ValidateSet('Password', 'S4U')][string]$LogonType = 'Password',
        [string]$KitRoot = $script:GwModuleRoot
    )
    $folder = Resolve-GwFullPath -Path $Path
    $state = Get-GwKitState -Path $folder
    if ($null -eq $state) {
        throw (New-Object System.InvalidOperationException(('No kit-state.json in {0}: run setup.ps1 for this folder first.' -f $folder)))
    }
    $tradingMode = [string](Get-GwPropertyValue -InputObject $state -Name 'TradingMode' -Default 'paper')
    $user = Get-GwCurrentUser
    $keepAlive = ($Mode -eq 'WslEngine')
    $atBoot = ($Mode -eq 'WslEngine' -and -not $AfterSignIn)

    $kind = 'SignIn'
    $trigger = 'Logon'
    $taskLogonType = 'InteractiveToken'
    $when = 'after {0} signs in' -f $user.Name
    if ($atBoot) {
        $kind = 'Boot'
        $trigger = 'Boot'
        $taskLogonType = $LogonType
        $when = 'at Windows startup, without sign-in'
    }
    $taskName = Get-GwTaskName -Kind $kind -TradingMode $tradingMode
    $description = 'Scheduled task "{0}": starts the gateway stack in {1} {2}' -f $taskName, $folder, $when
    if (-not $PSCmdlet.ShouldProcess($taskName, ('Register scheduled task ({0})' -f $when))) { return }
    if ($atBoot) { Assert-GwElevated -Operation 'Registering a task that runs at startup without sign-in' }

    $arguments = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Path "{1}"' -f (Join-Path $KitRoot 'start.ps1'), $folder
    $limit = 'PT1H'
    if ($keepAlive) {
        $arguments += ' -KeepAlive'
        $limit = 'PT0S'
    }
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $taskDescription = 'Created by the BrokerSRE Windows host kit (harden.ps1). Starts the IB Gateway stack in {0}; never replaces a running gateway.' -f $folder
    $xml = New-GwTaskXml -Description $taskDescription -UserSid $user.Sid -UserName $user.Name -LogonType $taskLogonType -Trigger $trigger `
        -Action @(@{ Command = $powershell; Arguments = $arguments }) -ExecutionTimeLimit $limit
    $runAsAccount = ''
    if ($taskLogonType -eq 'Password') { $runAsAccount = $user.Name }
    Register-GwKitTask -Path $folder -TaskName $taskName -Xml $xml -Action 'StartAtBoot' -Description $description -RunAsAccount $runAsAccount
}

function Register-GwResumeClockTask {
    <#
    .SYNOPSIS
    Registers the scheduled task that re-syncs the container VM's clock after a resume from sleep.
    .DESCRIPTION
    After the host sleeps, the clock of the WSL VM can lag (microsoft/WSL#10006). The task
    listens for the resume events in the System log and runs
    'wsl.exe -d <distribution> -u root -- hwclock -s', which sets the Linux clock from the
    hardware clock; the action is listed twice because the first read after a resume can time
    out. The distribution is Docker Desktop's ('docker-desktop') or the one that runs Docker
    Engine. Nothing is restarted. LogonType Interactive runs while the user is signed in; for a
    computer that runs without sign-in pass S4U or Password (needs elevation; Password makes
    Windows ask for the account password). doctor.ps1 measures whether the clock is right.
    .PARAMETER Path
    Gateway folder (setup.ps1 must have run there).
    .PARAMETER LogonType
    Interactive (default), S4U or Password.
    .OUTPUTS
    None. Side effects: one scheduled task, journal.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateSet('Interactive', 'S4U', 'Password')][string]$LogonType = 'Interactive'
    )
    $folder = Resolve-GwFullPath -Path $Path
    $state = Get-GwKitState -Path $folder
    if ($null -eq $state) {
        throw (New-Object System.InvalidOperationException(('No kit-state.json in {0}: run setup.ps1 for this folder first.' -f $folder)))
    }
    $distro = 'docker-desktop'
    if ([string](Get-GwPropertyValue -InputObject $state -Name 'Runtime' -Default '') -eq 'WslEngine') {
        $distro = [string](Get-GwPropertyValue -InputObject $state -Name 'Distro' -Default '')
    }
    if ($distro -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw (New-Object System.InvalidOperationException(('The WSL distribution name "{0}" is not usable in a task command line.' -f $distro)))
    }
    $taskName = Get-GwTaskName -Kind 'ClockFix'
    $description = 'Scheduled task "{0}": runs hwclock -s in {1} after every resume from sleep' -f $taskName, $distro
    if (-not $PSCmdlet.ShouldProcess($taskName, 'Register scheduled task (re-sync the container clock after resume)')) { return }
    if ($LogonType -ne 'Interactive') { Assert-GwElevated -Operation 'Registering a task that runs without sign-in' }

    $user = Get-GwCurrentUser
    $wsl = Join-Path $env:SystemRoot 'System32\wsl.exe'
    $arguments = '-d {0} -u root -- hwclock -s' -f $distro
    $taskLogonType = 'InteractiveToken'
    if ($LogonType -ne 'Interactive') { $taskLogonType = $LogonType }
    $taskDescription = 'Created by the BrokerSRE Windows host kit (harden.ps1). Sets the clock of the container VM from the hardware clock after a resume from sleep.'
    $xml = New-GwTaskXml -Description $taskDescription -UserSid $user.Sid -UserName $user.Name -LogonType $taskLogonType -Trigger 'Resume' `
        -Action @(@{ Command = $wsl; Arguments = $arguments }, @{ Command = $wsl; Arguments = $arguments }) -ExecutionTimeLimit 'PT5M'
    $runAsAccount = ''
    if ($taskLogonType -eq 'Password') { $runAsAccount = $user.Name }
    Register-GwKitTask -Path $folder -TaskName $taskName -Xml $xml -Action 'ResumeClockFix' -Description $description -RunAsAccount $runAsAccount
}

function Set-GwWslConfigValue {
    <#
    .SYNOPSIS
    Sets one key in .wslconfig, keeping everything else, with a backup and a journal entry.
    .DESCRIPTION
    Merges instead of overwriting: comments and other keys stay. Before the first change a copy
    of the existing file is saved next to it as '<file>.brokersre-backup-<UTC timestamp>'. The
    journal records the previous value of the key (or that it, its section or the file did not
    exist), which is what undo restores; later edits by the operator survive an undo. A value
    that is already set (compared case-insensitively) is left alone. The change takes effect
    only when WSL restarts ('wsl --shutdown' or a reboot); this function never restarts WSL,
    because that would stop the gateway.
    .PARAMETER Path
    Gateway folder (holds the journal).
    .PARAMETER WslConfigPath
    Path of .wslconfig; defaults to %UserProfile%\.wslconfig.
    .PARAMETER Section
    Section name without brackets, for example 'wsl2' or 'general'.
    .PARAMETER Key
    Key name.
    .PARAMETER Value
    Value to set.
    .OUTPUTS
    None. Side effects: .wslconfig, a backup file, journal.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$WslConfigPath = (Get-GwDefaultWslConfigPath),
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Value
    )
    $file = Resolve-GwFullPath -Path $WslConfigPath
    $text = Read-GwTextFile -Path $file
    $fileExisted = ($null -ne $text)
    $current = Get-GwIniValue -Text $text -Section $Section -Key $Key
    if ($null -ne $current -and $current.Trim() -ieq $Value) { return }
    $shown = 'not set'
    if ($null -ne $current) { $shown = $current.Trim() }
    $description = '.wslconfig: [{0}] {1} changed from {2} to {3}' -f $Section, $Key, $shown, $Value
    if (-not $PSCmdlet.ShouldProcess($file, $description)) { return }

    $backup = ''
    if ($fileExisted) {
        $stamp = (Get-GwUtcNow).ToString('yyyyMMddTHHmmssZ', [System.Globalization.CultureInfo]::InvariantCulture)
        $backup = '{0}.brokersre-backup-{1}' -f $file, $stamp
        if (-not [System.IO.File]::Exists($backup)) { [System.IO.File]::Copy($file, $backup) }
    }
    $sectionExisted = ((Find-GwIniKey -Line ([string[]]@(Split-GwIniLine -Text $text)) -Section $Section -Key $Key).SectionIndex -ge 0)
    $previousValue = ''
    if ($null -ne $current) { $previousValue = [string]$current }
    Add-GwJournalEntry -Path $Path -Action 'WslConfig' -Kind 'IniValue' -Description $description -Data @{
        File = $file; Section = $Section; Key = $Key; Existed = ($null -ne $current); PreviousValue = $previousValue
        SectionExisted = $sectionExisted; FileExisted = $fileExisted; BackupPath = $backup
    } | Out-Null
    Write-GwFileAtomic -Path $file -Text (Set-GwIniValue -Text $text -Section $Section -Key $Key -Value $Value)
    Write-GwConsole -Message ('{0}. Takes effect after WSL restarts (wsl --shutdown stops the gateway: do it in a maintenance window).' -f $description) -Status 'PASS'
}

function Add-GwFirewallBlockRule {
    <#
    .SYNOPSIS
    Adds a Windows Firewall rule that blocks inbound TCP 4001, 4002 and 9810 from the network.
    .DESCRIPTION
    Defence in depth: the compose file already binds the ports to 127.0.0.1. A block rule wins
    over any allow rule, and Windows Firewall does not filter loopback traffic, so local API
    clients keep working while other computers cannot reach the ports even if a compose file
    or a port proxy is changed later. One rule, all profiles, journaled; a rule that already
    exists is left alone. Needs elevation.
    .PARAMETER Path
    Gateway folder (holds the journal).
    .OUTPUTS
    None. Side effects: one firewall rule, journal.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (Invoke-GwFirewall -Operation Exists -Name $script:GwFirewallRuleName) { return }
    $description = 'Firewall: inbound block rule "{0}" for TCP ports 4001, 4002 and 9810' -f $script:GwFirewallRuleName
    if (-not $PSCmdlet.ShouldProcess('Windows Firewall', $description)) { return }
    Assert-GwElevated -Operation 'Adding a firewall rule'
    Add-GwJournalEntry -Path $Path -Action 'FirewallLoopbackOnly' -Kind 'FirewallRule' -Description $description -Data @{ RuleName = $script:GwFirewallRuleName } | Out-Null
    Invoke-GwFirewall -Operation Add -Name $script:GwFirewallRuleName -DisplayName 'BrokerSRE Gateway: block API ports from the network' `
        -Description 'Created by the BrokerSRE Windows host kit (harden.ps1 -FirewallLoopbackOnly). Loopback is not affected.' -Port @(4001, 4002, 9810)
    Write-GwConsole -Message $description -Status 'PASS'
}

function Undo-GwHardening {
    <#
    .SYNOPSIS
    Reverts every journaled host change that has not been reverted yet, newest first.
    .DESCRIPTION
    Per kind: PowerAcValue restores the AC seconds of the journaled scheme (and re-activates
    that scheme only if it is still the active one); RegistryValue writes the previous number
    back or removes the value that did not exist; ScheduledTask deletes the task unless an
    earlier entry shows it existed before; IniValue restores or removes the key (and the
    section or file the kit created, if it is empty again) while keeping the operator's other
    edits; FirewallRule removes the rule. Entries that need elevation are reported as
    NeedsElevation and stay in the journal for an elevated run. Each reverted entry is marked
    in the journal immediately, so an interrupted undo can be resumed. ConfirmImpact is High.
    .PARAMETER Path
    Gateway folder (holds the journal).
    .OUTPUTS
    PSCustomObject per processed entry: Action, Description, Result (Reverted, NeedsElevation or Failed).
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $journal = Get-GwJournal -Path $Path
    $pending = @($journal.Entries | Where-Object { -not $_.Reverted })
    [array]::Reverse($pending)
    $elevated = Test-GwIsAdministrator
    foreach ($entry in $pending) {
        $data = $entry.Data
        $needsElevation = ($entry.Kind -eq 'FirewallRule') -or ($entry.Kind -eq 'RegistryValue' -and [string]$data.Path -like 'HKLM:*')
        if ($needsElevation -and -not $elevated) {
            Write-GwConsole -Message ('Needs an elevated PowerShell to revert: {0}' -f $entry.Description) -Status 'WARN'
            [pscustomobject]@{ Action = $entry.Action; Description = $entry.Description; Result = 'NeedsElevation' }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($entry.Description, 'Revert')) { continue }
        $result = 'Reverted'
        switch ($entry.Kind) {
            'PowerAcValue' {
                $set = Invoke-GwPowerCfg -ArgumentList @('/setacvalueindex', [string]$data.Scheme, 'SUB_SLEEP', [string]$data.Setting, ([string][long]$data.PreviousSeconds))
                if ($set.ExitCode -ne 0) { $result = 'Failed' }
                elseif ((Get-GwActivePowerScheme) -eq ([string]$data.Scheme).ToLowerInvariant()) {
                    Invoke-GwPowerCfg -ArgumentList @('/setactive', [string]$data.Scheme) | Out-Null
                }
            }
            'RegistryValue' {
                if ($data.Existed -eq $true) {
                    Invoke-GwRegistry -Operation Set -Path ([string]$data.Path) -Name ([string]$data.Name) -Value ([int]$data.PreviousValue) -Kind 'DWord'
                }
                elseif ($null -ne (Invoke-GwRegistry -Operation Get -Path ([string]$data.Path) -Name ([string]$data.Name))) {
                    Invoke-GwRegistry -Operation Remove -Path ([string]$data.Path) -Name ([string]$data.Name)
                }
            }
            'ScheduledTask' {
                if ($data.ExistedBefore -ne $true -and (Test-GwKitTask -Name ([string]$data.TaskName))) {
                    $delete = Invoke-GwSchTasks -ArgumentList @('/Delete', '/TN', [string]$data.TaskName, '/F')
                    if ($delete.ExitCode -ne 0) { $result = 'Failed' }
                }
            }
            'IniValue' {
                $file = [string]$data.File
                $text = Read-GwTextFile -Path $file
                if ($null -ne $text) {
                    if ($data.Existed -eq $true) {
                        $text = Set-GwIniValue -Text $text -Section ([string]$data.Section) -Key ([string]$data.Key) -Value ([string]$data.PreviousValue)
                    }
                    else {
                        $createdSection = ((Get-GwPropertyValue -InputObject $data -Name 'SectionExisted' -Default $true) -ne $true)
                        $text = Remove-GwIniValue -Text $text -Section ([string]$data.Section) -Key ([string]$data.Key) -RemoveEmptySection:$createdSection
                    }
                    $createdFile = ((Get-GwPropertyValue -InputObject $data -Name 'FileExisted' -Default $true) -ne $true)
                    if ($createdFile -and [string]::IsNullOrEmpty($text)) { [System.IO.File]::Delete($file) }
                    else { Write-GwFileAtomic -Path $file -Text ([string]$text) }
                }
            }
            'FirewallRule' {
                if (Invoke-GwFirewall -Operation Exists -Name ([string]$data.RuleName)) {
                    Invoke-GwFirewall -Operation Remove -Name ([string]$data.RuleName)
                }
            }
            default { $result = 'Failed' }
        }
        if ($result -eq 'Reverted') {
            Set-GwJournalEntryState -Path $Path -Id $entry.Id -Note 'reverted by harden.ps1 -Undo'
            Write-GwConsole -Message ('Reverted: {0}' -f $entry.Description) -Status 'PASS'
        }
        else {
            Write-GwConsole -Message ('Could not revert: {0}' -f $entry.Description) -Status 'FAIL'
        }
        [pscustomobject]@{ Action = $entry.Action; Description = $entry.Description; Result = $result }
    }
}
