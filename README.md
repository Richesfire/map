# 秦末 209BC · 地图模块

程序化全球地图：立方体球寻址 + 1km² 切平面地块 + 流式加载 + 3D 地球仪。
引擎 **Godot 4.7**。

## 目录

| 目录 | 内容 |
|---|---|
| `godot/` | 地图工程（IAS 动作系统 + 地图模块）。用 Godot 打开 `godot/project.godot` 后 F5 |
| `assets/` | 地图素材源文件：14 个地形的白模/纹理/植被，46 个植被零件（.blend + .glb + 预览） |

## 操作

| 键 | 作用 |
|---|---|
| WASD / 空格 / F / ~ | 走、跳、上马、观察镜头 |
| **Backspace** | 灵魂状态（自由飞行）/ 回到身体 |
| **M** | 打开世界地图（3D 地球仪，拖拽旋转、滚轮缩放） |
| Esc | 关地图 / 回身体 |

## 说明

- `godot/.godot/` 是 Godot 的导入缓存，已排除。首次打开工程会自动重建（约 30 秒）。
- `assets/零件/海洋/` 目前只有说明：海洋按策划要求不要植被，且代码侧还没有海平面与海陆掩膜。
- 详细接入说明见 `godot/INTEGRATION.md`，模块契约见 `godot/docs/MAP_API.md`。

## 数据表（Excel -> JSON）

地形数据的唯一编辑源是 **`data/地形表.xlsx`**，游戏只读导出的 JSON。

```
data/地形表.xlsx          ← 策划编辑这里（地形 / 零件 两页）
        │  tools/export_terrain.py
        ▼
godot/data/terrain_types.json   ← 运行时读这个，不要手改
```

导出：

```bash
python tools/export_terrain.py
```

导出时会校验并直接报错中止：
- 地形 id 重复
- 起伏下限大于上限
- 引用了不存在的零件 `.glb`

**零件共享**：同一个零件编号写进多个地形的「零件」页，导出后引用的是同一份
`godot/assets/parts/<编号>.glb`，不会产生重复文件，运行时也只有一份 mesh。