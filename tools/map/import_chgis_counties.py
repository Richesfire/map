# -*- coding: utf-8 -*-
"""把 CHGIS V6 县治点位（Time Series County Points）里「公元 2 年」那一层导成地图数据。

数据源：CHGIS V6 Time Series County Points（doi:10.7910/DVN/Q9VOF5，CC0）
        文件：v6_time_cnty_pts_utf_wgs84.zip（解压出的 .shp/.dbf，WGS84，DBF 实为 GBK）

为什么是公元 2 年：汉书·地理志的版籍是元始二年（公元 2 年）。
字段 BEG_YR/END_YR 是这条点位“存在”的年份区间，取包住 2 的那一批。

用法：
    python tools/import_chgis_counties.py <v6_time_cnty_pts_utf_wgs84 不带后缀的路径> \
        [输出的 counties_han.json]

注意：不要用 PowerShell 读写产物，中文会坏；本脚本自己写 UTF-8。
"""
import json
import struct
import sys


def _dec(raw):
    """CHGIS 的 .dbf 是 UTF-8（.cpg 里写着 UTF-8）；老版本有 GBK 的，回退一下。"""
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("gbk", "replace")


def read_dbf(path):
    raw = open(path, "rb").read()
    nrec, hlen, rlen = struct.unpack("<IHH", raw[4:12])
    fields = []
    off = 32
    while raw[off] != 0x0D:
        name = raw[off:off + 11].split(b"\x00")[0].decode("latin-1")
        ftype = chr(raw[off + 11])
        flen = raw[off + 16]
        fields.append((name, ftype, flen))
        off += 32
    rows = []
    p = hlen
    for _ in range(nrec):
        row = raw[p:p + rlen]
        p += rlen
        if row[0:1] == b"*":
            continue
        q = 1
        d = {}
        for (name, ftype, flen) in fields:
            s = _dec(row[q:q + flen]).strip()
            q += flen
            if ftype in "NF":
                try:
                    d[name] = float(s) if s not in ("", "-") else None
                except ValueError:
                    d[name] = None
            else:
                d[name] = s
        rows.append(d)
    return rows


def read_shp_points(path, rows):
    raw = open(path, "rb").read()
    i = 100
    k = 0
    while i < len(raw):
        _num, clen = struct.unpack(">II", raw[i:i + 8])
        body = raw[i + 8:i + 8 + clen * 2]
        st = struct.unpack("<I", body[0:4])[0]
        if st == 1:
            x, y = struct.unpack("<dd", body[4:20])
            if k < len(rows):
                rows[k]["lon"] = round(x, 4)
                rows[k]["lat"] = round(y, 4)
        k += 1
        i += 8 + clen * 2
    return rows


def main():
    base = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "game/data/counties_han.json"
    rows = read_dbf(base + ".dbf")
    rows = read_shp_points(base + ".shp", rows)

    YEAR = 2  # 元始二年
    keep = []
    dropped = {"year": 0, "geom": 0, "name": 0, "dup": 0}
    for r in rows:
        beg, end = r.get("BEG_YR"), r.get("END_YR")
        if beg is None or end is None or not (beg <= YEAR <= end):
            dropped["year"] += 1
            continue
        lon, lat = r.get("lon"), r.get("lat")
        if lon is None or lat is None or not (-180 <= lon <= 180 and -85 <= lat <= 85):
            dropped["geom"] += 1
            continue
        name = r["NAME_CH"].strip()
        if not name or len(name) > 6:      # 有一条 15 字的脏记录
            dropped["name"] += 1
            continue
        keep.append({
            "n": name,
            "lon": lon,
            "lat": lat,
            "t": r["TYPE_CH"].strip() or "县",
            "loc": r["PRES_LOC"].strip(),
            "src": "CHGIS V6 SYS_ID %d" % int(r["SYS_ID"] or 0),
        })

    # 同一坐标、同一名字的重复点去掉（CHGIS 少量重复）
    seen = set()
    uniq = []
    for c in keep:
        key = (c["n"], round(c["lon"], 3), round(c["lat"], 3))
        if key in seen:
            dropped["dup"] += 1
            continue
        seen.add(key)
        uniq.append(c)
    keep = uniq

    doc = {
        "_comment": "汉书·地理志（元始二年，公元 2 年）县治点位。"
                    "数据源 CHGIS V6 Time Series County Points（doi:10.7910/DVN/Q9VOF5，CC0）；"
                    "由 tools/import_chgis_counties.py 生成，不要手改。",
        "version": 1,
        "year": YEAR,
        "counties": keep,
    }
    with open(out, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, ensure_ascii=False, indent=0)
        f.write("\n")

    print("原始 %d 条 -> 保留 %d 条，剔除 %s" % (len(rows), len(keep), dropped))
    types = {}
    for c in keep:
        types[c["t"]] = types.get(c["t"], 0) + 1
    print("类型分布:", types)
    print("写出:", out)


if __name__ == "__main__":
    main()
