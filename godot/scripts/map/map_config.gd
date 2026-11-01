class_name MapConfig
extends Resource

## ==============================================================
## 地图模块的全部可调参数。
##
## 其他模块如果只是想读地图的规则（不生成、只查询），
## 拿一个 MapConfig 实例就够了，不需要碰渲染。
##
## preview/render_preview.py 里的常量与这里一一对应。
## ==============================================================

@export_group("地块")
## 单个地块边长（米）。总纲规定 1km²，不要随便改。
@export var tile_size_m := 1000.0
## 地块网格每边顶点数。129 = 128 个四边形，约 7.8 米一格。
@export var mesh_res := 129
## 是否给地块生成碰撞体（玩家/敌人要站在地上就必须开）
@export var collision := true

@export_group("地形白膜")
## 整体基准高度
@export var height_base := 40.0
## 域扭曲强度：让等高线自然弯曲，不至于是一堆规则圆丘
@export var warp_amp := 120.0
@export var warp_period := 700.0
## 三层起伏的波长(m) 与振幅(m)。只做简单起伏，没有山脊峭壁。
@export var layer_periods: Array[float] = [1400.0, 430.0, 150.0]
@export var layer_amps: Array[float] = [70.0, 25.0, 8.0]

@export_group("撒点")
## 撒点网格间距(米)：调大 = 更省性能，调小 = 更密
@export var tree_step_m := 7.0
@export var rock_step_m := 11.0
@export var low_veg_step_m := 5.0
## 三种零件的分布遮罩波长
@export var forest_period := 260.0
@export var rock_period := 150.0
@export var low_veg_period := 45.0

@export_group("地表纹理")
## 坡度多少度开始往泥土过渡 / 多少度全泥。地表只有 草 / 泥土 两层。
@export var grass_dirt_lo := 8.0
@export var grass_dirt_hi := 26.0

@export_group("选定地块")
## 是否给选定地块画占位标记。**默认关闭**，正式内容由你自己的模块挂。
@export var show_designated_markers := false
