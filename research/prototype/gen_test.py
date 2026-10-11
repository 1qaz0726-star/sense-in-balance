# -*- coding: utf-8 -*-
"""DeepSeek 老師品質控制實驗。本檔案由 Claude 於 2026-09-24 撰寫。
問題：用簡體母語的模型教台灣用語，違規率多高？負面指令有沒有用？
"""
import json, os, pathlib, random, sys, time, requests
from states import sample, decide, render, URGENCY
from tw_lexicon import check

KEY = os.environ["DEEPSEEK_API_KEY"]  # 金鑰從環境變數讀取，不放進版控
URL = "https://api.deepseek.com/chat/completions"

BASE = """你是車用語音助理的文案產生器。我會給你「已經決策完成」的座艙狀態，
你只負責把決策講成一句給駕駛聽的話。你不需要做任何判斷或計算。

規則：
- 只輸出那一句話本身，不要解釋、不要引號、不要編號。
- 嚴格遵守字數上限。
- 不可以出現任何輸入裡沒有的數字。
- 緊急度是「不說話」時，只輸出 <silent>。"""

TW_RULE = """
- 必須是台灣人在車上會講的繁體中文口語。
- 禁用詞（大陸用語）：厘米、質量、信息、視頻、默認、打印、軟件、存儲、點擊、
  網絡、程序、數據、優化、激活、屏幕、傳感器、攝像頭、儀表盤、剎車、智能、
  空調（可用「冷氣」）、請您、為您。
- 不要客套、不要條列、不要反問、不要複讀輸入。"""

def build(states):
    lines = []
    for i, (s, d) in enumerate(states, 1):
        lines.append(f"【第{i}組】\n{render(s, d)}")
    return "\n\n".join(lines) + f"\n\n請依序輸出 {len(states)} 句，每行一句，格式為「編號. 句子」。"

def run(tag, sys_prompt, states, model="deepseek-flash"):
    body = {"model": model, "temperature": 1.0, "top_p": 0.95,
            "messages": [{"role": "system", "content": sys_prompt},
                         {"role": "user", "content": build(states)}]}
    t0 = time.time()
    r = requests.post(URL, headers={"Authorization": f"Bearer {KEY}"}, json=body, timeout=180)
    dt = time.time() - t0
    if not r.ok:
        print(f"[{tag}] HTTP {r.status_code}: {r.text[:300]}"); return None
    j = r.json()
    txt = j["choices"][0]["message"]["content"]
    u = j["usage"]
    return {"tag": tag, "text": txt, "usage": u, "sec": dt, "model": model}

def analyse(res, states):
    lines = [l.strip() for l in res["text"].splitlines() if l.strip()]
    rows, nbad, nlen, nsil_ok, nsil_tot = [], 0, 0, 0, 0
    for i, (s, d) in enumerate(states):
        out = lines[i] if i < len(lines) else ""
        out = out.split(".", 1)[-1].strip() if out[:2].rstrip(".").isdigit() else out
        ok, bad = check(out)
        limit = d["limit"]
        if d["urgency"] == "silent":
            nsil_tot += 1
            if "<silent>" in out: nsil_ok += 1
        else:
            if len(out) > limit: nlen += 1
        if not ok: nbad += 1
        rows.append((out, limit, ok, bad, d["urgency"]))
    return rows, nbad, nlen, nsil_ok, nsil_tot

if __name__ == "__main__":
    ss = sample(400, seed=7)
    pairs = [(s, decide(s)) for s in ss]
    # 刻意各取一些，讓測試涵蓋三種緊急度
    byu = {}
    for p in pairs: byu.setdefault(p[1]["urgency"], []).append(p)
    pick = byu["safety"][:7] + byu["proactive"][:7] + byu["silent"][:6]
    random.seed(1); random.shuffle(pick)
    print(f"測試樣本 {len(pick)} 組（safety 7 / proactive 7 / silent 6）\n")

    total_cost_tok = {"in": 0, "out": 0}
    for tag, sp in [("A_無台灣指令", BASE), ("B_有台灣指令", BASE + TW_RULE)]:
        res = run(tag, sp, pick)
        if not res: continue
        rows, nbad, nlen, nsok, nstot = analyse(res, pick)
        total_cost_tok["in"] += res["usage"]["prompt_tokens"]
        total_cost_tok["out"] += res["usage"]["completion_tokens"]
        print(f"===== {tag} ({res['model']}, {res['sec']:.1f}s) =====")
        print(f"  用語違規: {nbad}/{len(pick)} = {nbad/len(pick)*100:.0f}%")
        print(f"  超字數  : {nlen}/{len(pick)-nstot}")
        print(f"  該閉嘴而閉嘴: {nsok}/{nstot}")
        print(f"  token: in={res['usage']['prompt_tokens']} out={res['usage']['completion_tokens']}")
        for out, lim, ok, bad, urg in rows[:8]:
            m = "✅" if ok and (urg=="silent" or len(out)<=lim) else "❌"
            print(f"  {m} [{urg[:4]}≤{lim}字|實{len(out)}] {out[:44]}")
            for b in bad[:3]: print(f"        ⚠ {b[0]}:{b[1]}")
        print()
        json.dump({"tag":tag,"rows":[[r[0],r[1],r[2],r[4]] for r in rows]},
                  open(f"out_{tag}.json","w",encoding="utf-8"), ensure_ascii=False, indent=1)
    print(f"本次總 token: 輸入 {total_cost_tok['in']}, 輸出 {total_cost_tok['out']}")
