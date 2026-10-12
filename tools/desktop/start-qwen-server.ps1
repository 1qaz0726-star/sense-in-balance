# Start the official local Qwen GGUF runtime. No downloads or permanent changes.
[CmdletBinding()]
param(
    [string]$ServerPath = '',
    [string]$ModelPath = '',
    [string]$LogDirectory = '',
    [ValidateRange(512, 32768)][int]$ContextSize = 4096
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$taskModelAlias = 'Qwen2.5-1.5B-Instruct'

if ([string]::IsNullOrWhiteSpace($ServerPath)) {
    $ServerPath = $env:SENSE_LLAMA_SERVER
    if ([string]::IsNullOrWhiteSpace($ServerPath)) {
        $ServerPath = Join-Path $taskRepoRoot '.local\runtime\llama-server.exe'
    }
}
if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $ModelPath = $env:SENSE_QWEN_MODEL
    if ([string]::IsNullOrWhiteSpace($ModelPath)) {
        $ModelPath = Join-Path $taskRepoRoot '.local\models\Qwen2.5-1.5B-Instruct-Q8_0.gguf'
    }
}
if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
    $LogDirectory = Join-Path $taskRepoRoot '.local\desktop-demo\logs'
}

function ConvertTo-NativeArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $buffer = New-Object System.Text.StringBuilder
    [void]$buffer.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$buffer.Append(('\' * (2 * $slashes + 1)))
            [void]$buffer.Append('"')
        } else {
            [void]$buffer.Append(('\' * $slashes))
            [void]$buffer.Append($character)
        }
        $slashes = 0
    }
    [void]$buffer.Append(('\' * (2 * $slashes)))
    [void]$buffer.Append('"')
    return $buffer.ToString()
}

if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
    throw 'This Windows helper requires Get-NetTCPConnection to check port ownership.'
}
$taskListeners = @(Get-NetTCPConnection -LocalPort 8778 -State Listen -ErrorAction SilentlyContinue)
if ($taskListeners.Count -gt 0) {
    if (@($taskListeners | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') }).Count -gt 0) {
        throw 'Port 8778 is occupied by a non-loopback service; no process was changed.'
    }
    try {
        $taskModels = Invoke-RestMethod -Uri 'http://127.0.0.1:8778/v1/models' -Method Get -TimeoutSec 5
        if (-not ($taskModels.PSObject.Properties.Name -contains 'data')) {
            throw 'The existing service has no valid models list.'
        }
        $taskModelIds = @($taskModels.data | ForEach-Object {
            if ($_.PSObject.Properties.Name -contains 'id') { [string]$_.id }
        })
        if ($taskModelIds -cnotcontains $taskModelAlias) {
            throw "The existing service does not advertise $taskModelAlias."
        }
        Write-Output "Reusing local model $taskModelAlias at http://127.0.0.1:8778."
        exit 0
    } catch {
        throw "Port 8778 could not be verified; no process was changed. $($_.Exception.Message)"
    }
}

foreach ($taskRequired in @($ServerPath, $ModelPath)) {
    if (-not (Test-Path -LiteralPath $taskRequired -PathType Leaf)) {
        throw "Missing file: $taskRequired. See docs/WINDOWS_DESKTOP.md for official downloads."
    }
}
$ServerPath = (Resolve-Path -LiteralPath $ServerPath).Path
$ModelPath = (Resolve-Path -LiteralPath $ModelPath).Path
[void][System.IO.Directory]::CreateDirectory($LogDirectory)
$LogDirectory = (Resolve-Path -LiteralPath $LogDirectory).Path

$taskServerArguments = @(
    '-m', $ModelPath,
    '--alias', $taskModelAlias,
    '--host', '127.0.0.1', '--port', '8778',
    '-c', [string]$ContextSize, '-ngl', '99', '--parallel', '1',
    '--jinja', '--chat-template', 'chatml',
    '--temp', '0.2', '--top-k', '1', '--seed', '42', '-n', '256'
)
$taskQuotedArguments = ($taskServerArguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' '
$taskStamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$taskLaunched = Start-Process -FilePath $ServerPath -ArgumentList $taskQuotedArguments `
    -WorkingDirectory (Split-Path -Parent $ServerPath) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $LogDirectory "qwen-server-$taskStamp.stdout.log") `
    -RedirectStandardError (Join-Path $LogDirectory "qwen-server-$taskStamp.stderr.log")
$taskLaunched.Id | Set-Content -LiteralPath (Join-Path $LogDirectory 'qwen-server.pid') -Encoding ASCII
Write-Output "Started hidden local runtime PID $($taskLaunched.Id); model loading may take a moment."
Write-Output 'start-demo.ps1 checks /v1/models before starting the two apps.'
Write-Output "API: http://127.0.0.1:8778; model alias: $taskModelAlias; logs: $LogDirectory"
