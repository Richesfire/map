# -*- coding: utf-8 -*-
"""把 data/biomes/*.tres 规范成"编号 = 地貌号"的 29 份。

历史原因：make_biome_tres.gd 被用不同的 DEFAULTS 顺序跑过，目录里留下了
重名批次的文件（17_delta_wet 和 17_hill_red 并存，共 36 个）。加载端以前按
文件名排序取下标，于是 18..28 号地貌全部拿到隔壁的配置。

这个脚本不改内容，只改名 + 删多余的：按 id 找到文件，改成 NN_<id>.tres
（NN = biome_library.gd 里 LF_PROFILE 的地貌编号），不属于这 29 个名字的删掉。

用法：python ias/tools/canon_biome_tres.py [--dry]
"""
import re
import sys
from pathlib import Path

ORDER = [
    "plain_open", "hill_rolling", "mountain_mid", "plateau_steppe", "basin_flat",
    "valley_wide", "desert_sand", "steppe_temp", "forest_plain", "wetland_marsh",
    "ice_glacier", "coast_beach", "karst_cone", "yardang", "loess_yuan",
    "dune_sand", "glacial_valley", "delta_wet", "mtn_granite", "mtn_karst",
    "mtn_loess", "mtn_volcanic", "mtn_ice", "hill_red", "hill_loess",
    "hill_danxia", "desert_sand2", "desert_gobi", "desert_salt",
]
ID_RE = re.compile(r'^id = "([^"]*)"', re.M)


def main() -> int:
    dry = "--dry" in sys.argv[1:]
    root = Path(__file__).resolve().parents[2]
    folder = root / "ias-core" / "data" / "biomes"
    files = sorted(folder.glob("*.tres"))
    print(f"[规范化] {folder}：{len(files)} 个 .tres")

    by_id = {}
    for f in files:
        text = f.read_text(encoding="utf-8")
        m = ID_RE.search(text)
        if not m:
            print(f"  ! {f.name} 没有 id，跳过")
            continue
        by_id.setdefault(m.group(1), []).append(f)

    keep = set()
    for i, pid in enumerate(ORDER):
        if pid not in by_id:
            print(f"  ! 缺少配置 {pid}（编号 {i}），跳过")
            continue
        target = folder / f"{i:02d}_{pid}.tres"
        keep.add(target.name)
        srcs = by_id[pid]
        src = next((s for s in srcs if s.name == target.name), srcs[0])
        if src.name == target.name:
            print(f"  = {target.name}")
            continue
        print(f"  → {src.name} -> {target.name}")
        if not dry:
            target.write_bytes(src.read_bytes())

    for f in files:
        if f.name not in keep:
            print(f"  - 删除 {f.name}")
            if not dry:
                f.unlink()

    left = sorted(folder.glob("*.tres"))
    print(f"[规范化] 完成：{len(left)} 个文件")
    for f in left:
        print("   ", f.name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
