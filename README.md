# 秦末 209BC —— 开放世界原型（Godot 4.7）

秦末（公元前 209 年）题材的开放世界原型：程序化地形 + 2D 舆图 + 快速旅行。
地形和地貌全部由游戏自己的分类器从同一份高程数据求出（"一套数据"原则）。

> 技术交接（架构、数据链、分类规则、踩过的坑）：[docs/交接/交接_地图系统.md](docs/交接/交接_地图系统.md)
> 数据与仓库说明：[DATA.md](DATA.md)

## 目录结构

```
FengDi/
├─ Play.bat                启动游戏
├─ run_tests.bat           一键测试（6 项）
├─ config/                 配置表（人改的地方）
│   ├─ settlements.xlsx
│   ├─ schema.json         表结构 / 校验规则
│   └─ 同步配置表.bat       改完双击 → 生成 JSON
├─ game/                   Godot 工程
│   ├─ project.godot
│   ├─ scenes/ scripts/ shaders/ assets/
│   └─ data/
│      ├─ raw/             原始数据（高程、Hydro、城池源表）
│      ├─ generated/       工具生成（settlements.json、map_color.bin…）
│      ├─ textures/ biomes/
├─ tools/
│   ├─ map/                Python 数据工具（建图层、生成轮廓、编译配置表）
│   └─ test/               run_tests.ps1、map_pipeline.ps1
├─ artifacts/              截图 / 输出（不进 git）
└─ docs/                   策划、故事、模型、截图、交接
```

## 快速开始

环境：Godot **4.7**（Forward+）、Python **3.8+**（需要 openpyxl；装数据需要 numpy）。

```bash
python tools/get_data.py       # 下载约 280 MB 数据包到 game/data/raw/
```

然后任选一种：

- Windows：双击 `Play.bat`
- 或用 Godot 打开 `game/project.godot`

Godot 不在默认位置时，先设环境变量 `GODOT_EXE`。

## 改配置表

```
1. 打开 config\settlements.xlsx 改数据 → 保存 → 关闭
2. 双击 config\同步配置表.bat
3. 看到"已写出 settlements.json：1500 条" → 切回游戏，按 M 关掉地图再打开
```

- 表头三行固定：`##var`（字段名）/ `##type`（类型）/ `##`（说明），A 列只是指令列；
- 字段、类型、枚举、范围、唯一键、"每势力只能一个都城"等规则写在 `config/schema.json`；
- 校验不过会打印「第几行哪一列错」，**不写文件**，旧数据保持；
- 换图标/展示图：覆盖 `game/assets/map_icons/`、`game/assets/settle_images/` 里的同名 PNG，
  不用重新导入编辑器，开图即生效。

## 测试

```
双击 run_tests.bat
```

六项：`citytest`（城市场景）、`seamtest`（地形接缝）、`probe`（采样）、`selftest`（综合）、
`maptest`（2D 地图）、`bugtest`（窗口化交互，最慢约 40 s）。

改了 `main.gd` 先单独跑一次：

```
godot --headless --path game --check-only --script res://scripts/main.gd
```

改了着色器必须真开一次图——着色器编译错误只在完整输出里报 `SHADER ERROR`。

## 重新生成地图底图

```bash
python tools/map/build_map_layers.py              # 配色 + 阴影（约 2 分钟）
python tools/map/build_map_layers.py --contours   # 等高线
```

数据固定时不用重跑；改高程或配色方案才需要。

## 烘焙地貌编号图

`game/data/generated/landform_id.bin`（32 MB）不在数据包里。缺它游戏仍能跑，但 3D 撒点会退回
实时分类（慢几十倍）。需要时现烘（约 5 分钟，中途别中断）：

```powershell
godot --headless --path game --script res://tools/bake_landform_id.gd
```

## 常用调试参数

- `--start --fresh`：跳过标题直接开局
- `--map --mapzoom=120 --mapcenter=118.3,36.9`：直接开图并定位
- `--at=lon,lat`：3D 传送到坐标
- `--shots=path@frame`：指定帧截图
- `--pinkwater`：把水染成品红，确认水域位置
