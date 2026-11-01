class_name MapAnnotation
extends RefCounted

## ==============================================================
## 地图标注（不是选定地块！）
##
## 区别很重要：
##   * **选定地块 DesignatedTile** = 你手工圈定、地图要特殊处理的一格。
##     默认一个都没有，全世界都是程序化生成。
##   * **标注 MapAnnotation** = 地图上的一个具名点，只影响小地图上画什么，
##     完全不影响地形、撒点、生成。想标多少标多少。
##
## 咸阳、罗马、迦太基这些属于标注，属于标注这一类。
## ==============================================================

## 唯一 ID
var id := ""
## 小地图上显示的名字
var label := ""
## 单位方向（球面上的一点）
var dir := Vector3.UP
## 分类，由内容模块自己定义语义（city / ruin / shrine / poi ...）
var kind := "poi"

## 想挂什么挂什么
var payload: Variant = null


static func from_lonlat(ann_id: String, ann_label: String, lon: float, lat: float,
		ann_kind: String = "city") -> MapAnnotation:
	var a := MapAnnotation.new()
	a.id = ann_id
	a.label = ann_label
	a.dir = GeoSphere.lonlat_to_dir(lon, lat)
	a.kind = ann_kind
	return a


func tile() -> Vector3i:
	return GeoSphere.dir_to_tile(dir)
