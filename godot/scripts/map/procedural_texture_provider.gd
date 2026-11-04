class_name ProceduralTextureProvider
extends MapTextureProvider

## ==============================================================
## 程序生成的瓦片：采高程 → 高程配色 + 山体阴影
##
## 两阶段、分帧：
##   阶段 0  逐行采高程（world.get_height_dir）
##   阶段 1  逐行上色（高程分层 + 用邻点算坡度的浮雕阴影）
##
## 想换成真实地形图，把 MapGlobe 的 provider 换成 FileTextureProvider 即可，
## 地图系统代码不用动。
## ==============================================================

const CACHE_DIR := "user://region_cache"

var _h := PackedFloat32Array()
var _img: Image
var _row := 0
var _phase := 0
var _px := 0
var _lon0 := 0.0
var _lon1 := 0.0
var _lat0 := 0.0
var _lat1 := 0.0
var _span_m := 1.0
var _world: MapWorld


func try_cached(level: int, x: int, y: int) -> Image:
	var path := "%s/z%02d_x%d_y%d.png" % [CACHE_DIR, level, x, y]
	if not FileAccess.file_exists(path):
		return null
	return Image.load_from_file(path)


func begin(world: MapWorld, _level: int, x: int, y: int, span_deg: float, px: int) -> void:
	_world = world
	_px = px
	_row = 0
	_phase = 0
	_lon0 = x * span_deg
	_lat0 = y * span_deg
	_lon1 = _lon0 + span_deg
	_lat1 = _lat0 + span_deg
	_span_m = absf(span_deg) * 111000.0
	_h = PackedFloat32Array()
	_h.resize(px * px)
	_img = null


func step(max_rows: int) -> float:
	if _px <= 0:
		return 1.0
	var y1 := mini(_row + max_rows, _px)

	if _phase == 0:
		for j in range(_row, y1):
			var lat := lerpf(_lat1, _lat0, float(j) / float(_px - 1))
			for i in _px:
				var lon := lerpf(_lon0, _lon1, float(i) / float(_px - 1))
				var d := GeoSphere.lonlat_to_dir(lon, lat)
				_h[j * _px + i] = _world.get_height_dir(d) if _world != null else 0.0
		_row = y1
		if y1 >= _px:
			_blur(3)
			_phase = 1
			_row = 0
			_img = Image.create(_px, _px, false, Image.FORMAT_RGB8)
		return 0.55 * float(y1) / float(_px)

	_shade_rows(_row, y1)
	_row = y1
	return 0.55 + 0.45 * float(y1) / float(_px)


func _shade_rows(y0: int, y1: int) -> void:
	var px := _px
	for j in range(y0, y1):
		for i in px:
			# 3×3 平滑：地形每处微小起伏都跨色阶的话，描边会密得像电路板
			var hs := 0.0
			var cn := 0
			for dj: int in [-1, 0, 1]:
				for di: int in [-1, 0, 1]:
					var jj: int = j + dj
					var ii: int = i + di
					if jj >= 0 and jj < px and ii >= 0 and ii < px:
						hs += _h[jj * px + ii]
						cn += 1
			var h := hs / float(maxi(cn, 1))
			var b := _band(h)
			var c: Color = BAND_COLORS[b]
			# 和左边/上边的分层不同 -> 画一条描边（地图册那种勾线）
			# 只在"成片区域"的边界画线：统计 4 邻居里有几个和自己同档。
			# 少于 3 个说明这是孤立噪点，不画线（否则满屏碎点）。
			var same := 0
			var diff := false
			for d: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var ii2: int = i + d.x
				var jj2: int = j + d.y
				if ii2 < 0 or ii2 >= px or jj2 < 0 or jj2 >= px:
					continue
				var bn := _band(_h[jj2 * px + ii2])
				if bn == b:
					same += 1
				else:
					diff = true
			if diff and same >= 3:
				c = OUTLINE
			_img.set_pixel(i, j, c)


## 高程分档：负数是水，正数是陆
func _band(h: float) -> int:
	if h < -150.0:
		return 0      # 深海
	if h < 0.0:
		return 1      # 浅海
	if h < 60.0:
		return 2      # 平原
	if h < 200.0:
		return 3      # 丘陵
	if h < 500.0:
		return 4      # 高地
	if h < 1200.0:
		return 5      # 山地
	if h < 2200.0:
		return 6      # 高山
	return 7          # 雪线


const BAND_COLORS := [
	Color(0.09, 0.20, 0.36),   # 深海
	Color(0.19, 0.38, 0.55),   # 浅海
	Color(0.62, 0.74, 0.52),   # 平原
	Color(0.72, 0.74, 0.44),   # 丘陵
	Color(0.74, 0.62, 0.38),   # 高地
	Color(0.58, 0.44, 0.34),   # 山地
	Color(0.72, 0.66, 0.62),   # 高山
	Color(0.94, 0.94, 0.94),   # 雪线
]
const OUTLINE := Color(0.34, 0.30, 0.24)


func is_done() -> bool:
	return _phase == 1 and _row >= _px


func take() -> Image:
	var out := _img
	_img = null
	return out


## 生成完把图落到磁盘缓存（系统层调用）
func save_cache(level: int, x: int, y: int, img: Image) -> void:
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	img.save_png("%s/z%02d_x%d_y%d.png" % [CACHE_DIR, level, x, y])


## 可分离盒式模糊：高程场在像素尺度上太抖，不分档前先模糊，
## 否则色阶边界会碎成一片噪点（像电路板）。
func _blur(r: int) -> void:
	var px := _px
	var tmp := PackedFloat32Array()
	tmp.resize(px * px)
	var w := float(r * 2 + 1)
	# 横向
	for j in px:
		var acc := 0.0
		for k in range(-r, r + 1):
			acc += _h[j * px + clampi(k, 0, px - 1)]
		for i in px:
			tmp[j * px + i] = acc / w
			var out := clampi(i - r, 0, px - 1)
			var inn := clampi(i + r + 1, 0, px - 1)
			acc += _h[j * px + inn] - _h[j * px + out]
	# 纵向
	for i in px:
		var acc2 := 0.0
		for k in range(-r, r + 1):
			acc2 += tmp[clampi(k, 0, px - 1) * px + i]
		for j in px:
			_h[j * px + i] = acc2 / w
			var out2 := clampi(j - r, 0, px - 1)
			var inn2 := clampi(j + r + 1, 0, px - 1)
			acc2 += tmp[inn2 * px + i] - tmp[out2 * px + i]
