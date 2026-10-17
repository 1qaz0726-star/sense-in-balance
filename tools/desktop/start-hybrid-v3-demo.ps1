# Hybrid V3 desktop simulation: preserves original apps, models and AVD data.
# The visible emulators are for manual operation; cloud credentials are not required.
# Startup checks do not establish model quality, real vehicle actuation or S9 performance.
# After exact AVD checks, only dash_phone's virtual clock is aligned to center_tab;
# use -SkipClockSync to keep emulator clocks unchanged (freshness may then fail).
[CmdletBinding()]
param(
    [switch]$SkipInstall,
    [switch]$RestartApp,
    [switch]$SkipClockSync,
    [switch]$Coordination,
    [string]$SdkRoot = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$ModelLauncher = '',
    [string]$ServerPath = '',
    [string]$ModelPath = '',
    [string]$ApkPath = '',
    [string]$PhoneApkPath = '',
    [ValidateRange(60, 600)][int]$BootTimeoutSeconds = 180,
    [ValidateRange(15, 300)][int]$ModelTimeoutSeconds = 120
)

# PowerShell 5.1 在參數預設值求值時可能尚未提供 PSScriptRoot；在 param 後才解析本檔目錄。
$taskScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($taskScriptRoot)) {
    $taskScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($taskScriptRoot)) {
    throw '無法取得助手檔案所在目錄；請以 -File 或 .cmd 執行本檔。'
}
$taskWorkspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $taskScriptRoot '..\..')).TrimEnd('\')
# aapt cannot reliably open APKs through this checkout's Chinese path. Use only
# the dedicated ASCII junction after proving it refers to THIS exact checkout.
$taskAsciiWorkspace = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'codex-dev\sense-in-balance-hybrid-cloud'
$taskAsciiItem = Get-Item -LiteralPath $taskAsciiWorkspace -Force -ErrorAction Stop
$taskAsciiTargets = @($taskAsciiItem.Target)
if ($taskAsciiItem.LinkType -ne 'Junction' -or $taskAsciiTargets.Count -ne 1) {
    throw 'The dedicated ASCII hybrid checkout junction is missing or invalid; no startup was attempted.'
}
$taskAsciiTarget = [System.IO.Path]::GetFullPath([string]$taskAsciiTargets[0]).TrimEnd('\')
if (-not $taskWorkspaceRoot.Equals($taskAsciiTarget, [StringComparison]::OrdinalIgnoreCase) -and
    -not $taskWorkspaceRoot.Equals($taskAsciiWorkspace, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The dedicated ASCII junction points to another checkout; no startup was attempted.'
}
$taskWorkspaceRoot = $taskAsciiWorkspace
if ([string]::IsNullOrWhiteSpace($ModelLauncher)) {
    $ModelLauncher = Join-Path $taskScriptRoot 'start-hybrid-v3-model.ps1'
}
if ([string]::IsNullOrWhiteSpace($ApkPath)) {
    $ApkPath = Join-Path $taskWorkspaceRoot $(if ($Coordination) { '.local\cabin-c\cabin-c-pc-x64.apk' } else { '.local\hybrid-v3\hybrid-v3-pc-x64.apk' })
}
if ([string]::IsNullOrWhiteSpace($PhoneApkPath)) {
    $PhoneApkPath = Join-Path $taskWorkspaceRoot $(if ($Coordination) { '.local\cabin-c\cabin-c-driver-arm64-x64.apk' } else { '.local\hybrid-v3\hybrid-v3-driver-arm64-x64.apk' })
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskAdb = Join-Path $SdkRoot 'platform-tools\adb.exe'
$taskEmulator = Join-Path $SdkRoot 'emulator\emulator.exe'
$taskPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskModelAlias = 'cabin-v3-clean-hybrid'
$taskPackage = if ($Coordination) { 'com.auohack.cockpit_hmi.coordination' } else { 'com.auohack.cockpit_hmi.hybridv3' }
$taskComponent = "$taskPackage/com.auohack.cockpit_hmi.MainActivity"
$taskTabletSerial = 'emulator-5554'
$taskPhoneSerial = 'emulator-5556'
$taskLogRoot = Join-Path $taskWorkspaceRoot $(if ($Coordination) { '.local\cabin-c\logs' } else { '.local\hybrid-v3\logs' })
$taskExpectedModelHash = '91793812b9ad0fab54a85119fa7cb1b16d9129be446b5bbe63c8340e6d13fbd1'
$taskExpectedModelBytes = 1646573152
if ([string]::IsNullOrWhiteSpace($ModelPath)) {
    $ModelPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'codex-dev\sense-in-balance\.local\training\exports\cabin-v3-hybrid-gguf-20261017\cabin-v3-clean-hybrid-q8_0.gguf'
}
if ([string]::IsNullOrWhiteSpace($ServerPath)) {
    $ServerPath = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'codex-dev\cockpit-demo\runtime\llama-b11557-vulkan\llama-server.exe'
}
$ModelPath = [IO.Path]::GetFullPath($ModelPath)
$ServerPath = [IO.Path]::GetFullPath($ServerPath)

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

function Join-NativeArguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { ConvertTo-NativeArgument $_ }) -join ' ')
}

# Windows command lines must be parsed using Windows quoting rules; substring
# matches cannot prove which -m value or alias an existing process received.
function Get-HybridCommandArguments {
    param([string]$CommandLine)
    if (-not ('HybridV3NativeArgv' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HybridV3NativeArgv {
    [DllImport("shell32.dll", SetLastError=true)]
    private static extern IntPtr CommandLineToArgvW([MarshalAs(UnmanagedType.LPWStr)] string command, out int count);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr pointer);
    public static string[] Split(string command) {
        int count; IntPtr pointer = CommandLineToArgvW(command, out count);
        if (pointer == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        try {
            string[] result = new string[count];
            for (int i=0; i<count; i++) result[i] = Marshal.PtrToStringUni(Marshal.ReadIntPtr(pointer, i*IntPtr.Size));
            return result;
        } finally { LocalFree(pointer); }
    }
}
'@
    }
    return [HybridV3NativeArgv]::Split($CommandLine)
}

function Get-HybridOption {
    param([string[]]$Tokens, [string[]]$Names)
    $taskValues = @()
    for ($taskIndex = 1; $taskIndex -lt $Tokens.Length; $taskIndex++) {
        if ($Names -ccontains $Tokens[$taskIndex]) {
            if ($taskIndex + 1 -ge $Tokens.Length) { throw 'Incomplete V3 runtime option.' }
            $taskValues += $Tokens[$taskIndex + 1]
        }
    }
    if ($taskValues.Count -ne 1) { throw "Cannot verify unique runtime option $($Names -join '/')." }
    return [string]$taskValues[0]
}

function Assert-HybridModelOwner {
    $taskListeners = @(Get-ListeningPort 8781)
    if ($taskListeners.Count -eq 0) { throw 'V3 endpoint is not listening on 8781.' }
    if (@($taskListeners | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') }).Count -gt 0) {
        throw '8781 is not restricted to loopback. No service was changed.'
    }
    $taskOwnerIds = @($taskListeners | Select-Object -ExpandProperty OwningProcess -Unique)
    if ($taskOwnerIds.Count -ne 1) { throw '8781 has ambiguous process ownership.' }
    $taskOwner = Get-CimInstance Win32_Process -Filter "ProcessId = $($taskOwnerIds[0])"
    if ($null -eq $taskOwner -or [string]::IsNullOrWhiteSpace($taskOwner.ExecutablePath) -or
        [string]::IsNullOrWhiteSpace($taskOwner.CommandLine)) { throw 'Cannot inspect the V3 runtime process.' }
    if (-not ([IO.Path]::GetFullPath([string]$taskOwner.ExecutablePath)).Equals($ServerPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw '8781 belongs to another executable. Alias alone is not trusted; no process was changed.'
    }
    $taskTokens = @(Get-HybridCommandArguments ([string]$taskOwner.CommandLine))
    $taskRunningModel = Get-HybridOption -Tokens $taskTokens -Names @('-m', '--model')
    $taskRunningAlias = Get-HybridOption -Tokens $taskTokens -Names @('--alias')
    $taskRunningHost = Get-HybridOption -Tokens $taskTokens -Names @('--host')
    $taskRunningPort = Get-HybridOption -Tokens $taskTokens -Names @('--port')
    if (-not ([IO.Path]::GetFullPath($taskRunningModel)).Equals($ModelPath, [StringComparison]::OrdinalIgnoreCase) -or
        $taskRunningAlias -cne $taskModelAlias -or $taskRunningHost -cne '127.0.0.1' -or $taskRunningPort -cne '8781') {
        throw '8781 model path, alias, host or port does not match the pinned V3. No process was changed.'
    }
    return [int]$taskOwnerIds[0]
}

function Start-HybridApp {
    param([string]$Serial)
    $taskRunning = Invoke-DemoAdb -Arguments @('-s', $Serial, 'shell', 'pidof', $taskPackage) -AllowFailure
    if ($taskRunning.ExitCode -eq 0 -and $taskRunning.Output -match '^\d+(?:\s+\d+)*$') {
        Write-Host "Hybrid V3 App already running on $Serial; preserving its current screen and task."
        return
    }
    $taskLaunch = Invoke-DemoAdb -Arguments @('-s', $Serial, 'shell', 'am', 'start', '-W', '-n', $taskComponent) -TimeoutSeconds 30
    if (($taskLaunch.Output + "`n" + $taskLaunch.ErrorOutput) -match '(?m)^Error(?: type|:)') {
        throw "Hybrid V3 App failed to launch on ${Serial}: $($taskLaunch.Output) $($taskLaunch.ErrorOutput)"
    }
}

function Invoke-LocalTool {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 30,
        [switch]$AllowFailure
    )
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-NativeArguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo
    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            # 僅結束本次助手建立且逾時的 adb / 查詢程序，不碰模擬器或模型服務。
            $process.Kill()
            $process.WaitForExit()
            throw "工具查詢超過 $TimeoutSeconds 秒：$FilePath $($startInfo.Arguments)"
        }
        $result = [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = $stdoutTask.Result.Trim()
            ErrorOutput = $stderrTask.Result.Trim()
        }
        if ($result.ExitCode -ne 0 -and -not $AllowFailure) {
            throw "工具失敗（$($result.ExitCode)）：$FilePath $($startInfo.Arguments)`n$($result.Output)`n$($result.ErrorOutput)"
        }
        return $result
    } finally {
        $process.Dispose()
    }
}

function Invoke-DemoAdb {
    param([string[]]$Arguments, [int]$TimeoutSeconds = 30, [switch]$AllowFailure)
    return (Invoke-LocalTool -FilePath $taskAdb -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds -AllowFailure:$AllowFailure)
}

function Get-ListeningPort {
    param([int]$Port)
    return @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Get-DemoDevice {
    param([string]$Serial)
    $result = Invoke-DemoAdb -Arguments @('devices') -TimeoutSeconds 10
    foreach ($line in ($result.Output -split '\r?\n')) {
        if ($line -match '^(\S+)\s+(\S+)' -and $Matches[1] -eq $Serial) {
            return [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
        }
    }
    return $null
}

function Assert-AvdIdentity {
    param([string]$Serial, [string]$Name)
    $result = Invoke-DemoAdb -Arguments @('-s', $Serial, 'emu', 'avd', 'name') -TimeoutSeconds 10
    $names = @($result.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne 'OK' })
    if ($names.Count -ne 1 -or $names[0] -cne $Name) {
        throw "$Serial 不是預期的 AVD $Name（查到：$($names -join ', ')）。沒有關閉或更改任何既有模擬器。"
    }
    $taskConsolePort = [int]($Serial -replace '^emulator-', '')
    $taskRuntimeRoot = ([IO.Path]::GetFullPath((Join-Path $SdkRoot 'emulator'))).TrimEnd('\') + '\'
    foreach ($taskPort in @($taskConsolePort, ($taskConsolePort + 1))) {
        foreach ($taskListener in @(Get-ListeningPort $taskPort)) {
            $taskOwner = Get-CimInstance Win32_Process -Filter "ProcessId = $($taskListener.OwningProcess)"
            if ($null -eq $taskOwner -or [string]::IsNullOrWhiteSpace($taskOwner.ExecutablePath)) {
                throw "Cannot verify emulator listener ownership on port $taskPort."
            }
            $taskExecutable = [IO.Path]::GetFullPath([string]$taskOwner.ExecutablePath)
            if (-not $taskExecutable.StartsWith($taskRuntimeRoot, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetFileName($taskExecutable) -notmatch '^(?:emulator|qemu-system-[A-Za-z0-9_-]+)\.exe$') {
                throw "Port $taskPort belongs to another runtime; no process was replaced or stopped."
            }
        }
    }
}

function Assert-EmulatorPortsAvailable {
    param([int]$Port, [string]$Name)
    foreach ($candidate in @($Port, ($Port + 1))) {
        if (@(Get-ListeningPort $candidate).Count -gt 0) {
            throw "$Name 尚未出現在 adb，但連接埠 $candidate 已被佔用。請確認該程序；助手不會替換或關閉它。"
        }
    }
}

function Assert-EmulatorSlot {
    param($Definition)
    $device = Get-DemoDevice $Definition.Serial
    if ($null -ne $device) {
        Assert-AvdIdentity -Serial $Definition.Serial -Name $Definition.Name
    } else {
        Assert-EmulatorPortsAvailable -Port $Definition.Port -Name $Definition.Name
    }
}

function Start-OrReuseEmulator {
    param($Definition)
    # 在啟動前重新檢查，避免助手準備期間有人佔用同一 serial / port。
    $device = Get-DemoDevice $Definition.Serial
    if ($null -ne $device) {
        Assert-AvdIdentity -Serial $Definition.Serial -Name $Definition.Name
        Write-Host "沿用 $($Definition.Name)（$($Definition.Serial)，$($device.State)）。"
        return
    }
    Assert-EmulatorPortsAvailable -Port $Definition.Port -Name $Definition.Name
    $arguments = @(
        '-avd', $Definition.Name, '-port', [string]$Definition.Port,
        '-memory', '2048', '-cores', '2', '-no-snapshot-load', '-no-snapshot-save', '-no-audio',
        '-camera-back', 'none', '-camera-front', 'none', '-gpu', 'host', '-scale', $Definition.Scale
    )
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $stdout = Join-Path $taskLogRoot "$($Definition.Name)-$stamp.stdout.log"
    $stderr = Join-Path $taskLogRoot "$($Definition.Name)-$stamp.stderr.log"
    # 兩個模擬器需要讓使用者直接操作，因此明確開啟可見 GUI。
    $started = Start-Process -FilePath $taskEmulator -ArgumentList (Join-NativeArguments $arguments) -WindowStyle Normal -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Write-Host "已開啟 $($Definition.Name)，PID $($started.Id)，記憶體 2 GB。首次開機可能需要幾分鐘。"
}

function Wait-DemoBoot {
    param($Definition)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextReport = 0
    $identityChecked = $false
    while ($watch.Elapsed.TotalSeconds -lt $BootTimeoutSeconds) {
        $state = Invoke-DemoAdb -Arguments @('-s', $Definition.Serial, 'get-state') -TimeoutSeconds 5 -AllowFailure
        if ($state.ExitCode -eq 0 -and $state.Output -eq 'device') {
            if (-not $identityChecked) {
                Assert-AvdIdentity -Serial $Definition.Serial -Name $Definition.Name
                $identityChecked = $true
            }
            $boot = Invoke-DemoAdb -Arguments @('-s', $Definition.Serial, 'shell', 'getprop', 'sys.boot_completed') -TimeoutSeconds 5 -AllowFailure
            if ($boot.ExitCode -eq 0 -and $boot.Output -eq '1') {
                Write-Host "$($Definition.Name) 已完成開機。"
                return
            }
        }
        if ($watch.Elapsed.TotalSeconds -ge $nextReport) {
            Write-Host "等待 $($Definition.Name) 開機：$([int]$watch.Elapsed.TotalSeconds) / $BootTimeoutSeconds 秒…"
            $nextReport += 15
        }
        Start-Sleep -Seconds 3
    }
    throw "$($Definition.Name) 在 $BootTimeoutSeconds 秒內未完成開機；既有資料與程序皆保留。可稍後重跑助手。"
}

function Read-HybridVirtualClock {
    param([string]$Serial)
    if ($Serial -cnotin @('emulator-5554', 'emulator-5556')) {
        throw 'Virtual clock sampling is restricted to the two designated emulator serials.'
    }
    $taskBefore = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $taskClock = Invoke-DemoAdb -Arguments @('-s', $Serial, 'shell', 'date', '+%s%3N') -TimeoutSeconds 5
    $taskAfter = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    if ($taskClock.Output -notmatch '^\d{13}$') {
        throw "$Serial does not provide millisecond virtual-clock output; calibration cannot be verified."
    }
    if ($taskAfter -lt $taskBefore) { throw 'Host clock moved backwards during virtual-clock sampling.' }
    return [pscustomobject]@{
        Serial = $Serial
        DeviceUnixMs = [long]$taskClock.Output
        HostBeforeUnixMs = $taskBefore
        HostAfterUnixMs = $taskAfter
        HostMidpointUnixMs = ($taskBefore + $taskAfter) / 2.0
        QueryDurationMs = $taskAfter - $taskBefore
    }
}

function Measure-HybridClockDifference {
    param($TabletSample, $PhoneSample)
    # Normalize sequential readings to the same host instant. Half the measured
    # round trips bound the sampling uncertainty; do not pretend queries are instant.
    $taskDelta = ($PhoneSample.DeviceUnixMs - $TabletSample.DeviceUnixMs) -
        ($PhoneSample.HostMidpointUnixMs - $TabletSample.HostMidpointUnixMs)
    $taskUncertainty = ($TabletSample.QueryDurationMs + $PhoneSample.QueryDurationMs) / 2.0
    return [pscustomobject]@{
        PhoneAheadEstimateMs = $taskDelta
        SamplingUncertaintyMs = $taskUncertainty
        LowerBoundMs = $taskDelta - $taskUncertainty
        UpperBoundMs = $taskDelta + $taskUncertainty
        WithinBounds = (($taskDelta - $taskUncertainty) -ge 0 -and
            ($taskDelta + $taskUncertainty) -le 2000)
    }
}

function Sync-HybridVirtualClock {
    # This is emulator setup only. Never change the Windows clock, a physical
    # device, Android automatic-time settings or the product freshness policy.
    if ($taskTabletSerial -cne 'emulator-5554' -or $taskPhoneSerial -cne 'emulator-5556') {
        throw 'Virtual clock calibration requires exactly emulator-5554 and emulator-5556.'
    }
    Assert-AvdIdentity -Serial $taskTabletSerial -Name 'center_tab'
    Assert-AvdIdentity -Serial $taskPhoneSerial -Name 'dash_phone'
    $taskClockReceiptPath = Join-Path $taskLogRoot ('avd-clock-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.json')
    $taskClockReceipt = [ordered]@{
        schema_version = 1
        kind = 'avd_virtual_clock_calibration'
        created_utc = [DateTimeOffset]::UtcNow.ToString('o')
        tablet_serial = $taskTabletSerial
        tablet_avd = 'center_tab'
        phone_serial = $taskPhoneSerial
        phone_avd = 'dash_phone'
        requested_phone_ahead_ms = 500
        allowed_phone_ahead_ms = @(0, 2000)
        pc_clock_changed = $false
        tablet_clock_changed = $false
        automatic_time_settings_changed = $false
        phone_set_attempted = $false
        status = 'not_started'
    }
    try {
        if ($SkipClockSync) {
            $taskClockReceipt.status = 'skipped_by_option'
            Write-Warning 'SkipClockSync: virtual clocks were not calibrated. A phone behind the tablet can report stale/waiting data even with a healthy WebSocket.'
            return
        }
        $taskReference = Read-HybridVirtualClock -Serial $taskTabletSerial
        $taskOffset = $taskReference.DeviceUnixMs - $taskReference.HostMidpointUnixMs
        $taskSetHostTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $taskTarget = [long][Math]::Round($taskSetHostTime + $taskOffset + 500)
        $taskClockReceipt.reference_sample = $taskReference
        $taskClockReceipt.tablet_minus_host_midpoint_ms = $taskOffset
        $taskClockReceipt.set_request_host_unix_ms = $taskSetHostTime
        $taskClockReceipt.requested_phone_unix_ms = $taskTarget
        # Re-check the exact identities immediately before changing ONLY this AVD.
        Assert-AvdIdentity -Serial $taskTabletSerial -Name 'center_tab'
        Assert-AvdIdentity -Serial $taskPhoneSerial -Name 'dash_phone'
        # Identity checks take time, so refresh the target from the measured offset.
        $taskSetHostTime = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $taskTarget = [long][Math]::Round($taskSetHostTime + $taskOffset + 500)
        $taskClockReceipt.set_request_host_unix_ms = $taskSetHostTime
        $taskClockReceipt.requested_phone_unix_ms = $taskTarget
        $taskClockReceipt.phone_set_attempted = $true
        Write-Host 'Aligning only dash_phone virtual time to center_tab + 500 ms; PC/tablet clocks and automatic-time settings stay unchanged.'
        $taskSet = Invoke-DemoAdb -Arguments @('-s', $taskPhoneSerial, 'shell', 'cmd', 'alarm', 'set-time', [string]$taskTarget) -TimeoutSeconds 10 -AllowFailure
        $taskClockReceipt.set_exit_code = $taskSet.ExitCode
        $taskClockReceipt.set_output = $taskSet.Output
        $taskClockReceipt.set_error_output = $taskSet.ErrorOutput
        if ($taskSet.ExitCode -ne 0 -or
            ($taskSet.Output + "`n" + $taskSet.ErrorOutput) -match '(?im)error|exception|unknown command|not found|permission|usage:|unable|cannot|^false\s*$') {
            throw 'The phone AVD does not support cmd alarm set-time or rejected it. Clock synchronization was not verified.'
        }
        $taskTabletAfter = Read-HybridVirtualClock -Serial $taskTabletSerial
        $taskPhoneAfter = Read-HybridVirtualClock -Serial $taskPhoneSerial
        $taskDifference = Measure-HybridClockDifference -TabletSample $taskTabletAfter -PhoneSample $taskPhoneAfter
        $taskClockReceipt.tablet_verification_sample = $taskTabletAfter
        $taskClockReceipt.phone_verification_sample = $taskPhoneAfter
        $taskClockReceipt.verification = $taskDifference
        if (-not $taskDifference.WithinBounds) {
            throw "Phone/tablet virtual-clock difference was outside the verified 0..2000 ms interval after query-latency adjustment (estimate $($taskDifference.PhoneAheadEstimateMs) ms, uncertainty $($taskDifference.SamplingUncertaintyMs) ms)."
        }
        $taskClockReceipt.status = 'verified'
        Write-Host "Virtual clock calibration verified: phone ahead estimate $($taskDifference.PhoneAheadEstimateMs) ms (+/- $($taskDifference.SamplingUncertaintyMs) ms)."
    } catch {
        $taskClockReceipt.status = 'failed'
        $taskClockReceipt.error = $_.Exception.Message
        Write-Warning 'AVD clock calibration failed; freshness checks were not relaxed. Inspect the receipt or explicitly use -SkipClockSync after manual verification.'
        throw
    } finally {
        $taskClockReceipt.completed_utc = [DateTimeOffset]::UtcNow.ToString('o')
        $taskClockReceipt | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $taskClockReceiptPath -Encoding UTF8
        Write-Host "Virtual-clock receipt: $taskClockReceiptPath"
    }
}

function Wait-QwenModel {
    param($LauncherProcess)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextReport = 0
    $lastError = ''
    while ($watch.Elapsed.TotalSeconds -lt $ModelTimeoutSeconds) {
        $response = $null
        $taskHealth = $null
        if (@(Get-ListeningPort 8781).Count -gt 0) { [void](Assert-HybridModelOwner) }
        try {
            $taskHealth = Invoke-RestMethod -Uri 'http://127.0.0.1:8781/health' -Method Get -TimeoutSec 3
            $response = Invoke-RestMethod -Uri 'http://127.0.0.1:8781/v1/models' -Method Get -TimeoutSec 5
        } catch {
            $lastError = $_.Exception.Message
        }
        if ($null -ne $response) {
            if ($null -eq $taskHealth -or $taskHealth.PSObject.Properties.Name -notcontains 'status' -or $taskHealth.status -cne 'ok') {
                throw '8781 health response is not ready/valid; this service will not be used.'
            }
            if (-not ($response.PSObject.Properties.Name -contains 'data')) {
                throw '8781 的 /v1/models 回應格式不符；助手不會使用或更改這個服務。'
            }
            $ids = @($response.data | ForEach-Object {
                if ($_.PSObject.Properties.Name -contains 'id') { [string]$_.id }
            })
            if ($ids.Count -ne 1 -or $ids[0] -cne $taskModelAlias) {
                throw "8781 沒有指定模型 $taskModelAlias（查到：$($ids -join ', ')）。助手不會使用其他模型。"
            }
            [void](Assert-HybridModelOwner)
            Write-Host "真實模型已就緒：$taskModelAlias（電腦本地 127.0.0.1:8781）。"
            return
        }
        if ($null -ne $LauncherProcess) {
            $LauncherProcess.Refresh()
            if ($LauncherProcess.HasExited -and $LauncherProcess.ExitCode -ne 0) {
                throw "模型啟動腳本失敗（$($LauncherProcess.ExitCode)）；請查看 $taskLogRoot 的 qwen-launcher 記錄。"
            }
        }
        if ($watch.Elapsed.TotalSeconds -ge $nextReport) {
            Write-Host "等待 Qwen 載入：$([int]$watch.Elapsed.TotalSeconds) / $ModelTimeoutSeconds 秒…"
            $nextReport += 15
        }
        Start-Sleep -Seconds 3
    }
    throw "Qwen 在 $ModelTimeoutSeconds 秒內未就緒。最後錯誤：$lastError。服務保留，助手不會終止其他程序。"
}

function Start-OrReuseQwen {
    $listeners = @(Get-ListeningPort 8781)
    if ($listeners.Count -gt 0) {
        $nonLocal = @($listeners | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') })
        if ($nonLocal.Count -gt 0) {
            throw '8781 已被非 loopback 服務佔用。助手不會替換或更改它。'
        }
        $taskVerifiedOwner = Assert-HybridModelOwner
        Write-Host "Verified executable, exact model path and alias for existing PID $taskVerifiedOwner; model file SHA256 matched."
        Write-Host '8781 已有本地服務，先確認載入的模型。'
        Wait-QwenModel -LauncherProcess $null
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $stdout = Join-Path $taskLogRoot "qwen-launcher-$stamp.stdout.log"
    $stderr = Join-Path $taskLogRoot "qwen-launcher-$stamp.stderr.log"
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ModelLauncher,
        '-Port', '8781', '-ReadyTimeoutSeconds', [string]$ModelTimeoutSeconds)
    if (-not [string]::IsNullOrWhiteSpace($ServerPath)) { $arguments += @('-ServerPath', $ServerPath) }
    if (-not [string]::IsNullOrWhiteSpace($ModelPath)) { $arguments += @('-ModelPath', $ModelPath) }
    # ProcessOnly：僅本次已審閱的本地模型啟動子程序使用 Bypass；不更改永久／全機政策。
    $started = Start-Process -FilePath $taskPowerShell -ArgumentList (Join-NativeArguments $arguments) -WorkingDirectory (Split-Path -Parent $ModelLauncher) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    Wait-QwenModel -LauncherProcess $started
}

function Get-HubForwards {
    $result = Invoke-DemoAdb -Arguments @('forward', '--list') -TimeoutSeconds 10
    return @($result.Output -split '\r?\n' | ForEach-Object {
        $parts = $_.Trim() -split '\s+'
        if ($parts.Count -ge 3 -and $parts[1] -eq 'tcp:8767') {
            [pscustomobject]@{ Serial = $parts[0]; Local = $parts[1]; Remote = $parts[2] }
        }
    })
}

function Assert-HubPortAvailable {
    $forwards = @(Get-HubForwards)
    if ($forwards.Count -gt 0) {
        if ($forwards.Count -ne 1 -or $forwards[0].Serial -ne $taskTabletSerial -or $forwards[0].Remote -ne 'tcp:8767') {
            throw '8767 已有其他 adb forward，助手不會替換或移除它。'
        }
        return
    }
    if (@(Get-ListeningPort 8767).Count -gt 0) {
        throw '8767 已被無關的本機服務佔用，助手不會替換或關閉它。'
    }
}

function Ensure-HubForward {
    Assert-HubPortAvailable
    if (@(Get-HubForwards).Count -eq 0) {
        [void](Invoke-DemoAdb -Arguments @('-s', $taskTabletSerial, 'forward', '--no-rebind', 'tcp:8767', 'tcp:8767') -TimeoutSeconds 10)
    }
    $forwards = @(Get-HubForwards)
    if ($forwards.Count -ne 1 -or $forwards[0].Serial -ne $taskTabletSerial -or $forwards[0].Remote -ne 'tcp:8767') {
        throw '8767 forward 未通過驗證。助手不會重新綁定或移除其他 forward。'
    }
    Write-Host '同步橋接就緒：電腦 8767 → center_tab 8767。'
}

function Read-HubStatus {
    # Hub 在 /repair 送出首筆狀態；只讀取，不送出操作訊息。
    $socket = New-Object System.Net.WebSockets.ClientWebSocket
    $cancel = New-Object System.Threading.CancellationTokenSource
    $stream = New-Object System.IO.MemoryStream
    try {
        $cancel.CancelAfter(5000)
        $connect = $socket.ConnectAsync([Uri]'ws://127.0.0.1:8767/repair', $cancel.Token)
        # PS5.1 可能把 Task<VoidTaskResult> 的 GetResult 輸出送進 pipeline，必須明確抑制。
        [void]$connect.GetAwaiter().GetResult()
        $buffer = New-Object byte[] 16384
        $segment = [System.ArraySegment[byte]]::new($buffer)
        do {
            $receive = $socket.ReceiveAsync($segment, $cancel.Token)
            $frame = $receive.GetAwaiter().GetResult()
            if ($frame.MessageType -ne [System.Net.WebSockets.WebSocketMessageType]::Text) {
                throw 'Hub 沒有送出文字狀態。'
            }
            $stream.Write($buffer, 0, $frame.Count)
            if ($stream.Length -gt 65536) { throw 'Hub 狀態超過 64 KB。' }
        } while (-not $frame.EndOfMessage)
        return ([System.Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json)
    } finally {
        $socket.Abort()
        $socket.Dispose()
        $cancel.Dispose()
        $stream.Dispose()
    }
}

function Wait-HubStatus {
    $lastError = ''
    for ($taskAttempt = 1; $taskAttempt -le 5; $taskAttempt++) {
        $status = $null
        try { $status = Read-HubStatus } catch { $lastError = $_.Exception.Message }
        if ($null -ne $status) {
            $fields = @($status.PSObject.Properties.Name)
            if ($fields -notcontains 'type' -or $fields -notcontains 'schema' -or $fields -notcontains 'model' -or
                $status.type -cne 'repair_status' -or $status.schema -ne $(if ($Coordination) { 2 } else { 1 })) {
                throw '8767 is not the expected repair Hub schema.'
            }
            if ($Coordination -and ($fields -notcontains 'cabin_context' -or
                [string]::IsNullOrWhiteSpace([string]$status.cabin_context.cabin_session_id))) {
                throw 'C Hub did not expose a cabin session; readiness was not established.'
            }
            $modelStatus = [string]$status.model
            if ($modelStatus.Contains($taskModelAlias) -and $modelStatus.Contains('電腦本地推論')) {
                Write-Host 'Read-only WebSocket check passed: tablet reports the expected V3 PC model.'
                return
            }
            $lastError = 'The tablet has not reported the expected ready V3 PC model; another App may own its Hub port.'
        }
        Write-Host "Waiting for tablet Hub ($taskAttempt / 5); task completion and model quality are not yet tested."
        if ($taskAttempt -lt 5) { Start-Sleep -Seconds 2 }
    }
    throw "Hub readiness was not verified after five read-only attempts. $lastError"
}

try {
    Write-Host $(if ($Coordination) { 'C｜注意力模式與座艙能力協調' } else { 'Hybrid V3｜雙裝置桌面實測' }) -ForegroundColor Cyan
    foreach ($required in @($taskAdb, $taskEmulator, $taskPowerShell, $ModelLauncher, $ModelPath, $ServerPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少必要檔案：$required" }
    }
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        throw '缺少 Windows Get-NetTCPConnection，無法安全檢查連接埠。'
    }
    if ((Get-Item -LiteralPath $ModelPath).Length -ne $taskExpectedModelBytes -or
        (Get-FileHash -LiteralPath $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $taskExpectedModelHash) {
        throw 'V3 GGUF byte length or SHA256 mismatch. No emulator, App or model was started or changed.'
    }
    if (-not $SkipInstall) {
        $taskAapts = @(Get-ChildItem -LiteralPath (Join-Path $SdkRoot 'build-tools') -Filter aapt.exe -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        foreach ($requiredApk in @($ApkPath, $PhoneApkPath)) {
            if (-not (Test-Path -LiteralPath $requiredApk -PathType Leaf)) {
                throw "找不到實測 APK：$requiredApk。兩個裝置已有正確版本時可用 -SkipInstall。"
            }
            if ($taskAapts.Count -gt 0) {
                $taskBadging = Invoke-LocalTool -FilePath $taskAapts[0].FullName -Arguments @('dump', 'badging', $requiredApk) -TimeoutSeconds 30
                if ($taskBadging.Output -notmatch ("(?m)^package: name='" + [regex]::Escape($taskPackage) + "'")) {
                    throw "Wrong APK package: $requiredApk. Nothing was installed."
                }
            } else {
                Write-Warning 'aapt not available: APK identity cannot be preverified; installed package will be checked.'
            }
        }
    } else {
        Write-Warning 'SkipInstall reuses installed App data/version; the APK file version is not being reinstalled or proved.'
    }
    $available = Invoke-LocalTool -FilePath $taskEmulator -Arguments @('-list-avds') -TimeoutSeconds 15
    $avdNames = @($available.Output -split '\r?\n' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $devices = @(
        [pscustomobject]@{ Name = 'center_tab'; Serial = $taskTabletSerial; Port = 5554; Scale = '0.40' },
        [pscustomobject]@{ Name = 'dash_phone'; Serial = $taskPhoneSerial; Port = 5556; Scale = '0.27' }
    )
    foreach ($definition in $devices) {
        if ($avdNames -cnotcontains $definition.Name) { throw "缺少 AVD：$($definition.Name)。助手不會自動建立或改動 AVD。" }
        Assert-EmulatorSlot $definition
    }
    Assert-HubPortAvailable
    [void][System.IO.Directory]::CreateDirectory($taskLogRoot)
    Start-OrReuseQwen
    foreach ($definition in $devices) { Start-OrReuseEmulator $definition }
    foreach ($definition in $devices) { Wait-DemoBoot $definition }
    Sync-HybridVirtualClock

    # These two preserved demo packages share a Hub port. Switching the selected
    # demo stops only its known sibling on these identity-verified AVDs; no data
    # clear or uninstall is performed, and no original/physical App is touched.
    $taskSiblingPackage = if ($Coordination) { 'com.auohack.cockpit_hmi.hybridv3' } else { 'com.auohack.cockpit_hmi.coordination' }
    foreach ($definition in $devices) {
        Assert-AvdIdentity -Serial $definition.Serial -Name $definition.Name
        $taskSibling = Invoke-DemoAdb -Arguments @('-s', $definition.Serial, 'shell', 'pidof', $taskSiblingPackage) -AllowFailure
        if ($taskSibling.ExitCode -eq 0 -and $taskSibling.Output.Trim() -match '^\d') {
            [void](Invoke-DemoAdb -Arguments @('-s', $definition.Serial, 'shell', 'am', 'force-stop', $taskSiblingPackage) -TimeoutSeconds 15)
            Write-Host "Switching demo: stopped only $taskSiblingPackage on $($definition.Name); installed data retained."
        }
    }

    $installTargets = @(
        [pscustomobject]@{ Serial = $taskTabletSerial; Apk = $ApkPath; Label = '平板乘客詳細端' },
        [pscustomobject]@{ Serial = $taskPhoneSerial; Apk = $PhoneApkPath; Label = '手機駕駛摘要端' }
    )
    foreach ($target in $installTargets) {
        Assert-AvdIdentity -Serial $target.Serial -Name (($devices | Where-Object { $_.Serial -ceq $target.Serial }).Name)
        if ($SkipInstall) {
            $installed = Invoke-DemoAdb -Arguments @('-s', $target.Serial, 'shell', 'pm', 'path', $taskPackage) -TimeoutSeconds 15 -AllowFailure
            if ($installed.ExitCode -ne 0 -or $installed.Output -notmatch '(?m)^package:') {
                throw "-SkipInstall 已指定，但 $($target.Label)（$($target.Serial)）尚未安裝獨立 PC 實測 App（$taskPackage）。"
            }
            Write-Host "略過 $($target.Label) 安裝，沿用既有獨立實測 App。"
        } else {
            Write-Host "以 install -r 安裝或更新 $($target.Label)，保留既有資料（更新 APK 可能讓 Android 暫停該實測 App）。"
            $install = Invoke-DemoAdb -Arguments @('-s', $target.Serial, 'install', '-r', $target.Apk) -TimeoutSeconds 180
            if ($install.Output -notmatch '(?m)^Success\s*$') { throw "$($target.Label) APK 安裝結果不符預期：$($install.Output)" }
        }
        $taskInstalled = Invoke-DemoAdb -Arguments @('-s', $target.Serial, 'shell', 'pm', 'path', $taskPackage) -TimeoutSeconds 15 -AllowFailure
        if ($taskInstalled.ExitCode -ne 0 -or $taskInstalled.Output -notmatch '(?m)^package:') {
            throw "Hybrid V3 package was not found on $($target.Serial); no uninstall or data clear was attempted."
        }
    }
    Ensure-HubForward
    if ($RestartApp) {
        foreach ($target in $installTargets) {
            [void](Invoke-DemoAdb -Arguments @('-s', $target.Serial, 'shell', 'am', 'force-stop', $taskPackage) -TimeoutSeconds 15)
        }
        Write-Host '已依 -RestartApp 關閉兩個本次實測 App，接著啟動。'
    }
    Start-HybridApp -Serial $taskTabletSerial
    Wait-HubStatus
    Start-HybridApp -Serial $taskPhoneSerial
    Write-Host ''
    Write-Host '啟動完成：平板為乘客詳細端，手機為駕駛摘要端；請在 App 內配對、授權、修正並由駕駛確認。' -ForegroundColor Green
    Write-Host '需求提交使用電腦本地 V3 模型；兩屏仍須配對、授權與確認，不會自動執行。'
    Write-Host '收到逐項模擬 ACK 才完成任務；此模式不是 S9 端上、麥克風或人體效益測試。'
    Write-Host "重跑可加 -SkipInstall 保留正在操作的 App；必要時再加 -RestartApp。記錄：$taskLogRoot"
} catch {
    Write-Host ''
    Write-Host "啟動未完成：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '助手未卸載 App、未 wipe、未更改永久執行政策；切換模式只會暫停兩個指定模擬器上的另一個獨立示範 App。'
    exit 1
}
