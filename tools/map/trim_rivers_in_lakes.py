"""把落在湖面里的河段剔掉（河进湖就不再画线，视觉上融进湖里）。

用法：python tools/map/trim_rivers_in_lakes.py
直接改 game/data/raw/hydro.json，改前自动备份 .bak。
"""
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HYDRO = ROOT / "game" / "data" / "raw" / "hydro.json"


def in_poly(pt, poly):
    x, y = pt
    inside = False
    n = len(poly)
    j = n - 1
    for i in range(n):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y):
            x_cross = (xj - xi) * (y - yi) / (yj - yi + 1e-12) + xi
            if x < x_cross:
                inside = not inside
        j = i
    return inside


def main():
    d = json.loads(HYDRO.read_text(encoding="utf-8"))
    lakes = d.get("lakes", [])
    removed = 0
    for r in d["rivers"]:
        pts = r["p"]
        keep = []
        for p in pts:
            hit = False
            for l in lakes:
                lp = l["p"]
                if len(lp) < 3:
                    continue
                # 先按包围盒快速排除
                xs = [q[0] for q in lp]
                ys = [q[1] for q in lp]
                if not (min(xs) <= p[0] <= max(xs) and min(ys) <= p[1] <= max(ys)):
                    continue
                if in_poly(p, lp):
                    hit = True
                    break
            if hit:
                removed += 1
            else:
                keep.append(p)
        r["p"] = keep
    # 太短（<2 点）的河直接丢弃
    before = len(d["rivers"])
    d["rivers"] = [r for r in d["rivers"] if len(r["p"]) >= 2]
    shutil.copyfile(HYDRO, HYDRO.with_suffix(".json.bak"))
    HYDRO.write_text(json.dumps(d, ensure_ascii=False), encoding="utf-8")
    print("剔除湖内河点 %d 个，丢弃过短河段 %d 条" % (removed, before - len(d["rivers"])))


if __name__ == "__main__":
    main()
