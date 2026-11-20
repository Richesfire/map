"""把四份地点数据合并成一张干净的表（settlements.json / settlements.xlsx）。

用法（项目根目录）：
  python ias/tools/merge_settlements.py

输出：
  ias-core/data/settlements.json   游戏读的配置表
  ias-core/data/settlements.xlsx   给你改的表格
"""
import json
from pathlib import Path

from openpyxl import Workbook

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "ias-core" / "data"
CFG = DATA / "settlements"

KIND2TYPE = {
    "城": "city", "关": "fort", "邑": "village", "津": "fort", "渡": "fort",
    "镇": "town", "村": "village", "都": "capital",
}
COLS = ["id", "name", "type", "civ", "lon", "lat", "tier", "icon", "image", "note"]


def load(name, key):
    p = DATA / name
    if not p.exists():
        print("缺少", name)
        return []
    return json.loads(p.read_text(encoding="utf-8"))[key]


def main():
    rows = []
    # ① 3D 手作城（最高优先级）
    for c in load("cities.json", "cities"):
        rows.append({
            "id": c["id"], "name": c["name"],
            "type": "capital" if c["name"] == "咸阳" else "city",
            "civ": "", "lon": c["lon"], "lat": c["lat"], "tier": 1,
            "icon": "", "image": "", "note": c.get("note", ""),
            "_pri": 0, "_src": "cities",
        })
    # ② 史事点位
    for s in load("sites_han.json", "sites"):
        rows.append({
            "id": s["id"], "name": s["name"],
            "type": KIND2TYPE.get(s.get("kind", "城"), "village"),
            "civ": "", "lon": s["lon"], "lat": s["lat"], "tier": 2,
            "icon": "", "image": "", "note": s.get("src", ""),
            "_pri": 1, "_src": "sites",
        })
    # ③ 汉县
    for i, s in enumerate(load("counties_han.json", "counties")):
        rows.append({
            "id": "han_%04d" % i, "name": s["n"],
            "type": "village", "civ": "",
            "lon": s["lon"], "lat": s["lat"], "tier": 3,
            "icon": "", "image": "", "note": s.get("loc", ""),
            "_pri": 2, "_src": "counties",
        })
    # ④ 域外
    for i, s in enumerate(load("world_settlements.json", "settlements")):
        t = int(s.get("tier", 2))
        rows.append({
            "id": "w_%04d" % i, "name": s["name"],
            "type": "city" if t == 1 else ("town" if t == 2 else "village"),
            "civ": s.get("region", ""), "lon": s["lon"], "lat": s["lat"],
            "tier": t, "icon": "", "image": "",
            "note": s.get("note", ""), "_pri": 3, "_src": "world",
        })

    # 去重：同名 + 坐标 0.05° 内，保留优先级高的
    rows.sort(key=lambda r: r["_pri"])
    kept = []
    for r in rows:
        dup = False
        for k in kept:
            if k["name"] == r["name"] and abs(k["lon"] - r["lon"]) < 0.05 and abs(k["lat"] - r["lat"]) < 0.05:
                dup = True
                break
        if not dup:
            kept.append(r)

    for r in kept:
        r.pop("_pri", None)
        r.pop("_src", None)
    CFG.joinpath("settlements.json").write_text(
        json.dumps({"_comment": "由 merge_settlements.py 生成；改表请用 settlements.xlsx + sync_settlements.bat",
                    "version": 1, "settlements": kept}, ensure_ascii=False, indent=1),
        encoding="utf-8")
    print("settlements.json", len(kept), "条")

    wb = Workbook()
    ws = wb.active
    ws.title = "settlements"
    ws.append(COLS)
    for r in kept:
        ws.append([r.get(c, "") for c in COLS])
    ws.freeze_panes = "A2"
    CFG.mkdir(parents=True, exist_ok=True)
    wb.save(CFG / "settlements.xlsx")
    print("settlements.xlsx", len(kept), "行")


if __name__ == "__main__":
    main()
