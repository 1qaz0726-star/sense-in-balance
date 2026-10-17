# Rebuild one isolated Hybrid V3 APK. Does not install, launch, upgrade or train.
[CmdletBinding()]
param(
    [ValidateSet('Native', 'PC', 'Driver')][string]$Mode = 'Native',
    [switch]$Coordination,
    [string]$FlutterPath = '',
    [string]$SdkRoot = '',
    [string]$JavaHome = '',
    [string]$PythonPath = '',
    [string]$DeviceUrl = 'ws://10.0.2.2:8767/repair'
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$taskProfile = [Environment]::GetFolderPath('UserProfile')
$taskAsciiRepo = Join-Path $taskProfile 'codex-dev\sense-in-balance-hybrid-cloud'
$taskAsciiItem = Get-Item -LiteralPath $taskAsciiRepo -Force -ErrorAction Stop
$taskJunctionTargets = @($taskAsciiItem.Target)
if ($taskAsciiItem.LinkType -ne 'Junction' -or $taskJunctionTargets.Count -ne 1) {
    throw 'The dedicated ASCII hybrid checkout junction is missing or invalid.'
}
$taskJunctionTarget = [System.IO.Path]::GetFullPath([string]$taskJunctionTargets[0]).TrimEnd('\')
if (-not $taskRepoRoot.Equals($taskJunctionTarget, [StringComparison]::OrdinalIgnoreCase) -and
    -not $taskRepoRoot.Equals($taskAsciiRepo, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The ASCII hybrid junction points to another checkout. No build was started.'
}
$taskAppRoot = Join-Path $taskAsciiRepo 'app\cockpit_hmi'
$taskOutputRoot = Join-Path $taskAsciiRepo $(if ($Coordination) { '.local\cabin-c' } else { '.local\hybrid-v3' })
if ([string]::IsNullOrWhiteSpace($FlutterPath)) {
    $FlutterPath = Join-Path $taskProfile 'codex-dev\flutter-3.35.2\flutter\bin\flutter.bat'
}
if ([string]::IsNullOrWhiteSpace($SdkRoot)) {
    $SdkRoot = Join-Path $taskProfile 'AppData\Local\Android\Sdk'
}
if ([string]::IsNullOrWhiteSpace($JavaHome)) {
    $JavaHome = Join-Path $taskProfile 'codex-dev\jdk17\jdk-17.0.20.1+1'
}
if ([string]::IsNullOrWhiteSpace($PythonPath)) {
    $PythonPath = Join-Path $taskProfile '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
}
foreach ($taskRequired in @($FlutterPath, (Join-Path $JavaHome 'bin\java.exe'))) {
    if (-not (Test-Path -LiteralPath $taskRequired -PathType Leaf)) { throw "Missing tool: $taskRequired" }
}
if (-not (Test-Path -LiteralPath (Join-Path $SdkRoot 'platform-tools\adb.exe') -PathType Leaf)) {
    throw "Android SDK platform-tools are missing: $SdkRoot"
}
# Keep a build-time WebSocket address explicit. 10.0.2.2 is for the emulator;
# pass the S9 host's LAN address when building a physical driver companion.
$taskDeviceUri = $null
if (-not [Uri]::TryCreate($DeviceUrl, [UriKind]::Absolute, [ref]$taskDeviceUri) -or
    $taskDeviceUri.Scheme -notin @('ws', 'wss') -or
    [string]::IsNullOrWhiteSpace($taskDeviceUri.Host) -or
    $DeviceUrl -match '[^A-Za-z0-9:/._~\-\[\]]' -or
    -not [string]::IsNullOrEmpty($taskDeviceUri.UserInfo)) {
    throw 'DeviceUrl must be a plain ws:// or wss:// host/path URL without credentials, query or shell characters.'
}

$taskOriginalDirectory = Get-Location
$taskOriginalJavaHome = $env:JAVA_HOME
$taskOriginalAndroidHome = $env:ANDROID_HOME
$taskOriginalAndroidSdkRoot = $env:ANDROID_SDK_ROOT
$taskOriginalPath = $env:PATH
$taskBuildLock = $null
try {
    $env:JAVA_HOME = [System.IO.Path]::GetFullPath($JavaHome)
    $env:ANDROID_HOME = [System.IO.Path]::GetFullPath($SdkRoot)
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    $env:PATH = "$env:JAVA_HOME\bin;$(Split-Path -Parent $FlutterPath);$env:PATH"
    [void][System.IO.Directory]::CreateDirectory($taskOutputRoot)
    try {
        $taskBuildLock = [System.IO.File]::Open((Join-Path $taskOutputRoot 'build.lock'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch { throw 'Another Hybrid V3 build helper is running. Wait for it to finish; no build was started.' }
    Set-Location -LiteralPath $taskAppRoot
    $taskVersionLines = & $FlutterPath '--version' 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the installed Flutter version.' }
    $taskVersion = ($taskVersionLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($taskVersion -notmatch '(?m)^Flutter 3\.35\.2\b') {
        throw "Flutter 3.35.2 is required. Select its flutter.bat with -FlutterPath.`n$taskVersion"
    }
    if ($Coordination -and $Mode -ne 'Driver') {
        if (-not (Test-Path -LiteralPath $PythonPath -PathType Leaf)) {
            throw 'Python is required to bundle the C driver web companion; select it with -PythonPath.'
        }
        & $FlutterPath build web --release --no-pub -t lib/main_repair_web.dart --output=build/repair_web --no-web-resources-cdn --pwa-strategy=none --dart-define=CABIN_COORDINATION=true
        if ($LASTEXITCODE -ne 0) { throw 'C driver web build failed; no new host APK was produced.' }
        & $PythonPath -X utf8 tool/pack_repair_web.py
        if ($LASTEXITCODE -ne 0) { throw 'C web asset packaging failed; no new host APK was produced.' }
    }
    $taskArguments = @(
        'build', 'apk', '--release', '--no-pub',
        $(if ($Coordination) { '--build-name=1.2.0' } else { '--build-name=1.1.0' }),
        $(if ($Coordination) { '--build-number=2026101702' } else { '--build-number=2026101701' }),
        '--dart-define=HYBRID_V3_DEMO=true'
    )
    if ($Coordination) { $taskArguments += '--dart-define=CABIN_COORDINATION=true' }
    switch ($Mode) {
        'Native' {
            $taskArguments += @(
                '--target-platform', 'android-arm64,android-x64', '-t', 'lib/main_repair.dart',
                '--dart-define=SLM_PREFER_CABIN_V3=true', '--dart-define=REPAIR_EVAL_LOG=true'
            )
            $taskOutputName = 'hybrid-v3-native-arm64-x64.apk'
        }
        'PC' {
            $taskArguments += @(
                '--target-platform', 'android-x64', '-t', 'lib/main_repair.dart',
                '--dart-define=REPAIR_MODEL_URL=http://10.0.2.2:8781',
                '--dart-define=REPAIR_MODEL_ID=cabin-v3-clean-hybrid',
                '--dart-define=REPAIR_MODEL_SINGLE_USER=true', '--dart-define=REPAIR_EVAL_LOG=true'
            )
            $taskOutputName = 'hybrid-v3-pc-x64.apk'
        }
        'Driver' {
            $taskArguments += @(
                '--target-platform', 'android-arm64,android-x64', '-t', 'lib/main_repair_monitor.dart',
                "--dart-define=REPAIR_MONITOR_URL=$DeviceUrl"
            )
            $taskOutputName = 'hybrid-v3-driver-arm64-x64.apk'
        }
    }
    if ($Coordination) { $taskOutputName = $taskOutputName.Replace('hybrid-v3-', 'cabin-c-') }
    Write-Output "Building Hybrid V3 $Mode with cached dependencies. No pub upgrade or installation is performed."
    & $FlutterPath @taskArguments
    if ($LASTEXITCODE -ne 0) { throw "Flutter $Mode build failed with exit code $LASTEXITCODE." }
    $taskBuiltApk = Join-Path $taskAppRoot 'build\app\outputs\flutter-apk\app-release.apk'
    if (-not (Test-Path -LiteralPath $taskBuiltApk -PathType Leaf)) { throw 'Flutter completed without the expected release APK.' }
    $taskDestination = Join-Path $taskOutputRoot $taskOutputName
    if (Test-Path -LiteralPath $taskDestination) {
        $taskArchive = Join-Path $taskOutputRoot ('previous-builds\' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
        [void][System.IO.Directory]::CreateDirectory($taskArchive)
        Copy-Item -LiteralPath $taskDestination -Destination (Join-Path $taskArchive $taskOutputName) -ErrorAction Stop
    }
    Copy-Item -LiteralPath $taskBuiltApk -Destination $taskDestination -Force
    $taskReceipt = [ordered]@{
        CreatedAt = (Get-Date).ToString('o'); Mode = $Mode
        Apk = $taskDestination; Bytes = (Get-Item -LiteralPath $taskDestination).Length
        Sha256 = (Get-FileHash -LiteralPath $taskDestination -Algorithm SHA256).Hash.ToLowerInvariant()
        Flutter = '3.35.2'
        VersionName = $(if ($Coordination) { '1.2.0' } else { '1.1.0' })
        VersionCode = $(if ($Coordination) { 2026101702 } else { 2026101701 })
        Coordination = [bool]$Coordination
        Arguments = $taskArguments; Installed = $false; S9Tested = $false
    }
    $taskReceipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$taskDestination.receipt.json" -Encoding UTF8
    [pscustomobject]$taskReceipt
} finally {
    if ($null -ne $taskBuildLock) { $taskBuildLock.Dispose() }
    Set-Location -LiteralPath $taskOriginalDirectory.Path
    $env:JAVA_HOME = $taskOriginalJavaHome
    $env:ANDROID_HOME = $taskOriginalAndroidHome
    $env:ANDROID_SDK_ROOT = $taskOriginalAndroidSdkRoot
    $env:PATH = $taskOriginalPath
}
