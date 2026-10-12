# 開發與測試

這份指南針對新 clone；[LOCAL_DEVELOPMENT_HISTORY.md](LOCAL_DEVELOPMENT_HISTORY.md) 保留發布前本機記錄。原作完整入口和新版入口可分開建置，原始 Git 歷史保留。

## 環境

| 工具 | 目前使用的設定 |
|---|---|
| Flutter | **3.35.2**，已含 Dart 3.9 |
| JDK | **17** |
| Android SDK | Platform 36／34、Build Tools 35.0.0、Platform Tools、Command-line Tools；NDK 27.0.12077973、CMake 3.22.1 |
| Git、編輯器 | VS Code 或 Android Studio；建議 clone 到英文路徑，例如 `C:\dev\sense-in-balance` |
| Python 3 | 只有網頁資產打包及研究工具需要；純原生新版 APK 不需要網頁打包 |

Gradle wrapper 已在倉庫。確認 `flutter --version`、`flutter doctor -v`、`flutter doctor --android-licenses`，並由開發者處理 SDK 授權。當前 compile／target SDK 繼承 Flutter 預設 **36**；Android 14 模擬器是 API **34**。AGP 8.9.1 與 API 36 的相容性提示，以及比賽的 target 要求，需在正式發行前另行核對。

## 自動測試

在 `app/cockpit_hmi/`：

```powershell
flutter pub get
flutter analyze
flutter test
```

測試涵蓋原規則／檢查器／知識庫、Hub 生命週期、WebSocket、需求版本、局部修正／澄清／取消、執行逾時、第二屏失效與安全事件優先，以及儀表繪製／幾何。模型及車控大多使用替身；通過數不能當作真模型準確率。

Hub 測試使用本機 8765／8767 連線埠。若展示程式或自己的 adb forward 正在占用，先暫停該展示連線再跑。Windows 中文 TEMP 路徑若造成 isolate 問題，可在目前終端機設定 `$env:TEMP='C:\tmp'`，先建立該資料夾。

## 電腦雙原生 Android 展示

依 [WINDOWS_DESKTOP.md](WINDOWS_DESKTOP.md) 設定官方 Qwen 1.5B Q8_0、llama.cpp Vulkan、兩個 AVD 和啟動工具。這是已操作過的模型／模擬器配置；新通用助手也附於倉庫。

手動建置命令如下；每次輸出到同一 `app-debug.apk`，因此必須先保存第一份再建第二份。`tools/desktop/build-demo.ps1` 已處理保存。

```powershell
flutter build apk --debug --target-platform android-x64 -t lib/main_repair.dart --dart-define=REPAIR_DESKTOP_DEMO=true --dart-define=REPAIR_MODEL_URL=http://10.0.2.2:8778 --dart-define=REPAIR_EVAL_LOG=true
flutter build apk --debug --target-platform android-x64 -t lib/main_repair_monitor.dart --dart-define=REPAIR_DESKTOP_DEMO=true --dart-define=REPAIR_MONITOR_URL=ws://10.0.2.2:8767/repair
```

PC 測試 application ID 是 `com.auohack.cockpit_hmi.desktopdemo`，與原作 `com.auohack.cockpit_hmi` 分開。x64 APK 用於模擬器；S9 是 ARM64，不能使用這份 x64 APK。不同開發者 debug 簽章可能不同，原助手不會為了安裝而卸載既有 App。

平板底部展示情境包含正常、停車、左右自行車／機車／汽車及 CO₂。盲點按鈕先亮方向燈，約 1 秒後顯示原事件，展示維持 10 秒。正常行車清除暫態；停車逐步降速至 0／P。警示槽一般 64 dp、短橫向 48 dp，沒有警示時也預留空間。

主控示範先輸入「後座風小一點，音樂也小一點，導航提示不要變。」，再輸入「風量先不用改，其餘照剛剛。」，確認差異後才按「確認套用（模擬）」。由初始 3／5／5 變成 3／4／5，第二屏同步結果；具體成功／失敗及測試邊界見 [VALIDATION.md](VALIDATION.md)。

## 兩台實體 Android 平板

同一 Wi-Fi，操作平板建 `lib/main_repair.dart`，第二台建 `lib/main_repair_monitor.dart`。第二屏 URL 改成 `ws://<操作平板區網 IP>:8767/repair`；`10.0.2.2` 僅適用 Android 模擬器。

操作平板未設定 `REPAIR_MODEL_URL` 時會用原 `flutter_gemma` 端上路徑，需先匯入相容 `.litertlm` 或 `.task`。PC 的 `.gguf` 不能直接交給該插件。**本次沒有驗證 S9 的端上相容性／推論速度，也沒有完成兩台實體平板的整套測試。** 第一次下載模型需要網路；本地推論與區網同步不需要持續連外，但地圖圖磚與其他外部服務要分開考慮。

如暫時用 PC 推論，`REPAIR_MODEL_URL` 需設可達的服務地址；預設啟動助手只綁定 PC loopback，實體平板不能直接連這個 localhost 配置。本版不自動把模型 API 暴露到區網。

## 選用瀏覽器第二屏

純原生平板／手機不需這一步。新版網頁第二屏：

```powershell
flutter build web -t lib/main_repair_web.dart --output=build/repair_web --release --no-web-resources-cdn --pwa-strategy=none
python tool/pack_repair_web.py
```

原作網頁中控則使用 `lib/main_web.dart` 與 `tool/pack_web.py`。兩個打包器共用單一 assets 清單、互斥替換生成段，保留字型及 OFL；不要把生成 manifest 變更與 bundle 提交到 Git。新版 `build-demo.ps1 -PackWeb` 會於建置完畢還原 canonical manifest。

提交前的 `pubspec.yaml` 只列已追蹤基礎資產／字型；`assets/web/`、`assets/repair_web/` 是忽略的本機生成物，避免 clone 後因找不到 bundle 而建置失敗。兩個 packer 已用臨時資料做重跑／互切與 YAML 驗證。

## 原版與新版的責任

新版以 `Hub.start(network: false)` 重用原行車模擬與規則，再由 `RepairHub` 送出需求及行車事件；不另開原 8765／8766。安全警示不等待 Qwen。第二屏除了通訊心跳，也檢查事件本身時間；過期資料隱藏數值和舊警示。

原版地圖、問答、語音、劇本、角色流程仍於 `main.dart`／原檔。新版沒有真實 ASR、CAN、GPS、攝影機、ADAS 或自動駕駛介面。下一步應先驗證 S9／兩實機、真模型語義與可用性，再討論感測器與真實車控。
