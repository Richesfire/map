"""下载并解压项目运行所需的数据包（GitHub Release 附件）。

用法（在仓库根目录）：
    python tools/get_data.py

它会：
  1. 从 GitHub Release 下载 qmc_data_v1.zip（约 280 MB）
  2. 解压到 ias-core/data/（dem2k.bin、dem_map.bin、land_mask.bin、textures/…）
  3. 已存在的文件默认跳过（--force 强制覆盖）

如果访问 GitHub 慢，可以手动下载 zip 后用：python tools/get_data.py --zip 路径
"""
import argparse
import os
import sys
import urllib.request
import zipfile

REPO = "Richesfire/map"
ASSET = "qmc_data_v1.zip"
API = "https://api.github.com/repos/%s/releases" % REPO

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "ias-core", "data")


def find_asset_url() -> str:
    req = urllib.request.Request(API, headers={"User-Agent": "qmc-get-data"})
    with urllib.request.urlopen(req, timeout=60) as r:
        import json
        releases = json.load(r)
    for rel in releases:
        for a in rel.get("assets", []):
            if a["name"] == ASSET:
                return a["browser_download_url"]
    raise SystemExit("没有找到 Release 附件 %s，请先在 GitHub 上确认 Releases 页面" % ASSET)


def download(url: str, dst: str) -> None:
    print("下载", url)
    req = urllib.request.Request(url, headers={"User-Agent": "qmc-get-data"})
    with urllib.request.urlopen(req, timeout=120) as r, open(dst, "wb") as f:
        total = int(r.headers.get("Content-Length", 0))
        done = 0
        while True:
            chunk = r.read(1 << 20)
            if not chunk:
                break
            f.write(chunk)
            done += len(chunk)
            if total:
                pct = done * 100 // total
                sys.stdout.write("\r  %d%%  %.0f/%.0f MB" % (pct, done / 1e6, total / 1e6))
                sys.stdout.flush()
    print()


def extract(zip_path: str, force: bool) -> None:
    os.makedirs(DATA, exist_ok=True)
    with zipfile.ZipFile(zip_path) as z:
        for info in z.infolist():
            if info.is_dir():
                continue
            target = os.path.join(DATA, info.filename)
            if os.path.exists(target) and not force:
                print("跳过（已存在）", info.filename)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(info) as src, open(target, "wb") as dst:
                dst.write(src.read())
            print("解压", info.filename)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", help="本地已有的 zip 路径（跳过下载）")
    ap.add_argument("--force", action="store_true", help="覆盖已有文件")
    args = ap.parse_args()

    path = args.zip
    if not path:
        url = find_asset_url()
        path = os.path.join(ROOT, ASSET)
        download(url, path)
    extract(path, args.force)
    print("完成，数据已就位：", DATA)


if __name__ == "__main__":
    main()
