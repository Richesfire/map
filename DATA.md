# 数据与仓库说明

仓库里**只放代码、配置、文档和贴图**；运行所需的高程数据放在 GitHub Release 附件里。

## 新机器拉下来怎么跑

```bash
git clone https://github.com/Richesfire/map.git
cd map
python tools/get_data.py          # 下载解压约 280 MB 数据包，并建 ias/data 联接
```

然后双击 `ias/Play.bat`（或 Godot 打开 `ias/project.godot`）。

> ⚠️ 游戏读的是 `res://data/`，而数据放在 `ias-core/data/`，两者靠 `ias/data` 这个**目录联接**
> 打通（Windows 用 `mklink /J`，不需要管理员；其它系统是 symlink）。`get_data.py` 会自动建，
> 数据已在别处时用 `python tools/get_data.py --link-only` 补。
> 没有联接时游戏不会报错，只会打印 `[地形] 没有高程数据，用平地` 并显示一片平地。

数据会解压到 `ias-core/data/`：

| 文件 | 大小 | 用途 |
|---|---|---|
| dem2k.bin | 256 MB | 全球 2.4 km 高程（地形唯一真源） |
| dem2k.json | — | 底图经纬范围 |
| dem_map_lo.bin | 16 MB | 地图着色器用高程纹理（半分辨率） |
| dem_map.bin | 64 MB | 地图用全分辨率高程（备用） |
| land_mask.bin | 8 MB | 海陆掩膜 |
| landform_id.bin | 32 MB | 预烘焙地貌编号图（8192×4096；不随数据包，用 `ias/tools/bake_landform_id.gd` 现烘） |
| hydro.json | 1.4 MB | 江河湖泊（Natural Earth 抽稀） |
| settlements.json | 0.56 MB | GeoNames 现代聚落 10725 处（地图层已撤，留作 3D/调试） |
| sites_han.json | — | 秦汉史事点位 82 处（城邑坐标取 CHGIS） |
| counties_han.json | — | 汉书·地理志县治 1134 处（CHGIS V6，CC0） |
| mountain_features.json | — | 54 条山系特征 |
| cities.json | — | 手工城池 16 座 |
| textures/ | 18 MB | 地表 / 法线 / 树皮 / 叶簇 / 草叶图集 |
| biomes/ | — | 29 个地貌 `.tres` 配置（文件名 `编号_配置id`，编号 = 地貌号） |

## 自检

双击 `run_tests.bat`（或 `powershell -ExecutionPolicy Bypass -File tools/run_tests.ps1`）跑全部 6 项自检，约 70 秒。
Godot 不在默认路径时，先设置环境变量 `GODOT_EXE`。

## 为什么不用 LFS

GitHub 免费账号 LFS 是 1 GB 存储 + 1 GB/月流量。数据包 363 MB 放得下，
但每台机器 clone 一次就要拉一遍，一个月拉两三次就超额，且 LFS 上传在国内很慢。
Release 附件不占 LFS 配额，单独下载一次即可。

> **历史包袱**：`3ad3664`（第一个提交）曾经用 LFS 跟踪 `*.bin`，`4fb6bdb` 之后移出跟踪。
> 所以那几个老提交里的 `.bin` 是指针文件（约 130 字节），不是真数据；
> 本机的 LFS 缓存已经清掉（`git lfs prune` 不会清，因为指针还挂在历史里，只能手动删 `.git/lfs`）。
> 要还原：`git lfs fetch`（远端若还留着）或按 Release 重下。**当前工作区不受影响**，
> `ias-core/data/` 里都是真文件。

## 贴图

`ias-core/data/textures/` 里的图集随数据包一起分发，游戏中不存在从网络拉取贴图的脚本：

| 文件 | 用途 |
|---|---|
| `ground_atlas.png` + `ground_atlas.json` | 地表 4×4 图集（地形着色器按地貌混贴） |
| `ground_normal.png` | 地表法线 |
| `tree_atlas.png` | 树皮 / 叶簇图集 |
| `grass_sheet.png` | 草叶图集 |

换贴图直接替换同名文件即可（尺寸和图集切分见 `ground_atlas.json`）。
原始素材来自 ambientCG（CC0）。

## 提交约定

- 提交：代码、shader、`.tres`、文档、脚本、贴图；
- 不提交：`*.bin` 大文件、`.godot/`、`_tiles_cache/`、`_tiles_z6/`、备份目录、原始 zip；
- 每完成一个可验证功能提交一次，提交前跑 `tools/run_tests.ps1`（6 项 ≈ 70 秒）。
