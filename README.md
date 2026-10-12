# 感知有度｜智慧座艙雙屏原型

保留原作的「該說才說」規則警示，加入可局部修正的座艙需求協作，以及重新設計的行車儀表。用一台操作平板、一台只讀第二屏，加上本地 **Qwen2.5-1.5B-Instruct** 展示；目前車速、盲點與車控均為模擬。

本倉庫是 [Kinoko1412/sense-in-balance](https://github.com/Kinoko1412/sense-in-balance) 的公開 fork，從 `5ea2253` 延伸，保留原始 Git 歷史。原作團隊：**葉士愷・黃昱羲・胡馨**。原始提案、研究及 App 仍在倉庫；[原 README](docs/ORIGINAL_README.md) 另存，方便對照。

## 畫面與功能

![新版行車儀表](docs/images/instrument-normal.png)

| 行車警示 | 座艙需求協作 |
|---|---|
| ![右後方機車警示](docs/images/blindspot-motorcycle.png) | ![主控待確認需求](docs/images/controls-pending.png) |
| 警示區固定占位，不會擠壓或縮放儀表；左右汽車、機車、自行車以不同輪廓顯示。 | 一次提出多項需求，再只修改或取消其中一項；確認後才模擬執行，第二屏同步結果。 |

- **安全警示直接發出**：盲點與原規則不等模型；兩屏共用事件的側別、文字與物件。
- **不用整段重講**：Qwen 解析後排風量、媒體音量、導航音量三項需求，保留尚未修改的項目。提供澄清流程，執行有確認與版本檢查；含糊指令的理解仍有失敗，見驗證文件。
- **雙屏各司其職**：平板在「行車儀表／座艙主控」切換；第二屏在「行車儀表／協作結果」切換，沒有車控操作權限。
- **原作仍可獨立開啟**：地圖、知識庫問答、語音、原情境劇本和角色選擇保留於原入口，尚未全部遷入新版。

## 先在電腦操作

準備 **Flutter 3.35.2、JDK 17、Android SDK**；Windows 雙裝置展示另需 Android Emulator、兩個 API 34 x86_64 AVD，以及本機 Qwen GGUF／llama.cpp Vulkan runtime。Android 建置使用 SDK 36，與模擬器的 API 34 不同。

在英文路徑 clone，依 [Windows 雙裝置指南](docs/WINDOWS_DESKTOP.md) 準備模型和 AVD，再於倉庫根目錄執行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\desktop\build-demo.ps1
.\tools\desktop\start-demo.cmd
```

APK、模型、runtime 和 log 存於被 Git 忽略的 `.local/`；本倉庫只提供原始碼、截圖與工具，不包含預建 APK 或模型。設定外部檔案路徑、首次建置與同步連線，見上述指南。

## 開發入口

| Dart 入口 | 用途 |
|---|---|
| `lib/main.dart` | 原作完整 App、角色選擇 |
| `lib/main_repair.dart` | 新版操作平板：儀表＋局部修正＋確認 |
| `lib/main_repair_monitor.dart` | 新版原生只讀第二屏 |
| `lib/main_repair_web.dart` | 選用瀏覽器第二屏 |

檔案位於 `app/cockpit_hmi/`。建置參數、實體兩平板連線、測試方式見 [DEVELOPMENT.md](docs/DEVELOPMENT.md)；實測證據與限制見 [VALIDATION.md](docs/VALIDATION.md)。

## 驗證與邊界

已在此電腦用真正的 PC Qwen 1.5B 和兩個原生 Android 模擬器操作：左右盲點、第二屏同步、多項需求、局部取消與確認。最新繪製與幾何測試包含 45 組狀態；完整測試結果記錄於驗證文件。

這不是實車 ADAS 或自動駕駛系統：沒有 CAN、攝影機偵測或語音辨識；實際車控是替身。PC GGUF 驗證不代表 Samsung S9 端上 LiteRT 的速度或相容性。原研究的 12,000 組規則基準與約 70% 保持安靜是上游研究結果，不是新版模型準確率。

## 原作與授權

保留 `research/`、`app/slm_probe/`、`media/` 和既有第三方授權資料。新 UI 包含 Noto Sans TC 字型及 [SIL OFL 授權](app/cockpit_hmi/assets/fonts/OFL.txt)。Qwen、Flutter、各套件及圖資遵循各自授權；模型來源請用指南中的官方連結。

原倉庫沒有頂層專案 `LICENSE`，本 fork 沒有擅自新增整體授權。對外授權及商用範圍需由團隊共同確認。
