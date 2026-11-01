# -*- coding: utf-8 -*-
"""
地形表 Excel -> 运行时 JSON 导出器

用法：
    python tools/export_terrain.py

读：  data/地形表.xlsx      ← 策划编辑的源文件
写：  godot/data/terrain_types.json   ← 游戏运行时读的

设计约定：
  * Excel 是唯一编辑源，JSON 是构建产物，**不要手改 JSON**
  * 零件编号全局唯一；同一个编号可以写进多个地形，导出后引用的还是同一个 .glb
  * 导出时会做校验，有错直接报错退出（不要让错误进到运行时）
"""

import json
import os
import sys

from openpyxl import load_workbook

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
XLSX = os.path.join(ROOT, "data", "地形表.xlsx")
OUT = os.path.join(ROOT, "godot", "data", "terrain_types.json")
PARTS_DIR = os.path.join(ROOT, "godot", "assets", "parts")

SHEET_TERRAIN = "地形"
SHEET_PARTS = "零件"
SHEET_RULES = "群系规则"

# 表头 -> 内部字段（顺序即列顺序）
TERRAIN_COLS = [
    ("序号", "index", int),
    ("id", "id", str),
    ("中文名", "name_cn", str),
    ("整合地形", "is_integrated", None),
    ("白模", "terrain_model", str),
    ("纹理集", "texture_set", str),
    ("纹理1", "tex1", str),
    ("纹理2", "tex2", str),
    ("纹理3", "tex3", str),
    ("起伏下限m", "relief_lo", float),
    ("起伏上限m", "relief_hi", float),
    ("坡度倾向", "slope_bias", str),
    ("分布区域", "distribution", str),
    ("陆面占比%", "land_share_pct", float),
    ("优先级", "priority", int),
]

PARTS_COLS = [
    ("地形id", "id", str),
    ("中文名", "name_cn", str),
    ("乔木", "trees", str),
    ("石头", "rocks", str),
    ("低矮植被", "low", str),
]


def split_list(s):
    """'树_02、树_03, 树_04' -> ['树_02','树_03','树_04']"""
    if s is None:
        return []
    s = str(s).replace("，", ",").replace("、", ",").replace("；", ",").replace(";", ",")
    return [x.strip() for x in s.split(",") if x.strip()]


def cell(row, idx):
    v = row[idx] if idx < len(row) else None
    if isinstance(v, str):
        v = v.strip()
        if v == "":
            v = None
    return v


def to_bool(v):
    if v is None:
        return False
    if isinstance(v, bool):
        return v
    return str(v).strip() in ("1", "是", "true", "TRUE", "√", "Y", "y")


def read_sheet(wb, name, cols):
    if name not in wb.sheetnames:
        raise SystemExit(f"Excel 里找不到工作表「{name}」")
    ws = wb[name]
    rows = list(ws.iter_rows(values_only=True))
    if not rows:
        raise SystemExit(f"工作表「{name}」是空的")

    header = [str(c).strip() if c is not None else "" for c in rows[0]]
    # 按表头名定位列，允许策划调整列顺序
    positions = []
    for title, key, _ in cols:
        if title not in header:
            raise SystemExit(f"工作表「{name}」缺少列「{title}」（现有列：{header}）")
        positions.append((key, header.index(title)))

    out = []
    for raw in rows[1:]:
        if all(c is None or str(c).strip() == "" for c in raw):
            continue  # 跳过空行
        rec = {}
        for key, idx in positions:
            rec[key] = cell(raw, idx)
        out.append(rec)
    return out


def main():
    if not os.path.isfile(XLSX):
        raise SystemExit(f"找不到 {XLSX}")
    wb = load_workbook(XLSX, data_only=True)

    terrain_rows = read_sheet(wb, SHEET_TERRAIN, TERRAIN_COLS)
    parts_rows = read_sheet(wb, SHEET_PARTS, PARTS_COLS)

    # ---- 群系规则（可选页）：参数名 -> 数值
    rules = {}
    if SHEET_RULES in wb.sheetnames:
        ws = wb[SHEET_RULES]
        for row in ws.iter_rows(min_row=2, values_only=True):
            if not row or row[0] is None:
                continue
            key = str(row[0]).strip()
            try:
                rules[key] = float(row[1])
            except (TypeError, ValueError):
                raise SystemExit(f"群系规则「{key}」的值不是数字：{row[1]}")

    # ---- 零件表按地形 id 归并
    parts_by_id = {}
    for r in parts_rows:
        tid = r.get("id")
        if not tid:
            continue
        parts_by_id[tid] = {
            "trees": split_list(r.get("trees")),
            "rocks": split_list(r.get("rocks")),
            "low": split_list(r.get("low")),
        }

    # ---- 组装地形
    errors = []
    types = []
    seen = set()
    for r in terrain_rows:
        tid = r.get("id")
        if not tid:
            errors.append("有一行地形没有写 id")
            continue
        if tid in seen:
            errors.append(f"地形 id 重复：{tid}")
        seen.add(tid)

        lo = r.get("relief_lo")
        hi = r.get("relief_hi")
        if lo is None or hi is None:
            errors.append(f"{tid}：起伏上下限没填")
            lo = hi = 0
        elif float(lo) > float(hi):
            errors.append(f"{tid}：起伏下限 {lo} 大于上限 {hi}")

        tex = [t for t in (r.get("tex1"), r.get("tex2"), r.get("tex3")) if t]
        p = parts_by_id.get(tid, {"trees": [], "rocks": [], "low": []})

        types.append({
            "id": tid,
            "index": int(r.get("index") or 0),
            "name_cn": r.get("name_cn") or "",
            "is_integrated": to_bool(r.get("is_integrated")),
            "terrain_model": r.get("terrain_model") or "",
            "texture_set": r.get("texture_set") or "",
            "textures": tex,
            "vegetation": p,
            "shape": {
                "relief_m": [float(lo), float(hi)],
                "slope_bias": r.get("slope_bias") or "",
            },
            "distribution": split_list(r.get("distribution")),
            "land_share_pct": float(r.get("land_share_pct") or 0),
            "priority": int(r.get("priority") or 0),
        })

    # ---- 校验零件文件是否存在
    if os.path.isdir(PARTS_DIR):
        have = {f[:-4] for f in os.listdir(PARTS_DIR) if f.endswith(".glb")}
        used = set()
        for t in types:
            v = t["vegetation"]
            for k in ("trees", "rocks", "low"):
                for pid in v[k]:
                    used.add(pid)
                    if pid not in have:
                        errors.append(f"{t['id']}：引用了不存在的零件 {pid}.glb")
        orphan = have - used
        if orphan:
            print(f"提示：有 {len(orphan)} 个 glb 没被任何地形引用：{sorted(orphan)}")
    else:
        print(f"提示：{PARTS_DIR} 不存在，跳过零件文件校验")

    if errors:
        print("导出中止，Excel 里有这些问题：")
        for e in errors:
            print("  -", e)
        sys.exit(1)

    doc = {
        "version": 2,
        "note": "本文件由 tools/export_terrain.py 从 data/地形表.xlsx 生成，不要手改。"
                "第 1 项（is_integrated=是）是策划标注的「整合地形」，由策划在 PSD 里单独制作。"
                "零件编号全局唯一，可跨地形复用。",
        "biome_rules": rules,
        "coordinate_note": "distribution 只是大致区域；真正的全球分布需要陆地/海洋掩膜 + 生物群系数据，尚未实现。",
        "terrain_types": types,
    }

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)

    # 统计
    n_parts = len({pid for t in types for k in ("trees", "rocks", "low") for pid in t["vegetation"][k]})
    shared = {}
    for t in types:
        for k in ("trees", "rocks", "low"):
            for pid in t["vegetation"][k]:
                shared.setdefault(pid, []).append(t["id"])
    shared = {k: v for k, v in shared.items() if len(v) > 1}

    print(f"导出完成 -> {OUT}")
    print(f"  地形 {len(types)} 类，引用零件 {n_parts} 个，群系规则 {len(rules)} 条")
    if shared:
        print(f"  跨地形共享 {len(shared)} 个：")
        for k, v in sorted(shared.items()):
            print(f"    {k} -> {', '.join(v)}")


if __name__ == "__main__":
    main()
