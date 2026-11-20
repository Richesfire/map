"""离线生成 2D 地图底图：高程配色 + Hillshade。

用法（项目根目录）：
  python ias/tools/build_map_layers.py            # 生成 color/shade（8192x4096）
  python ias/tools/build_map_layers.py --preview  # 额外输出两张预览 PNG

输出：
  ias-core/data/map_color.bin   8192x4096 RGB888
  ias-core/data/map_shade.bin   8192x4096 灰度（255 = 亮）
  ias-core/data/map_color_preview.png / map_shade_preview.png（--preview 时）
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy import ndimage

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / "ias-core" / "data"
DEM = DATA / "dem2k.bin"
W, H = 8192, 4096
DEM_W, DEM_H = 16384, 8192
DEM_MIN, DEM_MAX = -11000.0, 9000.0


def main():
    preview = "--preview" in sys.argv
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
    color = np.where((h < 0.0)[..., None], sea, land)
    color = np.clip(color * 255.0, 0, 255).astype(np.uint8)
    color.tofile(DATA / "map_color.bin")
    print("map_color.bin", round((DATA / "map_color.bin").stat().st_size / 1048576, 1), "MB")

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
    shade.tofile(DATA / "map_shade.bin")
    print("map_shade.bin", round((DATA / "map_shade.bin").stat().st_size / 1048576, 1), "MB")

    if preview:
        Image.fromarray(color).resize((1600, 800), Image.LANCZOS).save(DATA / "map_color_preview.png")
        g = np.stack([shade] * 3, axis=-1)
        Image.fromarray(g).resize((1600, 800), Image.LANCZOS).save(DATA / "map_shade_preview.png")
        print("预览：map_color_preview.png / map_shade_preview.png")


if __name__ == "__main__":
    main()
