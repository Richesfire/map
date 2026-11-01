class_name DesignatedTile
extends RefCounted

## ==============================================================
## 选定地块 = 你手工圈定的一格（或几格）
##
## 翻成白话：**这一格我不用随机生成，我自己往里摆东西。**
## 它不是"世界地标"，不是"历史名城"，跟经纬度上的真实地点没有关系。
## 你圈哪儿就是哪儿。
##
## 地图对它的全部义务只有三条：
##   1. （可选）把这一格的地形压平 —— 默认不压，保留程序化起伏
##   2. （默认）这一格不撒树/石头/草丛，留白给你摆
##   3. 生成完发信号，告诉你这一格在局部坐标的哪，你把模型挂上去
##
## 剩下的一切——这格是什么、摆什么、有什么功能——都不归地图管。
## ==============================================================

## 唯一 ID，跨存档稳定，别用中文
var id := ""
## 备注，随便写，地图不解析
var note := ""

## 圈定的地块地址 Vector3i(面号, x, y)
var tile := Vector3i.ZERO
## 占几格 × 几格（同一立方体面内）。大多数情况就是 1 格。
var size_tiles := 1

## ---- 地形处理 ----
## 压平强度。**默认 0.0 = 保留程序化地形**，只有你明确要平台时才调大。
var flatten_amount := 0.0
## 压平半径（米）。以地块中心为圆心，会被夹到 ≤ 1000。
var flatten_radius_m := 500.0
## 压平的目标高度（米）。负数 = 自动取该点原始地形高度。
var flatten_height_m := -1.0

## ---- 撒点 ----
## 这一格里是否禁止撒点。默认禁止，留白给你摆东西。
var clear_scatter := true

## 解析后的实际压平高度（由 Registry 写入）
var resolved_height := 0.0

## 想挂什么挂什么，地图不关心
var payload: Variant = null


func center_dir() -> Vector3:
	return GeoSphere.tile_to_dir(tile + Vector3i(0, int(floor(float(size_tiles) * 0.5)),
			int(floor(float(size_tiles) * 0.5))))


## 到某个方向的球面距离（米）
func distance_m(dir: Vector3) -> float:
	return GeoSphere.distance_m(center_dir(), dir)


func contains_tile(t: Vector3i) -> bool:
	if t.x != tile.x:
		return false
	return t.y >= tile.y and t.y < tile.y + size_tiles \
			and t.z >= tile.z and t.z < tile.z + size_tiles
