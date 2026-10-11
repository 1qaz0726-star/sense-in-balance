# -*- coding: utf-8 -*-
"""依 INTERFACE.md v1.0 產生事件信封。

用途有二：
  1. 驗證 INTERFACE.md 的 schema 真的產得出來（不是紙上規格）
  2. 產樣本 JSON 給昱羲對著寫 client

用法：
    python emit.py            # 印四個情境各一則到 samples_v1.json
    python emit.py --serve    # 起 WebSocket server，每秒廣播一則（需 websockets 套件）

本檔案由 Claude 於 2026-09-29 撰寫。
"""
import io, json, os, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from states import decide

SCHEMA = "1.0"
_seq = 0


def _next_id():
    global _seq
    _seq += 1
    return "evt_%06d" % _seq


def envelope(domain, state, decision, source="L1", availability="ok", ts=None):
    return {
        "schema": SCHEMA,
        "event_id": _next_id(),
        "ts": round(ts if ts is not None else time.time(), 3),
        "source": source,
        "domain": domain,
        "state": state,
        "decision": decision,
        "availability": availability,
    }


def from_cabin_air(s, source="L1", availability="ok", ts=None):
    """把 states.py 的 sample() 單筆 + decide() 轉成 INTERFACE.md 的信封。"""
    d = decide(s)
    state = {
        "co2": int(s["co2"]), "co2_label": s["co2_label"],
        "trend": s["trend"], "trend_label": s["trend_label"],
        "t_in": int(s["t_in"]), "t_out": int(s["t_out"]),
        "recirc": s["recirc"], "occ": int(s["occ"]), "speed": int(s["speed"]),
    }
    decision = {
        "action": d["action"],
        "urgency": d["urgency"],
        "limit": d["limit"],
        "reason": d["reason"],
        "cost": d["cost"],            # 沒有就是 ""，不用 null
    }
    return envelope("cabin_air", state, decision, source, availability, ts)


def blind_spot(side, obj, ttc=None, speed=45, bbox=None, conf=None,
               source="L1", availability="ok", ts=None):
    state = {"side": side, "object": obj, "ttc_s": ttc, "speed": speed,
             "bbox": bbox, "confidence": conf}
    decision = {"action": "注意%s後方%s" % ("右" if side == "right" else "左", obj),
                "urgency": "safety", "limit": 8,
                "reason": "%s側偵測到%s" % ("右" if side == "right" else "左", obj),
                "cost": ""}
    return envelope("blind_spot", state, decision, source, availability, ts)


def query(question, online, answer_action, source="L1", availability="ok", ts=None):
    state = {"question": question, "online": online}
    decision = {"action": answer_action, "urgency": "reply", "limit": 30,
                "reason": "線上雲端回答" if online else "本地知識庫檢索",
                "cost": ""}
    return envelope("query", state, decision, source,
                    availability if online else "degraded", ts)


def slm_prompt(ev):
    """§6：由事件組出端側 SLM 的輸入文字。手機端照這個實作。"""
    s, d = ev["state"], ev["decision"]
    zh = {"safety": "安全", "proactive": "主動告知",
          "reply": "回答", "silent": "不說話"}[d["urgency"]]
    if ev["domain"] == "cabin_air":
        line1 = ("狀態: co2=%s%s 車內=%s 車外=%s 循環=%s 乘員=%s 車速=%s"
                 % (s["co2"], s["trend"], s["t_in"], s["t_out"],
                    s["recirc"], s["occ"], s["speed"]))
    elif ev["domain"] == "blind_spot":
        line1 = ("狀態: 方位=%s 物件=%s 車速=%s%s"
                 % (s["side"], s["object"], s["speed"],
                    "" if s["ttc_s"] is None else " TTC=%.1f秒" % s["ttc_s"]))
    else:
        line1 = "狀態: 提問=%s 連網=%s" % (s["question"], "是" if s["online"] else "否")
    line2 = "決策: %s | 原因=%s" % (d["action"], d["reason"])
    if d["cost"]:
        line2 += " | 代價=%s" % d["cost"]
    line3 = "緊急度: %s | 上限: %d字" % (zh, d["limit"])
    return "\n".join([line1, line2, line3])


def samples():
    base = 1790000000.0
    out = []
    # 情境 A 沉默：一切正常
    out.append(from_cabin_air(
        {"co2": "420", "co2_label": "正常", "trend": "→", "trend_label": "持平",
         "t_in": "22", "t_out": "24", "recirc": "外", "occ": "1", "speed": "35"},
        ts=base))
    # 情境 B 主動：CO2 上升
    out.append(from_cabin_air(
        {"co2": "1980", "co2_label": "高", "trend": "↑", "trend_label": "上升",
         "t_in": "26", "t_out": "31", "recirc": "內", "occ": "2", "speed": "90"},
        ts=base + 1))
    # 情境 C 安全：盲點，L2 偵測
    out.append(blind_spot("right", "機車", ttc=1.8, speed=45,
                          bbox=[0.62, 0.41, 0.19, 0.33], conf=0.87,
                          source="L2", ts=base + 2))
    # 情境 D 問答：離線
    out.append(query("冷氣濾網多久換一次？", False,
                     "這個我查不到，請參考車主手冊", ts=base + 3))
    return out


if __name__ == "__main__":
    evs = samples()
    here = os.path.dirname(os.path.abspath(__file__))
    io.open(os.path.join(here, "samples_v1.json"), "w", encoding="utf-8").write(
        json.dumps(evs, ensure_ascii=False, indent=2))
    lines = []
    for e in evs:
        lines.append("=" * 60)
        lines.append(json.dumps(e, ensure_ascii=False))
        lines.append("--- 手機端 SLM 輸入 ---")
        lines.append(slm_prompt(e))
    io.open(os.path.join(here, "samples_v1.txt"), "w", encoding="utf-8").write(
        "\n".join(lines))
    print("WROTE samples_v1.json / samples_v1.txt  (%d events)" % len(evs))
