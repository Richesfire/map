"""下载并解压项目运行所需的数据包（GitHub Release 附件），并建好 ias/data 目录联接。

用法（在仓库根目录）：
    python tools/get_data.py                 # 下载 + 解压 + 建联接
    python tools/get_data.py --zip 路径      # 用本地 zip，不下载
    python tools/get_data.py --link-only     # 只有数据已就位，只补建联接
    python tools/get_data.py --force         # 覆盖已有文件

它会：
  1. 从 GitHub Release 下载 qmc_data_v1.zip（约 280 MB）
  2. 解压到 ias-core/data/（dem2k.bin、dem_map.bin、land_mask.bin、textures/…）
  3. 建 ias/data -> ias-core/data 的目录联接（Windows: mklink /J；其它系统: symlink）
     —— 游戏里所有资源都走 res://data/，没有这个联接就看不到数据

注意：landform_id.bin（预烘焙地貌编号图，32 MB）不在数据包里，
需要用 ias/tools/bake_landform_id.gd 现烘，见 DATA.md。
"""
import argparse
import os
import subprocess
import sys
import urllib.request
import zipfile

REPO = "Richesfire/map"
ASSET = "qmc_data_v1.zip"
API = "https://api.github.com/repos/%s/releases" % REPO

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "ias-core", "data")
LINK = os.path.join(ROOT, "ias", "data")


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


def _same_path(a: str, b: str) -> bool:
    """realpath 会把 Windows 目录联接解析成目标，所以能识别"已经是这个联接"。"""
    return os.path.normcase(os.path.realpath(a)) == os.path.normcase(os.path.realpath(b))


def ensure_link(link: str = "", target: str = "", dry: bool = False) -> bool:
    """建 ias/data -> ias-core/data。已存在且指向正确时什么也不做。

    返回 True 表示联接已就绪（或 dry 时"将要就绪"）。
    """
    link = link or LINK
    target = target or DATA
    if not os.path.isdir(target):
        print("数据目录不存在，先跑解压：", target)
        return False
    if os.path.exists(link) or os.path.islink(link):
        if _same_path(link, target):
            print("目录联接已就绪：%s -> %s" % (link, target))
            return True
        print("注意：%s 已存在，但不是指向 %s 的联接，保持原样（不覆盖）" % (link, target))
        return False
    if dry:
        print("将创建联接：%s -> %s" % (link, target))
        return True
    os.makedirs(os.path.dirname(link), exist_ok=True)
    try:
        if os.name == "nt":
            # 目录联接不需要管理员权限；别用 mklink /D（那是符号链接，需要权限）
            subprocess.run([os.environ.get("COMSPEC", "cmd"), "/c", "mklink", "/J", link, target],
                           check=True, capture_output=True)
        else:
            os.symlink(target, link, target_is_directory=True)
    except (OSError, subprocess.CalledProcessError) as e:
        print("创建联接失败：", e)
        if os.name == "nt":
            print('手动办法：mklink /J "%s" "%s"' % (link, target))
        else:
            print('手动办法：ln -s "%s" "%s"' % (target, link))
        return False
    print("已创建目录联接：%s -> %s" % (link, target))
    return True


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", help="本地已有的 zip 路径（跳过下载）")
    ap.add_argument("--force", action="store_true", help="覆盖已有文件")
    ap.add_argument("--link-only", action="store_true", help="只建目录联接，不下载/解压")
    args = ap.parse_args()

    if args.link_only:
        ok = ensure_link()
        raise SystemExit(0 if ok else 1)

    path = args.zip
    if not path:
        url = find_asset_url()
        path = os.path.join(ROOT, ASSET)
        download(url, path)
    extract(path, args.force)
    ok = ensure_link()
    print("完成，数据已就位：", DATA)
    if not ok:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
