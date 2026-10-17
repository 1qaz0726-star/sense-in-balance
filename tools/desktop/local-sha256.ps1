# Stream hashes without depending on optional PowerShell module autoloading.
function Get-LocalSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$LiteralPath)
    $taskStream = [IO.File]::OpenRead($LiteralPath)
    $taskAlgorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($taskAlgorithm.ComputeHash($taskStream)).Replace('-', '').ToLowerInvariant()
    } finally {
        $taskAlgorithm.Dispose()
        $taskStream.Dispose()
    }
}
