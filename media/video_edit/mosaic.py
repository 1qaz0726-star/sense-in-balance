# 面紙包（彩色圓點＋品牌字）逐幀偵測後打馬賽克
# 判斷：同一塊區域同時有「粉紅、綠、橘」三種高飽和色點 → 面紙包；其他東西（紅卡、粉紅線、儀表）不會三色同時出現
import cv2, numpy as np, subprocess, sys, os

def detect(frame):
    h, w = frame.shape[:2]
    hsv = cv2.cvtColor(frame, cv2.COLOR_BGR2HSV)
    H, S, V = hsv[..., 0].astype(int), hsv[..., 1], hsv[..., 2]
    sat = (S > 90) & (V > 110)
    pink = sat & (H >= 150) & (H <= 175)
    green = sat & (H >= 35) & (H <= 85)
    orange = sat & (H >= 8) & (H <= 25)
    cyan = sat & (H >= 86) & (H <= 105)
    anyc = (pink | green | orange | cyan).astype(np.uint8) * 255
    roi = np.zeros_like(anyc); roi[:, : int(w * 0.62)] = 255   # 面紙只在畫面左半
    anyc = cv2.bitwise_and(anyc, roi)
    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (61, 61))
    blob = cv2.morphologyEx(anyc, cv2.MORPH_CLOSE, k)
    n, lab, stats, _ = cv2.connectedComponentsWithStats(blob)
    best = None
    for i in range(1, n):
        x, y, bw, bh, area = stats[i]
        if area < 1500: continue
        m = lab[y:y+bh, x:x+bw] == i
        cnt = [int((c[y:y+bh, x:x+bw] & m).sum()) for c in (pink, green, orange)]
        if sum(c > 60 for c in cnt) >= 2 and (best is None or area > best[4]):
            best = (x, y, bw, bh, area)
    if best is None: return None
    x, y, bw, bh, _ = best
    px, py = int(bw * 0.15) + 18, int(bh * 0.15) + 18
    return (max(0, x - px), max(0, y - py), min(w, x + bw + px), min(h, y + bh + py))

def pixelate(frame, box, block=28):
    x1, y1, x2, y2 = box
    roi = frame[y1:y2, x1:x2]
    if roi.size == 0: return frame
    small = cv2.resize(roi, (max(1, (x2-x1)//block), max(1, (y2-y1)//block)), interpolation=cv2.INTER_LINEAR)
    frame[y1:y2, x1:x2] = cv2.resize(small, (x2-x1, y2-y1), interpolation=cv2.INTER_NEAREST)
    return frame

def process(src, dst, preview=None):
    cap = cv2.VideoCapture(src)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30
    boxes = []
    while True:
        ok, f = cap.read()
        if not ok: break
        h, w = f.shape[:2]
        boxes.append(detect(f))
    cap.release()
    n = len(boxes); filled = list(boxes)
    for i in range(n):
        if filled[i] is None:
            for d in range(1, 16):
                for j in (i - d, i + d):
                    if 0 <= j < n and boxes[j] is not None:
                        filled[i] = boxes[j]; break
                if filled[i] is not None: break
    hits = sum(b is not None for b in boxes)
    out = []
    for i in range(n):
        win = [b for b in filled[max(0, i-7): i+8] if b is not None]
        out.append(None if not win else (min(b[0] for b in win), min(b[1] for b in win), max(b[2] for b in win), max(b[3] for b in win)))
    p = subprocess.Popen(['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'bgr24', '-s', f'{w}x{h}', '-r', '30', '-i', '-',
                          '-i', src, '-map', '0:v', '-map', '1:a', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '18', '-pix_fmt', 'yuv420p',
                          '-c:a', 'copy', '-shortest', dst], stdin=subprocess.PIPE)
    cap = cv2.VideoCapture(src)
    for i in range(n):
        ok, f = cap.read()
        if not ok: break
        if out[i]: f = pixelate(f, out[i])
        if preview and i == n // 2: cv2.imwrite(preview, cv2.resize(f, (960, 540)))
        p.stdin.write(f.tobytes())
    p.stdin.close(); p.wait()
    return hits, n

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    print(process(src, dst, sys.argv[3] if len(sys.argv) > 3 else None))
