# 該說才說：會自己動手的安靜座艙 AI

**感知有度 Sense in Balance**｜2026 AI 座艙感知與視覺化 Hackathon（實作組）

車上的提示越來越多，很多事系統自己就能處理，卻還是丟給駕駛。這個專案讓座艙 AI **先動手、少開口**：能自動處理的事直接做（例如車內 CO2 升高時自動切外循環），只有在有代價或有危險時，才用一句話告知。

## 架構

```
座艙狀態（CO2、溫度、內外循環、乘員、車速、盲點事件）
        │
        ▼
  規則引擎 rules.dart ── 決定「做什麼、多緊急、有沒有代價」
        │
        ├─ 安全警示 ──────────────► 直接發出，不等模型
        ├─ 可自動處理 ────────────► 執行層直接執行，有代價才告知
        └─ 需要告知 ──► 端側 SLM（Qwen2.5-1.5B，離線）措辭
                              │
                              ▼
                        檢查器 guard.dart ── 字數、簡體字、編造數字、誇大用語
                              │              不通過 → 改用固定模板
                              ▼
        數位儀表（緊急、最小資訊）＋ 中控（告知卡片、問答、地圖）＋ 語音播報
```

- **模型只負責措辭，不做決策**：1.5B 模型在開放式問答會產生幻覺，所以決策交給規則引擎，問答交給本地知識庫（`kb.dart`）。查不到就回答「這個我查不到，請參考車主手冊」。
- **多數時候不說話**：在 12,000 組窮舉狀態中，約 70% 的正解是保持安靜。
- **斷網照常運作**：決策、措辭、問答、語音都在裝置上離線執行。決賽前會加上雲端增強（Hybrid AI）。
- **雙屏同步**：手機當 AI Box，用 WebSocket（:8765）同步儀表與中控，1 秒心跳，3 秒逾時就顯示失效。iPad 用 Safari 開網頁版中控即可。

## 目錄

| 路徑 | 內容 |
|---|---|
| `app/cockpit_hmi/` | 座艙 HMI App（Flutter／Android）：規則引擎、SLM 措辭與檢查器、知識庫、WebSocket Hub、儀表、中控、網頁版中控 |
| `app/slm_probe/` | 端側模型實測用的小 App（手機與平板的 CPU／GPU 延遲與輸出品質） |
| `research/INTERFACE.md` | 跨裝置事件介面規格 |
| `research/prototype/` | Python 研究原型：狀態產生器與決策（`states.py`，App 規則引擎與它逐筆一致）、台灣用語檢核、模型基線評測 |
| `research/validation/` | 架構驗證腳本 |
| `media/remotion/` | 報名影片的 Remotion 動畫（片頭、團隊、問題、架構圖、片尾） |
| `media/video_edit/` | 影片剪輯管線：FFmpeg 分段、自動馬賽克、字幕、用 Whisper 逐段驗證音軌 |
| `media/slides/` | 提案簡報與報名表單產生器（python-pptx、python-docx） |

## 建置 App

需要 Flutter 3.35.2，以及 Android 14 以上（Target SDK 34）。

```bash
cd app/cockpit_hmi
flutter test                      # 16 項自動化測試
# 網頁版中控要先打包進 APK
flutter build web -t lib/main_web.dart --release --no-web-resources-cdn --pwa-strategy=none
python tool/pack_web.py
flutter build apk --release
```

第一次開啟 App 時，會從 Hugging Face（`litert-community/Qwen2.5-1.5B-Instruct`）下載模型檔，也可以手動匯入 `.litertlm`。APK 裡不含模型，也不含任何 API Key。

已建置好的 APK 放在 [Releases](../../releases)。

## 使用方式

- **一機模式**：平板開「中控」，內建 AI Box。
- **兩機模式**：手機開「儀表＋AI Box」，iPad 用 Safari 開 `http://<手機 IP>:8765` 當中控。

## 備註

- 盲點與 CO2 事件是模擬注入的，還沒有接上真實感測器或攝影機。
- 主動告知的措辭在手機上實測需要 4.6–6.8 秒；安全警示不經過模型，不受這個延遲影響。
- `media/` 和 `research/` 裡的腳本寫死了開發機的路徑，使用前請先改路徑。需要 API 的腳本從環境變數讀金鑰（`DEEPSEEK_API_KEY`、`GROQ_API_KEY`）。
- 拍攝素材、團隊照片、字型檔沒有放進 repo。Remotion 需要的 `public/NotoSansTC-VF.ttf` 請自行從 Google Fonts 下載（SIL OFL 1.1）。
- 使用的第三方元件與授權：Qwen2.5-1.5B-Instruct（Apache 2.0）、Flutter（BSD-3）、flutter_gemma（MIT）、flutter_tts（MIT）、flutter_map（BSD-3）、OpenStreetMap 圖資（ODbL，© OpenStreetMap contributors）、Remotion（Remotion License）。

## 團隊

葉士愷・黃昱羲・胡馨
