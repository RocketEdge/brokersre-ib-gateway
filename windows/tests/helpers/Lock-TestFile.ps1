# Test helper, run as a separate process: opens a file with no sharing, creates a marker file to
# say "the lock is held", keeps the lock for the given time and exits. Used to prove that the
# kit's atomic write retries while antivirus or indexing briefly holds the target.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Marker,
    [Parameter(Mandatory = $true)][int]$Milliseconds
)
$ErrorActionPreference = 'Stop'
$stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    [System.IO.File]::WriteAllText($Marker, 'locked')
    Start-Sleep -Milliseconds $Milliseconds
}
finally {
    $stream.Dispose()
}
exit 0
