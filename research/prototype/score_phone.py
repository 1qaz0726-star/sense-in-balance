# -*- coding: utf-8 -*-
"""替手機實測結果評分，並與筆電 Ollama 基線對照。

用法：
    python score_phone.py <results.md 路徑> [輸出.md]

判準與 baseline.py 完全相同，這樣兩邊的數字才可比：
  - 超字數      ：非 silent 題，輸出長度 > 上限
  - 編造數字    ：輸出裡出現輸入中沒有的數字
  - 含簡體／用語：tw_lexicon.check()
  - 該閉嘴而閉嘴：silent 題要輸出 <silent>

本檔案由 Claude 於 2026-09-29 撰寫。
"""
import io, re, sys, os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tw_lexicon import check

# 筆電 Ollama Q4_K_M、新提示、30 題（safety10/proactive10/silent10）的基線
BASELINE = {
    "編造數字": "0%", "含簡體": "0%", "數值方向錯": "0%",
    "該閉嘴而閉嘴": "10/10", "超字數": "53%",
}


def parse(path):
    """從探針產生的 results.md 抽出 (label, prompt, output)。"""
    txt = io.open(path, encoding="utf-8").read()
    items = []
    for m in re.finditer(
        r"###\s*(.+?)（(\w+)）\s*\n+\*\*提問\*\*：(.*?)\n+\*\*回答\*\*：(.*?)\n",
        txt, re.S
    ):
        label, backend, prompt, out = m.groups()
        items.append({
            "label": label.strip(),
            "backend": backend.strip(),
            "prompt": prompt.strip(),
            "out": out.strip(),
        })
    return items, txt


def limit_of(label, prompt):
    """從題目標籤或提示本文取得字數上限。"""
    m = re.search(r"≤(\d+)字", label)
    if m:
        return int(m.group(1))
    m = re.search(r"上限[:：]\s*(\d+)\s*字", prompt)
    return int(m.group(1)) if m else None


def score(items):
    n = len(items)
    n_len = n_num = n_simp = n_word = 0
    sil_ok = sil_tot = 0
    rows = []
    for it in items:
        out, prompt = it["out"], it["prompt"]
        lim = limit_of(it["label"], prompt)
        is_silent = (lim == 0)
        flags = []

        ok, bad = check(out)
        if any(b[0] == "簡體字" for b in bad):
            n_simp += 1
            flags.append("簡體")
        if any(b[0] == "大陸用語" for b in bad):
            n_word += 1
            flags.append("用語")

        # 編造數字：輸出的數字必須在輸入裡出現過
        newnum = [x for x in re.findall(r"\d+", out) if x not in prompt]
        if newnum:
            n_num += 1
            flags.append("編造數字%s" % newnum)

        if is_silent:
            sil_tot += 1
            if "<silent>" in out:
                sil_ok += 1
            else:
                flags.append("該閉嘴卻講話")
        else:
            # 字數不算標點（09-24 的建議規格：唸出來的時間才是約束）
            body = re.sub(r"[，。、！？；：「」（）,.!?;:\"'()\s]", "", out)
            if lim is not None and len(body) > lim:
                n_len += 1
                flags.append("超字數 %d>%d" % (len(body), lim))
        rows.append((it["label"], out, flags))

    nonsil = n - sil_tot
    return {
        "n": n, "rows": rows,
        "編造數字": "%d/%d (%.0f%%)" % (n_num, n, n_num / n * 100),
        "含簡體": "%d/%d (%.0f%%)" % (n_simp, n, n_simp / n * 100),
        "大陸用語": "%d/%d (%.0f%%)" % (n_word, n, n_word / n * 100),
        "該閉嘴而閉嘴": "%d/%d" % (sil_ok, sil_tot),
        "超字數": "%d/%d (%.0f%%)" % (n_len, nonsil, (n_len / nonsil * 100) if nonsil else 0),
    }


def main():
    src = sys.argv[1]
    dst = sys.argv[2] if len(sys.argv) > 2 else None
    items, raw = parse(src)
    if not items:
        print("PARSE_FAILED: 0 items")
        return
    r = score(items)

    b = []
    b.append("# 手機端新架構複測評分\n")
    b.append("來源：`%s`（%d 題）\n" % (os.path.basename(src), r["n"]))
    b.append("\n## 與筆電基線對照\n")
    b.append("| 指標 | **S21 `.litertlm` q8** | 筆電 Ollama Q4_K_M |")
    b.append("|---|---|---|")
    for k in ["編造數字", "含簡體", "該閉嘴而閉嘴", "超字數"]:
        b.append("| %s | **%s** | %s |" % (k, r[k], BASELINE.get(k, "—")))
    b.append("| 大陸用語 | **%s** | — |" % r["大陸用語"])
    b.append("\n> ⚠️ 兩邊條件不完全相同：筆電用 system/user/assistant 分開的 message 與 3 個 few-shot 輪次；")
    b.append("> 手機探針把 system prompt 與 few-shot **串成單一 user message**（`main.dart` 的 `_run()`）。")
    b.append("> 若手機明顯較差，先排除這個差異，再下「手機不行」的結論。\n")
    b.append("\n## 逐題\n")
    b.append("| 題目 | 輸出 | 問題 |")
    b.append("|---|---|---|")
    for label, out, flags in r["rows"]:
        mark = "OK" if not flags else "、".join(flags)
        b.append("| %s | %s | %s |" % (label, out.replace("|", "\\|"), mark))

    text = "\n".join(b) + "\n"
    if dst:
        io.open(dst, "w", encoding="utf-8").write(text)
        print("WROTE %s" % dst)
    else:
        io.open("score_out.md", "w", encoding="utf-8").write(text)
        print("WROTE score_out.md")


if __name__ == "__main__":
    main()
