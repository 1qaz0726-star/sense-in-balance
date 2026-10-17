# C 實作定稿：注意力模式與跨車型任務協調

設計定稿：2026-10-17。先完成既有規格、最新分支與三個專業角色的分析，再依本文件實作。基底為 `2ff3fe3176de66809ff45a8052c726544588aab4`；此文件的目標不是已通過的驗收結果，最終成果另列測試收據。

## 產品要解決什麼

保留入圍主題「該說才說：會自己動手的安靜座艙 AI」，深化既有少打擾及不用重講流程。同一句複合需求，先由受限 SLM 理解，再由主機判定本車能力、目前是否應請駕駛確認，最後收到逐項模擬回報才顯示完成。這些行為必須在兩個畫面與後端一致。

本次不把一般音量調整改成多次確認。展示集中在原系統的邊界：一串需求有部分無法執行，又碰上優先事件；需求要留下、修正要局部、解除不能自動執行。先前研究支持車內操作與干擾是重要問題，但本隊沒有使用者受測，不能宣稱痛點頻率、分心或事故改善的百分比。

## 本輪完整實作範圍

- A/B 為兩份明示虛構的模擬座艙能力。A 三項可獨立控制；B 未提供後座風量介面，音樂與導航仍獨立。兩者刻度相同，均只處理原有三項與 increase/decrease/keep/remove，不重訓或改 V3 提示格式。
- B 保留不支援的需求，封鎖整批確認。取得原本駕駛修補授權後，乘客明確取消後風項，其他需求保留。不可默默略過、改前座風量或把未知後風顯示為 0。
- 注意力模式接明示本機模擬來源與原有盲點警示。manual、assisted 仍由人負責駕駛；handoverRequested/unknown/來源過期/優先警示均阻擋新的非緊急確認與新修補授權。已有效授權的乘客可在期限內整理候選。
- 所有 blocker 解除後保持原需求，等待駕駛查看最新版，一次 `resume_confirm` 明確確認並執行。解除不自動送出、不自動切回摘要、不自動播舊需求。
- A/B 僅可在模擬停車且任務 idle/completed/cancelled 的乾淨狀態切換。新 session、配對碼與撤權；parsing/awaiting/failed/executing/indeterminate 都拒絕切換。
- 保留原版、Hybrid V3 基準分支、同學 cloud/ASR/記憶與原儀表。C 安裝包另設識別及啟動入口，原版可以回看。

## 系統責任與資料契約

`V3 -> IntentPatch -> 原 RepairController 合併 -> CabinPolicy 能力/注意力准入 -> 駕駛確認 -> MockCabinActuator -> 原 ACK 狀態機`。

V3 只提出意圖。能力、權限、資料鮮度、值域與執行均由固定程式處理。Host 為唯一任務主機，手機沒有判斷或執行權。

新增純 Dart `cabin_policy.dart`，由 `RepairCollaboration` 注入 optional policy；未注入時保留原 schema1 行為。C status 為 schema2，top-level `cabin_context` 含目前 session/profile、attention、能力評估與公開准入結果。

所有 C command 必須帶 `cabin_session_id`。task-bound 的 grant/revoke/confirm/resume_confirm/cancel 另外帶 `profile_id`、`profile_revision`、`attention_epoch`，以及原 task_id/revision。嚴格拒絕缺欄、額外欄、重複 key、不符版本及同 command_id 不同內容。UI 不自訂權限。

`CabinPolicy.identity` 為 `CabinContextIdentity`，包含上述四個 flat identity 欄位。profile 的 `supported` 決定控制能力，公開 `readable` 明確表示 B 後風不可讀。能力摘要綁當前 task/revision；不以 client 暫存值決定計畫。

注意力來源由 Host register source_id/source_session，只接受相同已登記來源、正向 sequence、合法 episode 與同單調時間域的 sampledAt。超前/倒序時間、時鐘倒退、舊 sequence/episode 不可讓舊狀態重新變新。TTL 3 秒、每秒 heartbeat 為本展示參數，非車規保證。初始未接入與過期都保守阻擋；每次後端准入同步重驗，不能只等 UI/watchdog。

attention_epoch 與 task revision 分離。一般 heartbeat 不增加 epoch，模式/blocker/續辦狀態變化才使舊確認失效。警示不改已送命令的 task identity，不以警示或逾時偽造撤銷。執行與 unknown 期間鎖住 session，原 late ACK 照常核對，不自動重送。C 模擬 adapter 再次檢查能力，完整逐項 ACK 及 session/profile 執行身分另行驗證，不能用 UI disabled 作防線。

## 畫面與操作定稿

沿用同學原深色、金色、平面分隔線、NotoSansTC。沒有卡片網格、呼吸光或模式縮放。儀表、原左右來車圖像與預留警示槽固定佔位，新狀態只進固定高度文字帶。

S9/中控保留完整候選、受限原因和合法修補。手機在第一次 blocker 到來切儀表一次，非緊急詳情退場。解除後固定帶提示「需求已保留，可查看最新摘要」，由人切摘要；唯一主動作為確認最新版。未知執行結果與斷線不得被簡化模式遮成成功。

展示設定放既有「展示情境」入口。可注入接管提醒、切人工/輔助模式、模擬來源中斷，並在合法停車乾淨狀態切 A/B。來源與車控一律明示模擬；遠端 observer 沒有注入或切車型指令。

## 驗收及交付

保留原 161 工程測試。新增來源順序/鮮度、多 blocker、後端 stale identity 拒絕、有效與過期 lease、能力雙層拒絕、session 切換、resume 一次確認、執行中警示/晚 ACK/unknown 鎖定測試。UI 檢查 B 不捏造風量、blocked 無執行主動作、固定高度與方向尺寸無 overflow。

用真 V3 在 PC 本地服務加兩 Android 模擬器跑 A 與 B 獨立 session，保存原始輸出、計畫、拒絕原因、最新確認、逐項 ACK、畫面與模型 SHA。明確區分 unit/fixture、真模型 controller 與真 UI。S9 尚未連線，不能填成已通過實機。原生 APK、PC 備援、Driver、Web 同時保持 schema 相容；部署腳本與說明同步更新。

交付為完整程式修改、本機可重開的雙屏 demo、安裝檔、測試收據、易懂而完整的 PDF 簡報。簡報先講問題與實際行為，再講差異、競賽對齊、實作/測試、限制與前景。實際驗收結果完成後才寫入成果頁。

## 後續方向

真 AAOS/CDC adapter 與授權、動態能力、不同刻度/共同音量資源衝突、外部手動改值重計畫、真實使用者驗證與 OEM PoC。這些列未來里程碑，不能當本輪成果。S9 一般 Android APK 不會自動取得 CarService/VHAL 控制權，也不提供自駕能力。
