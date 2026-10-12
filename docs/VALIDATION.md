# 驗證摘要

更新：2026-10-12。這是電腦上的雙原生 Android 展示：平板操作、第二屏只讀同步，Qwen2.5-1.5B 在 PC 本地執行。車速、油量、CO₂、盲點與車控都是模擬；不代表真車或感測器能力。

## 已取得的證據

| 範圍 | 實際驗證與限制 |
|---|---|
| 最新儀表 UI | `flutter analyze --no-pub` 通過；2 項繪製／幾何回歸測試通過，涵蓋 45 組狀態：4 尺寸 × 6 種繪製狀態，3 尺寸 × 7 種警示轉換。這是程式測試，不是模型準確率。 |
| 原生警示畫面 | 平板正常、右後機車、左後自行車、右後汽車，以及直向第二屏均實際操作、保存畫面。警示由原版規則與模板立即產生，不等待 Qwen。 |
| 警示不縮放 | 原生平板正常與三種警示的解析度相同；自車核心與 120 刻度共 **2 個取樣區域**逐像素相同。搭配幾何回歸測試支持位置、尺寸穩定，並非整張畫面一致。 |
| 少量真模型操作 | PC `Qwen2.5-1.5B-Instruct` GGUF Q8 解析三項需求，再只取消風量，確認模擬後雙屏為 **3／4／5**。原始 trace 耗時為 **2468 ms／427 ms**，輸入與快取條件不同；不能推論整體準確率、延遲分位數或 S9 效能。 |
| 最新完整測試套件 | 2026-10-12 發布前重跑：`flutter test --no-pub` **54 項全部通過**；`flutter analyze --no-pub` 無問題。含原規則、Hub 生命週期、需求版本／確認、同步與 UI；多數模型及車控使用替身。 |
| 發布版建置 | 在此電腦執行倉庫內 `tools/desktop/build-demo.ps1`，從只含基礎資產的 canonical manifest 成功建出平板與第二屏兩個 x64 debug APK。未用這次建置覆蓋既有裝置；尚未在第二台乾淨 Windows 電腦驗證完整安裝流程。兩個網頁打包器另經 15 次臨時資料重跑／互切與 YAML 解析驗證通過。 |

可檢查的公開證據：

- [正常儀表](images/instrument-normal.png)、[機車](images/blindspot-motorcycle.png)、[自行車](images/blindspot-bicycle.png)、[汽車](images/blindspot-car.png)、[直向第二屏](images/companion-motorcycle.png)。
- [需求待確認](images/controls-pending.png)、[確認完成](images/controls-complete.png)。
- [原生幾何取樣紀錄](evidence/instrument-geometry.json)、[真 Qwen 原始 trace](evidence/qwen-traces.jsonl)。

## 尚未證明的部分

- **含糊指令仍有失敗**：「那個先不要改」曾被模型直接猜成取消音樂，沒有先澄清。尚未完成 8 題開發題＋12 題保留題的系統性評估。
- **S9 端上尚未驗證**：目前模型在 PC；Android 端 LiteRT 的正確性、冷暖延遲、耗電及離線跨屏仍需真機量測。
- **最新橫向警示未取得原生截圖**：最新短橫向由 UI 回歸測試覆蓋，原生保存的是橫向常態；早期橫向警示證據不能代替最新版本驗證。
- **尚無真車／ASR／ADAS 整合**：盲點是手動事件注入，並無攝影機辨識、距離估計、正後方追撞或前方碰撞偵測。車控為記憶體模擬，尚未加入語音辨識。
- **上游基準不等於本次成果**：原專案的 12,000 組窮舉狀態與約 70% 安靜比例，屬於上游規則基準，不能當成本次 Qwen 準確率或使用者研究結果。

新入口保留原版儀表及安全規則，但未宣稱原地圖、停車知識庫、語音、劇本與完整角色流程全部遷入。同學原 App 與 Git 歷史保留。開發方法見 [DEVELOPMENT.md](DEVELOPMENT.md)；逐輪紀錄見 [LOCAL_VALIDATION_HISTORY.md](LOCAL_VALIDATION_HISTORY.md)。
