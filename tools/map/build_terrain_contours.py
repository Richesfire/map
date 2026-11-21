"""从烘焙好的地貌编号图提取矢量轮廓（marching squares）+ 出预览图。

用法（在项目根目录）：
  python tools/map/build_terrain_contours.py --region 118,122,29,33 --step 1 --out preview.png
  python tools/map/build_terrain_contours.py --out world.png --step 4 --preview 1600

参数：
  --region lon0,lon1,lat0,lat1   只处理这块区域（不填 = 全球）
  --step N                       先降采样 N 倍再提轮廓（1 = 全分辨率 8192×4096）
  --eps F                        Douglas-Peucker 简化阈值，单位 = 降采样后的格（默认 0.7）
  --preview W                    预览图宽度（默认 1400）
  --out PATH                     预览图输出路径
  --json PATH                    顺带把轮廓存成 json（可选）
"""
import json
import math
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "game" / "data" / "landform_id.bin"
DB = ROOT / "game" / "scripts" / "landform_db.gd"

W, H = 8192, 4096
NAMES = ['平原', '丘陵', '山地', '高原', '盆地', '河谷', '荒漠', '草原', '森林', '湿地', '冰雪', '水',
         '喀斯特', '雅丹', '黄土', '沙丘', '冰川谷', '三角洲', '花岗岩山地', '喀斯特山地', '黄土山地',
         '火山山地', '冰蚀山地', '红壤丘陵', '黄土丘陵', '丹霞丘陵', '沙质荒漠', '砾质荒漠', '盐碱地',
         '针叶林', '苔原']


def load_colors():
    txt = DB.read_text(encoding="utf-8")
    block = txt.split("const COLORS := [", 1)[1].split("]", 1)[0]
    cols = []
    for m in re.finditer(r"Color\(([\d.]+),\s*([\d.]+),\s*([\d.]+)\)", block):
        r, g, b = (float(m.group(i)) for i in (1, 2, 3))
        cols.append((int(r * 255), int(g * 255), int(b * 255)))
    return cols


# marching squares：16 种角点组合 → 线段（边编号 0=上 1=右 2=下 3=左，取边中点）
CASE_SEGS = {
    1: [(2, 3)], 2: [(1, 2)], 3: [(1, 3)], 4: [(0, 1)], 5: [(0, 3), (1, 2)], 6: [(0, 2)],
    7: [(0, 3)], 8: [(0, 3)], 9: [(0, 2)], 10: [(0, 1), (2, 3)], 11: [(0, 1)], 12: [(1, 3)],
    13: [(1, 2)], 14: [(2, 3)], 15: [],
}


def marching_squares(mask):
    """返回线段列表 [(x0,y0,x1,y1), ...]，坐标单位 = 格。"""
    pad = np.zeros((mask.shape[0] + 2, mask.shape[1] + 2), dtype=np.uint8)
    pad[1:-1, 1:-1] = mask
    a = pad[:-1, :-1]
    b = pad[:-1, 1:]
    c = pad[1:, 1:]
    d = pad[1:, :-1]
    case = (a * 8 + b * 4 + c * 2 + d).astype(np.uint8)
    parts = []
    for k, pairs in CASE_SEGS.items():
        if not pairs:
            continue
        ys, xs = np.nonzero(case == k)
        if ys.size == 0:
            continue
        for (e1, e2) in pairs:
            p1 = edge_point(e1, xs, ys)
            p2 = edge_point(e2, xs, ys)
            parts.append((p1[0], p1[1], p2[0], p2[1]))
    if not parts:
        return []
    x0 = np.concatenate([q[0] for q in parts]).astype(np.float64)
    y0 = np.concatenate([q[1] for q in parts]).astype(np.float64)
    x1 = np.concatenate([q[2] for q in parts]).astype(np.float64)
    y1 = np.concatenate([q[3] for q in parts]).astype(np.float64)
    return list(zip(x0.tolist(), y0.tolist(), x1.tolist(), y1.tolist()))


def edge_point(edge, xs, ys):
    # 边中点：上(0) = (x+0.5, y)  右(1) = (x+1, y+0.5)  下(2) = (x+0.5, y+1)  左(3) = (x, y+0.5)
    if edge == 0:
        return (xs + 0.5, ys.astype(np.float64))
    if edge == 1:
        return (xs.astype(np.float64) + 1.0, ys + 0.5)
    if edge == 2:
        return (xs + 0.5, ys.astype(np.float64) + 1.0)
    return (xs.astype(np.float64), ys + 0.5)


def join_loops(segs):
    """把线段接成闭合环。端点用 2 倍坐标取整做 key。"""
    key2pt = {}
    adj = {}
    for i, (x0, y0, x1, y1) in enumerate(segs):
        k0 = (int(round(x0 * 2)), int(round(y0 * 2)))
        k1 = (int(round(x1 * 2)), int(round(y1 * 2)))
        key2pt[k0] = (x0, y0)
        key2pt[k1] = (x1, y1)
        adj.setdefault(k0, []).append(k1)
        adj.setdefault(k1, []).append(k0)
    loops = []
    visited = set()
    for start, nbrs in adj.items():
        if start in visited:
            continue
        loop = [start]
        visited.add(start)
        prev, cur = start, nbrs[0]
        ok = True
        while cur != start:
            if cur in visited:
                ok = False
                break
            visited.add(cur)
            loop.append(cur)
            nxt = None
            for n in adj.get(cur, ()):
                if n != prev:
                    nxt = n
                    break
            if nxt is None:
                ok = False
                break
            prev, cur = cur, nxt
            if len(loop) > 400000:
                ok = False
                break
        if ok and len(loop) >= 4:
            loops.append([key2pt[k] for k in loop])
    return loops


def dp_simplify(pts, eps):
    if len(pts) < 4 or eps <= 0:
        return pts
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i0, i1 = stack.pop()
        if i1 <= i0 + 1:
            continue
        x0, y0 = pts[i0]
        x1, y1 = pts[i1]
        dx, dy = x1 - x0, y1 - y0
        n = math.hypot(dx, dy)
        best, idx = -1.0, -1
        for i in range(i0 + 1, i1):
            px, py = pts[i]
            if n < 1e-9:
                d = math.hypot(px - x0, py - y0)
            else:
                d = abs(dy * px - dx * py + x1 * y0 - y1 * x0) / n
            if d > best:
                best, idx = d, i
        if best > eps:
            keep[idx] = True
            stack.append((i0, idx))
            stack.append((idx, i1))
    return [p for p, k in zip(pts, keep) if k]


def chaikin(pts, iters):
    """闭合多边形的 Chaikin 平滑：直角 → 圆角，顶点数约翻倍。"""
    for _ in range(iters):
        out = []
        n = len(pts)
        for i in range(n):
            x0, y0 = pts[i]
            x1, y1 = pts[(i + 1) % n]
            out.append((0.75 * x0 + 0.25 * x1, 0.75 * y0 + 0.25 * y1))
            out.append((0.25 * x0 + 0.75 * x1, 0.25 * y0 + 0.75 * y1))
        pts = out
    return pts





def extract_lines(ids, x0, y0, step, out_path):
    """共享边界线：每对相邻且类别不同的格子只输出一条边，接成折线后简化 + 圆角。
    和"按类别取环"不同，这里同一条边只出现一次，所以不会出现双线。"""
    import collections
    h, w = ids.shape
    hor = ids[:, :-1] != ids[:, 1:]
    ver = ids[:-1, :] != ids[1:, :]
    segs = []
    ys, xs = np.nonzero(hor)
    for yy, xx in zip(ys.tolist(), xs.tolist()):
        segs.append(((xx + 1, yy), (xx + 1, yy + 1)))
    ys, xs = np.nonzero(ver)
    for yy, xx in zip(ys.tolist(), xs.tolist()):
        segs.append(((xx, yy + 1), (xx + 1, yy + 1)))
    print('   边界线段', len(segs))
    adj = collections.defaultdict(list)
    for a, b in segs:
        adj[a].append(b)
        adj[b].append(a)
    used = set()
    chains = []
    for a, b in segs:
        if (a, b) in used or (b, a) in used:
            continue
        chain = [a, b]
        used.add((a, b))
        # 向两端延伸
        for end in (0, 1):
            while True:
                tip = chain[-1] if end == 1 else chain[0]
                if len(adj[tip]) != 2:
                    break   # 三岔口就停，别顺着别的边界穿过去（会画成交叉线）
                nxt = None
                for c in adj[tip]:
                    if (tip, c) not in used and (c, tip) not in used:
                        nxt = c
                        break
                if nxt is None or len(chain) > 20000:
                    break
                used.add((tip, nxt))
                if end == 1:
                    chain.append(nxt)
                else:
                    chain.insert(0, nxt)
        if len(chain) >= 4:
            pts = [(float(x), float(y)) for x, y in chain]
            pts = dp_simplify(pts, 0.8)
            pts = chaikin(pts, 2)
            chains.append(pts)
    print('   折线', len(chains))
    with open(out_path, 'wb') as f:
        f.write(b'TLIN')
        f.write(np.uint32(1).tobytes())
        f.write(np.uint32(len(chains)).tobytes())
        arr_all = 0
        for pts in chains:
            a = np.asarray(pts, dtype=np.float64)
            n = a.shape[0]
            ll = np.empty((n, 2), dtype=np.float32)
            ll[:, 0] = (x0 + a[:, 0] * step) / W * 360.0 - 180.0
            ll[:, 1] = 90.0 - (y0 + a[:, 1] * step) / H * 180.0
            f.write(np.uint32(n).tobytes())
            f.write(ll.min(axis=0).astype(np.float32).tobytes())
            f.write(ll.max(axis=0).astype(np.float32).tobytes())
            f.write(ll.tobytes())
            arr_all += n
    print('   顶点', arr_all)


def main():
    args = sys.argv[1:]

    def arg(name, default=None):
        if name in args:
            return args[args.index(name) + 1]
        return default

    step = int(arg("--step", 1))
    eps = float(arg("--eps", 0.7))
    smooth = int(arg("--smooth", 2))
    preview_w = int(arg("--preview", 1400))
    out = Path(arg("--out", "contours_preview.png"))
    bin_out = arg("--bin", None)
    lines_out = arg("--lines", None)
    region = arg("--region", None)

    ids = np.fromfile(DATA, dtype=np.uint8).reshape(H, W)
    # 去斑：3×3 中值（对分类图近似多数表决），去掉孤立碎屑
    ids = ndimage.median_filter(ids, size=3)

    lon0, lon1, lat_s, lat_n = -180.0, 180.0, -90.0, 90.0
    if region:
        lon0, lon1, lat_s, lat_n = (float(v) for v in region.split(","))
    x0 = max(0, int((lon0 + 180.0) / 360.0 * W))
    x1 = min(W, int((lon1 + 180.0) / 360.0 * W))
    y0 = max(0, int((90.0 - lat_n) / 180.0 * H))
    y1 = min(H, int((90.0 - lat_s) / 180.0 * H))
    sub = ids[y0:y1:step, x0:x1:step]
    print(f"区域 {sub.shape[1]}×{sub.shape[0]} 格（每格 {360.0/W*step*111:.1f} km 纬向）")

    if lines_out:
        extract_lines(sub, x0, y0, step, lines_out)
        print('线条：', lines_out, Path(lines_out).stat().st_size // 1024, 'KB')
        return
    classes, counts = np.unique(sub, return_counts=True)
    cols = load_colors()
    order = [int(c) for c in classes]
    # 面积大的先画，小的后画压在上面
    order.sort(key=lambda c: -int(counts[list(classes).index(c)]))

    binf = None
    if bin_out:
        binf = open(bin_out, "wb")
        binf.write(b"TCON")
        binf.write(np.uint32(2).tobytes())
        binf.write(np.uint32(len(order)).tobytes())

    img = Image.new("RGB", (sub.shape[1], sub.shape[0]), (235, 228, 210))
    draw = ImageDraw.Draw(img)
    total_v = 0
    total_loops = 0
    for c in order:
        name = NAMES[c] if c < len(NAMES) else str(c)
        mask = (sub == c)
        segs = marching_squares(mask)
        loops = join_loops(segs)
        if not loops:
            continue
        col = cols[c] if c < len(cols) else (200, 200, 200)
        ring_buf = []
        for lp in loops:
            sp = dp_simplify(lp, eps)
            sp = chaikin(sp, smooth) if smooth > 0 else sp
            total_v += len(sp)
            total_loops += 1
            draw.polygon([(p[0], p[1]) for p in sp], fill=col, outline=col)
            if binf is not None:
                ring_buf.append(sp)
        if binf is not None:
            binf.write(np.uint32(c).tobytes())
            pos = binf.tell()
            binf.write(np.uint32(0).tobytes())      # 环数占位
            for sp in ring_buf:
                arr = np.asarray(sp, dtype=np.float64)
                n = arr.shape[0]
                # 格子坐标 → 经纬度（float32，运行时直接可用）
                ll = np.empty((n, 2), dtype=np.float32)
                ll[:, 0] = (x0 + arr[:, 0] * step) / W * 360.0 - 180.0
                ll[:, 1] = 90.0 - (y0 + arr[:, 1] * step) / H * 180.0
                binf.write(np.uint32(n).tobytes())
                binf.write(ll.min(axis=0).astype(np.float32).tobytes())
                binf.write(ll.max(axis=0).astype(np.float32).tobytes())
                binf.write(ll.tobytes())
            end = binf.tell()
            binf.seek(pos)
            binf.write(np.uint32(len(ring_buf)).tobytes())
            binf.seek(end)
        print(f"  {c:2d} {name:6s} 环 {len(loops):5d}  顶点 {total_v}")
    print(f"合计：{total_loops} 个环，{total_v} 个顶点")

    img = img.resize((preview_w, int(preview_w * sub.shape[0] / sub.shape[1])), Image.LANCZOS)
    img.save(out)
    print("预览：", out)
    if binf is not None:
        binf.close()
        print("二进制：", bin_out, Path(bin_out).stat().st_size // 1024, "KB")


if __name__ == "__main__":
    main()
