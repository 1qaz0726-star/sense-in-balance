# Build two independent x64 debug APKs. The script does not install or launch.
[CmdletBinding()]
param(
    [string]$FlutterPath = '',
    [string]$SdkRoot = '',
    [string]$JavaHome = '',
    [switch]$PackWeb
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskRepoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$taskAppRoot = Join-Path $taskRepoRoot 'app\cockpit_hmi'
$taskOutputRoot = Join-Path $taskRepoRoot '.local\desktop-demo'
$taskManifestPath = Join-Path $taskAppRoot 'pubspec.yaml'
$taskOriginalDirectory = Get-Location
$taskOriginalJavaHome = $env:JAVA_HOME
$taskOriginalAndroidHome = $env:ANDROID_HOME
$taskOriginalPath = $env:PATH
$taskOriginalManifest = $null

if ([string]::IsNullOrWhiteSpace($FlutterPath)) {
    $taskFlutterCommand = Get-Command flutter -CommandType Application -ErrorAction Stop | Select-Object -First 1
    $FlutterPath = $taskFlutterCommand.Source
}
if (-not (Test-Path -LiteralPath $FlutterPath -PathType Leaf)) {
    throw 'Flutter executable was not found. Supply -FlutterPath with the path to flutter.bat.'
}
$FlutterPath = (Resolve-Path -LiteralPath $FlutterPath).Path

function Invoke-DemoFlutter {
    param([string[]]$Arguments)
    & $FlutterPath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Flutter failed: $($Arguments -join ' ')" }
}

function ConvertTo-DemoNormalizedPath {
    param([string]$Path, [switch]$JavaBinary)
    $taskPath = $Path.Trim().Trim('"').Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($taskPath) -or -not [System.IO.Path]::IsPathRooted($taskPath)) {
        throw "Android tooling not ready: Flutter reported a missing or non-absolute path: $Path"
    }
    $taskPath = [System.IO.Path]::GetFullPath($taskPath)
    # Flutter 3.35.2 reports JAVA_HOME/bin/java without .exe on Windows.
    if ($JavaBinary -and [System.IO.Path]::GetFileName($taskPath) -ieq 'java') { $taskPath += '.exe' }
    return $taskPath.TrimEnd([char[]]@('\', '/'))
}

try {
    if (-not [string]::IsNullOrWhiteSpace($SdkRoot)) {
        if (-not (Test-Path -LiteralPath $SdkRoot -PathType Container)) { throw "Android SDK folder not found: $SdkRoot" }
        $env:ANDROID_HOME = (Resolve-Path -LiteralPath $SdkRoot).Path
    }
    if (-not [string]::IsNullOrWhiteSpace($JavaHome)) {
        if (-not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin\java.exe') -PathType Leaf)) {
            throw "JDK folder not found: $JavaHome"
        }
        $env:JAVA_HOME = (Resolve-Path -LiteralPath $JavaHome).Path
        $env:PATH = "$env:JAVA_HOME\bin;$env:PATH"
    }
    Set-Location -LiteralPath $taskAppRoot
    $taskVersionLines = & $FlutterPath '--version' 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Could not read Flutter version.' }
    $taskVersion = ($taskVersionLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
    if ($taskVersion -notmatch '(?m)^Flutter 3\.35\.2\b') {
        throw "This demo was validated with Flutter 3.35.2. Select that SDK with -FlutterPath.`n$taskVersion"
    }
    Write-Output $taskVersion
    if (-not [string]::IsNullOrWhiteSpace($SdkRoot) -or -not [string]::IsNullOrWhiteSpace($JavaHome)) {
        # Environment hints cannot override saved Flutter config or Studio's JDK.
        try { $taskDoctorLines = & $FlutterPath 'doctor' '-v' 2>&1 }
        catch { throw "Android tooling not ready: flutter doctor -v could not complete. $($_.Exception.Message)" }
        $taskDoctor = ($taskDoctorLines | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
        Write-Output $taskDoctor
        $taskSdkMatches = [regex]::Matches($taskDoctor, '(?m)Android SDK at\s+([^\r\n]+)')
        $taskJavaMatches = [regex]::Matches($taskDoctor, '(?m)Java binary at:\s*([^\r\n]+)')
        if ($taskSdkMatches.Count -ne 1 -or $taskJavaMatches.Count -ne 1) {
            throw 'Android tooling not ready: flutter doctor -v did not report one Android SDK at and one Java binary at path. Resolve Android SDK/JDK setup and rerun; the helper does not guess or change Flutter configuration.'
        }
        $taskSelectedSdk = ConvertTo-DemoNormalizedPath -Path $taskSdkMatches[0].Groups[1].Value
        $taskSelectedJava = ConvertTo-DemoNormalizedPath -Path $taskJavaMatches[0].Groups[1].Value -JavaBinary
        if (-not (Test-Path -LiteralPath $taskSelectedSdk -PathType Container) -or -not (Test-Path -LiteralPath $taskSelectedJava -PathType Leaf)) {
            throw "Android tooling not ready: Flutter selected a missing SDK/JDK. SDK: $taskSelectedSdk; Java: $taskSelectedJava. Resolve tool setup before building."
        }
        if (-not [string]::IsNullOrWhiteSpace($SdkRoot)) {
            $taskRequestedSdk = ConvertTo-DemoNormalizedPath -Path $env:ANDROID_HOME
            if (-not [string]::Equals($taskSelectedSdk, $taskRequestedSdk, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Flutter selected Android SDK '$taskSelectedSdk', but -SdkRoot requested '$taskRequestedSdk'. This parameter is only an ANDROID_HOME hint. Review flutter config (android-sdk) and flutter doctor -v, align the selection yourself, and rerun. No persistent configuration was changed."
            }
        }
        if (-not [string]::IsNullOrWhiteSpace($JavaHome)) {
            $taskRequestedJava = ConvertTo-DemoNormalizedPath -Path (Join-Path $env:JAVA_HOME 'bin\java.exe') -JavaBinary
            if (-not [string]::Equals($taskSelectedJava, $taskRequestedJava, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw "Flutter selected Java '$taskSelectedJava', but -JavaHome requested '$taskRequestedJava'. This parameter is only a JAVA_HOME/PATH hint. Review flutter config (jdk-dir), Android Studio's bundled JDK, and flutter doctor -v, align the selection yourself, and rerun. No persistent configuration was changed."
            }
        }
        Write-Output "Verified Flutter tool paths: SDK $taskSelectedSdk; Java $taskSelectedJava"
    }
    Invoke-DemoFlutter -Arguments @('pub', 'get')
    if ($PackWeb) {
        # The browser companion is optional. Restore the canonical source
        # manifest after the build; generated assets remain local and ignored.
        $taskOriginalManifest = [System.IO.File]::ReadAllBytes($taskManifestPath)
        Invoke-DemoFlutter -Arguments @(
            'build', 'web', '-t', 'lib/main_repair_web.dart', '--output=build/repair_web',
            '--release', '--no-web-resources-cdn', '--pwa-strategy=none'
        )
        $taskPythonCommand = Get-Command python -CommandType Application -ErrorAction Stop | Select-Object -First 1
        & $taskPythonCommand.Source 'tool/pack_repair_web.py'
        if ($LASTEXITCODE -ne 0) { throw 'Browser companion packaging failed.' }
    }
    [void][System.IO.Directory]::CreateDirectory($taskOutputRoot)
    Invoke-DemoFlutter -Arguments @(
        'build', 'apk', '--debug', '--target-platform', 'android-x64',
        '-t', 'lib/main_repair.dart',
        '--dart-define=REPAIR_MODEL_URL=http://10.0.2.2:8778',
        '--dart-define=REPAIR_DESKTOP_DEMO=true', '--dart-define=REPAIR_EVAL_LOG=true'
    )
    $taskBuiltApk = Join-Path $taskAppRoot 'build\app\outputs\flutter-apk\app-debug.apk'
    Copy-Item -LiteralPath $taskBuiltApk -Destination (Join-Path $taskOutputRoot 'tablet.apk') -Force
    Invoke-DemoFlutter -Arguments @(
        'build', 'apk', '--debug', '--target-platform', 'android-x64',
        '-t', 'lib/main_repair_monitor.dart', '--dart-define=REPAIR_DESKTOP_DEMO=true',
        '--dart-define=REPAIR_MONITOR_URL=ws://10.0.2.2:8767/repair'
    )
    Copy-Item -LiteralPath $taskBuiltApk -Destination (Join-Path $taskOutputRoot 'phone.apk') -Force
    Write-Output "Built tablet.apk and phone.apk in $taskOutputRoot."
    Write-Output 'Both are x64 emulator debug apps with an independent application ID; no device was changed.'
} finally {
    if ($null -ne $taskOriginalManifest) {
        [System.IO.File]::WriteAllBytes($taskManifestPath, $taskOriginalManifest)
    }
    Set-Location -LiteralPath $taskOriginalDirectory.Path
    $env:JAVA_HOME = $taskOriginalJavaHome
    $env:ANDROID_HOME = $taskOriginalAndroidHome
    $env:PATH = $taskOriginalPath
}
