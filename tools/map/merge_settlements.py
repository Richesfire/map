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
FACTIONS = {
    "咸阳": ("秦", "capital"), "雒阳": ("秦", "city"), "晋阳": ("秦", "city"),
    "成都": ("秦", "city"), "宛": ("秦", "city"), "陈": ("秦", "city"),
    "琅琊": ("秦", "city"), "邯郸": ("赵", "capital"), "巨鹿": ("赵", "city"),
    "临淄": ("齐", "capital"), "寿春": ("楚", "capital"), "郢": ("楚", "city"),
    "彭城": ("楚", "city"), "薛": ("楚", "city"), "会稽": ("楚", "city"),
    "蓟": ("燕", "capital"),
}
WORLD_FACTION = {
    "意大利": "罗马", "西西里": "罗马", "伊比利亚": "迦太基", "北非": "迦太基",
    "希腊": "马其顿", "爱琴海": "马其顿", "黑海": "马其顿",
    "西亚": "塞琉古", "埃及": "托勒密", "南亚": "孔雀", "中亚": "大夏",
    "高卢": "高卢", "阿拉伯": "纳巴泰", "东亚": "匈奴", "中美洲": "玛雅",
}
# 各势力都城（按名字指定）
WORLD_CAPITAL = {
    "罗马": "罗马", "马其顿": "佩拉", "塞琉古": "安条克", "托勒密": "亚历山大",
    "迦太基": "迦太基", "孔雀": "华氏城", "大夏": "巴克特拉", "纳巴泰": "佩特拉",
}
# 补中国缺的两个都城
EXTRA_CITIES = [
    {"id": "daliang", "name": "大梁", "lon": 114.34, "lat": 34.79, "faction": "魏", "type": "capital"},
    {"id": "xinzheng", "name": "新郑", "lon": 113.74, "lat": 34.39, "faction": "韩", "type": "capital"},
]
COLS = ["id", "name", "type", "faction", "rank", "lon", "lat", "icon", "image", "note"]


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
        fac, typ = FACTIONS.get(c["name"], ("", "city"))
        rows.append({
            "id": c["id"], "name": c["name"], "type": typ,
            "faction": fac, "rank": 1,
            "lon": c["lon"], "lat": c["lat"],
            "icon": "", "image": "", "note": c.get("note", ""),
            "_pri": 0, "_src": "cities",
        })
    for e in EXTRA_CITIES:
        rows.append({**e, "rank": 2, "icon": "", "image": "", "note": "", "_pri": 1, "_src": "extra"})
    # ② 史事点位
    for s in load("sites_han.json", "sites"):
        rows.append({
            "id": s["id"], "name": s["name"],
            "type": KIND2TYPE.get(s.get("kind", "城"), "village"),
            "faction": "", "rank": 2, "lon": s["lon"], "lat": s["lat"],
            "icon": "", "image": "", "note": s.get("src", ""),
            "_pri": 1, "_src": "sites",
        })
    # ③ 汉县
    for i, s in enumerate(load("counties_han.json", "counties")):
        rows.append({
            "id": "han_%04d" % i, "name": s["n"],
            "type": "village", "faction": "", "rank": 3,
            "lon": s["lon"], "lat": s["lat"],
            "icon": "", "image": "", "note": s.get("loc", ""),
            "_pri": 2, "_src": "counties",
        })
    # ④ 域外
    for i, s in enumerate(load("world_settlements.json", "settlements")):
        t = int(s.get("tier", 2))
        fac = WORLD_FACTION.get(s.get("region", ""), s.get("region", ""))
        is_cap = WORLD_CAPITAL.get(fac) == s["name"]
        rows.append({
            "id": "w_%04d" % i, "name": s["name"],
            "type": "capital" if is_cap else ("city" if t == 1 else ("town" if t == 2 else "village")),
            "faction": fac, "rank": t, "lon": s["lon"], "lat": s["lat"],
            "icon": "", "image": "",
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
    DATA.joinpath("settlements.json").write_text(
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
    (ROOT / "配置表").mkdir(parents=True, exist_ok=True)
    wb.save(ROOT / "配置表" / "settlements.xlsx")
    print("settlements.xlsx", len(kept), "行")


if __name__ == "__main__":
    main()
