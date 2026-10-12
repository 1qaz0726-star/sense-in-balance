# Windows 電腦雙裝置展示

這份指南用一台 Windows 電腦執行真正的 Qwen 1.5B，再用兩個原生 Android 模擬器操作與顯示。平板是操作主機；手機是只讀第二屏。車速、油量、盲點和車控都是展示模擬，沒有接真車或攝影機。

原作完整入口仍是 `app/cockpit_hmi/lib/main.dart`。本指南建置新版 `main_repair.dart` 與 `main_repair_monitor.dart`，保留原規則警示，新增局部修正需求與雙屏結果。S9 端上 LiteRT 模式是另一種配置，見 [DEVELOPMENT.md](DEVELOPMENT.md)；本指南的 x64 APK 不供 S9 安裝，也不能代表 S9 的推論速度。

## 1. 準備工具與模擬器

將倉庫 clone 到英文路徑，例如 `C:\dev\sense-in-balance`。安裝 Flutter **3.35.2**（包含 Dart 3.9）、JDK **17**、Git，以及 Android Studio／Android SDK。Android 建置套件依 [DEVELOPMENT.md](DEVELOPMENT.md) 的清單準備；SDK 36 是建置套件，下面的 Android 14 是模擬器映像，兩者用途不同。

先自行檢查 `flutter --version`、`flutter doctor -v` 與 Android SDK 授權。`build-demo.ps1` 可從 PATH 找 Flutter，或以 `-FlutterPath` 選擇 Flutter；不依賴 Codex 安裝或特定 Windows 使用者名稱。`-SdkRoot`／`-JavaHome` 只設定本次程序的 `ANDROID_HOME`／`JAVA_HOME`／PATH，屬於環境提示，不會覆蓋 Flutter 已保存的設定或 Android Studio 內建 JDK。

在 Android Studio 的 Device Manager 預先建立：

| AVD 名稱，大小寫須一致 | 裝置角色 | 系統映像 |
|---|---|---|
| `center_tab` | Tablet 裝置，平板主控／儀表 | Android 14／API 34、Google APIs、**x86_64** |
| `dash_phone` | Phone 裝置，駕駛只讀第二屏 | Android 14／API 34、Google APIs、**x86_64** |

這套助手適用 Windows x64 的 Android Emulator。需啟用 BIOS／UEFI 虛擬化及 Windows Hypervisor Platform（WHPX）。助手會以每台 2 GB RAM 啟動，固定使用 `emulator-5554` 和 `emulator-5556`；其他模擬器占用這兩個位置時會停止並說明原因，不會取代或清除它們。

## 2. 準備官方模型與 runtime

下載模型與 llama.cpp runtime，助手**不自動下載**：

- 模型：[官方 Qwen2.5-1.5B-Instruct-GGUF](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/tree/91cad51170dc346986eccefdc2dd33a9da36ead9)，選 `qwen2.5-1.5b-instruct-q8_0.gguf`，約 1.89 GB。
- Runtime：[llama.cpp b11557 官方 Windows Vulkan x64 release](https://github.com/ggml-org/llama.cpp/releases/tag/b11557)，選 `llama-b11557-bin-win-vulkan-x64.zip`，解壓**全部** runtime 檔案，包括 DLL，不要只取 EXE。

將檔案放到倉庫的本機目錄：

```text
.local/
  runtime/
    llama-server.exe
    ... 同一個 Vulkan release 的 DLL
  models/
    Qwen2.5-1.5B-Instruct-Q8_0.gguf
  desktop-demo/
    tablet.apk
    phone.apk
    logs/
```

`.local` 是本機產物，模型、runtime、APK 與 log 不應加入 Git。若檔案在其他地方，不必搬動：

```powershell
.\tools\desktop\start-demo.cmd -ServerPath 'D:\ai\runtime\llama-server.exe' -ModelPath 'D:\ai\models\qwen2.5-1.5b-instruct-q8_0.gguf'
```

也可在目前終端機設定 `$env:SENSE_LLAMA_SERVER` 和 `$env:SENSE_QWEN_MODEL` 為完整檔案路徑；明確參數優先於這兩個環境變數。PC 用的是 GGUF／Vulkan，端上用的 `.litertlm` 不能當作這個 runtime 的模型檔。

本次驗證過的官方下載 SHA256 可供自行核對：

| 檔案 | SHA256 |
|---|---|
| Qwen Q8_0 GGUF，上述固定 revision | `d7efb072e7724d25048a4fda0a3e10b04bdef5d06b1403a1c93bd9f1240a63c8` |
| b11557 Vulkan x64 ZIP | `6db23c5cf69e51f3dc2bf7f68277f4a791217bab853bd5b93afac1898d450b83` |

可用 PowerShell `Get-FileHash -Algorithm SHA256` 檢查下載檔。啟動助手會驗證 API 的模型 alias；alias 是服務識別，不取代模型檔雜湊校驗。

## 3. 建置兩個 APK

在倉庫根目錄執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\desktop\build-demo.ps1
```

Flutter 不在 PATH 時，指定你實際安裝的路徑；也可提供 SDK／JDK 的程序環境提示：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\desktop\build-demo.ps1 -FlutterPath 'C:\dev\flutter\bin\flutter.bat' -SdkRoot 'C:\Android\Sdk' -JavaHome 'C:\dev\jdk-17'
```

腳本先檢查 Flutter 3.35.2，再取得依賴、分別建置平板與手機 x64 debug APK，存為 `.local/desktop-demo/tablet.apk` 和 `phone.apk`。兩次建置共用 Flutter 的 `app-debug.apk` 路徑，因此腳本會先保存平板產物再建手機。這一步不安裝、不啟動任何裝置。

提供 `-SdkRoot`／`-JavaHome` 時，建置前會執行 `flutter doctor -v`，抽取 `Android SDK at`／`Java binary at`，將路徑正規化並忽略大小寫核對；Java 與指定 JDK 的 `bin/java.exe` 比較，兼容 Flutter 省略 `.exe` 的輸出。缺少工具路徑、檔案不存在或選擇不一致時停止，不猜測成功。請自行檢查 `flutter config` 的 `android-sdk`／`jdk-dir` 和 Android Studio 內建 JDK，依錯誤中的實際路徑調整後重跑；助手不修改永久配置。Doctor 其他平台工具提示不會單獨阻止 Android 建置，Android SDK 授權仍須先自行處理。

兩個 APK 使用獨立 application ID `com.auohack.cockpit_hmi.desktopdemo`，與原 App 分開。不同開發者的 debug 簽章可能不同；若既有 PC 測試 App 簽章不符，Android 會拒絕 `install -r`，助手不會藉由卸載原 App 解決。

手機原生第二屏不需要打包網頁。若另外需要由平板提供瀏覽器第二屏，建置時加 `-PackWeb`；這會先建 `main_repair_web.dart`、執行 `tool/pack_repair_web.py`，最後還原原本的 `pubspec.yaml`。此選項需要 Python 3；產生的網頁資產留在本機忽略目錄。不要在同一次建置混入原 `pack_web.py` 的資產清單。

## 4. 啟動與操作

在倉庫根目錄雙擊 `tools/desktop/start-demo.cmd`，或執行：

```powershell
.\tools\desktop\start-demo.cmd
.\tools\desktop\start-demo.cmd -SkipInstall
```

首次使用會啟動／驗證 PC 模型、開啟或沿用兩個指定 AVD、安裝兩個 APK，建立同步橋接，再開 App。已裝正確版本時用 `-SkipInstall`；只有需要重置當前 App 記憶體狀態時才加 `-RestartApp`。Android SDK 不在預設 `%LOCALAPPDATA%\Android\Sdk` 時，加 `-SdkRoot`。

平板預設是行車儀表，可用展示情境觸發左右盲點；切換座艙主控後，先提出需求、只修改其中一項，再確認模擬套用。手機預設顯示儀表，可切協作結果，但不能操作車控。參考驗證與已知模型限制見 [VALIDATION.md](VALIDATION.md)。

| 連接 | 用途 |
|---|---|
| PC `127.0.0.1:8778` | 本地 Qwen API，alias 必須是 `Qwen2.5-1.5B-Instruct` |
| 平板 `10.0.2.2:8778` | Android 模擬器存取 PC 的模型 |
| 平板 Hub `8767/repair` | 只讀狀態與原座艙事件 |
| PC adb forward `8767 → emulator-5554:8767` | 手機第二屏回連平板 Hub |
| 手機 `ws://10.0.2.2:8767/repair` | 同步第二屏，不載入模型 |

`10.0.2.2` 是 Android 模擬器的宿主機位址，不是兩台實體平板的設定。只需本地推論及同步時，不要求持續連外網；首次安裝套件及下載模型仍需網路。

模型程序隱藏在背景，log 存於 `.local/desktop-demo/logs`。如果 8778 已有服務，助手只在確認精確模型 alias 後沿用；無關埠占用、錯誤模型、錯誤 AVD、缺 APK 時會停止，不殺其他程序、不 wipe、不卸載。`start-qwen-server.ps1` 也可單獨呼叫，接受 `-ServerPath`／`-ModelPath`；它會輸出新程序 PID，模型真正就緒由 API 與雙屏助手另行確認。

CMD 與上述建置範例的 `ExecutionPolicy Bypass` 只作用在本次 PowerShell 程序，不呼叫 `Set-ExecutionPolicy`，不改永久 PATH 或 registry。建置助手在結束時還原目前工作目錄及暫時設定的環境變數。

通用建置助手已在這台電腦真正執行，從基礎資產清單建出兩個 APK；Doctor 路徑核對也已實際執行，確認使用指定 SDK 與 JDK。通用模型啟動助手已實測沿用既有本地服務分支，精確 alias 檢查成功，未另啟第二個模型程序。通用 `start-demo` 目前完成語法檢查與程式審閱；先前本機助手曾完成真 Qwen 與雙模擬器互動實測。仍未在第二台乾淨 Windows 電腦完整安裝驗證，不能把同機實測當成所有電腦都已支援。
