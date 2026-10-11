# -*- coding: utf-8 -*-
"""
驗證零：Qwen2.5 1.5B vs 3B 的繁體中文短句品質對照

本檔案由 Claude 於 2026-09-23 撰寫。

回答 A 區報告自承的第一條失效條件：
  「我完全沒有任何 1.5B vs 3B 的繁中對比數據…如果實測發現 1.5B 連
   『把 CO2 數值講成一句人話』都做不好，整個建議就倒了。」

用法：
    python 驗證零_跑測試.py

輸出：驗證零_結果_<時間戳>.md（左右對照，可直接人工評分）

⚠️ 限制（必須連同結果一起看）：
  Ollama 上的是 GGUF Q4_K_M，要上平板的是 .litertlm q8，不是同一個檔。
  本測試回答「1.5B 這個尺寸夠不夠」，不回答「那個特定檔案好不好」。
  但 Q4 比 q8 差 —— Q4 過得了，q8 一定過得了。
"""

import json
import time
import urllib.request
import urllib.error
from datetime import datetime

OLLAMA = "http://localhost:11434/api/chat"

# 兩個要比的模型。注意是 qwen2.5:3b（冒號），不是 qwen2.5-3b（那個有「小香菇」人格）
MODELS = ["qwen2.5:1.5b", "qwen2.5:3b"]

# 我們真正會用的 system prompt —— 不用原廠預設，因為要測的是「在我們的用途下夠不夠用」
SYSTEM = (
    "你是車輛座艙的語音助理。規則："
    "①一律用繁體中文（台灣用語）回答，禁止簡體字與英文。"
    "②只講一句話，最多 40 個字。"
    "③講人話，不要條列、不要客套、不要重複問題。"
    "④不確定的事就說不確定，不要編造車輛規格或維修步驟。"
)

# 20 題，分四類。每題標註「要看什麼」，讓人工評分有依據。
TESTS = [
    # --- A. 把數值講成人話（最核心的能力，A 區點名的那一項） ---
    ("A1", "車內二氧化碳 1340 ppm，車速 90，外面 31 度。現在該怎麼做？"),
    ("A2", "二氧化碳從 800 升到 1500 ppm，只花了 12 分鐘。這代表什麼？"),
    ("A3", "車內 CO2 是 2100 ppm。這個數字嚴重嗎？"),
    ("A4", "現在外溫 34 度，車內 26 度，開內循環。要換氣的話有什麼代價？"),
    ("A5", "後座有兩個人，車內二氧化碳 1600 ppm，還有 40 分鐘到目的地。建議？"),

    # --- B. 短口語輸入（駕駛真正會講的話） ---
    ("B1", "會冷"),
    ("B2", "有點悶"),
    ("B3", "太熱了"),
    ("B4", "空氣好像不太好"),
    ("B5", "幫我開窗"),

    # --- C. 會誘發幻覺的車輛知識（看它會不會亂編） ---
    ("C1", "儀表板那個黃色的燈亮了要怎麼辦？"),
    ("C2", "我的車胎壓應該打多少？"),
    ("C3", "引擎溫度表指到紅色區域，我該繼續開嗎？"),
    ("C4", "這台車的冷氣濾網多久換一次？"),
    ("C5", "方向盤在抖是什麼問題？"),

    # --- D. 繁簡與台灣用語（這是 OpenCC 要補的洞，先看模型自己行不行） ---
    ("D1", "螢幕上顯示的資訊看不清楚，怎麼調整？"),
    ("D2", "這個功能的預設值是什麼？"),
    ("D3", "幫我把空調設定存起來。"),
    ("D4", "行車記錄器的記憶體滿了。"),
    ("D5", "用一句話解釋什麼是內循環。"),
]

CATEGORY = {
    "A": "把數值講成人話（A 區點名的核心能力）",
    "B": "短口語輸入（駕駛真正會講的話）",
    "C": "會誘發幻覺的車輛知識（看它會不會亂編）",
    "D": "繁簡與台灣用語",
}


def ask(model, prompt):
    """呼叫 Ollama，回傳 (回答文字, 耗時秒數)。失敗回傳 (錯誤訊息, None)。"""
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": prompt},
        ],
        "stream": False,
        "options": {"temperature": 0.2, "seed": 42},  # 固定種子，兩邊條件一致
    }).encode("utf-8")

    req = urllib.request.Request(
        OLLAMA, data=body, headers={"Content-Type": "application/json"}
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            data = json.loads(r.read().decode("utf-8"))
        return data["message"]["content"].strip(), time.time() - t0
    except urllib.error.URLError as e:
        return f"[連線失敗：{e}。Ollama 有在跑嗎？]", None
    except Exception as e:
        return f"[錯誤：{e}]", None


def main():
    stamp = datetime.now().strftime("%Y%m%d_%H%M")
    out_path = f"驗證零_結果_{stamp}.md"
    lines = []

    lines.append("# 驗證零結果：Qwen2.5 1.5B vs 3B 繁中短句品質")
    lines.append("")
    lines.append(f"**執行時間**：{datetime.now():%Y-%m-%d %H:%M}")
    lines.append(f"**模型**：`{MODELS[0]}` vs `{MODELS[1]}`（皆 Ollama GGUF Q4_K_M）")
    lines.append("**參數**：temperature 0.2、seed 42、兩邊使用完全相同的 system prompt")
    lines.append("")
    lines.append("> ⚠️ **本測試回答「1.5B 這個尺寸夠不夠用」，不回答「.litertlm q8 那個檔好不好」。**")
    lines.append("> Ollama 的是 Q4_K_M，平板要用的是 q8。**Q4 過得了，q8 一定過得了。**")
    lines.append("")
    lines.append("## 評分方式")
    lines.append("")
    lines.append("每一題在 ⭐ 欄填 `1.5B` / `3B` / `平手` / `都不行`。判準三項：")
    lines.append("")
    lines.append("1. **是繁體中文嗎**（出現簡體字或英文 = 直接不及格）")
    lines.append("2. **有沒有把事情講成人話**（不是複述問題、不是條列、不是客套）")
    lines.append("3. **有沒有亂編**（C 類特別看這個；不知道就說不知道才是對的）")
    lines.append("")
    lines.append("> 🔴 **只要 1.5B 在 A 類五題裡有三題以上明顯輸，就代表 A 區的失效條件成立，"
                 "端側化的主選模型要重新考慮（改 gemma-4-E2B 或接受 LLM 留在筆電）。**")
    lines.append("")
    lines.append("---")
    lines.append("")

    print(f"開始測試 {len(TESTS)} 題 x {len(MODELS)} 模型...\n")

    totals = {m: [] for m in MODELS}
    last_cat = None

    for tid, prompt in TESTS:
        cat = tid[0]
        if cat != last_cat:
            lines.append(f"## {cat}. {CATEGORY[cat]}")
            lines.append("")
            last_cat = cat

        lines.append(f"### {tid}　{prompt}")
        lines.append("")
        lines.append("| 模型 | 回答 | 秒 |")
        lines.append("|---|---|---|")

        for m in MODELS:
            ans, dur = ask(m, prompt)
            if dur is not None:
                totals[m].append(dur)
            # 把換行壓成一行，避免破壞表格
            flat = ans.replace("\n", " ").replace("|", "｜")
            secs = f"{dur:.1f}" if dur is not None else "—"
            lines.append(f"| `{m}` | {flat} | {secs} |")
            print(f"  [{tid}] {m}: {flat[:50]}")

        lines.append("")
        lines.append("**⭐ 誰贏**：　　　　**備註**：")
        lines.append("")

    lines.append("---")
    lines.append("")
    lines.append("## 速度（僅供參考，不是判準）")
    lines.append("")
    lines.append("| 模型 | 平均秒/題 | 總秒 |")
    lines.append("|---|---|---|")
    for m in MODELS:
        if totals[m]:
            avg = sum(totals[m]) / len(totals[m])
            lines.append(f"| `{m}` | {avg:.1f} | {sum(totals[m]):.0f} |")
    lines.append("")
    lines.append("> ⚠️ 這是筆電（RTX 3050 4GB）的數字，**與 Tab S9 無關**，不要拿去外推。")
    lines.append("> 平板的效能是驗證一要回答的，不是這一份。")
    lines.append("")
    lines.append("## 結論（人工填寫）")
    lines.append("")
    lines.append("- A 類 1.5B 輸幾題：______ / 5")
    lines.append("- 1.5B 有沒有出現簡體字或英文：______")
    lines.append("- 1.5B 在 C 類有沒有亂編：______")
    lines.append("- **裁決**：☐ 1.5B 夠用，照 v2 的 §6 走　☐ 1.5B 不夠，改用 gemma-4-E2B　☐ 都不夠，LLM 留在筆電")
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("*本檔案由 `驗證零_跑測試.py` 產生（Claude 於 2026-09-23 撰寫）。評分欄需人工填寫。*")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print(f"\n完成。結果寫到：{out_path}")


if __name__ == "__main__":
    main()
