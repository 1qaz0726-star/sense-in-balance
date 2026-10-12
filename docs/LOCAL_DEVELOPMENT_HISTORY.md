# 發布前本機開發紀錄

此文件完整保留發布前的本機操作紀錄。文內使用者路徑、外部助手及產物是當時環境；團隊新 clone 請依 [DEVELOPMENT.md](DEVELOPMENT.md) 與 [WINDOWS_DESKTOP.md](WINDOWS_DESKTOP.md)。下文的「未推送」等描述僅代表各輪記錄當時的狀態。

---

# 本地開發與「不用重講」測試

這份副本從 GitHub 的 `5ea2253` 開始，本地分支 `codex/partial-repair-demo`。新增一個可獨立建置的停車文字原型；原座艙警示模式保留。還沒有推回 GitHub。

這台電腦已準備好可攜式 Flutter 與 JDK，沒有永久修改系統 PATH。先在 PowerShell 執行：

```powershell
. 'C:\Users\USER\Desktop\友達\啟動開發環境.ps1'
```

它只設定目前終端機的環境並進入專案。`C:\Users\USER\codex-dev\sense-in-balance` 是指向桌面 Git 副本的英文路徑 junction，兩處是同一份檔案。若 PowerShell 的本機政策禁止腳本，可在該終端機手動設定 `JAVA_HOME`／`ANDROID_HOME`，並用 Flutter 的完整路徑執行，不必改整台電腦的執行政策。

## 電腦需要什麼

| 工具 | 用途 |
|---|---|
| Flutter **3.35.2** | Dart 已包含在內（3.9.0），不需另外裝 Dart |
| Git | 下載與版本管理 |
| JDK **17** | Android Gradle 建置；Gradle wrapper 已在 repo |
| Android SDK | Platform 36／34（部分依賴需要）、Build Tools 35.0.0、Platform Tools、Command-line Tools、NDK 27.0.12077973、CMake 3.22.1，依目前專案設定 |
| VS Code／Android Studio | 編輯器擇一；Android Studio 也能管理 SDK 與 JDK |
| Python 3 | 此 repo 的網頁畫面打包腳本使用 |

原 README 寫 Target SDK 34，但實際 Gradle 使用 Flutter 預設的 compile／target SDK **36**。不要把「Android 14／SDK 34」和「電腦建置套件」混為一談。AGP 8.9.1 的官方最高支援 API 35，目前組合可能提示相容性警告；版本調整和比賽 target 規定另行核對，不在這版偷偷變更。

Flutter／專案路徑建議用英文且不要有空白。中文路徑若被 Android Gradle 擋住，可把開發副本放到如 `C:\dev\sense-in-balance`；不要為此刪除原檔。

確認環境：

```powershell
flutter --version
flutter doctor -v
flutter doctor --android-licenses
flutter devices
```

`doctor --android-licenses` 由開發者閱讀並處理授權。若 Windows 看不到 S9，檢查 USB 除錯、平板上的授權提示、USB 資料線及 Samsung 驅動。

## 先跑自動化測試

新版雙裝置入口已整合原版儀表／警示與「不用重講」。雙擊工作區根目錄 `啟動雙裝置實測.cmd`，平板預設顯示「行車儀表」，上方可切「座艙主控」；手機預設顯示行車儀表，也可切換「協作結果」。

在平板底部「展示情境」列按「右後方機車」或「左後方自行車」：先亮方向燈，1 秒後顯示原版盲點事件，這個展示版本保留 10 秒。按「正常行車」清除暫態警示；「模擬停車」按原模擬器每秒減速，最終 0 km/h／P 檔。CO₂ 上升與換氣也可在同一列觸發；主控頁可由頂部「展示情境」打開控制列。安全警示在兩個頁面上方顯示，第二屏的警示與導覽固定，不隨內容捲動。主控的確認／取消固定於需求區下緣，待確認差異可在其上方捲動查看。

文字警示區現在固定占位，警示出現／清除不會縮小儀表；第二屏短橫向使用較矮的固定警示區。底部也可按「左後方汽車」「右後方汽車」檢查汽車示意圖。汽車、機車與自行車仍是原版注入介面的分類示意，沒有新增真實偵測來源。

原 `Hub` 使用 `start(network: false)` 在新版內產生原事件，以 `RepairHub` 的可選 `cockpit_event` 送給第二屏；不另占 8765／8766，也保留原 `start()` 的角色與網路行為。儀表值取自原 `Hub._simulate()`，盲點是情境注入，沒有接 CAN、GPS 或攝影機辨識。安全文字仍由規則直接發出；PC Qwen 用於局部修正，原空氣告知在未載入端上模型時使用原模板。

在 `app/cockpit_hmi`：

```powershell
flutter pub get
flutter analyze
flutter test
```

原測試涵蓋規則、12,000 組固定基準、輸出檢查、知識庫及原雙屏通訊。新增測試涵蓋局部修正、取消、澄清上下文、舊確認、重複確認、遲到模型結果、執行逾時與第二屏同步。**這些測試使用模型／車控替身，不代表真 Qwen 的理解測試已通過。**

## PC 雙原生 Android 實測（2026-10-12）

已完成「文字需求 → 真 Qwen 解析 → 局部修正 → 確認模擬 → 雙屏同步」。這是 **PC 推論＋兩台 Android 模擬器** 的可互動模式；原 S9 端上 LiteRT 模式仍保留，尚未完成真機驗證。

| 角色 | 實際配置 |
|---|---|
| PC 模型主機 | 官方 `Qwen2.5-1.5B-Instruct` **Q8_0 GGUF**；`llama.cpp` Vulkan，模型 alias `Qwen2.5-1.5B-Instruct`；API `http://127.0.0.1:8778` |
| 平板操作端 | AVD `center_tab`、`emulator-5554`、x86_64；`lib/main_repair.dart`，呼叫 `http://10.0.2.2:8778` 的 PC 模型，自行提供 Hub 8767 |
| 手機第二屏 | AVD `dash_phone`、`emulator-5556`、x86_64；原生 `lib/main_repair_monitor.dart` 連 `ws://10.0.2.2:8767/repair`；只讀同步，不載入模型、不發控制命令 |
| 網路橋接 | host `adb -s emulator-5554 forward tcp:8767 tcp:8767`；手機的 `10.0.2.2:8767` 經電腦回到平板 Hub |
| App 身分 | 兩個裝置各裝 `com.auohack.cockpit_hmi.desktopdemo`，component 為 `com.auohack.cockpit_hmi.desktopdemo/com.auohack.cockpit_hmi.MainActivity`；可與同學原 APK 共存 |

模型啟動檔為 `C:\Users\USER\codex-dev\cockpit-demo\runtime\start-qwen-server.ps1`，模型及 runtime 另外準備，未包進 APK。此 x64 APK 供電腦模擬器使用；不是 S9 LiteRT 模型效能測試。手機不需 Chrome 或瀏覽器首次開啟流程。

### 一鍵啟動與重跑

在工作區根目錄雙擊 [啟動雙裝置實測.cmd](../../啟動雙裝置實測.cmd)，或執行：

```powershell
& 'C:\Users\USER\Desktop\友達\啟動雙裝置實測.cmd'
& 'C:\Users\USER\Desktop\友達\啟動雙裝置實測.cmd' -SkipInstall
```

預設以 `adb install -r` 分別安裝／更新 `output/desktop-demo/不用重講_PC模擬器.apk` 與 `output/desktop-demo/不用重講_手機第二屏.apk`，保留實測 App 資料，不卸載同學原 App。更新 APK 可能暫停正在執行的實測 App；已有正確版本時用 `-SkipInstall`。需要重置記憶體內的模擬狀態才加 `-RestartApp`，預設不強制重啟已有實測 App。

助手驗 SDK、AVD 身分、連接埠和 `/v1/models` 的指定 alias。沿用正確 AVD；新開模擬器採 2 GB RAM、可見 GUI、不讀寫 snapshot。模型、boot、Hub 都有限等待時間；Hub 只讀確認 `repair_status`／schema 1 與 PC Qwen 模型狀態。錯誤模型、其他 AVD 或無關服務佔埠時報錯，不關閉或取代它們。若原 App 仍佔用平板內的 8767，請手動關閉後重跑。

Windows PowerShell 5.1 的本機政策是 `Restricted`；CMD 與模型啟動子程序僅在**當次程序**使用 `-ExecutionPolicy Bypass`。不呼叫 `Set-ExecutionPolicy`，不改 registry、永久 PATH 或全機／使用者政策。記錄位於 `output/desktop-demo/logs`。[PS1](../../啟動雙裝置實測.ps1) 的預設流程（含兩 APK 安裝）及 `-SkipInstall` 均已完整實測成功；兩個原生 App 已可並排互動。

### 重建 PC 版本

在 `app/cockpit_hmi` 建置。兩者共用 `app-debug.apk` 產物路徑，所以先另存平板 APK，再建手機：

```powershell
flutter build apk --debug --target-platform android-x64 -t lib/main_repair.dart --dart-define=REPAIR_MODEL_URL=http://10.0.2.2:8778 --dart-define=REPAIR_DESKTOP_DEMO=true --dart-define=REPAIR_EVAL_LOG=true
Copy-Item -LiteralPath 'build\app\outputs\flutter-apk\app-debug.apk' -Destination '..\..\..\output\desktop-demo\不用重講_PC模擬器.apk'
flutter build apk --debug --target-platform android-x64 -t lib/main_repair_monitor.dart --dart-define=REPAIR_DESKTOP_DEMO=true --dart-define=REPAIR_MONITOR_URL=ws://10.0.2.2:8767/repair
Copy-Item -LiteralPath 'build\app\outputs\flutter-apk\app-debug.apk' -Destination '..\..\..\output\desktop-demo\不用重講_手機第二屏.apk'
```

`REPAIR_DESKTOP_DEMO=true` 讓 Gradle 使用獨立實測 applicationId；不設定會沿用原身分，可能與同學 APK 簽章不符，不要以卸載原 App 解決。平板的 `REPAIR_EVAL_LOG=true` 開啟本地開發紀錄；手機只顯示狀態。未設定 `REPAIR_MODEL_URL` 的原 `main_repair.dart` 仍使用端上 LiteRT backend。

### 已完成的操作與界線

1. 從初值風量／音樂／導航 **3／5／5** 開始，自由輸入「後座的風幫我調小，音樂也調小，導航聲音保持現在這樣。」真 Qwen 回傳三項 pending，確認前不改模擬值。
2. 輸入「風量先不用改，其餘照剛剛。」取消風量需求，保留音樂降低與導航維持。
3. 按確認模擬；平板及手機第二屏均顯示完成，結果為 **3／4／5**。

原始輸入／模型 JSON、Hub 完成回報及額外 API probe 位於工作區 `output/desktop-demo/native-qwen-traces.jsonl`、`native-end-to-end-ack.json`、`real-qwen-probe.json`。詳見 [VALIDATION.md](VALIDATION.md)。仍是文字輸入、記憶體車控模擬，未實作語音辨識或真車控制。

**尚未證明的能力：**含糊輸入「那個先不要改」在 API probe 曾被猜成取消 `mediaVolume`，而沒有提問，不能聲稱澄清可靠。早期冷 probe 約 13 秒，後續 App trace 有 518 ms／524 ms，屬不同輸入、probe 及快取狀態，不能當作 S9 速度、穩定延遲或整體準確率。48 項程式單測不是 48 題模型成績。8 題開發題＋12 題保留題、S9 LiteRT 端上推論、真機離線跨屏、車主對照仍需分別驗證。

## 建置原 S9／瀏覽器原型

先建只讀駕駛畫面，再將其打包給主平板提供：

```powershell
flutter build web -t lib/main_repair_web.dart --output=build/repair_web --release --no-web-resources-cdn --pwa-strategy=none
python tool/pack_repair_web.py
flutter build apk -t lib/main_repair.dart --debug
```

產物通常為 `build/app/outputs/flutter-apk/app-debug.apk`。它是測試 APK，不能當成商店正式發布版本。另一種方式是建原 `main.dart`，首頁的「不用重講」入口也能進入新流程。

目前 companion 的打包清單與原 `tool/pack_web.py` 不能同時產生第二個 `assets:` 欄位；請使用乾淨 manifest 建這次原型，原中控網頁的建置仍依原 README。

第二屏同時打包本地 CanvasKit 與 Noto Sans TC 繁體中文字型；字型來源與 OFL 授權見 `assets/fonts`。仍需用兩台真機在保留區網、關閉外網的情況驗證完整離線流程。

## 兩台平板怎麼測

1. **S9** 安裝 APK，開模型設定，下載或匯入 repo 指定 `.litertlm`（約 1.6 GB）。等 Qwen 就緒。其他格式如 GGUF 不能直接匯入。
2. **第二台 Android** 連同一 Wi-Fi／本地熱點，用瀏覽器開 S9 頁面上顯示的 `http://<S9 IP>:8767`。這版是駕駛只讀畫面，不載入模型。
3. 在 S9 輸入「後座風小一點，音樂也小一點，導航提示不要變。」
4. 檢查三個待執行項目；此時還不能出現執行完成。
5. 輸入「風量先不用改，其餘照剛剛。」風量項目應移除，音樂降低與導航維持仍存在。
6. 按確認。等模擬執行回報，核對風量 **3**、音樂 **4**、導航 **5**（初值分別 3／5／5）。第二屏應收到相同結果。
7. 再測「那個不要改」→澄清→只回答「音樂」；也測取消、連點確認、解析中取消、關閉第二屏 Wi-Fi 後重連。斷線畫面不可把舊結果當作最新狀態。
8. 關閉外網但保留區網，重試解析與跨屏。此功能不依賴地圖；不代表原中控線上圖磚也能離線使用。

**能力界線：**這版使用真模型進行文字解析，但未加入 ASR，也沒有連接 CAN／真空調／真音響。確認後只改記憶體內的模擬值；第二屏只讀。原安全警示流程沒有改成讓模型決策。

## 真模型與使用者驗證

用 `research/repair_eval_cases.json` 的開發題調整提示後，鎖住提示，再做保留題（holdout）。保留題用過之後即不再是全新的驗證；下一輪另找不同措辭。

每題記錄原文、模型原始 JSON、預期與實際待執行項、解析時間、是否誤改未指定項目。JSON 不合法或語意不確定應停止／澄清，不能為了提高完成率自動猜測。

這次準備 **8 題開發題＋12 題保留題**，是待測參考答案，尚不是模型成績。每題從指定 `pending` 開始；預設 pending 可用步驟 3 建立。獨立題取消舊需求再開始。執行模擬後數值會累積，重開此頁可恢復初值。

接上 S9，用下列開發模式記錄模型原文和解析耗時（含排隊）；一般 APK 預設不記錄：

```powershell
flutter run -t lib/main_repair.dart --dart-define=REPAIR_EVAL_LOG=true
```

終端機會輸出 `REPAIR_EVAL` JSON，包括原文、待執行項、澄清上下文、原始輸出、耗時與實際 backend。每次解析均使用新模型 session，不保留完整聊天歷史。此紀錄留在本機，測試後關閉記錄模式；解析逾時但模型稍後完成的紀錄不能當作使用者已成功收到結果。

先報「正確題數／總題數、合法 JSON 題數、未指定項目誤改次數、需要澄清時是否亂猜」，再擴成 50–100 句未用過的口語。驗收首要條件是**確認前不執行、取消不執行、修正不誤改其他項、結果未知不宣稱成功**；若真模型語意達不到要求，就縮小支持的語句或調整解析方式，不以自動化替身測試冒充通過。

S9 真機另外記錄：實際選用 GPU 或 CPU、首次與暖機後時間、P50／P95、30 分鐘穩定性與記憶體／發熱。本版 GPU 優先、失敗才退 CPU，沒有手動切換 backend 的按鈕。原 repo 的措辭速度不能直接套用到這個更長的解析提示。模擬器只驗 UI 和流程，不能代表 S9 的模型效能。

最後找 6–8 位車主做探索性對照：「整句重講」與「局部修正」，交叉安排使用順序，保持相同任務與預先安排錯誤。量測修復輪數、重講字數、完成時間、放棄及誤操作；不要宣稱小樣本已證明道路安全改善。

官方資料：[Flutter Android 設定](https://docs.flutter.dev/platform-integration/android/setup)、[Flutter 3.35.2 Android 預設值](https://raw.githubusercontent.com/flutter/flutter/3.35.2/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt)、[AGP 8.9 相容性](https://developer.android.com/build/releases/agp-8-9-0-release-notes)、[Android Java 需求](https://developer.android.com/build/jdks)。
