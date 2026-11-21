# -*- coding: utf-8 -*-
"""给 counties_han.json 里的县加上郡国归属（点落面）。

数据源：CHGIS V6 Time Series Prefecture Polygons（doi:10.7910/DVN/I0Q7SM，CC0）
        文件 v6_time_pref_pgn_utf_wgs84（WGS84，UTF-8，面要素）
做法：取公元 2 年（元始二年）有效的郡级面，对每个县做"点落面"，
      命中多个时取 bbox 最小的那个；命不中就留空（CHGIS 早期年份有缺口）。

用法：
  python tools/attrib_counties.py <pref不带后缀路径> game/data/counties_han.json
"""
import json
import math
import struct
import sys


def _dec(raw):
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


def read_polygons(path, nrows):
    """返回每个记录的 (bbox, rings)。shp 里 Polygon = type 5。"""
    raw = open(path, "rb").read()
    out = []
    i = 100
    k = 0
    while i < len(raw) and k < nrows:
        _num, clen = struct.unpack(">II", raw[i:i + 8])
        body = raw[i + 8:i + 8 + clen * 2]
        st = struct.unpack("<I", body[0:4])[0]
        rec = None
        if st == 5:
            nb, np_ = struct.unpack("<ii", body[36:44])
            parts = list(struct.unpack("<%di" % nb, body[44:44 + 4 * nb]))
            base = 44 + 4 * nb
            pts = []
            for j in range(np_):
                x, y = struct.unpack("<dd", body[base + 16 * j: base + 16 * j + 16])
                pts.append((x, y))
            rings = []
            for j, p0 in enumerate(parts):
                p1 = parts[j + 1] if j + 1 < nb else np_
                rings.append(pts[p0:p1])
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            rec = ((min(xs), min(ys), max(xs), max(ys)), rings)
        out.append(rec)
        k += 1
        i += 8 + clen * 2
    return out


def in_ring(x, y, ring):
    inside = False
    n = len(ring)
    j = n - 1
    for i in range(n):
        xi, yi = ring[i]
        xj, yj = ring[j]
        if (yi > y) != (yj > y):
            xr = (xj - xi) * (y - yi) / (yj - yi + 1e-18) + xi
            if x < xr:
                inside = not inside
        j = i
    return inside


def main():
    base = sys.argv[1]
    cpath = sys.argv[2] if len(sys.argv) > 2 else "game/data/counties_han.json"
    rows = read_dbf(base + ".dbf")
    polys = read_polygons(base + ".shp", len(rows))

    # 元始二年那一年严格有效的郡面只有 17 个（CHGIS 早期年份缺口大），
    # 所以放宽到整个西汉（-206..25），用汉代的郡界做近似归属。
    Y0, Y1 = -206, 25
    units = []
    for r, p in zip(rows, polys):
        beg, end = r.get("BEG_YR"), r.get("END_YR")
        if p is None or beg is None or end is None or not (beg <= Y1 and end >= Y0):
            continue
        name = r.get("NAME_CH", "").strip()
        if not name:
            continue
        units.append({"name": name, "type": r.get("TYPE_CH", "").strip(),
                      "bbox": p[0], "rings": p[1]})
    print("汉时段（%d..%d）有效的郡级面：%d 个" % (Y0, Y1, len(units)))

    doc = json.load(open(cpath, encoding="utf-8"))
    cs = doc["counties"]
    hit = 0
    miss = []
    for c in cs:
        x, y = c["lon"], c["lat"]
        best = None
        for u in units:
            b = u["bbox"]
            if x < b[0] or x > b[2] or y < b[1] or y > b[3]:
                continue
            if not any(in_ring(x, y, rg) for rg in u["rings"]):
                continue
            area = (b[2] - b[0]) * (b[3] - b[1])
            if best is None or area < best[0]:
                best = (area, u)
        if best is None:
            c.pop("j", None)
            miss.append(c["n"])
        else:
            c["j"] = best[1]["name"]
            c["jt"] = best[1]["type"]
            hit += 1
    json.dump(doc, open(cpath, "w", encoding="utf-8", newline="\n"),
              ensure_ascii=False, indent=0)
    print("归属成功 %d / %d（缺 %d）" % (hit, len(cs), len(miss)))
    print("未命中示例:", "，".join(miss[:12]))
    from collections import Counter
    top = Counter(c.get("j") for c in cs if c.get("j")).most_common(8)
    print("郡下县数 top:", top)


if __name__ == "__main__":
    main()
