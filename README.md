# 秦末 209BC —— 开放世界原型（Godot 4.7）

秦末（公元前 209 年）题材的开放世界原型：程序化地形 + 2D 卷轴地图 + 快速旅行。
地形和地貌全部由游戏自己的分类器从同一份高程数据求出（"一套数据"原则）；
地图上不写任何文字，只画舆图符号，名字只在点开的面板里看。

> 技术交接（架构、数据链、分类规则、踩过的坑）看 **[交接_地图系统.md](交接_地图系统.md)**。
> 数据与仓库说明看 **[DATA.md](DATA.md)**。

## 快速开始

环境：Godot **4.7**（Forward+）、Python **3.8+**。

```bash
git clone https://github.com/Richesfire/map.git
cd map
python tools/get_data.py       # 下载约 280 MB 数据包，并建好 ias/data 目录联接
```

然后任选一种：

- Windows：双击 `ias\Play.bat`（Godot 不在默认位置时先设环境变量 `GODOT_EXE`）
- 或用 Godot 打开 `ias/project.godot`

`get_data.py` 会把数据解压到 `ias-core/data/`，并在 `ias/` 下建一个指向它的目录联接——
游戏里所有资源都走 `res://data/`，**没有这个联接就看不到数据**（游戏会退化成一片平地，
只打印一行 `[地形] 没有高程数据，用平地`）。数据已在别处时，只需补联接：

```bash
python tools/get_data.py --link-only
```

`landform_id.bin`（32 MB 预烘焙地貌编号图）不在数据包里。缺它游戏仍能跑，但 3D 撒点会退回
实时分类（慢几十倍）。需要时现烘（约 5 分钟，中途别中断）：

```powershell
godot --headless --path ias --script res://tools/bake_landform_id.gd
```

## 目录

| 路径 | 内容 |
|---|---|
| `ias/` | Godot 工程：`scripts/` 逻辑、`shaders/` 着色器、`scenes/` 场景、`tools/` 烘焙与诊断工具 |
| `ias/data` | 指向 `ias-core/data` 的目录联接（不跟踪、不单独存一份） |
| `ias-core/data/` | 高程、水系、城池/史事/汉县、地貌配置；`*.bin` 不进 git |
| `tools/` | `get_data.py`（下载数据）、`run_tests.ps1`（回归测试） |
| `docs/` | `策划/` 策划案与兵种表、`故事/` 设定、`模型/` 武器模型、`截图/<日期>/` 各轮验证截图（都不参与构建） |

## 测试

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_tests.ps1
```

6 项，约 70 秒。改了 `main.gd` 先单独跑一次
`godot --headless --path ias --check-only --script res://scripts/main.gd`；
改了着色器必须真开一次图——着色器编译错误只在完整输出里报 `SHADER ERROR`。

## 常用调试参数

```powershell
$g = "C:\Program Files (x86)\Steam\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe"
& $g --path ias -- --start --fresh --map --mapzoom=60 --mapcenter=112.9,35.85 --at=112.45,34.62
& $g --path ias -- --start --fresh --map --mapzoom=1 --shots="C:\a.png@8|C:\b.png@12"
```

完整参数表见 [交接_地图系统.md](交接_地图系统.md) 第 1 节。

## 数据与素材许可

| 来源 | 用途 | 许可 |
|---|---|---|
| 仓库 Release 附件 `qmc_data_v1.zip` | 高程底图、地表贴图 | 本项目数据包 |
| CHGIS V6 Time Series | 汉书·地理志县治 1134 处 | CC0 1.0 |
| Natural Earth | 江河湖泊（抽稀） | 公有领域 |
| ambientCG | 地表/法线/树皮/草叶贴图 | CC0 |
| GeoNames | 现代聚落（地图层已撤，数据保留） | CC BY 4.0 |

代码部分暂未选择开源许可证。
