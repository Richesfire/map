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
			_blur(1)
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
			var h := _h[j * px + i]
			var b := _band(h)

			# 边界判定：4 邻居里有没有不同档
			var boundary := false
			for d: Vector2i in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
				var ii: int = i + d.x
				var jj: int = j + d.y
				if ii < 0 or ii >= px or jj < 0 or jj >= px:
					continue
				if _band(_h[jj * px + ii]) != b:
					boundary = true
					break

			var c: Color
			if boundary:
				# 边界像素：在像素内取 2×2 子样本（双线性插值，不用再采高程），
				# 按各档出现比例混色 —— 边缘就是平滑过渡，而不是方块台阶。
				var acc := Color(0, 0, 0)
				var n := 0.0
				for sy in [0.25, 0.75]:
					for sx in [0.25, 0.75]:
						var hh := _hbil(float(i) + sx, float(j) + sy)
						acc += BAND_COLORS[_band(hh)]
						n += 1.0
				c = acc / n
				# 描边：边界处压暗一点，形成地图册式的勾线
				c = c.lerp(OUTLINE, 0.35)
			else:
				c = BAND_COLORS[b]

			# 等高线：每 100 米一条细线，平原地带也能看出结构（地图册的观感）
			if h > 0.0:
				var ph := fposmod(h, 100.0)
				if ph < 12.0:
					c = c.lerp(OUTLINE, 0.22)
				# 起伏阴影：用左右/上下高差做很淡的明暗，让平缓地形也有立体感
				var gx := 0.0
				var gy := 0.0
				if i > 0 and i < px - 1:
					gx = _h[j * px + i + 1] - _h[j * px + i - 1]
				if j > 0 and j < px - 1:
					gy = _h[(j + 1) * px + i] - _h[(j - 1) * px + i]
				var sh := clampf(1.0 + (-gx * 0.5 - gy * 0.6) * 0.010, 0.90, 1.10)
				c = Color(c.r * sh, c.g * sh, c.b * sh)

			_img.set_pixel(i, j, c)


## 双线性插值取高度（越界钳制）
func _hbil(x: float, y: float) -> float:
	var px := _px
	var x0 := clampi(int(floor(x)), 0, px - 1)
	var y0 := clampi(int(floor(y)), 0, px - 1)
	var x1 := mini(x0 + 1, px - 1)
	var y1 := mini(y0 + 1, px - 1)
	var fx := clampf(x - float(x0), 0.0, 1.0)
	var fy := clampf(y - float(y0), 0.0, 1.0)
	var a := lerpf(_h[y0 * px + x0], _h[y0 * px + x1], fx)
	var b2 := lerpf(_h[y1 * px + x0], _h[y1 * px + x1], fx)
	return lerpf(a, b2, fy)


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
