# 開發與測試

這份指南針對新 clone；[LOCAL_DEVELOPMENT_HISTORY.md](LOCAL_DEVELOPMENT_HISTORY.md) 保留發布前本機記錄。原作完整入口和新版入口可分開建置，原始 Git 歷史保留。

## 2026-10-13修訂：有限設定、可靠回報、可操作展示

本輪只修方案01的既有語意／狀態／HMI缺口，不新增任務接力、控制項、雲端或市場題。V11印刷第5及8頁允許Android Emulator與PC AI Box；Android14／target34、標準Android可移植介面是目前範圍，S9端上及實體雙平板驗證留待有設備時處理。文字輸入就是有效的使用者輸入，不為本輪交付改用未驗證雲端ASR。

本輪完整套件108/108通過、靜態分析No issues found（14.9秒）。第一次全套107通過／1失敗來自新UI測試未清理watch；測試以try/finally提前dispose修正後，完整重跑通過，不冒稱應用程式因此新增了功能。最新兩APK、web release及本地打包成功；aapt核對target34、compile36、min24。下文88/88與舊原生圖均屬2026-10-12，[本輪工程／建置、模型與runtime SHA](evidence/engineering-validation-20261013.json)另存。

v2手動真模型回歸已保存：[固定20例](evidence/repair-model-eval-20261013-final-v2.json)保護20/20、14真Qwen＋6預先澄清、raw patch／澄清契約12/14實際呼叫符合；[同批16例](evidence/repair-challenge-20261013-final-v2.json)保護16/16、12真Qwen＋4預先澄清、raw僅4/12符合。本輪prompt首句改為有限舒適設定、不能授權／確認／執行，guard也改；因此不作單一改動的因果歸因，更不稱模型準確率100%。

保留[同日v1的14/16](evidence/repair-challenge-20261013-final.json)與10月12日10/16→12/16；原預期不改，全部仍是已見開發回歸。新原始輸出／測試／APK／截圖另存日期與版本，不能以更新程式自動宣稱舊證據覆蓋新版本。

本輪要驗證的回報契約：

- **部分成功：**成功項移出pending，保留其成功回報；仍經駕駛確認當下版本，重試只送未完成項。取消只撤回尚未執行的項目，不把已完成設定倒轉。
- **已完成快照：**completed的pending保留確認過的歷史提案，不能由此重新執行。只有部分失敗的剩餘pending才作下一次確認的待辦；兩種狀態不能混讀。
- **逐項完整性：**支援部分成功的adapter必須回傳每項ACK；檢查success布林、action、前後值、項目範圍。若提供總體state，須與各項結果相符；不帶總體state時，以驗證過的items.after更新本次數值。缺項、矛盾或無法判定的回報進indeterminate，禁止自動重送，避免完成過的相對調整再次執行。
- **舊atomic ACK：**沒有items的既有回報僅作明確的原子整批相容契約；不能拿它推論部分成功，也不稱車規／功能安全認證。legacy未提供本次項目的新值時，不沿用舊state／舊item當成最新值；未來宣稱partial的adapter必須提供逐項資料。
- **畫面：**結果已完成就先顯示已完成項與回報；隱藏該任務失效的授權／確認操作。尚有澄清或結果未知時，不把候選當成可執行完成。

最小工程驗收例：風量成功、音樂失敗後，第二次不得再送風量；缺media ACK／布林格式錯／action或state矛盾時不得重試；取消剩餘待辦後此前風量成功仍可見。這些是模擬adapter與狀態機驗收，不是人體效率或實車安全成績。

兩個API34 AVD已安裝最新APK，原作與demo套件共存，並走完無故障注入的原生文字流程：三項需求真Qwen→配對／授權→真Qwen只取消風量→駕駛確認最新版本→逐項mock ACK、3／4／5。兩筆raw均符合預期、guard未調整；沒有導航按鈕或麥克風輸入。完成畫面三值無需捲動，失效的授權／確認／取消按鈕隱藏。[候選](evidence/native/20261013/repair-driver-candidate.png)、[駕駛完成](evidence/native/20261013/repair-driver-complete.png)、[完成JSON](evidence/native/20261013/repair-final-status.json)、[真Qwen trace](evidence/native/20261013/repair-qwen-traces.jsonl)可核對；部分／延遲／矛盾ACK由工程測試覆蓋，未在本次原生流程注入。

交件、既有／新增與第三方元件勾稽見[SUBMISSION_CHECKLIST.md](SUBMISSION_CHECKLIST.md)。現有啟動／建置方法繼續使用；108項測試、語意v2、建置與最新原生結果已回填，正式PPT／影片／表單仍按勾稽表補齊。

本輪以PC本地AI核心與可操作文字路徑交付；模型／runtime檔案、端點與真推論trace作來源證據。這次PC與AVD均未斷外網，完整斷外網操作仍未驗證，不能把localhost、Offline架構欄位或本地檔SHA單獨當成整台PC斷網證明；Offline技術加權由評審確認，不預填已獲加分。

## 環境

| 工具 | 目前使用的設定 |
|---|---|
| Flutter | **3.35.2**，已含 Dart 3.9 |
| JDK | **17** |
| Android SDK | Platform 36／34、Build Tools 35.0.0、Platform Tools、Command-line Tools；NDK 27.0.12077973、CMake 3.22.1 |
| Git、編輯器 | VS Code 或 Android Studio；建議 clone 到英文路徑，例如 `C:\dev\sense-in-balance` |
| Python 3 | 只有網頁資產打包及研究工具需要；純原生新版 APK 不需要網頁打包 |

Gradle wrapper 已在倉庫。確認 `flutter --version`、`flutter doctor -v`、`flutter doctor --android-licenses`，並由開發者處理 SDK 授權。當前 **compile SDK 36、target SDK 34、min SDK 24**；Android 14模擬器是API34。`android/app/build.gradle.kts`已明確設定target 34，兩個最新x64 debug APK已成功建出並以aapt確認target 34及獨立application ID。這解決V11的TargetSDK34建置項，不等於S9真機、離線語音或全部交件要求已驗證。AGP 8.9.1與compile API36的相容性提示仍需留意。

## 自動測試

在 `app/cockpit_hmi/`：

```powershell
flutter pub get
flutter analyze
flutter test
```

2026-10-12最終完整套件88/88通過、靜態分析No issues。測試涵蓋原規則／檢查器／知識庫、Hub生命週期、WebSocket、角色配對／120秒任務授權、局部修正／澄清／取消、版本確認、逾時／斷線、執行回執，以及儀表繪製／幾何。新增回歸驗證：授權後在awaitingClarification按鈕修另一項，未回答澄清不被directPatch抹掉；driver確認被拒，文字回答後才完成一次mock執行。模型及車控大多使用替身；通過數不是模型準確率或88位受試者。[最終驗證記錄與source／APK SHA](evidence/final-validation.json)

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

示範流程如下：

1. 乘客詳細平板輸入「後座風小一點，音樂也小一點，導航提示不要變。」。「帶入示範需求」只填入文字；提交仍由真Qwen提出候選，不是固定解析答案。
2. 打開「連接駕駛屏」，讓另一螢幕輸入六位配對碼；未配對時第二屏只有觀察權。
3. 駕駛檢查短摘要並按「授權乘客協助120秒」。
4. 乘客帶入「只取消風量」並提交實際文字「風量先不用改，其餘照剛剛。」；真Qwen提出rearFan:remove，原音樂降低／導航keep待辦保留。一般語意修改跑模型，含糊／不支援輸入可由守門規則先澄清；逐項按鈕另可使用但不呼叫模型。
5. 駕駛核對最新版本，按「確認套用（車控模擬）」。收到逐項ACK才完成；初始3／5／5變成3／4／5，兩屏同步結果。舊版本、收權／逾時／斷線不能復活先前修正，執行中不能重送。

桌面展示的「安排一項誤解」只改尚未執行的導航提案，兩屏標示人工安排及來源，不授權也不執行。不要把示範注入寫成Qwen自然失敗率。這是方案01的角色分工，沒有完整方案02任務owner交接。證據與限制見[VALIDATION.md](VALIDATION.md)；精簡團隊審查見[方案01簡報](repair-proposal.pdf)（12頁）。

最終兩target34 APK已重新建置／aapt核對、安裝並在兩AVD完成上述無注入文字流程：[乘客局部取消](evidence/native/repair-passenger-final.png)、[駕駛最新摘要](evidence/native/repair-driver-final-candidate.png)、[駕駛回執](evidence/native/repair-driver-final.png)、[乘客完成](evidence/native/repair-passenger-final-complete.png)。[兩筆真Qwen trace](evidence/native/repair-final-qwen-traces.txt)保留初始三項raw與rearFan:remove修正；[完成狀態JSON](evidence/native/repair-final-status.json)為completed、pending只剩media decrease／nav keep、模擬值3／4／5。這證明該次局部改口流程，沒有測麥克風或量測自然錯誤率。

先前target36的混合文字＋按鈕、手動導航誤解展示仍保留[乘客](evidence/native/repair-passenger-revised.png)、[駕駛](evidence/native/repair-driver-revised.png)、[回執](evidence/native/repair-driver-complete.png)，該次也觀察到授權120秒到期禁止編輯、重新授權恢復。人工故障與按鈕不冒充模型輸出；機器回放又是另一種證據，不能混用人體時間或成功率。

## 真模型評測與四條件回放

`test_manual/repair_model_eval.dart`是明確手動啟動的PC真模型評測，排除於一般測試套件。使用`research/repair_eval_cases.json`固定公開20例；原分組仍叫development／holdout，但題目已被看過並用來調規則，不能稱獨立未見樣本。未保護13/20符合預期，保護鏈路20/20；[挑戰修正後重跑](evidence/repair-model-after-challenge-fix.json)仍20/20、14例真正模型生成＋6例確定性澄清。歷史原始輸出、規則分流與機器時間均保留於[證據包](VALIDATION.md)。

[新開發者挑戰首次結果](evidence/repair-challenge-new.json)共16例，完整changes／澄清／projected pending契約10/16通過，12次真Qwen＋4次規則澄清。預期在執行前寫定並保留SHA-256，首次run未改production；但作者已讀現行程式和公開20例，仍不是獨立人類驗證或母體準確率。修正後只能稱同批已見題目的開發回歸；澄清只查存在，不驗問句品質。

[最小修正後同批回歸](evidence/repair-challenge-after-fix.json)為12/16，10次真Qwen＋6次規則澄清；N06否定取消與N14不支援加熱已修，N02／N08／N09／N12仍不符合事前契約。N08改為保守澄清，因原預期是取消兩音量仍記失敗，不改答案粉飾。首次檔案與預期保持原位元；修後結果不能稱新的未見測試。

`test_manual/repair_replay.dart`比較全重說、局部修正單客戶端、局部修正雙客戶端、按鈕修正；同初始值及明示注入錯誤，讀取逐項模擬回執。現存四條件數字是挑戰修正前記錄、每條件只跑一次，沒有ASR或人的閱讀／口語時間，不能算人類效率、第二屏人因優勢或S9效能。B/C模型把取消風量解成keep，由明確取消規則改為remove並保留raw；不能將保護後結果全部歸給SLM。詳見[研究與測試計畫](REPAIR_EVIDENCE_AND_TEST_PLAN.md)。

## 兩台實體 Android 平板

同一Wi-Fi，乘客詳細平板建`lib/main_repair.dart`，駕駛端建`lib/main_repair_monitor.dart`。駕駛URL改成`ws://<乘客平板區網IP>:8767/repair`；`10.0.2.2`僅適用Android模擬器。連上不等於取得駕駛權限，仍須六位碼配對；每次修正授權只適用目前task，最後由駕駛確認版本。

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

新版以`Hub.start(network: false)`重用原行車模擬與規則，再由`RepairHub`送出需求及行車事件；不另開原8765／8766。安全警示不等待Qwen。駕駛端除了通訊心跳，也檢查事件本身時間；過期資料隱藏數值和舊警示。配對連線6秒靜默會失效，120秒修正授權不因心跳延長；恢復連線須重新配對／授權。

原版地圖、問答、語音、劇本、角色流程仍於`main.dart`／原檔，原同學歷史與入口保留。新版沒有CAN、GPS、攝影機、ADAS或自動駕駛介面。

新版Android ASR橋接只用`SpeechRecognizer.createOnDeviceSpeechRecognizer`，先檢查on-device服務；裝置或繁體中文語言模型不可用、權限拒絕或辨識失敗時回到文字，不改用generic recognizer／雲端。辨識文字先填入供核對，不直接送出車控。這是已實作的本地路徑，**麥克風與S9尚未實測，不能稱完成離線語音**；Android模擬器亦可能沒有可用引擎。下一步的S9／兩實體、ASR與更廣泛語意／可用性驗證仍如實標待測。
