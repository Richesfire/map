extends RefCounted
## 世界地形的唯一真源（single source of truth）。
##
## 策划案 3.2 的三层结构在这里落地：
##   ① 宏观底图   data/dem2k.bin（2.4km 全球高程，墨卡托）
##   ② 山体特征   data/mountain_features.json（位置/峰顶/山脚/范围/走向/种子）
##   ③ 局部高度图 全局坐标确定性噪声（同坐标同高度，不依赖玩家位置）
##
## 渲染、碰撞、植被、小地图、世界地图阴影全部调用本文件的函数，
## 不允许任何模块自己读 dem.bin 另行算高度。

const DEM2K_W := 16384
const DEM2K_H := 8192
const DEM_W := 4096
const DEM_H := 2048
const DEM_MIN := -11000.0
const DEM_MAX := 9000.0

const FEATURES_PATH := "res://data/mountain_features.json"
const BiomeLib := preload("res://scripts/biome_library.gd")

# ---- 地貌类型：温度带(9) × 湿度带(5) = 45 类，高地变体再 +45 ----
const B_LAND_MAX := 90
const B_OCEAN := 90
const B_ICE := 91
const B_SNOW := 92
const B_ROCK := 93
const BIOME_COUNT := 94

const TEMP_NAMES := ["寒带", "亚寒带", "冷温带", "温带", "暖温带", "亚热带", "热带边缘", "热带", "赤道带"]
const MOIST_NAMES := ["荒漠", "半荒漠", "干草原", "草原", "湿润"]

static var _dem: PackedByteArray = PackedByteArray()
static var _is_merc: bool = false
static var _gw: int = 0
static var _gh: int = 0
static var _lon0: float = -180.0
static var _lon1: float = 180.0
static var _lat0: float = 90.0
static var _lat1: float = -90.0
static var _mask: PackedByteArray = PackedByteArray()
# 近场高程补丁（局部高度图）
static var _ov: PackedByteArray = PackedByteArray()
static var _ov_w: int = 0
static var _ov_h: int = 0
static var _ov_lon0: float = 0.0
static var _ov_lon1: float = 0.0
static var _ov_lat0: float = 90.0
static var _ov_lat1: float = -90.0
static var _ov_blend: float = 6.0
static var _ov_ready: bool = false
static var _ov_disabled: bool = false
static var _cities: Array = []
const MASK_W := 4096
const MASK_H := 2048
static var _loaded: bool = false
static var _features: Array = []
static var _fa: Array = []                    # 打包特征（热路径）
static var _fseed: PackedInt32Array = PackedInt32Array()
static var _latmin: PackedFloat32Array = PackedFloat32Array()
static var _latmax: PackedFloat32Array = PackedFloat32Array()
static var _load_ms: int = 0
# 近场置换贴图（可平铺 R8）：0 平原 / 1 丘陵 / 2 山地脊 / 3 沙丘
static var _disp: Array = []
const DISP_PX := 64
const DISP_AMP := 6.0
const DISP_AMP_SCALE := 320.0
const DISP_TILE_M := 600.0


# =====================================================================
#  装载
# =====================================================================
static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var t0 := Time.get_ticks_msec()
	_load_dem()
	_load_features()
	_load_cities()
	_load_overlay_manifest()
	_load_ms = Time.get_ticks_msec() - t0
	print("[地形] 真源就绪：底图 %d 字节，山体特征 %d 条，用时 %d ms"
			% [_dem.size(), _features.size(), _load_ms])


static func _load_overlay_manifest() -> void:
	if _ov_disabled:
		return
	var f := FileAccess.open("res://data/overlay.json", FileAccess.READ)
	if f == null:
		return
	var js: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(js) != TYPE_DICTIONARY:
		return
	var p := String(js.get("path", ""))
	if p == "":
		return
	load_overlay(p, float(js.get("blend_km", 6.0)))


static func _load_dem() -> void:
	var f := FileAccess.open("res://data/dem2k.bin", FileAccess.READ)
	if f != null:
		_dem = f.get_buffer(f.get_length())
		f.close()
		_is_merc = false
		_gw = DEM2K_W
		_gh = DEM2K_H
		print("[地形] 2.4km 底图 %d 字节（等距圆柱 %dx%d）" % [_dem.size(), _gw, _gh])
		return
	f = FileAccess.open("res://data/dem.bin", FileAccess.READ)
	if f == null:
		print("[地形] 没有高程数据，用平地")
		return
	_dem = f.get_buffer(f.get_length())
	f.close()
	_is_merc = false
	_gw = DEM_W
	_gh = DEM_H
	print("[地形] 9.8km 底图 %d 字节" % _dem.size())


## 载入区域底图（同目录同名 .json 给出 w/h/lon0/lat0/lon1/lat1）
## 用于「300m 真值 vs 2.4km/1.2km 生成」的 A/B/C 对照。
static func load_custom(path: String) -> bool:
	var meta_path := path.get_basename() + ".json"
	if not FileAccess.file_exists(meta_path):
		meta_path = path + ".json"
	var jf := FileAccess.open(meta_path, FileAccess.READ)
	if jf == null:
		print("[地形] 缺少区域元数据：", meta_path)
		return false
	var meta: Variant = JSON.parse_string(jf.get_as_text())
	jf.close()
	if typeof(meta) != TYPE_DICTIONARY:
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	_dem = f.get_buffer(f.get_length())
	f.close()
	_gw = int(meta.get("w", 0))
	_gh = int(meta.get("h", 0))
	_lon0 = float(meta.get("lon0", -180.0))
	_lon1 = float(meta.get("lon1", 180.0))
	_lat0 = float(meta.get("lat0", 90.0))
	_lat1 = float(meta.get("lat1", -90.0))
	_is_merc = false
	_loaded = true
	if _features.is_empty():
		_load_features()
	print("[地形] 区域底图 %s  %dx%d  lon %.2f..%.2f lat %.2f..%.2f"
			% [path.get_file(), _gw, _gh, _lon0, _lon1, _lat0, _lat1])
	return true


static func _load_features() -> void:
	var f := FileAccess.open(FEATURES_PATH, FileAccess.READ)
	if f == null:
		print("[地形] 没有山体特征表，只用地形底图")
		return
	var txt := f.get_as_text()
	f.close()
	var js: Variant = JSON.parse_string(txt)
	if typeof(js) != TYPE_DICTIONARY:
		print("[地形] 山体特征表解析失败")
		return
	var arr: Array = js.get("features", [])
	for d in arr:
		if typeof(d) != TYPE_DICTIONARY:
			continue
		var flon := float(d.get("lon", 0.0))
		var flat := float(d.get("lat", 0.0))
		var halflen := maxf(float(d.get("length_km", 200.0)) * 0.5, 1.0)
		var halfwid := maxf(float(d.get("width_km", 60.0)) * 0.5, 1.0)
		var az := deg_to_rad(float(d.get("azimuth", 0.0)))
		var su := sin(az)
		var cu := cos(az)
		var radius := sqrt(halflen * halflen + halfwid * halfwid)
		# 主峰在走向坐标系里的位置（可给真实峰顶坐标，缺省取山系中心）
		var plon := float(d.get("peak_lon", flon))
		var plat := float(d.get("peak_lat", flat))
		var pdx := (plon - flon) * 111.32 * cos(deg_to_rad(flat))
		var pdy := (plat - flat) * 110.54
		var pk := float(d.get("peak", 2000.0))
		var ft := float(d.get("foot", 200.0))
		var shp := maxf(float(d.get("shape", 1.35)), 0.2)
		var gr := clampf(float(d.get("grain", 0.12)), 0.0, 0.5)
		var sd := int(d.get("seed", 1))
		var pu := clampf(pdx * su + pdy * cu, -halflen * 0.9, halflen * 0.9)
		var pv := clampf(pdx * cu - pdy * su, -halfwid * 0.6, halfwid * 0.6)
		var cosl := maxf(cos(deg_to_rad(flat)), 0.02)
		_features.append({
			"name": String(d.get("name", "")),
			"lon": flon, "lat": flat, "cosl": cosl,
			"peak": pk, "foot": ft,
			"halflen": halflen, "halfwid": halfwid,
			"su": su, "cu": cu,
			"shape": shp, "grain": gr, "seed": sd,
			"pu": pu, "pv": pv,
			"dlat": radius / 110.54 + 0.15,
			"radius": radius,
		})
		var packed := PackedFloat64Array([
			flon, flat, cosl, pk, ft, halflen, halfwid,
			su, cu, shp, gr, pu, pv,
		])
		_fa.append(packed)
		_fseed.append(sd)
		_latmin.append(flat - radius / 110.54 - 0.2)
		_latmax.append(flat + radius / 110.54 + 0.2)
	print("[地形] 山体特征 %d 条" % _features.size())


static func feature_names() -> Array:
	ensure_loaded()
	var out: Array = []
	for f in _features:
		out.append(f["name"])
	return out


# =====================================================================
#  ① 宏观底图
# =====================================================================
static func _merc_y(lat: float) -> float:
	var la := clampf(lat, -85.05, 85.05)
	var r := deg_to_rad(la)
	return (1.0 - log(tan(r) + 1.0 / cos(r)) / PI) * 0.5


static func dem_at(lon: float, lat: float) -> float:
	if _dem.is_empty():
		return 0.0
	var gw := _gw
	var gh := _gh
	var fx := ((lon - _lon0) / (_lon1 - _lon0) * float(gw)) - 0.5
	var fy := ((_lat0 - lat) / (_lat0 - _lat1) * float(gh)) - 0.5
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var acc := 0.0
	var dem := _dem
	var size := dem.size()
	for dy in 2:
		var py := clampi(y0 + dy, 0, gh - 1) * gw
		var wy := ty if dy == 1 else 1.0 - ty
		for dx in 2:
			var i := (py + clampi(x0 + dx, 0, gw - 1)) * 2
			if i + 1 >= size:
				continue
			var raw := float(dem[i]) + float(dem[i + 1]) * 256.0
			acc += (raw / 65535.0 * (DEM_MAX - DEM_MIN) + DEM_MIN) * wy * (tx if dx == 1 else 1.0 - tx)
	return acc


# =====================================================================
#  ② 山体特征层
# =====================================================================
## 在底图之上按“替换目标高度”抬升，而不是把峰顶海拔直接加上去，
## 因此重叠的多个山体不会重复抬升（只会向更高的目标收敛）。
static func _raise(lon: float, lat: float, h: float,
		flon: float, flat: float, cosl: float, peak: float, foot: float,
		halflen: float, halfwid: float, su: float, cu: float,
		shape: float, grain: float, seed: int, pu: float, pv: float) -> float:
	var dlon := lon - flon
	if dlon > 180.0:
		dlon -= 360.0
	elif dlon < -180.0:
		dlon += 360.0
	var dx := dlon * 111.32 * cosl
	var dy := (lat - flat) * 110.54
	var u := dx * su + dy * cu
	if absf(u) > halflen:
		return h
	var v := dx * cu - dy * su
	if absf(v) > halfwid:
		return h
	# 已经高于这条山脉能抬到的上限，直接跳过（省掉两次噪声）
	if h >= peak * 1.15:
		return h

	# 主峰 / 山脊补高：以真实峰顶为中心，沿走向拉长的高斯。
	# 底图已经把山脉画出来了，这里只补“被平滑掉的高度”，所以窗口很小，
	# 山脚和平原不会被整体垫高。
	var sgu := clampf(halfwid * 0.8, 3.0, 12.0)
	var sgv := clampf(halfwid * 0.4, 2.5, 8.0)
	var du := (u - pu) / sgu
	var dv := (v - pv) / sgv
	var hub := exp(-(du * du + dv * dv))
	if hub < 0.002:
		return h
	var target := h + (peak - h) * hub
	# 主峰附近的脊状起伏
	var g := _vnoise(u * 0.045 + 11.3, v * 0.055 - 7.7, seed + 91) * 2.0 - 1.0
	g = 1.0 - absf(g) * 1.6
	target += (peak - h) * hub * grain * g
	target = minf(target, peak)
	if target <= h:
		return h
	return target


static func _raise_packed(lon: float, lat: float, h: float, f: PackedFloat64Array, seed: int) -> float:
	return _raise(lon, lat, h, f[0], f[1], f[2], f[3], f[4], f[5], f[6],
			f[7], f[8], f[9], f[10], seed, f[11], f[12])


static func _feature_raise(f: Dictionary, lon: float, lat: float, h: float) -> float:
	return _raise(lon, lat, h, float(f['lon']), float(f['lat']), float(f['cosl']),
			float(f['peak']), float(f['foot']), float(f['halflen']), float(f['halfwid']),
			float(f['su']), float(f['cu']), float(f['shape']), float(f['grain']),
			int(f['seed']), float(f['pu']), float(f['pv']))


static func _load_mask() -> void:
	var f := FileAccess.open("res://data/land_mask.bin", FileAccess.READ)
	if f == null:
		return
	_mask = f.get_buffer(f.get_length())
	f.close()
	print("[地形] 海陆掩膜 %d 字节" % _mask.size())


## 掩膜判定是否水域（世界地图用；三维地形用高度判断即可）
static func is_water(lon: float, lat: float) -> bool:
	if _mask.is_empty():
		return false
	var x := clampi(int((lon + 180.0) / 360.0 * MASK_W), 0, MASK_W - 1)
	var y := clampi(int((90.0 - lat) / 180.0 * MASK_H), 0, MASK_H - 1)
	return _mask[y * MASK_W + x] <= 127


## 手工城市（策划案 3.2：城市保护范围内地表不受程序置换影响）
static func _load_cities() -> void:
	var f := FileAccess.open("res://data/cities.json", FileAccess.READ)
	if f == null:
		return
	var js: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(js) != TYPE_DICTIONARY:
		return
	for c in js.get("cities", []):
		_cities.append({
			"id": String(c.get("id", "")),
			"name": String(c.get("name", "")),
			"lon": float(c.get("lon", 0.0)),
			"lat": float(c.get("lat", 0.0)),
			"radius": float(c.get("radius_km", 1.5)),
			"blend": maxf(float(c.get("blend_km", 4.0)), 0.2),
			"height": float(c.get("height", 0.0)),
			"coslat": maxf(cos(deg_to_rad(float(c.get("lat", 0.0)))), 0.05),
		})
	# height 为 0 的按底图自动取（dem_at 不依赖城市，不会递归）
	for i in _cities.size():
		var c2: Dictionary = _cities[i]
		if float(c2["height"]) <= 0.001:
			c2["height"] = dem_at(float(c2["lon"]), float(c2["lat"])) + 3.0
			_cities[i] = c2
	if not _cities.is_empty():
		print("[地形] 手工城市 %d 座" % _cities.size())


static func cities() -> Array:
	ensure_loaded()
	return _cities


## 城市权重与手工高程：x = 权重（1=完全手工地面），y = 手工高程
static func city_blend(lon: float, lat: float) -> Vector2:
	var best_w := 0.0
	var best_h := 0.0
	for i in _cities.size():
		var c: Dictionary = _cities[i]
		var cosl: float = c["coslat"]
		var dx := (lon - float(c["lon"])) * 111.32 * cosl
		var dy := (lat - float(c["lat"])) * 110.54
		var d := sqrt(dx * dx + dy * dy)
		var r := float(c["radius"])
		var b := float(c["blend"])
		if d >= r + b:
			continue
		var w := 1.0 - smoothstep(r, r + b, d)
		if w > best_w:
			best_w = w
			best_h = float(c["height"])
	return Vector2(best_w, best_h)


## 载入近场补丁（同目录同名 .json 给边界）
static func load_overlay(path: String, blend_km: float = 6.0) -> bool:
	var meta_path := path.get_basename() + ".json"
	if not FileAccess.file_exists(meta_path):
		meta_path = path + ".json"
	var jf := FileAccess.open(meta_path, FileAccess.READ)
	if jf == null:
		print("[地形] 近场补丁缺少元数据：", meta_path)
		return false
	var meta: Variant = JSON.parse_string(jf.get_as_text())
	jf.close()
	if typeof(meta) != TYPE_DICTIONARY:
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	_ov = f.get_buffer(f.get_length())
	f.close()
	_ov_w = int(meta.get("w", 0))
	_ov_h = int(meta.get("h", 0))
	_ov_lon0 = float(meta.get("lon0", -180.0))
	_ov_lon1 = float(meta.get("lon1", 180.0))
	_ov_lat0 = float(meta.get("lat0", 90.0))
	_ov_lat1 = float(meta.get("lat1", -90.0))
	_ov_blend = maxf(blend_km, 0.5)
	_ov_ready = _ov.size() == _ov_w * _ov_h * 2
	print("[地形] 近场补丁 %s  %dx%d  lon %.2f..%.2f lat %.2f..%.2f  融合 %.1f km"
			% [path.get_file(), _ov_w, _ov_h, _ov_lon0, _ov_lon1, _ov_lat0, _ov_lat1, _ov_blend])
	return _ov_ready


static func disable_overlay() -> void:
	_ov_ready = false
	_ov_disabled = true
	_ov = PackedByteArray()
	print("[地形] 近场补丁已关闭")


## 补丁内双线性采样
static func overlay_at(lon: float, lat: float) -> float:
	if not _ov_ready:
		return 0.0
	var fx := ((lon - _ov_lon0) / (_ov_lon1 - _ov_lon0) * float(_ov_w)) - 0.5
	var fy := ((_ov_lat0 - lat) / (_ov_lat0 - _ov_lat1) * float(_ov_h)) - 0.5
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var acc := 0.0
	var ov := _ov
	var size := ov.size()
	for dy in 2:
		var py := clampi(y0 + dy, 0, _ov_h - 1) * _ov_w
		var wy := ty if dy == 1 else 1.0 - ty
		for dx in 2:
			var i := (py + clampi(x0 + dx, 0, _ov_w - 1)) * 2
			if i + 1 >= size:
				continue
			var raw := float(ov[i]) + float(ov[i + 1]) * 256.0
			acc += (raw / 65535.0 * (DEM_MAX - DEM_MIN) + DEM_MIN) * wy * (tx if dx == 1 else 1.0 - tx)
	return acc


## 补丁权重：越靠近补丁边缘越小，0 表示完全不用补丁
static func overlay_weight(lon: float, lat: float) -> float:
	if not _ov_ready:
		return 0.0
	if lon < _ov_lon0 or lon > _ov_lon1 or lat > _ov_lat0 or lat < _ov_lat1:
		return 0.0
	var cosl := maxf(cos(deg_to_rad(lat)), 0.05)
	var d_w := (lon - _ov_lon0) * 111.32 * cosl
	var d_e := (_ov_lon1 - lon) * 111.32 * cosl
	var d_n := (_ov_lat0 - lat) * 110.54
	var d_s := (lat - _ov_lat1) * 110.54
	var d := minf(minf(d_w, d_e), minf(d_n, d_s))
	return smoothstep(0.0, _ov_blend, d)


## 底图（有近场补丁时按权重混合）
static func base_height(lon: float, lat: float) -> float:
	var h := dem_at(lon, lat)
	if _ov_ready:
		var w := overlay_weight(lon, lat)
		if w > 0.001:
			h = lerpf(h, overlay_at(lon, lat), w)
	return h


## 只叠山体特征（不含底图与细节）
static func _features_only(h: float, lon: float, lat: float) -> float:
	for i in _fa.size():
		if lat < _latmin[i] or lat > _latmax[i]:
			continue
		h = _raise_packed(lon, lat, h, _fa[i], _fseed[i])
	return h


## 宏观地势：底图（含近场补丁）+ 山体特征（不含细节噪声）—— 地图阴影用的就是它
static func macro_height(lon: float, lat: float) -> float:
	ensure_loaded()
	return _macro(lon, lat, city_blend(lon, lat))


static func _macro(lon: float, lat: float, cb: Vector2) -> float:
	var h := _features_only(base_height(lon, lat), lon, lat)
	if cb.x > 0.001:
		h = lerpf(h, cb.y, cb.x)
	return h


## 同上，但强制不用近场补丁（接缝对照用）
static func macro_height_no_ov(lon: float, lat: float) -> float:
	ensure_loaded()
	return _features_only(dem_at(lon, lat), lon, lat)


# =====================================================================
#  ③ 局部高度图（全局坐标确定性噪声）
# =====================================================================
static func _hash(ix: int, iy: int, seed: int) -> float:
	var n: int = (ix * 73856093) ^ (iy * 19349663) ^ (seed * 83492791)
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0xFFFFFF) / 16777215.0


static func _vnoise(x: float, y: float, seed: int) -> float:
	var ix := int(floor(x))
	var iy := int(floor(y))
	var fx := x - float(ix)
	var fy := y - float(iy)
	var sx := fx * fx * (3.0 - 2.0 * fx)
	var sy := fy * fy * (3.0 - 2.0 * fy)
	var a := _hash(ix, iy, seed)
	var b := _hash(ix + 1, iy, seed)
	var c := _hash(ix, iy + 1, seed)
	var d := _hash(ix + 1, iy + 1, seed)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy)


static func _fbm(x: float, y: float, seed: int, octaves: int) -> float:
	var amp := 0.5
	var freq := 1.0
	var acc := 0.0
	var norm := 0.0
	for i in octaves:
		acc += (_vnoise(x * freq, y * freq, seed + i * 131) * 2.0 - 1.0) * amp
		norm += amp
		amp *= 0.5
		freq *= 2.03
	if norm <= 0.0:
		return 0.0
	return acc / norm


## 可平铺的 2D 值噪声：period 为格点数，超出即回绕 → 贴图无缝
static func _tile_vnoise(x: float, y: float, period: int, seed: int) -> float:
	var ix := int(floor(x))
	var iy := int(floor(y))
	var fx := x - float(ix)
	var fy := y - float(iy)
	var sx := fx * fx * (3.0 - 2.0 * fx)
	var sy := fy * fy * (3.0 - 2.0 * fy)
	var x0 := ((ix % period) + period) % period
	var y0 := ((iy % period) + period) % period
	var x1 := (x0 + 1) % period
	var y1 := (y0 + 1) % period
	var a := _hash(x0, y0, seed)
	var b := _hash(x1, y0, seed)
	var c := _hash(x0, y1, seed)
	var d := _hash(x1, y1, seed)
	return lerpf(lerpf(a, b, sx), lerpf(c, d, sx), sy)


static func _tile_fbm(x: float, y: float, period: int, seed: int, ridged: bool) -> float:
	var v := _tile_vnoise(x, y, period, seed) * 0.65
	v += _tile_vnoise(x * 2.0, y * 2.0, period * 2, seed + 7) * 0.35
	if ridged:
		v = 1.0 - absf(v * 2.0 - 1.0)
	return clampf(v, 0.0, 1.0)


## 四张置换贴图：平原(缓)、丘陵(中)、山地(脊)、沙丘(波)
static func _build_disp() -> void:
	if not _disp.is_empty():
		return
	var seeds := [1101, 2203, 3307, 4409, 5519, 6607, 7717, 8803, 9901, 12007, 13043]
	var ridged := [false, false, true, false, false, true, true, false, true, true, false]
	var total := 11
	for k in total:
		var buf := PackedByteArray()
		buf.resize(DISP_PX * DISP_PX)
		for y in DISP_PX:
			for x in DISP_PX:
				var u := float(x) / float(DISP_PX)
				var v := float(y) / float(DISP_PX)
				var val := _tile_fbm(u * 8.0, v * 8.0, 8, seeds[k], ridged[k])
				if k == 3:
					# 沙丘：叠一条低频波
					val = clampf(val * 0.55 + 0.45 * (0.5 + 0.5 * sin(u * TAU * 3.0 + val * 2.0)), 0.0, 1.0)
				elif k == 4:
					# 水面/湿地的缓波
					val = clampf(val * 0.6 + 0.4 * (0.5 + 0.5 * sin(v * TAU * 2.0 + val * 3.0)), 0.0, 1.0)
				elif k == 6:
					# 喀斯特：溶蚀洼地 + 石芽
					var pit := _tile_vnoise(u * 26.0, v * 26.0, 26, seeds[k])
					val = clampf(val * 0.55 + 0.45 * (1.0 - smoothstep(0.42, 0.75, pit)), 0.0, 1.0)
				elif k == 7:
					# 雅丹：平行风蚀垄
					val = clampf(val * 0.5 + 0.5 * (0.5 + 0.5 * sin(u * TAU * 7.0 + val * 2.4)), 0.0, 1.0)
				elif k == 8:
					# 黄土：树枝状沟壑
					var gx := _tile_vnoise(u * 14.0, v * 3.0, 14, seeds[k])
					val = clampf(1.0 - absf(gx * 2.0 - 1.0) * 1.6, 0.0, 1.0) * 0.75 + val * 0.25
				elif k == 9:
					# 冰裂/碎石：多组方向交错的裂隙
					var c1 := _tile_vnoise(u * 11.0, v * 11.0, 11, seeds[k])
					var c2 := _tile_vnoise(u * 17.0 + 5.0, v * 17.0 - 3.0, 17, seeds[k] + 1)
					var cr := minf(c1, c2)
					val = clampf(1.0 - smoothstep(0.16, 0.42, cr) * 1.25 + val * 0.30, 0.0, 1.0)
				elif k == 10:
					# 缓波：低频大起伏（平原/盆地用）
					val = clampf(0.35 + 0.65 * _tile_fbm(u * 2.2, v * 2.2, 4, seeds[k], false), 0.0, 1.0)
				buf[y * DISP_PX + x] = int(clampf(val, 0.0, 1.0) * 255.0)
		_disp.append(buf)
	print("[地形] 置换贴图 %d 张（%dpx，平铺 %.0f m）" % [_disp.size(), DISP_PX, DISP_TILE_M])


## 双线性采样置换贴图（可平铺），返回 0..1
static func _disp_at(k: int, u: float, v: float) -> float:
	var b: PackedByteArray = _disp[k]
	var fx := u * float(DISP_PX)
	var fy := v * float(DISP_PX)
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var xa := ((x0 % DISP_PX) + DISP_PX) % DISP_PX
	var ya := ((y0 % DISP_PX) + DISP_PX) % DISP_PX
	var xb := (xa + 1) % DISP_PX
	var yb := (ya + 1) % DISP_PX
	var c00 := float(b[ya * DISP_PX + xa])
	var c10 := float(b[ya * DISP_PX + xb])
	var c01 := float(b[yb * DISP_PX + xa])
	var c11 := float(b[yb * DISP_PX + xb])
	return lerpf(lerpf(c00, c10, tx), lerpf(c01, c11, tx), ty) / 255.0


## 细节起伏：细尺度 ~1km（近处）+ 粗尺度 ~6km（远景也能看出山脊沟谷）
static func _amp(h: float) -> float:
	if h > 2200.0:
		return 32.0
	if h > 900.0:
		return 24.0
	if h > 350.0:
		return 16.0
	if h > 80.0:
		return 13.0
	return 10.0


static func detail_fine(lon: float, lat: float, h: float) -> float:
	if h < -2.0:
		return 0.0
	_build_disp()
	var mx := lon * 111320.0 * cos(deg_to_rad(lat))
	var my := lat * 110540.0
	var u := mx / DISP_TILE_M
	var v := my / DISP_TILE_M

	# 按高程连续混合三类地形（不会在边界出现台阶）
	var w_ridge := smoothstep(700.0, 1700.0, h)
	var w_hill := smoothstep(120.0, 620.0, h) * (1.0 - w_ridge)
	var w_flat := maxf(1.0 - w_ridge - w_hill, 0.0)
	# 干燥低地（草原/荒漠）用沙丘纹
	var w_dune := 0.0
	var moist := _vnoise(lon * 0.42 + 100.0, lat * 0.42 - 30.0, 2027)
	var belt := clampf(1.0 - absf(absf(lat) - 25.0) / 13.0, 0.0, 1.0)
	if h < 900.0:
		w_dune = clampf((0.42 - moist * (1.0 - 0.62 * belt)) * 3.0, 0.0, 1.0) * (1.0 - w_hill - w_ridge)
		w_flat = maxf(w_flat - w_dune, 0.0)

	var dv := 0.0
	# 置换贴图是“近处细节”，振幅必须跟波长匹配：600m 尺度只给 1.5~4m
	# 振幅/平铺尺度/用哪两张贴图，全部来自该地貌的配置
	var kind := landform_kind(lon, lat, h)
	var prof: Dictionary = BiomeLib.profile_for(kind)
	# 简化：每种地貌只用一张置换图，振幅/尺度全局统一，起伏性格由贴图本身表达
	var ids: Array = prof["disp_tiles"]
	var u2 := mx / DISP_AMP_SCALE
	var v2 := my / DISP_AMP_SCALE
	dv = _disp_at(int(ids[0]), u2, v2)
	var d := (dv - 0.5) * 2.0 * DISP_AMP

	# 坡度越大越“崎岖”：用底图梯度估个坡，陡坡加脊状起伏、平地保持平缓
	var dd := 0.0018
	var h_e := dem_at(lon + dd, lat)
	var h_n := dem_at(lon, lat + dd)
	var kmk := dd * 111.0
	var slope := sqrt(pow((h_e - h) / kmk, 2.0) + pow((h_n - h) / kmk, 2.0))
	var sk := clampf(slope / 260.0, 0.0, 1.0)
	var x := lon * 111.32 * cos(deg_to_rad(lat)) * 0.001
	var y := lat * 110.54 * 0.001
	var rough := 1.0 - absf(_fbm(x * 2.6, y * 2.6, 551, 3) * 2.0 - 1.0)
	var fine := _vnoise(x * 14.0, y * 14.0, 733)
	d += (rough - 0.5) * 2.0 * (1.2 + DISP_AMP * 0.35 * sk)
	d += (fine - 0.5) * 2.0 * (0.4 + DISP_AMP * 0.12 * sk)
	return d


# =====================================================================
#  地形模块拼装（stamp）：小 heightfield 按格子摆放、旋转、叠到宏观地形上
# =====================================================================
const CELL_M := 2048.0          # 格子边长（米，x=经度方向、y=纬度方向）
const SN := 129                 # 模块贴图分辨率
const SN_F := 129.0
const STAMP_KINDS := 6          # 0 山脊 / 1 孤峰 / 2 V谷 / 3 台地 / 4 缓丘 / 5 陡坎
## 近景只加视觉细节，不改宏观地形 —— 模块振幅置 0（按《地貌分类系统》第 48/160 条）
const STAMP_SCALE := 0.0

static var _stamp_tex: Array = []
static var _cell_cache: Dictionary = {}

## 模块贴图：返回 -1..1 的高度（未乘振幅），边缘已压到 0
static func _build_stamp(kind: int) -> PackedFloat32Array:
	var a := PackedFloat32Array()
	a.resize(SN * SN)
	for j in SN:
		for i in SN:
			var u := (float(i) + 0.5) / SN_F * 2.0 - 1.0
			var v := (float(j) + 0.5) / SN_F * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var val := 0.0
			match kind:
				0:
					# 山脊：一条略微弯曲的脊线，两侧下切
					var d := absf(v - 0.32 * sin(u * 3.4))
					val = maxf(0.0, 1.0 - d * 3.0) * (0.62 + 0.55 * _vnoise(u * 4.0, v * 4.0, 11))
					val *= 0.75 + 0.35 * (1.0 - absf(u))
				1:
					# 孤峰：锥形 + 噪声
					val = pow(maxf(0.0, 1.0 - r), 1.2) * (0.55 + 0.65 * _vnoise(u * 5.0, v * 5.0, 12))
				2:
					# V 形谷（负高度）
					var d2 := absf(v - 0.28 * sin(u * 2.6))
					val = -maxf(0.0, 1.0 - d2 * 2.4) * (0.65 + 0.45 * _vnoise(u * 3.0, v * 3.0, 13))
				3:
					# 台地：平顶 + 陡边
					val = smoothstep(0.92, 0.62, r) * (0.88 + 0.22 * _vnoise(u * 2.0, v * 2.0, 14))
				4:
					# 缓丘
					val = pow(maxf(0.0, 1.0 - r * r), 1.4) * (0.82 + 0.32 * _vnoise(u * 2.5, v * 2.5, 15))
				5:
					# 陡坎：一侧高、一侧低，中间陡降
					val = smoothstep(-0.30, 0.30, v) * (0.85 + 0.25 * _vnoise(u * 3.0, v * 3.0, 16))
			var edge := 1.0 - smoothstep(0.74, 1.0, maxf(absf(u), absf(v)))
			a[j * SN + i] = val * edge
	return a


static func _ensure_stamps() -> void:
	if not _stamp_tex.is_empty():
		return
	for k in STAMP_KINDS:
		_stamp_tex.append(_build_stamp(k))
	print("[地形] 地形模块 %d 种就绪" % STAMP_KINDS)


static func _sample_stamp(k: int, u: float, v: float) -> float:
	var a: PackedFloat32Array = _stamp_tex[k]
	var fx := (u * 0.5 + 0.5) * SN_F - 0.5
	var fy := (v * 0.5 + 0.5) * SN_F - 0.5
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	var xa := clampi(x0, 0, SN - 1)
	var xb := clampi(x0 + 1, 0, SN - 1)
	var ya := clampi(y0, 0, SN - 1) * SN
	var yb := clampi(y0 + 1, 0, SN - 1) * SN
	var c00 := a[ya + xa]
	var c10 := a[ya + xb]
	var c01 := a[yb + xa]
	var c11 := a[yb + xb]
	return lerpf(lerpf(c00, c10, tx), lerpf(c01, c11, tx), ty)


## 该格子里放哪些模块（确定性：只由格子坐标决定）
static func _cell_stamps(cx: int, cy: int) -> Array:
	var key := Vector2i(cx, cy)
	if _cell_cache.has(key):
		return _cell_cache[key]
	_ensure_stamps()
	var out: Array = []
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(key) ^ 0x9E3779B9

	# 该格子的宏观海拔与纬度（决定放山还是放丘）
	var clat := ((float(cy) + 0.5) * CELL_M) / 110540.0
	var clon := ((float(cx) + 0.5) * CELL_M) / 111320.0
	var hh := macro_height(clon, clat)

	var n := 0
	if hh > 1500.0:
		n = 2
	elif hh > 700.0:
		n = rng.randi_range(1, 2)
	elif hh > 250.0:
		n = 1 if rng.randf() < 0.75 else 0
	else:
		n = 1 if rng.randf() < 0.35 else 0

	for i in n:
		var kind := 4
		var amp := 12.0
		if hh > 2600.0:
			kind = [0, 0, 1, 1, 3, 5][rng.randi_range(0, 5)]
			amp = rng.randf_range(140.0, 240.0)
		elif hh > 1500.0:
			kind = [0, 1, 2, 3, 5][rng.randi_range(0, 4)]
			amp = rng.randf_range(90.0, 170.0)
		elif hh > 700.0:
			kind = [0, 1, 2, 4][rng.randi_range(0, 3)]
			amp = rng.randf_range(40.0, 90.0)
		elif hh > 250.0:
			kind = [2, 4, 5][rng.randi_range(0, 2)]
			amp = rng.randf_range(15.0, 40.0)
		else:
			kind = [2, 4][rng.randi_range(0, 1)]
			amp = rng.randf_range(6.0, 18.0)
		# 谷地是负高度
		if kind == 2:
			amp = -amp * 0.8

		var size := rng.randf_range(950.0, 1500.0)
		var sx := (float(cx) + rng.randf_range(0.28, 0.72)) * CELL_M
		var sy := (float(cy) + rng.randf_range(0.28, 0.72)) * CELL_M
		out.append({
			"kind": kind, "amp": amp, "size": size,
			"x": sx, "y": sy, "rot": rng.randf() * TAU,
			"cos": cos(rng.randf() * TAU), "sin": sin(rng.randf() * TAU),
		})
	_cell_cache[key] = out
	return out


## 查询某点被模块抬升/压低多少米
static func stamps_height(lon: float, lat: float) -> float:
	if STAMP_SCALE <= 0.0:
		return 0.0
	var mx := lon * 111320.0
	var my := lat * 110540.0
	var cx := int(floor(mx / CELL_M))
	var cy := int(floor(my / CELL_M))
	var add := 0.0
	for dy in [-1, 0, 1]:
		for dx in [-1, 0, 1]:
			for s in _cell_stamps(cx + dx, cy + dy):
				var px: float = mx - float(s["x"])
				var py: float = my - float(s["y"])
				var c: float = s["cos"]
				var sn: float = s["sin"]
				# 反向旋转到模块局部坐标
				var lx := px * c + py * sn
				var ly := -px * sn + py * c
				var half: float = float(s["size"]) * 0.5
				var u := lx / half
				var v := ly / half
				if absf(u) > 1.0 or absf(v) > 1.0:
					continue
				var w := 1.0 - smoothstep(0.74, 1.0, maxf(absf(u), absf(v)))
				add += _sample_stamp(int(s["kind"]), u, v) * float(s["amp"]) * w * STAMP_SCALE
	return add


# =====================================================================
#  地貌形态分类（《地貌分类系统》第三节的 12 个一级地貌）
# =====================================================================
const LF_PLAIN := 0
const LF_HILL := 1
const LF_MOUNTAIN := 2
const LF_PLATEAU := 3
const LF_BASIN := 4
const LF_VALLEY := 5
const LF_DESERT := 6
const LF_STEPPE := 7
const LF_FOREST := 8
const LF_WETLAND := 9
const LF_ICE := 10
const LF_COAST := 11
const LF_KARST := 12
const LF_YARDANG := 13
const LF_LOESS := 14
const LF_DUNE := 15
const LF_GLACIAL := 16
const LF_DELTA := 17
const LF_MTN_GRANITE := 18
const LF_MTN_KARST := 19
const LF_MTN_LOESS := 20
const LF_MTN_VOLCANIC := 21
const LF_MTN_ICE := 22
const LF_HILL_RED := 23
const LF_HILL_LOESS := 24
const LF_HILL_DANXIA := 25
const LF_DESERT_SAND := 26
const LF_DESERT_GOBI := 27
const LF_DESERT_SALT := 28
const LF_COUNT := 29

## 地貌类型的代表色（地图/小地图共用，和地表观感对应）
const LF_COLORS := [
	Color(0.55, 0.60, 0.36),  # 0 平原
	Color(0.50, 0.55, 0.34),  # 1 丘陵
	Color(0.46, 0.44, 0.40),  # 2 山地
	Color(0.62, 0.58, 0.42),  # 3 高原
	Color(0.52, 0.55, 0.38),  # 4 盆地
	Color(0.42, 0.52, 0.38),  # 5 河谷
	Color(0.80, 0.72, 0.50),  # 6 荒漠
	Color(0.66, 0.64, 0.40),  # 7 草原
	Color(0.30, 0.42, 0.24),  # 8 森林
	Color(0.34, 0.44, 0.36),  # 9 湿地
	Color(0.86, 0.88, 0.90),  # 10 冰雪
	Color(0.78, 0.74, 0.56),  # 11 海岸
	Color(0.56, 0.54, 0.46),  # 12 喀斯特
	Color(0.74, 0.60, 0.42),  # 13 雅丹
	Color(0.68, 0.58, 0.40),  # 14 黄土
	Color(0.84, 0.76, 0.54),  # 15 沙丘
	Color(0.80, 0.84, 0.86),  # 16 冰川谷
	Color(0.42, 0.50, 0.34),  # 17 三角洲
	Color(0.44, 0.42, 0.38),  # 18 花岗岩山地
	Color(0.54, 0.52, 0.44),  # 19 喀斯特山地
	Color(0.64, 0.54, 0.38),  # 20 黄土山地
	Color(0.38, 0.36, 0.34),  # 21 火山山地
	Color(0.84, 0.86, 0.88),  # 22 冰蚀山地
	Color(0.66, 0.46, 0.36),  # 23 红壤丘陵
	Color(0.64, 0.55, 0.40),  # 24 黄土丘陵
	Color(0.70, 0.42, 0.32),  # 25 丹霞丘陵
	Color(0.82, 0.74, 0.52),  # 26 沙质荒漠
	Color(0.66, 0.62, 0.54),  # 27 砾质荒漠
	Color(0.86, 0.84, 0.76),  # 28 盐碱地
]


static func landform_color(kind: int) -> Color:
	return LF_COLORS[clampi(kind, 0, LF_COLORS.size() - 1)]


const MAT_NAMES := ["壤土", "砂质", "岩质"]


## 地貌材质：0 壤土 / 1 砂质 / 2 岩质（低频噪声，成片分布）
static func landform_material(lon: float, lat: float) -> int:
	var v := _vnoise(lon * 2.3 + 41.0, lat * 2.3 - 17.0, 8081)
	if v > 0.66:
		return 2
	if v < 0.34:
		return 1
	return 0


const LF_NAMES := ["平原", "丘陵", "山地", "高原", "盆地", "河谷",
		"荒漠", "草原", "森林", "湿地", "冰雪", "海岸",
		"喀斯特", "雅丹", "黄土", "沙丘", "冰川谷", "三角洲",
		"花岗岩山地", "喀斯特山地", "黄土山地", "火山山地", "冰蚀山地",
		"红壤丘陵", "黄土丘陵", "丹霞丘陵", "沙质荒漠", "砾质荒漠", "盐碱地"]


## 地貌形态：由海拔、坡度、相对起伏和气候代理共同决定。
## 只用于选近景资源，不参与宏观高度。
static func landform_kind(lon: float, lat: float, h: float) -> int:
	if h < -8.0:
		return LF_COAST
	var alat := absf(lat)
	# 极地整片冰盖（南极内陆高、格陵兰也高，不能只看低海拔）
	if lat < -58.0:
		return LF_ICE
	if lat > 72.0:
		return LF_ICE
	if alat > 73.0 and h < 500.0:
		return LF_ICE
	if h > 5800.0 - maxf(alat - 30.0, 0.0) * 110.0:
		return LF_ICE
	if h < 8.0:
		return LF_COAST

	# 坡度与相对起伏（用 1.5km 邻域的高低差近似）
	var dd := 0.0135
	var h_e := dem_at(lon + dd, lat)
	var h_w := dem_at(lon - dd, lat)
	var h_n := dem_at(lon, lat + dd)
	var h_s := dem_at(lon, lat - dd)
	var km := dd * 111.0
	var slope := sqrt(pow((h_e - h_w) / (2.0 * km), 2.0) + pow((h_n - h_s) / (2.0 * km), 2.0))
	var hi := maxf(maxf(h_e, h_w), maxf(h_n, h_s))
	var lo := minf(minf(h_e, h_w), minf(h_n, h_s))
	var relief := hi - lo

	var m := moist_at(lon, lat)
	# 分类用的温度不带高频噪声，否则逐顶点在阈值上来回跳，地表会出同心环带
	var t := 28.0 - 0.42 * absf(lat) - 0.0062 * maxf(h, 0.0)

	# 喀斯特排在山区判定之前：峰丛本来就陡，但成因不同
	# 喀斯特只在中国西南（桂黔滇）与中南半岛北部出现，不再全球热带都算
	var karst_region := (lon > 100.0 and lon < 116.0 and lat > 19.0 and lat < 32.0)
	if karst_region and m > 0.45 and h > 60.0 and h < 1800.0 and relief < 700.0:
		return LF_KARST

	# 干旱区优先判定（否则低平的沙漠会被判成丘陵/平原）
	# 盐碱：只在极干、极平的内陆盆地（柴达木、死海、盐湖周边），不能泛化到三大沙漠
	if m < 0.10 and relief < 120.0 and h < 4500.0 and slope < 2.0:
		return LF_DESERT_SALT
	if m < 0.38 and h < 2200.0 and relief < 400.0:
		if m < 0.24:
			return LF_DESERT_GOBI
		if m < 0.31:
			return LF_DESERT_SAND
		return LF_DUNE if slope < 6.0 else LF_DESERT_GOBI

	# 起伏大 → 山地；中等 → 丘陵
	if slope > 22.0 or relief > 700.0:
		# 高海拔山谷 → 冰川谷
		if h > 3000.0 and relief > 500.0:
			return LF_GLACIAL
		# 山地按岩性/成因细分
		if h > 3200.0:
			return LF_MTN_ICE
		if karst_region and m > 0.45:
			return LF_MTN_KARST
		if lat > 30.0 and lat < 42.0 and lon > 100.0 and lon < 118.0 and m > 0.18 and m < 0.46 and h < 2200.0:
			return LF_MTN_LOESS
		if _vnoise(lon * 0.21 + 13.0, lat * 0.21 - 5.0, 9917) > 0.90:
			return LF_MTN_VOLCANIC
		return LF_MTN_GRANITE
	if slope > 7.0 or relief > 220.0:
		if t > 15.0 and m > 0.50:
			return LF_HILL_RED
		if lat > 30.0 and lat < 42.0 and lon > 100.0 and lon < 118.0 and m > 0.18 and m < 0.46:
			return LF_HILL_LOESS
		if relief > 180.0 and slope > 12.0 and h < 900.0:
			return LF_HILL_DANXIA
		return LF_HILL

	# —— 特殊地貌（都是相对平坦但成因不同的区域）——
	# 雅丹/风蚀垄：极干旱、低平
	if m < 0.14 and h < 1400.0 and slope < 3.0:
		return LF_YARDANG
	# 沙丘：干旱、平坦、低海拔
	if m < 0.20 and h < 900.0 and slope < 1.5:
		return LF_DUNE
	# 黄土：中纬半干旱、台地边缘
	if lat > 30.0 and lat < 42.0 and lon > 100.0 and lon < 118.0 and m > 0.20 and m < 0.46 and h > 250.0 and h < 1700.0 and slope < 5.0:
		return LF_LOESS
	# 三角洲：近海低平、湿润
	if h < 25.0 and m > 0.55 and slope < 0.8:
		return LF_DELTA
	# 高而平 → 高原
	if h > 1200.0:
		return LF_PLATEAU
	# 局部低洼 → 盆地
	if h < (h_e + h_w + h_n + h_s) * 0.25 - 25.0:
		return LF_BASIN
	# 干旱区
	if m < 0.12 and h < 1200.0:
		return LF_DESERT_SALT
	if m < 0.18:
		return LF_DESERT_GOBI
	if m < 0.24:
		return LF_DESERT_SAND
	if m < 0.30 and absf(lat) > 24.0 and absf(lat) < 45.0:
		return LF_DESERT_GOBI
	# 湿润低平 → 湿地
	if m > 0.72 and slope < 1.0 and h < 60.0 and relief < 40.0:
		return LF_WETLAND
	# 温度带区分草原 / 森林
	if t < 10.0 or m < 0.45:
		return LF_STEPPE
	return LF_FOREST


## 局部地貌：域扭曲 + 脊状多重分形。
## 不追求和真实地形一致，只要求在玩家周围长出血肉：山有脊、谷有沟、平原是缓丘。
static func landform(lon: float, lat: float, h: float) -> float:
	var mx := lon * 111320.0 * cos(deg_to_rad(lat))
	var my := lat * 110540.0
	# 域扭曲：让山脊不是直的
	var w1 := _fbm(mx * 0.00033, my * 0.00033, 6101, 3)
	var w2 := _fbm(mx * 0.00033 + 7.3, my * 0.00033 - 2.1, 6102, 3)
	var wx := mx + (w1 - 0.5) * 3000.0
	var wy := my + (w2 - 0.5) * 3000.0

	# 脊状多重分形（5 个倍频，1/f）
	var r := 0.0
	var amp := 0.55
	var freq := 0.00038
	var tot := 0.0
	for i in 5:
		var v := 1.0 - absf(_vnoise(wx * freq, wy * freq, 7100 + i) * 2.0 - 1.0)
		r += v * amp
		tot += amp
		amp *= 0.52
		freq *= 2.15
	r /= tot

	# 振幅按地形类别：这就是“这里是山 / 丘陵 / 平原”的区别
	var amp_m := 8.0
	if h > 2600.0:
		amp_m = 85.0
	elif h > 1500.0:
		amp_m = 62.0
	elif h > 700.0:
		amp_m = 34.0
	elif h > 250.0:
		amp_m = 18.0
	# 脊线本身再抬一点，沟谷压低，形成“山脊—山谷”
	var shape := pow(r, 1.35)
	return (shape - 0.48) * 2.0 * amp_m


static func detail_coarse(lon: float, lat: float, h: float) -> float:
	if h < -2.0:
		return 0.0
	return landform(lon, lat, h)


## spacing 为网格顶点间距（米）：间距多大，就只保留能分辨的尺度，避免混叠。
## spacing <= 0 表示全精度（玩家位置、植被、小地图）。
static func height_ll(lon: float, lat: float, spacing: float) -> float:
	var cb := city_blend(lon, lat)
	var h := _macro(lon, lat, cb)
	var dscale := 1.0 - cb.x          # 城市内地面保持平整
	if dscale <= 0.001:
		return h
	if spacing <= 0.0:
		return h + (detail_fine(lon, lat, h) + detail_coarse(lon, lat, h)
				+ stamps_height(lon, lat)) * dscale
	var f := 1.0 - smoothstep(180.0, 900.0, spacing)
	var c := 1.0 - smoothstep(1200.0, 3500.0, spacing)
	if f > 0.002:
		h += detail_fine(lon, lat, h) * f * dscale
	if c > 0.002:
		h += detail_coarse(lon, lat, h) * c * dscale
		h += stamps_height(lon, lat) * c * dscale
	return h


# =====================================================================
#  坐标
# =====================================================================
static func lonlat_of(x: float, z: float, clon: float, clat: float) -> Vector2:
	return Vector2(clon + x / (111320.0 * cos(deg_to_rad(clat))), clat - z / 110540.0)


static func height_xyz(x: float, z: float, clon: float, clat: float, detail_fade: float) -> float:
	var ll := lonlat_of(x, z, clon, clat)
	return height_ll(ll.x, ll.y, detail_fade)


## 两点间大圆距离（米）
static func distance_m(lon1: float, lat1: float, lon2: float, lat2: float) -> float:
	var p1 := deg_to_rad(lat1)
	var p2 := deg_to_rad(lat2)
	var dp := deg_to_rad(lat2 - lat1)
	var dl := deg_to_rad(lon2 - lon1)
	var a := sin(dp * 0.5) * sin(dp * 0.5) + cos(p1) * cos(p2) * sin(dl * 0.5) * sin(dl * 0.5)
	return 6371000.0 * 2.0 * atan2(sqrt(a), sqrt(maxf(1.0 - a, 0.0)))


# =====================================================================
#  地貌分类
# =====================================================================
## 只用现有数据（纬度、海拔、低频湿度噪声）做的近似分类。
## 后续接入真实气候/降水/植被数据时替换本函数即可，调用方不用改。
## 温度代理：基准 28℃，纬度递减，海拔每千米约 -6.2℃
static func temp_at(lon: float, lat: float, h: float) -> float:
	var tn := (_vnoise(lon * 0.12, lat * 0.12, 4242) - 0.5) * 7.0
	return 28.0 - 0.42 * absf(lat) - 0.0062 * maxf(h, 0.0) + tn


## 湿度代理：低频噪声 + 副热带干旱带（撒哈拉/阿拉伯/澳洲中部）
static func moist_at(lon: float, lat: float) -> float:
	var m := _vnoise(lon * 0.42 + 100.0, lat * 0.42 - 30.0, 2027) * 0.5 + 0.5
	var belt := clampf(1.0 - absf(absf(lat) - 25.0) / 13.0, 0.0, 1.0)
	# 副热带干旱带：真实世界里 15-35 度大陆内部就是沙漠（撒哈拉、阿拉伯、澳洲中部）
	return m * (1.0 - 0.78 * belt)


static func biome_at(lon: float, lat: float, h: float) -> int:
	if h < -8.0:
		return B_OCEAN
	var alat := absf(lat)
	if alat > 73.0 and h < 500.0:
		return B_ICE
	var snowline := 5800.0 - maxf(alat - 30.0, 0.0) * 110.0
	if h > snowline:
		return B_SNOW
	var t := temp_at(lon, lat, h)
	if h > 3400.0 and t < 6.0:
		return B_ROCK
	var m := moist_at(lon, lat)
	var tb := clampi(int(floor((t + 12.0) / 6.0)), 0, 8)
	var mb := clampi(int(floor(m * 5.0)), 0, 4)
	var idx := tb * 5 + mb
	if h > 1200.0:
		idx += 45
	return idx


## 解出 (温度带, 湿度带)
static func _bands(b: int) -> Vector2i:
	if b >= B_LAND_MAX:
		return Vector2i(-1, -1)
	var highland := b >= 45
	var k := b - 45 if highland else b
	return Vector2i(int(k / 5), k % 5)


static func biome_name(b: int) -> String:
	match b:
		B_OCEAN:
			return "海洋"
		B_ICE:
			return "冰盖"
		B_SNOW:
			return "雪线以上"
		B_ROCK:
			return "高山裸岩"
	var bd := _bands(b)
	if bd.x < 0:
		return "未知"
	var nm: String = TEMP_NAMES[bd.x] + MOIST_NAMES[bd.y]
	if b >= 45:
		nm += "（高地）"
	return nm


static func biome_color(b: int) -> Color:
	match b:
		B_OCEAN:
			return Color(0.09, 0.17, 0.25)
		B_ICE:
			return Color(0.91, 0.94, 0.96)
		B_SNOW:
			return Color(0.92, 0.93, 0.94)
		B_ROCK:
			return Color(0.49, 0.46, 0.41)
	var bd := _bands(b)
	if bd.x < 0:
		return Color(0.3, 0.3, 0.3)
	var t01 := float(bd.x) / 8.0
	var m01 := float(bd.y) / 4.0
	var dry := Color(0.60, 0.55, 0.38)
	var wet := Color(0.19, 0.32, 0.15)
	var c := dry.lerp(wet, pow(m01, 0.85))
	var cold := clampf(1.0 - t01 * 1.7, 0.0, 1.0)
	c = c.lerp(Color(0.46, 0.48, 0.42), cold * 0.42)
	if b >= 45:
		c = c.lerp(Color(0.40, 0.38, 0.33), 0.22)
	var j := (0.93 + 0.14 * _vnoise(float(b) * 3.1, float(b) * 7.7, 88)) * 0.84
	return Color(clampf(c.r * j, 0.0, 1.0), clampf(c.g * j, 0.0, 1.0), clampf(c.b * j, 0.0, 1.0))


static func biome_map_color(b: int) -> Color:
	var c := biome_color(b)
	var lum := c.r * 0.35 + c.g * 0.45 + c.b * 0.20
	var paper := Color(lum + 0.16, lum * 0.92 + 0.11, lum * 0.72 + 0.04)
	return c.lerp(paper, 0.55)


## 植被密度权重（0..1.2）
static func tree_density(b: int) -> float:
	if b >= B_LAND_MAX:
		return 0.0
	var bd := _bands(b)
	var t01 := float(bd.x) / 8.0
	var m01 := float(bd.y) / 4.0
	var d := clampf((m01 - 0.22) * 1.75, 0.0, 1.2)
	d *= 1.0 - clampf((t01 - 0.72) * 1.4, 0.0, 1.0) * 0.35
	if b >= 45:
		d *= 0.45
	return d


## 针叶还是阔叶：冷带 / 高地用针叶
static func is_conifer(b: int) -> bool:
	if b >= B_LAND_MAX:
		return false
	var bd := _bands(b)
	return bd.x <= 2 or b >= 45


# =====================================================================
#  世界地图烘焙（1024×512）：底图 + 山体特征 + 地貌配色 + 地势阴影
# =====================================================================
static func bake_map(w: int, hgt: int) -> Array:
	ensure_loaded()
	if _mask.is_empty():
		_load_mask()
	var n := w * hgt
	if _dem.is_empty():
		return []

	var gw := _gw
	var gh := _gh
	var lon_step := 360.0 / float(w)
	var lat_step := 180.0 / float(hgt)

	# 列索引 / 行索引只算一次
	var cols := PackedInt32Array()
	cols.resize(w)
	for x in w:
		var lon := -180.0 + (float(x) + 0.5) * lon_step
		cols[x] = clampi(int((lon + 180.0) / 360.0 * float(gw)), 0, gw - 1) * 2

	var rows := PackedInt32Array()
	var lats := PackedFloat32Array()
	rows.resize(hgt)
	lats.resize(hgt)
	for y in hgt:
		var lat := 90.0 - (float(y) + 0.5) * lat_step
		lats[y] = lat
		var fy := (90.0 - lat) / 180.0 * float(gh)
		rows[y] = clampi(int(fy), 0, gh - 1) * gw * 2

	# ① 底图
	var heights := PackedFloat32Array()
	heights.resize(n)
	var dem := _dem
	var dem_size := dem.size()
	for y in hgt:
		var base: int = rows[y]
		var o: int = y * w
		for x in w:
			var i: int = base + cols[x]
			if i + 1 >= dem_size:
				continue
			var raw := float(dem[i]) + float(dem[i + 1]) * 256.0
			heights[o + x] = raw / 65535.0 * (DEM_MAX - DEM_MIN) + DEM_MIN

	# ①.5 近场补丁（只影响补丁覆盖的几十个像素，代价可忽略）
	if _ov_ready:
		var ox0 := int(floor((_ov_lon0 + 180.0) / lon_step))
		var ox1 := int(ceil((_ov_lon1 + 180.0) / lon_step))
		var oy0 := clampi(int(floor((90.0 - _ov_lat0) / lat_step)), 0, hgt - 1)
		var oy1 := clampi(int(ceil((90.0 - _ov_lat1) / lat_step)), 0, hgt - 1)
		for oy in range(oy0, oy1 + 1):
			var olat := lats[oy]
			for oxc in range(ox0, ox1 + 1):
				var oxm := ((oxc % w) + w) % w
				var olon := -180.0 + (float(oxm) + 0.5) * lon_step
				var ow := overlay_weight(olon, olat)
				if ow > 0.001:
					var oidx := oy * w + oxm
					heights[oidx] = lerpf(heights[oidx], overlay_at(olon, olat), ow)

	# ② 山体特征：只遍历每条山脉自己的包围盒，代价很小
	for fi in _fa.size():
		var f: PackedFloat64Array = _fa[fi]
		var seed: int = _fseed[fi]
		var flon: float = f[0]
		var flat: float = f[1]
		var cosl: float = f[2]
		var rad: float = sqrt(f[5] * f[5] + f[6] * f[6])
		var dlat := rad / 110.54
		var dlon := rad / (111.32 * maxf(cosl, 0.05))
		var y0 := clampi(int(floor((90.0 - (flat + dlat)) / lat_step)), 0, hgt - 1)
		var y1 := clampi(int(ceil((90.0 - (flat - dlat)) / lat_step)), 0, hgt - 1)
		var x0 := int(floor((flon - dlon + 180.0) / lon_step))
		var x1 := int(ceil((flon + dlon + 180.0) / lon_step))
		for y in range(y0, y1 + 1):
			var lat := lats[y]
			var o := y * w
			for xc in range(x0, x1 + 1):
				var xm := ((xc % w) + w) % w
				var lon := -180.0 + (float(xm) + 0.5) * lon_step
				var idx := o + xm
				var hh := heights[idx]
				var nv := _raise_packed(lon, lat, hh, f, seed)
				if nv > hh:
					heights[idx] = nv

	var sea_c := biome_map_color(B_OCEAN)
	var sea_lum := sea_c.r * 0.35 + sea_c.g * 0.45 + sea_c.b * 0.20
	var sea_paper := Color(sea_lum * 1.00 + 0.16, sea_lum * 0.92 + 0.11, sea_lum * 0.72 + 0.04)
	sea_c = sea_c.lerp(sea_paper, 0.55)
	var sea_rgb := Vector3i(int(sea_c.r * 255.0), int(sea_c.g * 255.0), int(sea_c.b * 255.0))

	# ③ 配色（1/4 分辨率，地貌是大色块，放到全分辨率算只是浪费）+ 地势阴影（全分辨率）
	var cw := maxi(w / 2, 1)
	var ch := maxi(hgt / 2, 1)
	var colbuf := PackedByteArray()
	colbuf.resize(cw * ch * 3)
	for cy in ch:
		var clat := 90.0 - (float(cy) + 0.5) / float(ch) * 180.0
		for cx in cw:
			var clon := -180.0 + (float(cx) + 0.5) / float(cw) * 360.0
			# 高度直接取全分辨率结果，别再算一遍山体特征
			var hsrc: float = heights[mini(cy * 2, hgt - 1) * w + mini(cx * 2, w - 1)]
			var bid := B_OCEAN if is_water(clon, clat) else biome_at(clon, clat, hsrc)
			var c := biome_map_color(bid)
			var lum := c.r * 0.35 + c.g * 0.45 + c.b * 0.20
			var paper := Color(lum * 1.00 + 0.16, lum * 0.92 + 0.11, lum * 0.72 + 0.04)
			c = c.lerp(paper, 0.55)
			var ci := (cy * cw + cx) * 3
			colbuf[ci] = int(clampf(c.r, 0.0, 1.0) * 255.0)
			colbuf[ci + 1] = int(clampf(c.g, 0.0, 1.0) * 255.0)
			colbuf[ci + 2] = int(clampf(c.b, 0.0, 1.0) * 255.0)

	var sb := PackedByteArray()
	sb.resize(n)
	for y in hgt:
		var lat := lats[y]
		var km_x := 40075.0 * maxf(cos(deg_to_rad(lat)), 0.02) / float(w)
		var km_y := 20004.0 / float(hgt)
		var o := y * w
		var ym := maxi(y - 1, 0) * w
		var yp := mini(y + 1, hgt - 1) * w
		for x in w:
			var idx := o + x
			var hxm := heights[o + (x - 1 + w) % w]
			var hxp := heights[o + (x + 1) % w]
			var sx := (hxp - hxm) * 0.5 / km_x
			var sy := (heights[yp + x] - heights[ym + x]) * 0.5 / km_y
			var shade := 0.60 - (sx * 0.60 + sy * 0.80) * 0.0032
			shade = clampf(shade, 0.22, 1.0)
			sb[idx] = int(shade * 255.0)



	var img := Image.create_from_data(cw, ch, false, Image.FORMAT_RGB8, colbuf)
	var sh := Image.create_from_data(w, hgt, false, Image.FORMAT_L8, sb)
	return [img, sh, heights]


# =====================================================================
#  验收用：山体统计
# =====================================================================
## 在一条山系自己的“走向矩形”内采样，返回
##   底图峰顶 / 该山系抬升后的峰顶 / 山脚（两侧山麓平均）/ 峰顶坐标
## 只统计这条山系自己的作用范围，不会被相邻山系（如横断山）干扰。
static func feature_stats(nm: String) -> Dictionary:
	ensure_loaded()
	for f in _features:
		if String(f["name"]) != nm:
			continue
		var flon := float(f["lon"])
		var flat := float(f["lat"])
		var halflen := float(f["halflen"])
		var halfwid := float(f["halfwid"])
		var su := float(f["su"])
		var cu := float(f["cu"])
		var peak_h := float(f["peak"])
		var foot_h := float(f["foot"])
		var shape := float(f["shape"])
		var grain := float(f["grain"])
		var seed := int(f["seed"])
		var pu := float(f["pu"])
		var pv := float(f["pv"])
		var cosl := maxf(cos(deg_to_rad(flat)), 0.05)
		# 真实峰顶坐标
		var plon := flon + (pu * su + pv * cu) / (111.32 * cosl)
		var plat := flat + (pu * cu - pv * su) / 110.54

		# 峰顶附近 ±0.15°（约 15km）扫 31×31
		var pdem := -99999.0
		var pfin := -99999.0
		var blon := plon
		var blat := plat
		for iy in 31:
			for ix in 31:
				var lon := plon - 0.15 + 0.30 * float(ix) / 30.0
				var lat := plat - 0.15 + 0.30 * float(iy) / 30.0
				var hd := dem_at(lon, lat)
				pdem = maxf(pdem, hd)
				var hf := _raise(lon, lat, hd, flon, flat, cosl, peak_h, foot_h,
						halflen, halfwid, su, cu, shape, grain, seed, pu, pv)
				if hf > pfin:
					pfin = hf
					blon = lon
					blat = lat

		# 山脚：山体两侧 |v| = halfwid 一线的平均
		var foot_sum := 0.0
		var foot_n := 0
		for iu in 21:
			for side in [-1.0, 1.0]:
				var u := -halflen * 0.6 + 1.2 * halflen * float(iu) / 20.0
				var v: float = side * halfwid
				var dx := u * su + v * cu
				var dy := u * cu - v * su
				var lon := flon + dx / (111.32 * cosl)
				var lat := flat + dy / 110.54
				foot_sum += _raise(lon, lat, dem_at(lon, lat), flon, flat, cosl,
						peak_h, foot_h, halflen, halfwid, su, cu, shape, grain, seed, pu, pv)
				foot_n += 1
		return {
			"name": nm, "dem_peak": pdem, "peak": pfin,
			"foot": foot_sum / maxf(float(foot_n), 1.0),
			"lon": blon, "lat": blat,
		}
	return {}
