"""把 settlements.xlsx 同步成 settlements.json（游戏读的表）。

用法：双击 tools/sync_settlements.bat，或
  python ias/tools/sync_settlements.py
"""
import json
import shutil
import sys
from pathlib import Path

from openpyxl import load_workbook

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "ias-core" / "data"
CFG = DATA / "settlements"
CFG.mkdir(parents=True, exist_ok=True)
XLSX = CFG / "settlements.xlsx"
JSON = CFG / "settlements.json"
BACKUP = CFG / "settlements.bak.json"

TYPES = {"capital", "city", "town", "village", "fort", "ruins"}
COLS = ["id", "name", "type", "civ", "lon", "lat", "tier", "icon", "image", "note"]


def main() -> int:
    if not XLSX.exists():
        print("找不到", XLSX)
        return 1
    try:
        wb = load_workbook(XLSX, read_only=True, data_only=True)
    except PermissionError:
        print("表格正被 Excel 打开，请先保存并关闭，再运行。")
        return 1
    ws = wb.active
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        print("表格是空的")
        return 1
    head = [str(c).strip() if c else "" for c in rows[0]]
    try:
        idx = {c: head.index(c) for c in COLS}
    except ValueError as e:
        print("表头缺列：", e, "\n需要：", " ".join(COLS))
        return 1

    out, errors, seen = [], [], set()
    for n, r in enumerate(rows[1:], start=2):
        if not r or all(v is None or str(v).strip() == "" for v in r):
            continue
        rec = {}
        for c in COLS:
            v = r[idx[c]] if idx[c] < len(r) else None
            rec[c] = "" if v is None else (v.strip() if isinstance(v, str) else v)
        rid = str(rec["id"]).strip()
        if not rid:
            errors.append(f"第{n}行：id 为空")
            continue
        if rid in seen:
            errors.append(f"第{n}行：id 重复（{rid}）")
            continue
        seen.add(rid)
        t = str(rec["type"]).strip().lower()
        if t not in TYPES:
            errors.append(f"第{n}行：type '{t}' 不合法（{ '/'.join(sorted(TYPES)) }）")
            continue
        try:
            lon = float(rec["lon"]); lat = float(rec["lat"])
        except (TypeError, ValueError):
            errors.append(f"第{n}行：经纬度不是数字")
            continue
        if not (-180 <= lon <= 180 and -90 <= lat <= 90):
            errors.append(f"第{n}行：经纬度越界 ({lon}, {lat})")
            continue
        try:
            tier = int(rec["tier"]) if str(rec["tier"]).strip() != "" else 2
        except ValueError:
            tier = 2
        out.append({
            "id": rid, "name": str(rec["name"]), "type": t,
            "civ": str(rec["civ"]), "lon": lon, "lat": lat, "tier": tier,
            "icon": str(rec["icon"]), "image": str(rec["image"]), "note": str(rec["note"]),
        })

    if errors:
        print("发现 %d 个问题，未写入：" % len(errors))
        for e in errors[:20]:
            print("  -", e)
        return 1

    if JSON.exists():
        shutil.copyfile(JSON, BACKUP)
    JSON.write_text(json.dumps({"_comment": "由 settlements.xlsx 同步生成", "version": 1,
                                "settlements": out}, ensure_ascii=False, indent=1),
                    encoding="utf-8")
    kinds = {}
    for r in out:
        kinds[r["type"]] = kinds.get(r["type"], 0) + 1
    print("已写入 %d 条：%s" % (len(out), "，".join(f"{k} {v}" for k, v in sorted(kinds.items()))))
    print("切回游戏、打开地图即可生效。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
