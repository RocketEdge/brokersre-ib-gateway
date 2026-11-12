# Secret handling of the Windows host kit: writing the IBKR username and password files exactly
# as the container expects them, restricting the folder to the operator's account, and inspecting
# existing files without ever showing their content. The kit never logs, prints or returns a
# secret, and nothing here puts one on a command line.

function Write-GwSecretFile {
    <#
    .SYNOPSIS
    Writes a SecureString to a file as UTF-8 without byte-order mark and without trailing newline.
    .DESCRIPTION
    The gateway image reads the file with "$(<file)": a byte-order mark, UTF-16 or a carriage
    return would become part of the username or password and the login would fail (and repeated
    failed logins can lock an IBKR account). Windows PowerShell 5.1 produces exactly those
    defects with '>' (UTF-16), Out-File and Set-Content -Encoding UTF8 (byte-order mark), so the
    value is written with System.IO.File.WriteAllText and UTF8Encoding($false).
    The SecureString is copied to a BSTR, read once and the BSTR is zeroed and freed in a
    finally block whatever happens. The text goes to a temporary file in the same (protected)
    folder and replaces the target in one step. An empty value or one containing a line break
    or NUL is refused; the error message never contains the value.
    .PARAMETER Path
    Secret file to create or replace. Its directory must exist.
    .PARAMETER SecureValue
    The secret, as returned by Read-Host -AsSecureString.
    .OUTPUTS
    None. Side effect: the file holds exactly the UTF-8 bytes of the value.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][System.Security.SecureString]$SecureValue
    )
    $target = Resolve-GwFullPath -Path $Path
    if (-not $PSCmdlet.ShouldProcess($target, 'Write secret file (UTF-8, no byte-order mark, no newline)')) { return }
    $directory = Split-Path -Parent $target
    $temporary = Join-Path $directory ('.{0}.{1}.tmp' -f (Split-Path -Leaf $target), [guid]::NewGuid().ToString('N'))
    $pointer = [IntPtr]::Zero
    $text = $null
    try {
        $pointer = Get-GwBstr -SecureValue $SecureValue
        $text = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ($text.Length -eq 0) {
            throw (New-Object System.ArgumentException('The value is empty; nothing was written.'))
        }
        if ($text.IndexOfAny([char[]]@([char]13, [char]10, [char]0)) -ge 0) {
            throw (New-Object System.ArgumentException('The value contains a line break or a NUL character; nothing was written.'))
        }
        [System.IO.File]::WriteAllText($temporary, $text, (New-Object System.Text.UTF8Encoding($false)))
        Move-GwFileOverwrite -Source $temporary -Destination $target
    }
    finally {
        $text = $null
        Clear-GwBstr -Pointer $pointer
        if ([System.IO.File]::Exists($temporary)) { [System.IO.File]::Delete($temporary) }
    }
}

function Protect-GwSecretFolder {
    <#
    .SYNOPSIS
    Restricts a folder to the current Windows account: inheritance off, every other entry removed.
    .DESCRIPTION
    Replaces the folder's access list with one rule: full control for the current user, inherited
    by files and subfolders. SYSTEM and Administrators lose access too (an administrator can
    still take ownership; that is Windows, not something a file ACL can prevent).
    A fresh DirectorySecurity object is applied instead of an edited copy of the current one, so
    the owner section is never rewritten (Set-Acl fails for a non-elevated user when it has to
    restore an owner such as BUILTIN\Administrators).
    Observed on Docker Desktop 4.99.0 with the WSL 2 backend (2026-11-12): a file in a folder
    protected this way is still readable inside a container through a read-only bind mount,
    because Docker Desktop accesses Windows files as the signed-in user. Docker Engine inside a
    WSL distribution reaches the file through the same user's session (not verified here).
    With -IncludeSystem the list also names SYSTEM and the Administrators group. That is the
    fallback for a Docker installation whose file sharing runs under another account: still no
    inheritance and no ordinary users, but not owner-only. setup.ps1 uses it only after the
    owner-only list was shown not to work, and says so.
    .PARAMETER Path
    Existing folder, normally <gateway folder>\secrets.
    .PARAMETER IncludeSystem
    Also allow SYSTEM (S-1-5-18) and BUILTIN\Administrators (S-1-5-32-544).
    .OUTPUTS
    None. Side effect: the folder's access list.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$IncludeSystem
    )
    $target = Resolve-GwFullPath -Path $Path
    $user = Get-GwCurrentUser
    $who = '{0} only' -f $user.Name
    if ($IncludeSystem) { $who = '{0}, SYSTEM and Administrators' -f $user.Name }
    if (-not $PSCmdlet.ShouldProcess($target, ('Restrict access to {0} (disable inheritance, remove other entries)' -f $who))) { return }
    $sids = New-Object System.Collections.Generic.List[string]
    $sids.Add($user.Sid)
    if ($IncludeSystem) {
        $sids.Add('S-1-5-18')
        $sids.Add('S-1-5-32-544')
    }
    $inheritance = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sidText in $sids) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier($sidText)),
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    # Not Set-Acl: on an already protected folder it failed with "the process does not possess
    # the SeSecurityPrivilege privilege" (it also tries to write the audit section). The .NET
    # call writes only the section that changed, the access rules. The method lives on
    # DirectoryInfo in .NET Framework and in FileSystemAclExtensions in .NET.
    $info = New-Object System.IO.DirectoryInfo($target)
    if ($PSVersionTable.PSEdition -eq 'Core') { [System.IO.FileSystemAclExtensions]::SetAccessControl($info, $security) }
    else { $info.SetAccessControl($security) }
}

function Get-GwAclOtherIdentity {
    <#
    .SYNOPSIS
    Lists the accounts, other than the current user, that are allowed to access a path.
    .DESCRIPTION
    Read-only. Compares by SID so a renamed or localised account name does not matter; an
    identity that cannot be translated is reported by its raw value.
    .PARAMETER Path
    Existing file or folder.
    .OUTPUTS
    System.String[] of account names; nothing when only the current user has access.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $currentSid = (Get-GwCurrentUser).Sid
    $acl = Get-Acl -LiteralPath (Resolve-GwFullPath -Path $Path)
    $names = New-Object System.Collections.Generic.List[string]
    foreach ($rule in $acl.Access) {
        if ([string]$rule.AccessControlType -ne 'Allow') { continue }
        $sidText = [string]$rule.IdentityReference.Value
        try { $sidText = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
        catch [System.Security.Principal.IdentityNotMappedException] {
            Write-Verbose ('Identity not translated: {0}' -f $rule.IdentityReference.Value)
        }
        if ($sidText -eq $currentSid) { continue }
        $name = [string]$rule.IdentityReference.Value
        if (-not $names.Contains($name)) { $names.Add($name) }
    }
    return [string[]]$names.ToArray()
}

function Get-GwSecretFileFinding {
    <#
    .SYNOPSIS
    Inspects the bytes of a secret file and names every encoding defect, without revealing content.
    .DESCRIPTION
    Reads the bytes, classifies them and forgets them. The result is a list of fixed codes:
    Missing, Empty, Utf8Bom, Utf16 (a UTF-16 mark or any NUL byte), CarriageReturn,
    TrailingLineFeed (line feeds at the very end only), EmbeddedLineFeed (a line break inside
    the value) and InvalidUtf8 (for example ANSI-encoded accented characters). Neither the
    content nor its length is returned.
    .PARAMETER Path
    Secret file.
    .OUTPUTS
    System.String[] of codes; nothing for a clean file.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $target = Resolve-GwFullPath -Path $Path
    if (-not [System.IO.File]::Exists($target)) { return [string[]]@('Missing') }
    $bytes = [System.IO.File]::ReadAllBytes($target)
    if ($bytes.Length -eq 0) { return [string[]]@('Empty') }
    $findings = New-Object System.Collections.Generic.List[string]
    $start = 0
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        return [string[]]@('Utf16')
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $findings.Add('Utf8Bom')
        $start = 3
    }
    if ([Array]::IndexOf($bytes, [byte]0) -ge 0) { return [string[]]@('Utf16') }
    if ([Array]::IndexOf($bytes, [byte]13) -ge 0) { $findings.Add('CarriageReturn') }
    # The trailing run is every CR or LF at the end; a line feed before it is inside the value.
    $end = $bytes.Length
    while ($end -gt $start -and ($bytes[$end - 1] -eq 10 -or $bytes[$end - 1] -eq 13)) { $end-- }
    $trailingLineFeed = $false
    for ($index = $end; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 10) { $trailingLineFeed = $true }
    }
    if ($trailingLineFeed) { $findings.Add('TrailingLineFeed') }
    $embedded = $false
    for ($index = $start; $index -lt $end; $index++) {
        if ($bytes[$index] -eq 10) { $embedded = $true }
    }
    if ($embedded) { $findings.Add('EmbeddedLineFeed') }
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        [void]$strict.GetCharCount($bytes, $start, $bytes.Length - $start)
    }
    catch [System.Text.DecoderFallbackException] {
        $findings.Add('InvalidUtf8')
    }
    [Array]::Clear($bytes, 0, $bytes.Length)
    return [string[]]$findings.ToArray()
}

function Test-GwSecretEncoding {
    <#
    .SYNOPSIS
    Doctor check: is a secret file encoded the way the container needs it?
    .DESCRIPTION
    FAIL for defects that become part of the credential (byte-order mark, UTF-16, carriage
    return, embedded line break, empty file); WARN for bytes that are not valid UTF-8; PASS for
    a clean file, also when it ends with a single line feed, which the image strips; SKIP when
    the file does not exist. The content is never shown.
    .PARAMETER Path
    Secret file.
    .PARAMETER Name
    Check name to report, for example 'SecretEncodingPassword'.
    .OUTPUTS
    Check result object (New-GwCheckResult).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $fix = 'Re-create the file with setup.ps1 -ResetSecrets. Do not write secrets with Notepad, ">" or Out-File: Windows PowerShell 5.1 adds a byte-order mark or writes UTF-16.'
    $findings = @(Get-GwSecretFileFinding -Path $Path)
    if ($findings -contains 'Missing') {
        return (New-GwCheckResult -Name $Name -Status 'SKIP' -Detail 'The secret file does not exist yet.' -Fix 'Run setup.ps1.')
    }
    $descriptions = @{
        Empty            = 'the file is empty'
        Utf8Bom          = 'it starts with a UTF-8 byte-order mark'
        Utf16            = 'it is UTF-16 (or contains NUL bytes)'
        CarriageReturn   = 'it contains a carriage return (Windows line ending)'
        EmbeddedLineFeed = 'it contains a line break inside the value'
    }
    $fatal = @($findings | Where-Object { $descriptions.ContainsKey($_) } | ForEach-Object { $descriptions[$_] })
    if ($fatal.Count -gt 0) {
        $detail = 'The login would fail: {0}.' -f ($fatal -join '; ')
        return (New-GwCheckResult -Name $Name -Status 'FAIL' -Detail $detail -Fix $fix)
    }
    if ($findings -contains 'InvalidUtf8') {
        return (New-GwCheckResult -Name $Name -Status 'WARN' -Detail 'The file is not valid UTF-8 (probably ANSI-encoded special characters).' -Fix $fix)
    }
    if ($findings -contains 'TrailingLineFeed') {
        return (New-GwCheckResult -Name $Name -Status 'PASS' -Detail 'UTF-8 without byte-order mark; ends with a line feed, which the image strips.')
    }
    return (New-GwCheckResult -Name $Name -Status 'PASS' -Detail 'UTF-8 without byte-order mark and without line break.')
}

function Test-GwSecretAcl {
    <#
    .SYNOPSIS
    Doctor check: can only the current account read the secrets folder?
    .PARAMETER Path
    The secrets folder.
    .OUTPUTS
    Check result object: PASS (current user only), WARN (other accounts listed by name), SKIP
    (folder missing).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory = $true)][string]$Path)
    $name = 'SecretFolderAccess'
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return (New-GwCheckResult -Name $name -Status 'SKIP' -Detail 'The secrets folder does not exist yet.' -Fix 'Run setup.ps1.')
    }
    $others = @(Get-GwAclOtherIdentity -Path $Path)
    if ($others.Count -eq 0) {
        return (New-GwCheckResult -Name $name -Status 'PASS' -Detail 'Only your Windows account can read the secrets folder.')
    }
    $detail = 'Other accounts can read the secrets folder: {0}.' -f ($others -join ', ')
    return (New-GwCheckResult -Name $name -Status 'WARN' -Detail $detail -Fix 'Run setup.ps1 again; it restricts the folder to your account and keeps the existing secrets.')
}
