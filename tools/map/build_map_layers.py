"""离线生成 2D 地图底图：高程配色 + Hillshade。

用法（项目根目录）：
  python tools/map/build_map_layers.py            # 生成 color/shade（8192x4096）
  python tools/map/build_map_layers.py --preview  # 额外输出两张预览 PNG

输出：
  game/data/map_color.bin   8192x4096 RGB888
  game/data/map_shade.bin   8192x4096 灰度（255 = 亮）
  game/data/map_color_preview.png / map_shade_preview.png（--preview 时）
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "game" / "data"
DEM = DATA / "raw" / "dem2k.bin"
W, H = 8192, 4096
DEM_W, DEM_H = 16384, 8192
DEM_MIN, DEM_MAX = -11000.0, 9000.0




def build_contours(out_path, step=2):
    """从高程提取等高线折线，写成 TLIN 格式（运行时已支持读取）。"""
    from scipy import ndimage as ndi
    raw = np.fromfile(DEM, dtype='<u2').reshape(DEM_H, DEM_W).astype(np.float32)
    h = raw / 65535.0 * (DEM_MAX - DEM_MIN) + DEM_MIN
    h = ndi.gaussian_filter(h, 2.0)
    h = h[::step, ::step]              # 4096x2048
    hh, ww = h.shape
    print('   等高线网格', ww, 'x', hh)
    import collections
    lines = []
    for th in range(250, 6001, 250):
        mask = h > th
        a = mask[:-1, :-1]; b = mask[:-1, 1:]; c = mask[1:, 1:]; d = mask[1:, :-1]
        case = a.astype(np.uint8) * 8 + b * 4 + c * 2 + d
        segs = []
        for k, pairs in {
            1: [(3, 2)], 2: [(2, 1)], 3: [(3, 1)], 4: [(0, 1)], 5: [(0, 3), (1, 2)],
            6: [(0, 2)], 7: [(0, 3)], 8: [(0, 3)], 9: [(0, 2)], 10: [(0, 1), (2, 3)],
            11: [(0, 1)], 12: [(1, 3)], 13: [(1, 2)], 14: [(2, 3)],
        }.items():
            ys, xs = np.nonzero(case == k)
            if ys.size == 0:
                continue
            for e1, e2 in pairs:
                def pt(e):
                    if e == 0: return (xs + 0.5, ys.astype(np.float64))
                    if e == 1: return (xs.astype(np.float64) + 1.0, ys + 0.5)
                    if e == 2: return (xs + 0.5, ys.astype(np.float64) + 1.0)
                    return (xs.astype(np.float64), ys + 0.5)
                p1 = pt(e1); p2 = pt(e2)
                segs.extend(zip(p1[0].tolist(), p1[1].tolist(), p2[0].tolist(), p2[1].tolist()))
        adj = collections.defaultdict(list)
        for x0, y0, x1, y1 in segs:
            k0 = (round(x0*2), round(y0*2)); k1 = (round(x1*2), round(y1*2))
            adj[k0].append(k1); adj[k1].append(k0)
        used = set()
        cnt = 0
        for x0, y0, x1, y1 in segs:
            k0 = (round(x0*2), round(y0*2)); k1 = (round(x1*2), round(y1*2))
            if (k0, k1) in used or (k1, k0) in used:
                continue
            chain = [k0, k1]; used.add((k0, k1))
            for _ in range(4000):
                tip = chain[-1]
                nxt = None
                for q in adj[tip]:
                    if (tip, q) not in used and (q, tip) not in used:
                        nxt = q; break
                if nxt is None:
                    break
                used.add((tip, nxt)); chain.append(nxt)
            if len(chain) >= 4:
                # Chaikin 圆角 2 次：把 9.8km 的直角磨成曲线
                pts = [(c[0] * 0.5, c[1] * 0.5) for c in chain]
                for _ in range(2):
                    out = []
                    n = len(pts) - 1
                    for i in range(n):
                        x0, y0 = pts[i]; x1, y1 = pts[i + 1]
                        out.append((0.75 * x0 + 0.25 * x1, 0.75 * y0 + 0.25 * y1))
                        out.append((0.25 * x0 + 0.75 * x1, 0.25 * y0 + 0.75 * y1))
                    pts = out
                lines.append(pts)
                cnt += 1
        print(f'   {th:5d} m  折线 {cnt}')
    with open(out_path, 'wb') as f:
        f.write(b'TLIN'); f.write(np.uint32(1).tobytes()); f.write(np.uint32(len(lines)).tobytes())
        total = 0
        for chain in lines:
            pts = np.array(chain, dtype=np.float64)
            n = pts.shape[0]
            ll = np.empty((n, 2), dtype=np.float32)
            ll[:, 0] = pts[:, 0] / ww * 360.0 - 180.0
            ll[:, 1] = 90.0 - pts[:, 1] / hh * 180.0
            f.write(np.uint32(n).tobytes())
            f.write(ll.min(axis=0).astype(np.float32).tobytes())
            f.write(ll.max(axis=0).astype(np.float32).tobytes())
            f.write(ll.tobytes())
            total += n
    print('   等高线', len(lines), '条 /', total, '点 ->', out_path)


def main():
    preview = "--preview" in sys.argv
    if "--contours" in sys.argv:
        build_contours(DATA / "generated" / "map_contour.bin")
        return
    raw = np.fromfile(DEM, dtype="<u2")
    if raw.size != DEM_W * DEM_H:
        raise SystemExit(f"dem2k.bin 尺寸不对：{raw.size} != {DEM_W*DEM_H}")
    dem = raw.reshape(DEM_H, DEM_W).astype(np.float32)
    h = dem / 65535.0 * (DEM_MAX - DEM_MIN) + DEM_MIN
    # 降到 8192x4096（4 格取平均）
    h = h.reshape(H, 2, W, 2).mean(axis=(1, 3))
    print("高程范围 %.0f .. %.0f" % (h.min(), h.max()))

    # ---- 配色：低饱和羊皮纸色系 ----
    def mix(a, b, t):
        return a + (b - a) * t

    def smooth(e0, e1):
        t = np.clip((h - e0) / (e1 - e0), 0.0, 1.0)
        return t * t * (3 - 2 * t)

    land = np.stack([np.full_like(h, 0.90), np.full_like(h, 0.85), np.full_like(h, 0.70)], axis=-1)
    for e0, e1, col in [
        (50, 300, (0.80, 0.74, 0.58)),
        (300, 900, (0.72, 0.63, 0.47)),
        (900, 2000, (0.68, 0.58, 0.44)),
        (2000, 3500, (0.58, 0.50, 0.40)),
        (3500, 5000, (0.50, 0.44, 0.37)),
    ]:
        t = smooth(e0, e1)[..., None]
        land = mix(land, np.array(col, dtype=np.float32), t)
    # 海：浅蓝灰 → 深蓝灰
    sea_d = np.clip(-h / 4000.0, 0.0, 1.0)[..., None]
    sea = mix(np.array([0.56, 0.62, 0.66], np.float32), np.array([0.26, 0.34, 0.44], np.float32), sea_d)
    # 内陆洼地（约旦河谷/死亡谷/阿法尔/盖塔拉/吐鲁番）不画成海
    is_sea = h < 0.0
    lon_g = (np.arange(W, dtype=np.float32) + 0.5) * (360.0 / W) - 180.0
    lat_g = 90.0 - (np.arange(H, dtype=np.float32) + 0.5) * (180.0 / H)
    LON, LAT = np.meshgrid(lon_g, lat_g)
    for (x0, x1, y0, y1) in [(34.7, 36.3, 29.4, 33.6), (-117.6, -115.9, 34.8, 37.2),
                             (40.3, 42.6, 10.6, 14.2), (25.8, 29.2, 28.8, 31.2),
                             (88.6, 89.9, 41.6, 43.4)]:
        is_sea &= ~((LON > x0) & (LON < x1) & (LAT > y0) & (LAT < y1))
    # 去掉小水体/现代水库：只保留面积 > 200 像素的连通水体（约 4800 km² 以上）；
    # 大湖由 hydro.json 单独填充，不依赖这里
    lab, nl = ndimage.label(is_sea)
    if nl > 0:
        sizes = ndimage.sum(is_sea, lab, range(1, nl + 1))
        keep = np.zeros(nl + 1, dtype=bool)
        keep[1:] = sizes >= 200
        is_sea = keep[lab]
    # 海岸线抗锯齿：把高程上采样 4 倍算海陆，再缩回来得到每格 0..1 的覆盖率，
    # 这样放大后海岸是渐变的软边，不是 4.9km 一格的硬台阶。
    from scipy import ndimage as _ndi
    cover = is_sea.astype(np.float32)
    up = _ndi.zoom(cover, 4.0, order=1).astype(np.float32)
    hup = _ndi.zoom(h, 4.0, order=1).astype(np.float32)
    soft = np.clip((0.0 - hup) / 12.0, 0.0, 1.0)      # ±12m 内渐变
    up = np.clip(up * 0.35 + soft * 0.65, 0.0, 1.0)
    cover = _ndi.zoom(up, 0.25, order=1).astype(np.float32)
    cover = np.clip(cover, 0.0, 1.0)
    color = land * (1.0 - cover[..., None]) + sea * cover[..., None]
    color = np.clip(color * 255.0, 0, 255).astype(np.uint8)
    color.tofile(DATA / "generated" / "map_color.bin")
    print("map_color.bin", round((DATA / "generated" / "map_color.bin").stat().st_size / 1048576, 1), "MB")

    # ---- Hillshade：西北偏北来光，高度角 45° ----
    hs = ndimage.gaussian_filter(h, 1.2)
    gy, gx = np.gradient(hs)
    # 每格约 4.9km；按经纬度缩放：经度方向随纬度收缩
    lat = 90.0 - (np.arange(H, dtype=np.float32) + 0.5) * (180.0 / H)
    km_x = 40075.0 * np.cos(np.deg2rad(lat)) / W
    dx = gx / (km_x[:, None] * 1000.0)
    dy = gy / (4.9 * 1000.0)
    az = np.deg2rad(315.0)     # 西北
    alt = np.deg2rad(45.0)
    nx = -dx
    ny = -dy
    nz = np.ones_like(h)
    norm = np.sqrt(nx * nx + ny * ny + nz * nz)
    lx = np.cos(alt) * np.sin(az)
    ly = np.cos(alt) * np.cos(az)
    lz = np.sin(alt)
    shade = (nx * lx + ny * ly + nz * lz) / norm
    # 拉伸到 0..1：只取 2%..98% 分位，避免大片灰平
    lo, hi = np.percentile(shade, [2.0, 98.0])
    shade = np.clip((shade - lo) / max(hi - lo, 1e-6), 0.0, 1.0)
    # 极区那两行会拉丝，直接用相邻行
    shade[:12] = shade[12]
    shade[-12:] = shade[-13]
    shade = (shade * 255.0).astype(np.uint8)
    shade.tofile(DATA / "generated" / "map_shade.bin")
    print("map_shade.bin", round((DATA / "generated" / "map_shade.bin").stat().st_size / 1048576, 1), "MB")

    if preview:
        Image.fromarray(color).resize((1600, 800), Image.LANCZOS).save(DATA / "map_color_preview.png")
        g = np.stack([shade] * 3, axis=-1)
        Image.fromarray(g).resize((1600, 800), Image.LANCZOS).save(DATA / "map_shade_preview.png")
        print("预览：map_color_preview.png / map_shade_preview.png")


if __name__ == "__main__":
    main()
