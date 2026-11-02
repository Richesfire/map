class_name Exploration
extends RefCounted

## ==============================================================
## 探索记录
##
## 玩家走过的地方记为"已探索"。记录用经纬度网格（约 1.1km 一格），
## 存在 user://explored.dat，跨存档保留。
##
## 作用有两个：
##   1. 大地图上没去过的地方压一层旧地图迷雾
##   2. **限制缩放** —— 没去过的地方不能放大到村庄级，
##      这样就不需要为没去过的地方烘焙高清贴图
## ==============================================================

const CELL_DEG := 0.01            # 约 1.1 km
const REVEAL_KM := 1.0            # 玩家周围 1 公里照亮
const SAVE_PATH := "user://explored.dat"

## 已探索格子：key = "i_j"（i = 经度格号, j = 纬度格号）
var cells := {}


func _key(i: int, j: int) -> String:
	return "%d_%d" % [i, j]


func _cell_of(lon: float, lat: float) -> Vector2i:
	return Vector2i(int(floor(lon / CELL_DEG)), int(floor(lat / CELL_DEG)))


## 标记某点周围（半径约 REVEAL_KM）为已探索
func mark_lonlat(lon: float, lat: float) -> bool:
	var c := _cell_of(lon, lat)
	var r := int(ceil(REVEAL_KM / (CELL_DEG * 111.0)))
	var added := false
	for dj in range(-r, r + 1):
		for di in range(-r, r + 1):
			if di * di + dj * dj > r * r:
				continue
			var k := _key(c.x + di, c.y + dj)
			if not cells.has(k):
				cells[k] = true
				added = true
	return added


func is_explored_lonlat(lon: float, lat: float) -> bool:
	var c := _cell_of(lon, lat)
	return cells.has(_key(c.x, c.y))


func is_explored_dir(dir: Vector3) -> bool:
	var ll := GeoSphere.dir_to_lonlat(dir)
	return is_explored_lonlat(ll.x, ll.y)


func count() -> int:
	return cells.size()


func save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_var(cells)
	f.close()


func load_saved() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		return
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return
	var v: Variant = f.get_var()
	f.close()
	if v is Dictionary:
		cells = v
