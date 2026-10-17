# Hybrid 分支＋座艙 V3 模型

本次以同學 `shikai/hybrid-cloud` 的 `70ed02eb2ddc67ede8648954ba957621c976446e` 完整 clone 為基底，另開本機 `codex/hybrid-v3-integration`，保留該提交與全部 Git 歷史。舊工作目錄、原版模型、V1/V2/V3 訓練與 Android 檔案均保留。本次沒有實作 C 注意力／跨車型功能，也沒有重訓。

## 接好了什麼

- 保留同學的雲端理解、車主記憶、台語／華語錄音橋接、TTS、原儀表與雙屏授權／確認／回執。`repair_cloud_model.dart`、`repair_cloud_speech.dart`、`owner_memory.dart` 與 Kotlin MainActivity 不被覆蓋。
- 加回模型分槽、固定來源／大小／SHA256 驗證、下載恢復與匯入功能。原版與 V3 使用不同路徑；內建 ID 不可換成另一份 manifest。
- V3 只解析 `rearFan / mediaVolume / navVolume` 與局部修正。暖機使用修復提示；啟用 V3 時，原座艙主動告知走模板，不能把 JSON 播成語音。安全警示仍由原規則直接產生。
- 保留 Hybrid parser 的 cloud／memory 路由，合入先前取消與改口修正。記憶命中、雲端解讀、規則澄清與真正 Qwen 生成仍分開記錄；記憶不是模型權重自動學習。
- PC V3 使用單一 user 訊息：`kRepairSystemPrompt + "\n\n" + compact JSON`，保留 Qwen 內嵌模板，不用強制 JSON 解碼冒充準確率改善。原版 HTTP 接法保持原預設。
- `HYBRID_V3_DEMO=true` 產生獨立 `com.auohack.cockpit_hmi.hybridv3` 套件，不取代原 App、trainingdemo 或 desktopdemo。

## 模型身分

| 用途 | 檔案／大小 | SHA256 |
|---|---|---|
| S9／Android V3 | LiteRT-LM，1,823,647,040 bytes | `abc57627d87b529328541e5a2194209fab641f3aa17de3c2a31376cc39de9702` |
| PC V3 備援 | GGUF Q8_0，1,646,573,152 bytes；alias `cabin-v3-clean-hybrid` | `91793812b9ad0fab54a85119fa7cb1b16d9129be446b5bbe63c8340e6d13fbd1` |
| 原版 Android | LiteRT-LM，1,597,931,520 bytes | `faa60663b333290c1496c499828b21d3e3254a788cacd8cce917ce0f761a2dc9` |

PC GGUF 由已合併 V3 BF16 直接匯出 Q8，沒有再合併 adapter，也沒有另外產生 BF16 GGUF。模型仍為 1.5B 參數；檔案大小與參數規模不同。兩種部署格式不能互換副檔名使用。

## 建置與執行

這台電腦沿用已安裝 Flutter 3.35.2、JDK17、Android SDK、llama.cpp；英文 junction `C:/Users/USER/codex-dev/sense-in-balance-hybrid-cloud` 指向本工作目錄。腳本只改本次程序環境，不升級工具、不改永久設定。執行前先在 `app/cockpit_hmi` 做 `flutter pub get`。

```powershell
.\tools\desktop\build-hybrid-v3.ps1 -Mode Native
.\tools\desktop\build-hybrid-v3.ps1 -Mode PC
.\tools\desktop\build-hybrid-v3.ps1 -Mode Driver
.\tools\desktop\start-hybrid-v3-demo.ps1
```

建置輸出在 `.local/hybrid-v3/`；模型與 APK 不上 Git。Native APK 是 S9 優先版，含 arm64/x64，預設嘗試 V3 槽。首次在裝置使用，要在「連接駕駛屏 → 開啟模型設定 → 匯入實驗版本」依序選 manifest 與 LiteRT-LM；原版可另行下載／選回，互不覆蓋。PC APK 是 x64 模擬器備援版，連到 Windows 本地 `8781`。

Driver APK 同時含 arm64/x64；預設連線 `10.0.2.2` 僅供模擬器。實體手機須以 `-Mode Driver -DeviceUrl ws://<S9的區網IP>:8767/repair` 重新建置，兩裝置同區網、配對後操作。這個入口 URL 目前是建置參數，不能直接把模擬器 URL 當 S9 網址。PC 備援若由實體 S9 使用也須另行設定正確位址；本次 PC 服務只綁 loopback，沒有擅自對外開放。

## 測試與證據怎麼看

普通 `flutter test` 是工程測試，不會真的呼叫 LLM。另有明確 opt-in 的 `test_manual/hybrid_v3_smoke.dart`，使用本機真 V3、production parser／授權／controller 與記憶體模擬車控；它不是 UI 或人體研究。

```powershell
flutter test test_manual/hybrid_v3_smoke.dart --dart-define=REPAIR_MODEL_URL=http://127.0.0.1:8781 --dart-define=REPAIR_MODEL_ID=cabin-v3-clean-hybrid --dart-define=REPAIR_MODEL_SINGLE_USER=true
```

測試需求：`後座風小一點，音樂也小一點，導航提示不要變。` → 駕駛授權 → `風量先不用改，其餘照剛剛。` → 拒絕舊版本確認 → 最新確認 → 模擬 ACK。預期風量3、音樂4、導航5，僅執行一次。`keep` 仍包含在命令／回執中但數值不變；`remove` 取消待辦，不是回復已執行設定。

本次實測收據、模型原始輸出、建置紀錄與截圖以交付資料夾 `output/hybrid-v3-20261017/evidence/` 為準。歷史 README 的108測試或舊模型分數不代表這次成果；不要拿單一示範的秒數當 S9 或整體準確率。

## 已知限制

- S9 目前未接到電腦，未宣稱實機速度、GPU 相容性或兩實體裝置驗收完成。
- 沿用同學 native controller60秒／生成55秒，PC controller30秒／HTTP28秒。這是等待容忍設定，並非加速；原先我們的原生15秒門檻不是因此被模型超越。
- V3 歷史 D02 音樂指令誤拒尚未重新訓練修正，不能說全面勝過原版。測試失敗或逾時不等於已執行。
- 未提供雲端金鑰／ASR服務參數，本次交付不含憑證，也未實際呼叫付費雲端；雲端與記憶的組合路由由工程測試覆蓋。不得把雲端輸出、規則或記憶算成 V3 模型答對。
- 同學分支的「雲端教材」目前只是本次計數；沒有持久化教材或自動再訓練。ASR-only 設定與總離線切換的既有界線記在整合稽核，本次不擴大改造。
- 車速、盲點與車控仍全部模擬，沒有真車、CAN、ADAS 或自動駕駛控制。

本次完成後先以這一版作為共同基準，再進行 C 的能力判斷／注意力協調設計。
