# C 版本沿用的 V3 模型

底模：`Qwen/Qwen2.5-1.5B-Instruct`，revision `989aa7980e4cf806f80c7fef2b1adb7bc71aa306`。2026-10-16／17 既有 V3 工作以有限合成座艙意圖／局部修正資料做 response-only QLoRA，合併權重後轉 Android Q8 LiteRT-LM 與 PC Q8_0 GGUF。本次 C 改版沿用該模型，沒有新訓練、權重裁剪或 teacher-logit 蒸餾。

| 檔案 | 大小 bytes | SHA-256 |
|---|---:|---|
| `cabin-v3-clean-q8-c2048.litertlm` | 1,823,647,040 | `abc57627d87b529328541e5a2194209fab641f3aa17de3c2a31376cc39de9702` |
| `cabin-v3-clean-hybrid-q8_0.gguf` | 1,646,573,152 | `91793812b9ad0fab54a85119fa7cb1b16d9129be446b5bbe63c8340e6d13fbd1` |

Android 模型 ID：`qwen25-15b-v3-clean-q8-c2048`。PC alias：`cabin-v3-clean-hybrid`。既有 adapter SHA-256：`3477069956dda08ddfe3b5110f96834a6b0ab4d5528899d0ad010f6798efa42a`。

僅供 `rearFan`、`mediaVolume`、`navVolume` 的候選 JSON 與局部修正；程式另外驗證本車能力、角色、授權、模式、最新版與模擬執行回報。不是任意車控模型、醫療或行車安全模型，也不是自駕模型。

C 已記錄 215 項工程測試、33 項真模型控制器檢查與保存雙屏證據審查；它們不構成一般模型準確率。原生 x86 首次暖機失敗，正常重開一次成功；單筆 CPU 候選 33.75 秒。S9 未驗證，歷史 D02 音樂誤拒仍存在，沒有新的人類盲測或使用者成效資料。

`MODEL_CARD_HYBRID_V3_HISTORICAL.txt` 及 `MODEL_CARD_ORIGINAL_HISTORICAL.txt` 保留先前階段事實，不能把當時 161 項測試或前一輪耗時當成本輪結果。完整本輪範圍見 [交接說明](../README.md)。

這是修改後權重，並非 Qwen 官方發布。保留 [Qwen Apache 2.0 授權](../licenses/Qwen-Apache-2.0-LICENSE.txt) 與 [上游 README](../licenses/Qwen-upstream-README.md)；此模型說明不替 App 或第三方程式重新授權。
