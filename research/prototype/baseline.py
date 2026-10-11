# -*- coding: utf-8 -*-
"""基線實驗 B1/B2：未微調的 Qwen 拿到「已決策」提示 + few-shot，表現如何？
本檔案由 Claude 於 2026-09-24 撰寫。
依據：SFT 方法論審查 §5.4「如果 B1 就夠好，你不需要蒸餾，只需要改提示」。
"""
import json, sys, time, requests
from states import sample, decide, render
from tw_lexicon import check

OLLAMA = "http://localhost:11434/api/chat"

SYS = """你是車用語音助理。我會給你「已經決策完成」的座艙狀態，
你只負責把決策講成一句給駕駛聽的話。你不需要做任何判斷或計算。

規則：
- 只輸出那一句話本身，不要解釋、不要引號、不要編號。
- 嚴格遵守字數上限。
- 不可以出現任何輸入裡沒有的數字。
- 緊急度是「不說話」時，只輸出 <silent>。
- 必須是台灣人在車上會講的繁體中文口語。
- 禁用大陸用語：厘米、質量、信息、視頻、默認、數據、屏幕、傳感器、智能、請您、為您。
- 不要客套、不要條列、不要反問、不要複讀輸入。"""

FEWSHOT = [
    ("狀態: co2=1980↑ 車內=26 車外=31 循環=內 乘員=2 車速=90\n"
     "決策: 切換外循環 | 原因=CO2 1980 偏高且仍在上升 | 代價=車內將升溫約2度\n"
     "緊急度: 主動告知 | 上限: 15字", "二氧化碳偏高，切外循環會稍微變熱"),
    ("狀態: co2=2600↑↑ 車內=22 車外=12 循環=內 乘員=4 車速=110\n"
     "決策: 立即切換外循環 | 原因=CO2 2600 已達嗜睡風險\n"
     "緊急度: 安全 | 上限: 8字", "快切外循環，會想睡"),
    ("狀態: co2=420→ 車內=22 車外=24 循環=外 乘員=1 車速=35\n"
     "決策: 維持現狀 | 原因=各項數值正常\n"
     "緊急度: 不說話 | 上限: 0字", "<silent>"),
]

def ask(model, prompt):
    msgs = [{"role": "system", "content": SYS}]
    for u, a in FEWSHOT:
        msgs += [{"role": "user", "content": u}, {"role": "assistant", "content": a}]
    msgs.append({"role": "user", "content": prompt})
    r = requests.post(OLLAMA, json={"model": model, "messages": msgs, "stream": False,
                                    "options": {"temperature": 0, "num_predict": 64}}, timeout=180)
    r.raise_for_status()
    return r.json()["message"]["content"].strip()

def evaluate(model, pairs):
    nbad = nsimp = nlen = nsil_ok = nsil_tot = nnum = 0
    rows = []
    t0 = time.time()
    for s, d in pairs:
        try:
            out = ask(model, render(s, d))
        except Exception as e:
            out = f"<ERR {e}>"
        ok, bad = check(out)
        if not ok: nbad += 1
        if any(b[0] == "簡體字" for b in bad): nsimp += 1
        # 事實一致性：輸出的數字必須出現在輸入裡
        import re
        src = render(s, d)
        newnum = [x for x in re.findall(r"\d+", out) if x not in src]
        if newnum: nnum += 1
        if d["urgency"] == "silent":
            nsil_tot += 1
            if "<silent>" in out: nsil_ok += 1
        else:
            if len(out) > d["limit"]: nlen += 1
        rows.append({"in": src, "out": out, "urg": d["urgency"], "lim": d["limit"],
                     "ok": ok, "newnum": newnum})
    dt = time.time() - t0
    n = len(pairs)
    return {"model": model, "n": n, "sec": round(dt,1),
            "用語違規": nbad, "含簡體": nsimp, "超字數": nlen,
            "編造數字": nnum, "該閉嘴而閉嘴": f"{nsil_ok}/{nsil_tot}", "rows": rows}

if __name__ == "__main__":
    ss = sample(400, seed=7)
    pairs = [(s, decide(s)) for s in ss]
    byu = {}
    for p in pairs: byu.setdefault(p[1]["urgency"], []).append(p)
    pick = byu["safety"][:10] + byu["proactive"][:10] + byu["silent"][:10]
    print(f"基線測試 {len(pick)} 題（safety 10 / proactive 10 / silent 10）\n")
    for model in sys.argv[1:]:
        r = evaluate(model, pick)
        print(f"===== {model}  ({r['sec']}s / {r['n']}題) =====")
        for k in ["用語違規","含簡體","超字數","編造數字","該閉嘴而閉嘴"]:
            v = r[k]
            print(f"  {k:<8}: {v}" + (f"  ({v/r['n']*100:.0f}%)" if isinstance(v,int) else ""))
        for row in r["rows"][:10]:
            mark = "✅" if row["ok"] and not row["newnum"] and (row["urg"]=="silent" or len(row["out"])<=row["lim"]) else "❌"
            print(f"  {mark} [{row['urg'][:4]}≤{row['lim']}|實{len(row['out'])}] {row['out'][:50]}")
        json.dump(r, open(f"base_{model.replace(':','_')}.json","w",encoding="utf-8"), ensure_ascii=False, indent=1)
        print()
