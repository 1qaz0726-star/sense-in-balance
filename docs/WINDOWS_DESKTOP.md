# Windows 電腦雙裝置展示

這份指南用一台Windows電腦執行真正的Qwen1.5B，再用兩個原生Android模擬器展示「不用重講」。平板是乘客詳細端／狀態主機，手機是駕駛端：未配對時觀察，六位碼配對後可授權乘客修正、收權、確認最新版本與查看逐項ACK。車速、油量、盲點和車控都是展示模擬，沒有接真車或攝影機。

原作完整入口仍是 `app/cockpit_hmi/lib/main.dart`。本指南建置新版 `main_repair.dart` 與 `main_repair_monitor.dart`，保留原規則警示，新增局部修正需求與雙屏結果。S9 端上 LiteRT 模式是另一種配置，見 [DEVELOPMENT.md](DEVELOPMENT.md)；本指南的 x64 APK 不供 S9 安裝，也不能代表 S9 的推論速度。

2026-10-13修訂：108/108工程測試及靜態分析通過。部分成功只重試剩餘項，矛盾回報待查證，完成畫面優先顯示實際模擬回報；新建置／原生證據見[本輪驗證](evidence/engineering-validation-20261013.json)。本輪已見20／16例的保護鏈路回歸為20/20、16/16，真模型原始契約分別12/14、4/12；不能稱模型100%或人體效益。下方10月12日數據是保留基準，詳見[驗證與限制](VALIDATION.md)。

## 1. 準備工具與模擬器

將倉庫 clone 到英文路徑，例如 `C:\dev\sense-in-balance`。安裝 Flutter **3.35.2**（包含 Dart 3.9）、JDK **17**、Git，以及 Android Studio／Android SDK。Android建置套件依[DEVELOPMENT.md](DEVELOPMENT.md)的清單準備；目前compile SDK36、target SDK34、min SDK24。兩個最新APK已建出並經aapt確認target 34；下面的Android 14／API34則是模擬器映像，不能以它代替APK的target核對。

先自行檢查 `flutter --version`、`flutter doctor -v` 與 Android SDK 授權。`build-demo.ps1` 可從 PATH 找 Flutter，或以 `-FlutterPath` 選擇 Flutter；不依賴 Codex 安裝或特定 Windows 使用者名稱。`-SdkRoot`／`-JavaHome` 只設定本次程序的 `ANDROID_HOME`／`JAVA_HOME`／PATH，屬於環境提示，不會覆蓋 Flutter 已保存的設定或 Android Studio 內建 JDK。

在 Android Studio 的 Device Manager 預先建立：

| AVD 名稱，大小寫須一致 | 裝置角色 | 系統映像 |
|---|---|---|
| `center_tab` | Tablet裝置，乘客詳細端／狀態主機／儀表 | Android 14／API 34、Google APIs、**x86_64** |
| `dash_phone` | Phone裝置，未配對觀察，配對後駕駛授權／確認／ACK | Android 14／API 34、Google APIs、**x86_64** |

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

手機原生第二屏不需要打包網頁。若另外需要由平板提供瀏覽器第二屏，建置時加 `-PackWeb`；這會先建 `main_repair_web.dart`、執行 `tool/pack_repair_web.py`，最後還原原本的 `pubspec.yaml`。此選項需要 Python 3；先確認 `python --version` 能執行真正的Python，Windows的Microsoft Store捷徑不算已安裝。產生的網頁資產留在本機忽略目錄。不要在同一次建置混入原 `pack_web.py` 的資產清單。

## 4. 啟動與操作

在倉庫根目錄雙擊 `tools/desktop/start-demo.cmd`，或執行：

```powershell
.\tools\desktop\start-demo.cmd
.\tools\desktop\start-demo.cmd -SkipInstall
```

首次使用會啟動／驗證 PC 模型、開啟或沿用兩個指定 AVD、安裝兩個 APK，建立同步橋接，再開 App。已裝正確版本時用 `-SkipInstall`；只有需要重置當前 App 記憶體狀態時才加 `-RestartApp`。Android SDK 不在預設 `%LOCALAPPDATA%\Android\Sdk` 時，加 `-SdkRoot`。

平板可顯示儀表與乘客明細，手機可顯示儀表與駕駛摘要。更新角色功能後先重新建置／安裝兩份APK；`-SkipInstall`只適用已安裝正確新版本，助手不以此自動更新程式。

操作順序：

1. 平板輸入／帶入「後座風小一點，音樂也小一點，導航提示不要變。」並提交。帶入按鈕只填文字，預設示範仍由PC真Qwen解析；不會因是示範台詞而改成固定答案。
2. 在平板打開「連接駕駛屏」，查看六位配對碼；手機切到協作摘要輸入此碼。連線成功但未配對仍是觀察者。
3. 手機駕駛端核對摘要，按「授權乘客協助120秒」。
4. 平板帶入「只取消風量」並提交「風量先不用改，其餘照剛剛。」；真Qwen提出取消風量待辦，其餘音樂降低／導航keep保留。逐項按鈕與規則澄清另有分流紀錄，不冒充模型輸出。
5. 駕駛看最新版本並「確認套用（車控模擬）」。接受確認與收到ACK是不同階段；回執到達後才顯示模擬完成。初始風量／音樂／導航3／5／5變成3／4／5。
6. 未授權、舊版本、收權、授權逾時與斷線時操作受阻；恢復連線需重新配對／授權，不能重送已執行動作。這些權限邊界另有工程測試，先前target36的原生互動也實際觀察120秒到期禁止編輯、重新授權可繼續。

桌面展示情境中的「安排一項誤解」手動改尚未執行的導航候選，畫面與回執來源都有人工安排標示；它不授權、不執行，不代表模型自然錯誤率。方案01只包含這段修復協作，沒有完整任務owner交接。參考[驗證結果與限制](VALIDATION.md)、[詳細研究](REPAIR_EVIDENCE_AND_TEST_PLAN.md)及[隊友審查簡報](repair-proposal.pdf)（12頁）。

最終兩個target34 APK已重建、aapt核對、安裝並在兩個AVD實際走完上述無注入文字流程：[乘客局部取消](evidence/native/repair-passenger-final.png)、[駕駛最新摘要](evidence/native/repair-driver-final-candidate.png)、[駕駛回執與3／4／5](evidence/native/repair-driver-final.png)。兩次[真Qwen trace](evidence/native/repair-final-qwen-traces.txt)及[完成狀態JSON](evidence/native/repair-final-status.json)另存。這次沒有手動故障或按鈕修導航，是局部改口／取消的原生證據，不代表自然錯誤修復率或人體效益，也不能與A/B/C/D的修復計時混用。

先前target36的手動導航誤解與混合文字＋按鈕流程另保留[乘客](evidence/native/repair-passenger-revised.png)、[駕駛](evidence/native/repair-driver-revised.png)、[回執](evidence/native/repair-driver-complete.png)；該次實際觀察120秒到期禁止編輯、重新授權可繼續，不能將人工故障當模型自然誤判。

| 連接 | 用途 |
|---|---|
| PC `127.0.0.1:8778` | 本地 Qwen API，alias 必須是 `Qwen2.5-1.5B-Instruct` |
| 平板 `10.0.2.2:8778` | Android 模擬器存取 PC 的模型 |
| 平板 Hub `8767/repair` | 狀態／原座艙事件；配對駕駛可送授權、確認與取消，其他遠端連線只讀 |
| PC adb forward `8767 → emulator-5554:8767` | 手機第二屏回連平板 Hub |
| 手機 `ws://10.0.2.2:8767/repair` | 駕駛摘要與配對權限指令，不載入模型 |

`10.0.2.2` 是 Android 模擬器的宿主機位址，不是兩台實體平板的設定。只需本地推論及同步時，不要求持續連外網；首次安裝套件及下載模型仍需網路。

10月12日歷史基準：88項工程測試通過、靜態分析No issues；含按鈕修另一項仍保留未回答澄清、禁止確認、回答後mock只執行一次。公開固定20例歷史未保護解析13/20，挑戰修正後保護鏈路重跑20/20，14次真Qwen＋6次規則澄清；題目已看過並用來調守門規則，不是獨立未見測試或SLM獨力100%。新16例開發者挑戰首次10/16（12真Qwen＋4規則），修後同批已見回歸12/16（10真Qwen＋6規則），仍有4項契約缺口；預期與首次紀錄保留，不是人類／母體驗證。不能把20/20推成一般語言都能理解。現存A/B/C/D是修正前各一次機器回放，有真模型／WebSocket與模擬ACK，沒有受試者、ASR或人體效益量測。數據、失敗及raw輸出見[VALIDATION.md](VALIDATION.md)。

[10月12日驗證JSON](evidence/final-validation.json)統一保存工程結果、web release成功、兩APK規格、原生流程、source／APK SHA與未測限制；不把成功建置或模擬器互動當成S9實測。

Android語音橋接已加入嚴格on-device ASR：裝置／繁體中文模型不支持時顯示未就緒並回文字，不切雲端。這套模擬器助手使用`-no-audio`啟動AVD，**不是麥克風／ASR測試**；S9真機、本地語音與斷外網兩實體全流程仍未驗證。程式存在不能稱完成S9離線能力。

模型程序隱藏在背景，log 存於 `.local/desktop-demo/logs`。如果 8778 已有服務，助手只在確認精確模型 alias 後沿用；無關埠占用、錯誤模型、錯誤 AVD、缺 APK 時會停止，不殺其他程序、不 wipe、不卸載。`start-qwen-server.ps1` 也可單獨呼叫，接受 `-ServerPath`／`-ModelPath`；它會輸出新程序 PID，模型真正就緒由 API 與雙屏助手另行確認。

CMD 與上述建置範例的 `ExecutionPolicy Bypass` 只作用在本次 PowerShell 程序，不呼叫 `Set-ExecutionPolicy`，不改永久 PATH 或 registry。建置助手在結束時還原目前工作目錄及暫時設定的環境變數。

通用建置助手已在這台電腦真正執行，從基礎資產清單建出兩個 APK；Doctor 路徑核對也已實際執行，確認使用指定 SDK 與 JDK。通用模型啟動助手已實測沿用既有本地服務分支，精確 alias 檢查成功，未另啟第二個模型程序。2026-10-13亦以通用 `start-demo -RestartApp` 實際完成既有模型重用、啟動兩AVD、install -r、新版App啟動及Hub橋接，再由原生UI走完兩次真Qwen與駕駛確認。仍未在第二台乾淨 Windows 電腦完整安裝驗證，不能把同機實測當成所有電腦都已支援。
