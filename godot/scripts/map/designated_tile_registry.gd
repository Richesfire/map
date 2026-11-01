class_name DesignatedTileRegistry
extends RefCounted

## ==============================================================
## 选定地块登记表
##
## **默认是空的。** 空表意味着全世界都是未选定地块，全部程序化生成。
## 你圈一格就往里 add 一条，不圈就什么都不用做。
##
## 3×3 邻域查表的依据：压平半径被夹在一格（约 1km）以内，
## 所以任何一点能影响到的选定地块，一定在它所在格的 3×3 邻域里。
## 注意：邻域只在同一个立方体面内查。
## ==============================================================

var _all: Array = []
var _by_tile: Dictionary = {}          # Vector3i -> DesignatedTile
var _resolved := false


func add(dt: DesignatedTile) -> void:
	if dt.flatten_radius_m > 1000.0:
		dt.flatten_radius_m = 1000.0

	_all.append(dt)
	for dz in dt.size_tiles:
		for dy in dt.size_tiles:
			var t := dt.tile + Vector3i(0, dy, dz)
			_by_tile[t] = dt


## 把所有"自动高度"的选定地块按地形实际高度定死。必须在 TerrainNoise 建好之后调用一次。
func resolve(gen: TerrainNoise) -> void:
	for entry in _all:
		var dt := entry as DesignatedTile
		if dt == null:
			continue
		if dt.flatten_height_m < 0.0:
			dt.resolved_height = gen.height_at(dt.center_dir())
		else:
			dt.resolved_height = dt.flatten_height_m
	_resolved = true


func is_resolved() -> bool:
	return _resolved


func all() -> Array:
	return _all


func count() -> int:
	return _all.size()


func is_empty() -> bool:
	return _all.is_empty()


func at_tile(t: Vector3i) -> DesignatedTile:
	return _by_tile.get(t)


func at_dir(dir: Vector3) -> DesignatedTile:
	return _by_tile.get(GeoSphere.dir_to_tile(dir))


## 某个地块 3x3 邻域内所有可能影响它的选定地块（去重）
func near_tile(t: Vector3i) -> Array:
	return _collect(t)


func near_dir(dir: Vector3) -> Array:
	return _collect(GeoSphere.dir_to_tile(dir))


func _collect(center: Vector3i) -> Array:
	if _by_tile.is_empty():
		return []
	var out: Array = []
	var seen := {}
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			var t := Vector3i(center.x, center.y + dy, center.z + dz)
			if not _by_tile.has(t):
				continue
			var dt: DesignatedTile = _by_tile[t]
			if seen.has(dt):
				continue
			seen[dt] = true
			out.append(dt)
	return out


# ================================================================ 地形与撒点
## 把高度压向指定高度。flatten_amount 为 0 的地块完全不参与，代价为零。
static func apply_flatten(tiles: Array, dir: Vector3, base_h: float) -> float:
	var h := base_h
	for p in tiles:
		var dt: DesignatedTile = p
		if dt.flatten_amount <= 0.0:
			continue
		var d := dt.distance_m(dir)
		if d >= dt.flatten_radius_m:
			continue
		# 圆心 72% 以内是纯平台，外面一圈平滑过渡
		var t := 1.0 - smoothstep(dt.flatten_radius_m * 0.72, dt.flatten_radius_m, d)
		t *= dt.flatten_amount
		h = lerpf(h, dt.resolved_height, t)
	return h


## 这个点是否落在某个"禁止撒点"的选定地块里
static func is_scatter_blocked(tiles: Array, dir: Vector3) -> bool:
	for p in tiles:
		var dt: DesignatedTile = p
		if not dt.clear_scatter:
			continue
		if dt.distance_m(dir) < dt.flatten_radius_m:
			return true
	return false
