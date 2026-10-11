# -*- coding: utf-8 -*-
"""任務 A 的狀態輸入產生器（笛卡兒積 + 抽樣）。
本檔案由 Claude 於 2026-09-24 撰寫。
設計依據：SFT 方法論審查 §4.2-3「輸入端多樣性由程式保證，不由老師保證」。
"""
import itertools, random

CO2   = [("420","正常"),("880","偏高"),("1340","偏高"),("1980","高"),("2600","很高")]
TREND = [("↑↑","快速上升"),("↑","上升"),("→","持平"),("↓","下降")]
TIN   = ["18","22","26","30","34"]
TOUT  = ["4","12","24","31","38"]
RECIRC= ["內","外"]
OCC   = ["1","2","4"]
SPEED = ["0","35","90","110"]

# 領域專家審查：緊急度決定字數，不是固定 25 字
URGENCY = {
    "safety":   ("安全",   8),   # 危急，愈短愈好
    "proactive":("主動告知",15),  # 系統主動說話，要克制
    "reply":    ("回答",   30),  # 使用者問了才答，可以長一點
    "silent":   ("不說話", 0),   # 一等公民：什麼都不說
}

def sample(n, seed=42):
    random.seed(seed)
    pool = list(itertools.product(CO2, TREND, TIN, TOUT, RECIRC, OCC, SPEED))
    random.shuffle(pool)
    out = []
    for (co2,co2l),(tr,trl),tin,tout,rec,occ,spd in pool[:n]:
        out.append({
            "co2": co2, "co2_label": co2l, "trend": tr, "trend_label": trl,
            "t_in": tin, "t_out": tout, "recirc": rec, "occ": occ, "speed": spd,
        })
    return out

def decide(s):
    """規則引擎（簡化版）：算出決策、緊急度、代價。SLM 不做這一步。"""
    co2 = int(s["co2"]); tin = int(s["t_in"]); tout = int(s["t_out"])
    spd = int(s["speed"]); rising = s["trend"] in ("↑","↑↑")
    delta = tout - tin

    if co2 >= 2500:
        act, urg, why = "立即切換外循環", "safety", f"CO2 {co2} 已達嗜睡風險"
    elif co2 >= 1500 and rising:
        act, urg, why = "切換外循環", "proactive", f"CO2 {co2} 偏高且仍在上升"
    elif co2 >= 1500:
        act, urg, why = "切換外循環", "proactive", f"CO2 {co2} 偏高"
    elif co2 >= 800 and rising and s["recirc"] == "內":
        act, urg, why = "建議稍後換氣", "proactive", f"CO2 {co2} 上升中"
    else:
        act, urg, why = "維持現狀", "silent", "各項數值正常"

    # 代價：由規則引擎算，不讓 SLM 編（領域專家審查的要求）
    cost = ""
    if act.endswith("外循環") and abs(delta) >= 6:
        cost = f"車內將{'升溫' if delta > 0 else '降溫'}約{min(abs(delta)//2, 5)}度"
    if s["recirc"] == "外" and act.endswith("外循環"):
        act, urg, cost, why = "維持現狀", "silent", "", "已經是外循環"
    return {"action": act, "urgency": urg, "reason": why, "cost": cost,
            "speed": spd, "limit": URGENCY[urg][1]}

def render(s, d):
    return (f"狀態: co2={s['co2']}{s['trend']} 車內={s['t_in']} 車外={s['t_out']} "
            f"循環={s['recirc']} 乘員={s['occ']} 車速={s['speed']}\n"
            f"決策: {d['action']} | 原因={d['reason']}" + (f" | 代價={d['cost']}" if d['cost'] else "") + "\n"
            f"緊急度: {URGENCY[d['urgency']][0]} | 上限: {d['limit']}字")

if __name__ == "__main__":
    ss = sample(300)
    from collections import Counter
    c = Counter(decide(s)["urgency"] for s in ss)
    print("300 組抽樣的緊急度分布:", dict(c))
    print(f"→ 其中『不說話』佔 {c['silent']/3:.1f}%\n")
    for s in ss[:4]:
        print(render(s, decide(s))); print("-"*50)
