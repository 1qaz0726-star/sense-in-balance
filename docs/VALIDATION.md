# 驗證摘要

更新：2026-10-12。本輪「不用重講」新增乘客詳細端、六位碼駕駛配對、120秒本task修正授權、乘客局部修改、駕駛確認最新版本、逐項ACK及去重。第二屏未配對時只讀；配對後有駕駛授權／確認權限。Qwen2.5-1.5B在PC本地執行；車速、油量、CO₂、盲點和車控仍為模擬。這是方案01的分工，不是完整任務owner交接、真車或感測器能力。

## 已取得的證據

| 範圍 | 實際驗證與限制 |
|---|---|
| 最新儀表 UI | `flutter analyze --no-pub` 通過；2 項繪製／幾何回歸測試通過，涵蓋 45 組狀態：4 尺寸 × 6 種繪製狀態，3 尺寸 × 7 種警示轉換。這是程式測試，不是模型準確率。 |
| 原生警示畫面 | 平板正常、右後機車、左後自行車、右後汽車，以及直向第二屏均實際操作、保存畫面。警示由原版規則與模板立即產生，不等待 Qwen。 |
| 警示不縮放 | 原生平板正常與三種警示的解析度相同；自車核心與 120 刻度共 **2 個取樣區域**逐像素相同。搭配幾何回歸測試支持位置、尺寸穩定，並非整張畫面一致。 |
| 早期少量真模型操作 | 原PC GGUF Q8三項需求／局部取消trace仍保留，曾為2468ms／427ms；輸入與快取條件不同，不是最新延遲基準，也不代表S9效能。 |
| 最終完整測試套件 | 本輪實際`flutter test --no-pub` **88/88通過**（約40秒）、`flutter analyze --no-pub` No issues（約3.5秒）。含語意保護、配對／任務授權、版本確認、逾時／斷線、去重、JSON邊界、原規則及UI；多數模型／車控用替身。88是測試數，不是人數或準確率。 |
| 按鈕保留澄清回歸 | 已修directPatch抹掉未回答clarification的P2。新增測試走授權→待澄清→按鈕改另一項→driver確認受拒→文字回答→mock只執行一次；不因另一項已改好就把整個任務當成可執行。這是工程測試，不是人因結果。 |
| 真Qwen固定20例 | PC本地GGUF Q8、公開固定8個development＋12個原稱holdout題目：未保護13/20，保護鏈路20/20；挑戰修正後重跑仍20/20，14次真模型＋6次deterministic_clarification。新檔另存，歷史未覆寫。題目已看過並用來改守門規則，不是獨立未見測試，不是SLM獨力100%。 |
| 新開發者16例首次挑戰 | 執行前固定預期並留SHA-256，首次run沒有改production，完整changes／澄清／projected pending契約 **10/16**；12筆真Qwen、4筆規則澄清。6失敗涵蓋否定取消、集合指代、不支援座椅加熱、額外keep／澄清及全撤回同義說法。作者已讀程式及公開題，不是獨立人類驗證；澄清只查有無，不查品質。修正後同批回歸另報，不能抹去首次結果。 |
| 新16例修正後已見回歸 | **12/16**符合完整契約，10真Qwen＋6規則澄清；N06與N14已修，仍失敗N02／N08／N09／N12。N08保守澄清未完成原預期的雙音量取消，照樣記fail。保留首次10/16與原預期位元，不改答案；同批已讀並調規則，不稱未見或獨立驗證。 |
| 最新原生角色協作全流程 | 最終兩target34 APK重建／aapt核對、安裝後，在兩AVD走完真Qwen三項候選→六位碼配對→駕駛授權→真Qwen只取消風量→駕駛確認最新版本→模擬ACK、两屏3／4／5。兩筆raw／trace與完成JSON保存：completed，pending只剩media decrease／nav keep。這次沒有手動故障或導航按鈕，是局部改口，不是自然錯誤修復率；未測麥克風或人体效益。 |
| 歷史原生安排誤解流程 | 先前target36 debug APK的兩AVD完成手動導航誤解並明示來源、真Qwen取消風量、按鈕導航keep、driver確認與mockACK。該次也觀察120秒到期禁編輯、重新授權可繼續。混合文字＋按鈕與人工故障均另標，不冒充最新無注入流程或模型自然失敗。 |
| 修正前四條件技術回放 | 同fault、同初始3／5／5；A全重說、B局部單客戶端、C局部雙客戶端、D按鈕。各執行一次，最終3／4／5。B/C/D移除風量pending，A可明列風量keep；不只驗終值。C/D有兩個實際WS客戶端，沒有人體／ASR測試。歷史數據保留，不稱最新修正後回放。 |
| 真模型與規則分工 | 預設範例／一般局部文字輸入仍真跑Qwen。B/C raw把風量取消解成keep，明確取消規則校正remove；raw與最終結果分開保存。明確含糊／不支援輸入會先澄清；按鈕不呼叫模型。 |
| 人工安排誤解 | 桌面模式才可手動改尚未執行的導航候選；兩屏標「展示安排的誤解，尚未執行」，完成後保留來源。注入不會授權／執行，不算自然模型失敗率。 |
| Android ASR程式 | 已實作嚴格`createOnDeviceSpeechRecognizer`，服務／語言模型不可用或權限拒絕就回文字，不切generic／雲端。已辨識文字先供核對。程式檢查不是麥克風／語音實測，S9仍未測。 |
| Target SDK建置與AVD互動 | target SDK明確34，compile36、min24；最終乘客／駕駛兩x64 debug APK重建、aapt確認target34與`com.auohack.cockpit_hmi.desktopdemo`，已安裝且完成上述完整無注入流程。解決V11這項target建置要求；不代表S9、兩實體、語音或其他交件項全部合規。 |
| 通用助手的歷史建置 | 此前在本機執行倉庫內`tools/desktop/build-demo.ps1`，從只含基礎資產的canonical manifest建出兩個x64 debug APK，該次沒有覆蓋裝置；最終角色版本另已安裝、完成最新原生流程。尚未在第二台乾淨Windows電腦驗證完整安裝。兩個網頁打包器曾經15次臨時資料重跑／互切與YAML解析驗證；最新駕駛web release也建置成功。 |

可檢查的公開證據：

- [最終驗證總表與source／APK SHA](evidence/final-validation.json)：88/88、No issues、web release、target34／compile36兩APK及最新原生流程；0位受試者、S9／麥克風／兩實體斷外網等限制一併保存。
- [正常儀表](images/instrument-normal.png)、[機車](images/blindspot-motorcycle.png)、[自行車](images/blindspot-bicycle.png)、[汽車](images/blindspot-car.png)、[直向第二屏](images/companion-motorcycle.png)。
- [需求待確認](images/controls-pending.png)、[確認完成](images/controls-complete.png)。
- 最新target34原生流程：[乘客局部取消](evidence/native/repair-passenger-final.png)、[駕駛候選摘要](evidence/native/repair-driver-final-candidate.png)、[駕駛ACK與3／4／5](evidence/native/repair-driver-final.png)、[乘客完成](evidence/native/repair-passenger-final-complete.png)、[兩筆真Qwen raw／trace](evidence/native/repair-final-qwen-traces.txt)、[完成狀態JSON](evidence/native/repair-final-status.json)。
- 歷史target36明示人工誤解／混合輸入：[乘客修正](evidence/native/repair-passenger-revised.png)、[駕駛摘要](evidence/native/repair-driver-revised.png)、[乘客完成](evidence/native/repair-passenger-complete.png)、[駕駛回執](evidence/native/repair-driver-complete.png)、[駕駛完成摘要](evidence/native/repair-driver-complete-summary.png)。
- [原生幾何取樣紀錄](evidence/instrument-geometry.json)、[真 Qwen 原始 trace](evidence/qwen-traces.jsonl)。
- [固定20例未保護輸出](evidence/repair-model-before.json)、[此前保護鏈路與分流](evidence/repair-model-final.json)、[挑戰修正後固定20例重跑](evidence/repair-model-after-challenge-fix.json)、[修正前四條件機器回放](evidence/repair-replay-final.json)。
- [新16例挑戰首次結果與事前預期](evidence/repair-challenge-new.json)：原raw、最終patch、projected pending與6項失敗均保留。
- [新16例最小修正後已見回歸](evidence/repair-challenge-after-fix.json)：12/16；原契約未改、4項失敗及N08保守澄清如實保留。
- [完整證據與測試計畫](REPAIR_EVIDENCE_AND_TEST_PLAN.md)、[方案01審查簡報](repair-proposal.pdf)（12頁）。

## 如何閱讀機器回放

修正前保存的repair-only時間A／B／C／D為164／126／127／0ms；到ACK為170／134／134／13ms。每條件只有一次，D在毫秒計時粒度下顯示0，**不是沒有耗時**。無人的閱讀、說話、授權猶豫或駕駛任務，不能寫效率提高百分比、第二屏減少分心或車主少重講幾次。原生混合輸入展示有自己的截圖證據，沒有使用這些機器時間作為使用者完成時間；修正後回放若有新紀錄須另存。

20例的exact只檢查changes與是否澄清，不涵蓋所有使用語言、ASR口音、權限及跨屏執行。新16例另外檢查projected pending，首次10/16、修後12/16清楚顯示原20/20不可泛化；契約失敗也不等於錯誤執行，這批沒有接執行器。N02終態正確但多傳keep，N12取消正確但多問一次；首次N06錯刪音樂待辦、N14未承認不支援加熱已修正，原始失敗不刪。N08雖改保守澄清，仍未完成原要求；按鈕與確認仍需保留，不能只報成功展示。

這些由不同測試／紀錄分開驗證；零錯誤小樣本不代表產品普遍正確或量產安全。本輪0位受試者，沒有自家高頻／付費／人體效益資料。新獨立保留集與人類比較屬未來驗證，不以招募阻擋目前成果。

## 尚未證明的部分

- **原始模型仍會誤解**：早期「那個先不要改」猜取消音樂的紀錄保留；本輪保護鏈路會先澄清。固定20例已測完但已看過／調規則，不能代表未見說法已通過；自然語言一般化仍需更廣泛驗證。
- **S9 端上尚未驗證**：目前模型在 PC；Android 端 LiteRT 的正確性、冷暖延遲、耗電及離線跨屏仍需真機量測。
- **最新橫向警示未取得原生截圖**：最新短橫向由 UI 回歸測試覆蓋，原生保存的是橫向常態；早期橫向警示證據不能代替最新版本驗證。
- **尚無真車／語音實測／ADAS整合**：盲點是手動事件注入，並無攝影機辨識、距離估計、正後方追撞或前方碰撞偵測。車控為記憶體模擬。ASR橋接已加入，但沒有麥克風／S9／口音或斷外網兩實體驗證，不能寫離線語音已完成。
- **模擬器與實體驗證分開**：TargetSDK34已由最終兩APK的aapt核對，compile36、min24，已安裝並走完無注入完整原生流程；這仍不是S9、兩實體平板、麥克風或其他交件項的驗證。歷史target36人工故障／按鈕流程獨立保留。
- **上游基準不等於本次成果**：原專案的 12,000 組窮舉狀態與約 70% 安靜比例，屬於上游規則基準，不能當成本次 Qwen 準確率或使用者研究結果。

新入口保留原版儀表及安全規則，但未宣稱原地圖、停車知識庫、語音、劇本與完整角色流程全部遷入。同學原 App 與 Git 歷史保留。開發方法見 [DEVELOPMENT.md](DEVELOPMENT.md)；逐輪紀錄見 [LOCAL_VALIDATION_HISTORY.md](LOCAL_VALIDATION_HISTORY.md)。
