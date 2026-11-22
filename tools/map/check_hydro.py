"""水系数据体检：防止批量过滤误删主干河流。

用法：
  python tools/map/check_hydro.py

检查项：
  1. 白名单里的主干河必须存在，且点数不得少于历史下限；
  2. 报告点距 > 0.6° 的可疑河段（这些多半是数据里只有两点的假河），
     但白名单里的河即使超阈值也只警告、不视为可删；
  3. 报告入海口是否落在海里（用 dem2k 高程判断）。
"""
import json
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HYDRO = ROOT / "game" / "data" / "raw" / "hydro.json"
DEM = ROOT / "game" / "data" / "raw" / "dem2k.bin"
DEM_W, DEM_H = 16384, 8192
DEM_MIN, DEM_MAX = -11000.0, 9000.0

# 必须存在的主干河（名字 -> 最少点数）
PROTECTED = {
    "Yangtze": 100,
    "Huang": 60,
    "Xi": 30,
    "Dong": 30,
    "Bei": 30,
    "Amur": 20,
    "Mekong": 20,
    "Indus": 20,
    "Ganges": 20,
}


class Dem:
    def __init__(self, path):
        self.ok = path.exists()
        self.data = None
        if self.ok:
            raw = path.read_bytes()
            self.data = struct.unpack("<%dH" % (DEM_W * DEM_H), raw[: DEM_W * DEM_H * 2])

    def at(self, lon, lat):
        if not self.ok:
            return 0.0
        x = int((lon + 180.0) / 360.0 * DEM_W)
        y = int((90.0 - lat) / 180.0 * DEM_H)
        if not (0 <= x < DEM_W and 0 <= y < DEM_H):
            return 0.0
        v = self.data[y * DEM_W + x]
        return v / 65535.0 * (DEM_MAX - DEM_MIN) + DEM_MIN


def main() -> int:
    if not HYDRO.exists():
        print("找不到", HYDRO)
        return 1
    d = json.loads(HYDRO.read_text(encoding="utf-8"))
    rivers = d["rivers"]
    dem = Dem(DEM)
    bad = []

    # 1) 白名单
    by_name = {}
    for r in rivers:
        by_name.setdefault(str(r.get("n", "")), []).append(r)
    for name, minpts in PROTECTED.items():
        got = by_name.get(name, [])
        total = sum(len(r["p"]) for r in got)
        if not got:
            bad.append("主干河缺失：%s" % name)
        elif total < minpts:
            bad.append("主干河点数偏少：%s 只有 %d 点（应 >= %d）" % (name, total, minpts))

    # 2) 可疑长直线
    suspicious = 0
    for r in rivers:
        pts = r["p"]
        if len(pts) < 2:
            continue
        gap = max(abs(pts[i + 1][0] - pts[i][0]) + abs(pts[i + 1][1] - pts[i][1])
                  for i in range(len(pts) - 1))
        if gap > 0.6:
            suspicious += 1
            nm = str(r.get("n", ""))
            tag = "（白名单，勿删）" if nm in PROTECTED else ""
            print("  可疑直线 %-18s 点距 %.2f%s" % (nm, gap, tag))

    # 3) 白名单河的入海口
    for name in PROTECTED:
        for r in by_name.get(name, []):
            tail = r["p"][-1] if r["p"][-1][0] > r["p"][0][0] else r["p"][0]
            h = dem.at(tail[0], tail[1])
            if h > -5.0:
                print("  入海口未到海：%-10s 末端 %.2f,%.2f 高程 %.0f m"
                      % (name, tail[0], tail[1], h))

    print("河流 %d 条，可疑长直线 %d 段" % (len(rivers), suspicious))
    if bad:
        print("发现问题：")
        for b in bad:
            print("  -", b)
        return 1
    print("主干河齐全。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
