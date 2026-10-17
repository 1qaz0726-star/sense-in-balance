# Start the exact V3 GGUF on a separate local endpoint. Existing services stay running.
[CmdletBinding()]
param(
    [string]$ModelPath = '',
    [string]$ServerPath = '',
    [ValidateRange(1024, 65535)][int]$Port = 8781,
    [ValidateRange(512, 32768)][int]$ContextSize = 4096,
    [ValidateRange(0, 99)][int]$GpuLayers = 99,
    [ValidateRange(10, 300)][int]$ReadyTimeoutSeconds = 120
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$taskModelAlias = 'cabin-v3-clean-hybrid'
$taskExpectedHash = '91793812b9ad0fab54a85119fa7cb1b16d9129be446b5bbe63c8340e6d13fbd1'
$taskExpectedBytes = 1646573152
$taskEndpoint = "http://127.0.0.1:$Port"
$taskLogDirectory = Join-Path $taskRepoRoot '.local\hybrid-v3\logs'

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $ModelPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'codex-dev\sense-in-balance\.local\training\exports\cabin-v3-hybrid-gguf-20261017\cabin-v3-clean-hybrid-q8_0.gguf'
}
if ([string]::IsNullOrWhiteSpace($ServerPath)) {
    $ServerPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'codex-dev\cockpit-demo\runtime\llama-b11557-vulkan\llama-server.exe'
}
foreach ($taskRequired in @($ModelPath, $ServerPath)) {
    if (-not (Test-Path -LiteralPath $taskRequired -PathType Leaf)) {
        throw "Missing local file: $taskRequired. This helper does not download or substitute a model."
    }
}
# GetFullPath preserves the validated ASCII junction spelling needed by llama.cpp.
$ModelPath = [System.IO.Path]::GetFullPath($ModelPath)
$ServerPath = [System.IO.Path]::GetFullPath($ServerPath)
if ($ModelPath -match '[^\x00-\x7F]') {
    throw 'This runtime requires an ASCII model path. Use the existing verified codex-dev junction.'
}
if ((Get-Item -LiteralPath $ModelPath).Length -ne $taskExpectedBytes -or
    (Get-FileHash -LiteralPath $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $taskExpectedHash) {
    throw 'V3 model size or SHA256 mismatch. No process was started or changed.'
}

function Test-HybridV3Ready {
    $taskHealth = Invoke-RestMethod -Uri "$taskEndpoint/health" -TimeoutSec 3
    if ($taskHealth.status -cne 'ok') { return $false }
    $taskModels = Invoke-RestMethod -Uri "$taskEndpoint/v1/models" -TimeoutSec 3
    if ($taskModels.PSObject.Properties.Name -notcontains 'data') { return $false }
    $taskMatches = @($taskModels.data | Where-Object {
        $_.PSObject.Properties.Name -contains 'id' -and $_.id -ceq $taskModelAlias
    })
    return $taskMatches.Count -eq 1
}

function ConvertTo-HybridNativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $taskBuffer = New-Object System.Text.StringBuilder
    [void]$taskBuffer.Append('"')
    $taskSlashes = 0
    foreach ($taskCharacter in $Value.ToCharArray()) {
        if ($taskCharacter -eq '\') { $taskSlashes++; continue }
        if ($taskCharacter -eq '"') {
            [void]$taskBuffer.Append(('\' * (2 * $taskSlashes + 1)))
            [void]$taskBuffer.Append('"')
        } else {
            [void]$taskBuffer.Append(('\' * $taskSlashes))
            [void]$taskBuffer.Append($taskCharacter)
        }
        $taskSlashes = 0
    }
    [void]$taskBuffer.Append(('\' * (2 * $taskSlashes)))
    [void]$taskBuffer.Append('"')
    return $taskBuffer.ToString()
}

if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw 'Get-NetTCPConnection is required to check the dedicated local port.'
}
$taskListeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
if ($taskListeners.Count -gt 0) {
    # An advertised alias cannot prove which model bytes another process loaded.
    # Refuse reuse rather than attributing an unowned endpoint to this verified file.
    throw "Port $Port is already occupied. This helper will not trust an alias alone or kill/reuse an existing process. No process was changed."
}

[void][System.IO.Directory]::CreateDirectory($taskLogDirectory)
$taskStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$taskStdout = Join-Path $taskLogDirectory "v3-server-$taskStamp.stdout.log"
$taskStderr = Join-Path $taskLogDirectory "v3-server-$taskStamp.stderr.log"
$taskServerArguments = @(
    '-m', $ModelPath, '--alias', $taskModelAlias,
    '--host', '127.0.0.1', '--port', [string]$Port,
    '-c', [string]$ContextSize, '-ngl', [string]$GpuLayers, '--parallel', '1',
    '--jinja', '--temp', '0', '--top-k', '1', '--top-p', '0.95',
    '--repeat-penalty', '1.0', '--seed', '42', '-n', '256'
)
# The GGUF's original Qwen chat template is used; never override it with chatml.
$taskQuotedArguments = ($taskServerArguments | ForEach-Object { ConvertTo-HybridNativeArgument $_ }) -join ' '
$taskProcess = Start-Process -FilePath $ServerPath -ArgumentList $taskQuotedArguments `
    -WorkingDirectory (Split-Path -Parent $ServerPath) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $taskStdout -RedirectStandardError $taskStderr
$taskProcess.Id | Set-Content -LiteralPath (Join-Path $taskLogDirectory 'hybrid-v3-server.pid') -Encoding ASCII
$taskDeadline = [DateTime]::UtcNow.AddSeconds($ReadyTimeoutSeconds)
do {
    $taskProcess.Refresh()
    if ($taskProcess.HasExited) {
        throw "The newly launched V3 runtime exited ($($taskProcess.ExitCode)). See $taskStderr. Existing services remain unchanged."
    }
    try {
        if (Test-HybridV3Ready) {
            [pscustomobject]@{
                Reused = $false; Endpoint = $taskEndpoint; ModelId = $taskModelAlias
                ProcessId = $taskProcess.Id; GpuLayers = $GpuLayers
                ModelSha256 = $taskExpectedHash; ModelPath = $ModelPath
                StdoutLog = $taskStdout; StderrLog = $taskStderr
                Readiness = 'Health and exact model alias verified; generation must be tested separately.'
            }
            return
        }
    } catch {
        # Only bounded readiness is retried. No process is killed or reconfigured.
    }
    Start-Sleep -Seconds 2
} while ([DateTime]::UtcNow -lt $taskDeadline)
throw "V3 readiness timed out after $ReadyTimeoutSeconds seconds; PID $($taskProcess.Id) was left running for inspection. See $taskStderr."
