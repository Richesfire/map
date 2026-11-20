# -*- coding: utf-8 -*-
"""筛掉现代水库/人工湖，只留 209 BC 之前就在的大湖。

HydroLAKES 是现代湖泊，没有"天然/水库"类型字段，只能按两条硬规则筛：
1. 面积 >= 500 km²：小湖里绝大多数是现代水库/人工湖（三峡、密云、官厅…），
   大湖基本都是天然构造湖/构造断陷湖；
2. 名字里带 Reservoir / 以及一份已知人工湖黑名单（Bratsk、Toktogul 这类
   名字里不带 Reservoir 的）。

用法：python ias/tools/filter_lakes.py [--dry]
"""
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "ias-core" / "data" / "hydro.json"
MIN_KM2 = 500.0
BLACKLIST = {
    "ijsselmeer",          # 1932 年拦海大坝形成
    "lake mead", "lake powell",
    "toktogul suu saktagychy", "toktogul",
    "bratsk reservoir", "rybinsk reservoir", "kakhovka reservoir",
    "kremenchuk reservoir", "samara reservoir", "vilyuy reservoir",
    "kainji reservoir", "nam ngum reservoir", "amistad reservoir",
    "smallwood reservoir", "cabonga reservoir", "dozois reservoir",
    "serebryanskoe reservoir", "nurek", "kapchagay", "kapchagayskoye",
    "represa de sobradinho",
    "represa de tucurui",
    "represa itaipu",
    "represa tres marias",
    "repressa de jupia",
    "lake volta",
    "lake kariba",
    "lake nasser",
    "lake argyle",
    "williston lake",
    "lake sakakawea",
    "lake oahe",
    "fort peck lake",
    "salton sea",
    "sarygamysh koli",
    "shardara",
    "buhayrat ath tharthar",
    "professor doctor ingenieur w. j. van blommestein meer",
    "reservoir manicouagan",
    "reservoir de la grande 2",
    "reservoir de la grande 3",
    "reservoir gouin",
    "reservoir pipmuacan",
    "reservoir de caniapiscau",
    "lake mead",
    "lake powell",
}
NAME_RE = re.compile(r"reservoir|水库|\bdam\b", re.I)


def area_km2(poly):
    R = 6371.0
    s = 0.0
    for i in range(len(poly)):
        lo1, la1 = map(math.radians, poly[i])
        lo2, la2 = map(math.radians, poly[(i + 1) % len(poly)])
        s += (lo2 - lo1) * (2.0 + math.sin(la1) + math.sin(la2))
    return abs(s) * R * R / 2.0


def main():
    dry = "--dry" in sys.argv
    data = json.loads(ROOT.read_text(encoding="utf-8"))
    lakes = data["lakes"]
    kept, dropped = [], []
    for l in lakes:
        a = area_km2(l["p"])
        name = l["n"].strip()
        if a < MIN_KM2:
            dropped.append((name, a, "小湖(<%.0f km²)" % MIN_KM2))
        elif NAME_RE.search(name) or name.lower() in BLACKLIST:
            dropped.append((name, a, "已知人工湖"))
        else:
            kept.append(l)
    print("湖：%d -> %d（去掉 %d）" % (len(lakes), len(kept), len(dropped)))
    for n, a, why in sorted(dropped, key=lambda x: -x[1])[:12]:
        print("  - %-30s %8.0f km²  %s" % (n[:30], a, why))
    print("留下的最小 8 个:")
    for l in sorted(kept, key=lambda x: area_km2(x["p"]))[:8]:
        print("  + %-30s %8.0f km²" % (l["n"][:30], area_km2(l["p"])))
    if dry:
        print("[dry] 未写入")
        return
    data["lakes"] = kept
    ROOT.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print("已写回", ROOT)


if __name__ == "__main__":
    main()
