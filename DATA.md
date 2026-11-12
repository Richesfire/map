# 数据与仓库说明

仓库里**只放代码、配置、文档和贴图**；运行所需的高程数据放在 GitHub Release 附件里。

## 新机器拉下来怎么跑

```bash
git clone https://github.com/Richesfire/map.git
cd map
python tools/get_data.py          # 下载并解压约 280 MB 数据包
```

然后双击 `ias/Play.bat`（或 Godot 打开 `ias/project.godot`）。

数据会解压到 `ias-core/data/`：

| 文件 | 大小 | 用途 |
|---|---|---|
| dem2k.bin | 256 MB | 全球 2.4 km 高程（地形唯一真源） |
| dem2k.json | — | 底图经纬范围 |
| dem_map.bin | 64 MB | 地图着色器用高程纹理 |
| land_mask.bin | 8 MB | 海陆掩膜 |
| mountain_features.json | — | 54 条山系特征 |
| cities.json | — | 手工城市（咸阳） |
| textures/ | 18 MB | 地表 / 法线 / 树皮 / 叶簇 / 草叶图集 |
| biomes/ | — | 12 个地貌 `.tres` 配置 |

## 自检

双击 `run_tests.bat`（或 `powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1`）跑全部 7 项自检，约 90 秒。
Godot 不在默认路径时，先设置环境变量 `GODOT_EXE`。

## 为什么不用 LFS

GitHub 免费账号 LFS 是 1 GB 存储 + 1 GB/月流量。数据包 363 MB 放得下，
但每台机器 clone 一次就要拉一遍，一个月拉两三次就超额，且 LFS 上传在国内很慢。
Release 附件不占 LFS 配额，单独下载一次即可。

## 贴图怎么换

- 地表：`python fetch_textures.py` → `data/textures/ground_atlas.png`
- 法线：`python fetch_normals.py` → `data/textures/ground_normal.png`
- 树/草：`python make_tree_atlas.py` → `tree_atlas.png` / `grass_sheet.png`

三个脚本都在仓库根目录，素材来自 ambientCG（CC0）。

## 提交约定

- 提交：代码、shader、`.tres`、文档、脚本、贴图；
- 不提交：`*.bin` 大文件、`.godot/`、`_tiles_cache/`、`_tiles_z6/`、备份目录、原始 zip；
- 每完成一个可验证功能提交一次，提交前跑 `--bugtest`。
