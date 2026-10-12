# 雙裝置桌面實測：一台 Android 平板、一台 Android 手機，以及電腦上的真實 Qwen。
# 不變更永久環境變數、全機／使用者執行原則、AVD 設定或 App 資料；不卸載、不 wipe、不移動視窗。
# 平板為乘客詳細端，手機為駕駛摘要端；啟動後仍須六位碼配對、駕駛授權、局部修正與最終確認。
# 預設需求文字提交仍真跑 Qwen；手動安排誤解會標示來源，逐項按鈕修正不呼叫模型。
# 此助手不是 S9 端上或麥克風測試；Android ASR 的嚴格本地路徑尚未實測。
# 倉庫設定 compile SDK 36、target SDK 34、min SDK 24；最終兩個 APK 已重建、aapt 核對、安裝並走完原生流程。
# 最新 target 34 原生流程使用兩次真 Qwen 文字輸入、駕駛確認與模擬 ACK；先前 target 36 人工故障／按鈕流程另保留。
# 模擬器流程完成不代替 S9、麥克風、兩實體斷外網或人體效益驗證。
# 最終工程／APK／原生流程記錄與 SHA：docs/evidence/final-validation.json；隊友簡報：docs/repair-proposal.pdf。
# 例：.\tools\desktop\start-demo.ps1 -SkipInstall
# 只有需要重置 App 當前狀態時，才加上 -RestartApp。
[CmdletBinding()]
param(
    [switch]$SkipInstall,
    [switch]$RestartApp,
    [string]$SdkRoot = (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
    [string]$ModelLauncher = '',
    [string]$ServerPath = '',
    [string]$ModelPath = '',
    [string]$ApkPath = '',
    [string]$PhoneApkPath = '',
    [ValidateRange(60, 600)][int]$BootTimeoutSeconds = 240,
    [ValidateRange(15, 300)][int]$ModelTimeoutSeconds = 180,
    [ValidateRange(15, 180)][int]$HubTimeoutSeconds = 90
)

# PowerShell 5.1 在參數預設值求值時可能尚未提供 PSScriptRoot；在 param 後才解析本檔目錄。
$taskScriptRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($taskScriptRoot)) {
    $taskScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($taskScriptRoot)) {
    throw '無法取得助手檔案所在目錄；請以 -File 或 .cmd 執行本檔。'
}
$taskWorkspaceRoot = [System.IO.Path]::GetFullPath((Join-Path $taskScriptRoot '..\..'))
if ([string]::IsNullOrWhiteSpace($ModelLauncher)) {
    $ModelLauncher = Join-Path $taskScriptRoot 'start-qwen-server.ps1'
}
if ([string]::IsNullOrWhiteSpace($ApkPath)) {
    $ApkPath = Join-Path $taskWorkspaceRoot '.local\desktop-demo\tablet.apk'
}
if ([string]::IsNullOrWhiteSpace($PhoneApkPath)) {
    $PhoneApkPath = Join-Path $taskWorkspaceRoot '.local\desktop-demo\phone.apk'
}

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$taskAdb = Join-Path $SdkRoot 'platform-tools\adb.exe'
$taskEmulator = Join-Path $SdkRoot 'emulator\emulator.exe'
$taskPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskModelAlias = 'Qwen2.5-1.5B-Instruct'
$taskPackage = 'com.auohack.cockpit_hmi.desktopdemo'
$taskComponent = 'com.auohack.cockpit_hmi.desktopdemo/com.auohack.cockpit_hmi.MainActivity'
$taskTabletSerial = 'emulator-5554'
$taskPhoneSerial = 'emulator-5556'
$taskLogRoot = Join-Path $taskWorkspaceRoot '.local\desktop-demo\logs'

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
        '-memory', '2048', '-no-snapshot-load', '-no-snapshot-save', '-no-audio',
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

function Wait-QwenModel {
    param($LauncherProcess)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextReport = 0
    $lastError = ''
    while ($watch.Elapsed.TotalSeconds -lt $ModelTimeoutSeconds) {
        $response = $null
        try {
            $response = Invoke-RestMethod -Uri 'http://127.0.0.1:8778/v1/models' -Method Get -TimeoutSec 5
        } catch {
            $lastError = $_.Exception.Message
        }
        if ($null -ne $response) {
            if (-not ($response.PSObject.Properties.Name -contains 'data')) {
                throw '8778 的 /v1/models 回應格式不符；助手不會使用或更改這個服務。'
            }
            $ids = @($response.data | ForEach-Object {
                if ($_.PSObject.Properties.Name -contains 'id') { [string]$_.id }
            })
            if ($ids -cnotcontains $taskModelAlias) {
                throw "8778 沒有指定模型 $taskModelAlias（查到：$($ids -join ', ')）。助手不會使用其他模型。"
            }
            Write-Host "真實模型已就緒：$taskModelAlias（電腦本地 127.0.0.1:8778）。"
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
    $listeners = @(Get-ListeningPort 8778)
    if ($listeners.Count -gt 0) {
        $nonLocal = @($listeners | Where-Object { $_.LocalAddress -notin @('127.0.0.1', '::1') })
        if ($nonLocal.Count -gt 0) {
            throw '8778 已被非 loopback 服務佔用。助手不會替換或更改它。'
        }
        Write-Host '8778 已有本地服務，先確認載入的模型。'
        Wait-QwenModel -LauncherProcess $null
        return
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $stdout = Join-Path $taskLogRoot "qwen-launcher-$stamp.stdout.log"
    $stderr = Join-Path $taskLogRoot "qwen-launcher-$stamp.stderr.log"
    $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $ModelLauncher)
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
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $nextReport = 0
    $lastError = ''
    while ($watch.Elapsed.TotalSeconds -lt $HubTimeoutSeconds) {
        $status = $null
        try {
            $status = Read-HubStatus
        } catch {
            $lastError = $_.Exception.Message
        }
        if ($null -ne $status) {
            $fields = @($status.PSObject.Properties.Name)
            if ($fields -notcontains 'type' -or $fields -notcontains 'schema' -or $fields -notcontains 'model' -or $status.type -ne 'repair_status' -or $status.schema -ne 1) {
                throw '8767 回傳的不是預期的 repair Hub，助手不會使用這個服務。'
            }
            $modelStatus = [string]$status.model
            if ($modelStatus.Contains('電腦本地推論') -and $modelStatus.Contains('Qwen 2.5 1.5B')) {
                Write-Host '平板同步服務及真實 PC Qwen 狀態已就緒。'
                return
            }
            if ($modelStatus.Contains('正在連接電腦') -or $modelStatus.Contains('電腦模型尚未就緒')) {
                $lastError = $modelStatus
            } else {
                throw "8767 不是 PC 實測 App 的模型狀態：$modelStatus。可能原 App 仍佔用平板內的 Hub 8767；請手動關閉它。助手不會自動關閉其他 App。"
            }
        }
        if ($watch.Elapsed.TotalSeconds -ge $nextReport) {
            Write-Host "等待平板同步服務：$([int]$watch.Elapsed.TotalSeconds) / $HubTimeoutSeconds 秒…"
            $nextReport += 15
        }
        Start-Sleep -Seconds 3
    }
    throw "平板同步服務在 $HubTimeoutSeconds 秒內未就緒。請確認平板 APK 是 PC 模擬器版本。最後錯誤：$lastError"
}

try {
    Write-Host '不用重講｜雙裝置桌面實測' -ForegroundColor Cyan
    foreach ($required in @($taskAdb, $taskEmulator, $taskPowerShell, $ModelLauncher)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "缺少必要檔案：$required" }
    }
    if (-not (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
        throw '缺少 Windows Get-NetTCPConnection，無法安全檢查連接埠。'
    }
    if (-not $SkipInstall) {
        foreach ($requiredApk in @($ApkPath, $PhoneApkPath)) {
            if (-not (Test-Path -LiteralPath $requiredApk -PathType Leaf)) {
                throw "找不到實測 APK：$requiredApk。兩個裝置已有正確版本時可用 -SkipInstall。"
            }
        }
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

    $installTargets = @(
        [pscustomobject]@{ Serial = $taskTabletSerial; Apk = $ApkPath; Label = '平板乘客詳細端' },
        [pscustomobject]@{ Serial = $taskPhoneSerial; Apk = $PhoneApkPath; Label = '手機駕駛摘要端' }
    )
    foreach ($target in $installTargets) {
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
    }
    Ensure-HubForward
    if ($RestartApp) {
        foreach ($target in $installTargets) {
            [void](Invoke-DemoAdb -Arguments @('-s', $target.Serial, 'shell', 'am', 'force-stop', $taskPackage) -TimeoutSeconds 15)
        }
        Write-Host '已依 -RestartApp 關閉兩個本次實測 App，接著啟動。'
    }
    $launch = Invoke-DemoAdb -Arguments @('-s', $taskTabletSerial, 'shell', 'am', 'start', '-W', '-n', $taskComponent) -TimeoutSeconds 30
    if (($launch.Output + [Environment]::NewLine + $launch.ErrorOutput) -match '(?m)^Error(?: type|:)') { throw "平板 App 啟動失敗：$($launch.Output) $($launch.ErrorOutput)" }
    Wait-HubStatus
    $phoneLaunch = Invoke-DemoAdb -Arguments @('-s', $taskPhoneSerial, 'shell', 'am', 'start', '-W', '-n', $taskComponent) -TimeoutSeconds 30
    if (($phoneLaunch.Output + [Environment]::NewLine + $phoneLaunch.ErrorOutput) -match '(?m)^Error(?: type|:)') { throw "手機第二屏 App 啟動失敗：$($phoneLaunch.Output) $($phoneLaunch.ErrorOutput)" }
    Write-Host ''
    Write-Host '啟動完成：平板為乘客詳細端，手機為駕駛摘要端；請在 App 內配對、授權、修正並由駕駛確認。' -ForegroundColor Green
    Write-Host '預設需求提交仍由電腦本地 Qwen 真實推論；手動安排誤解有標示，按鈕修正不呼叫模型。'
    Write-Host '收到逐項模擬 ACK 才完成任務；此模式不是 S9 端上、麥克風或人體效益測試。'
    Write-Host "重跑可加 -SkipInstall 保留正在操作的 App；必要時再加 -RestartApp。記錄：$taskLogRoot"
} catch {
    Write-Host ''
    Write-Host "啟動未完成：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '助手未卸載 App、未 wipe、未更改永久執行政策，也未關閉其他程序。'
    exit 1
}
