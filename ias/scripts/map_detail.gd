extends RefCounted
## 高倍地图细节层（流式）：把可见范围按屏幕 1/4 分辨率烘成一张 RGBA8，
## 分块（tile）在后台线程做，主线程每块合入并 tex.update()，所以是“边烘边出现”。
##
## 通道：R = 地貌编号，G = 阴影，B = 水线标记，A = 该 texel 已烘好（255）
## 颜色/符号/纸色仍全部在 map.gdshader 里算，风格只有一份。

const TG := preload("res://scripts/terrain_gen.gd")

const MIN_PX := 32
const MAX_PX := 720
const TILE := 96          # 单块边长（texel）
const APRON := 8          # 阴影差分需要的四周余量（texel）

var tex: ImageTexture = null
var img: Image = null
var px_w := 0
var px_h := 0
var lon0 := 0.0           # 西
var lon1 := 0.0           # 东
var lat0 := 0.0           # 北
var lat1 := 0.0           # 南
var ox := 0.0             # 世界 uv 左上角
var oy := 0.0
var sx := 1.0             # 世界 uv 跨度
var sy := 1.0
var tiles_total := 0
var tiles_done := 0
var first_ready := false
var ms := 0
var started := 0          # 开始烘焙的毫秒时间戳
var tile_state := PackedByteArray()   # 每块是否已合入
var _nx := 0
var _ny := 0
var _cx := 0.0            # 当前“第一优先级”中心（texel 坐标）
var _cy := 0.0
const RADIAL_N := 64      # 揭开半径的分环带数（越细，半径越连续）
var _band_w := 1.0
var _band_need := PackedInt32Array()
var cancelled := false    # 被抛弃的窗口立刻停，别在后台抢线程
var _adopt = null   # 同缩放的旧窗口，重叠区直接搬

var _dlon := 0.0
var _dlat := 0.0
var _order: Array = []          # [[tx,ty], ...] 由近到远
var _qi := 0
var _gid := -1
var _stage := 0                 # 0=高程 1=分类 2=去斑
var _t0 := 0
var _tw := 0
var _th := 0
var _tx0 := 0
var _ty0 := 0
var _hgt := PackedFloat32Array()
var _lid := PackedByteArray()
var _out := PackedByteArray()


func setup(p_lon0: float, p_lat0: float, p_lon1: float, p_lat1: float, pw: int, ph: int,
		adopt = null) -> void:
	# 上限按长边等比缩，别把画面拉变形（4K 屏时自动降分辨率，帧时可控）
	var k: float = minf(1.0, float(MAX_PX) / float(maxi(pw, ph)))
	px_w = maxi(MIN_PX, int(float(pw) * k))
	px_h = maxi(MIN_PX, int(float(ph) * k))

	# 同缩放的旧窗口：把原点吸附到它的 texel 网格上，重叠区就能整块搬过来，
	# 吸附量不到 1 个 texel（4 屏幕像素），看不出来
	_adopt = null
	var d_new := (p_lon1 - p_lon0) / float(px_w)
	if adopt != null and not adopt.cancelled:
		var d_old: float = adopt.lon_per_texel()
		if absf(d_old / d_new - 1.0) < 0.01:
			var nx := roundf((p_lon0 - adopt.lon0) / d_old)
			var ny := roundf((adopt.lat0 - p_lat0) / d_old)
			p_lon0 = adopt.lon0 + nx * d_old
			p_lat0 = adopt.lat0 - ny * d_old
			d_new = d_old
			p_lon1 = p_lon0 + float(px_w) * d_new
			p_lat1 = p_lat0 - float(px_h) * d_new
			_adopt = adopt
	lon0 = p_lon0
	lon1 = p_lon1
	lat0 = p_lat0
	lat1 = p_lat1
	_dlon = (lon1 - lon0) / float(px_w)
	_dlat = (lat0 - lat1) / float(px_h)
	ox = (lon0 + 180.0) / 360.0
	oy = (90.0 - lat0) / 180.0
	sx = (lon1 - lon0) / 360.0
	sy = (lat0 - lat1) / 180.0

	img = Image.create(px_w, px_h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	tex = ImageTexture.create_from_image(img)

	# 分块 + 由近到远排序（先出屏幕中心那一块）
	var nx := int(ceil(float(px_w) / float(TILE)))
	var ny := int(ceil(float(px_h) / float(TILE)))
	_nx = nx
	_ny = ny
	_cx = float(px_w) * 0.5
	_cy = float(px_h) * 0.5
	tiles_total = nx * ny
	tile_state.resize(tiles_total)
	tile_state.fill(0)
	var mid := Vector2(float(nx - 1) * 0.5, float(ny - 1) * 0.5)
	var cells: Array = []
	for ty in ny:
		for tx in nx:
			var d := Vector2(float(tx), float(ty)).distance_to(mid)
			cells.append([d, tx, ty])
	cells.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	_order.clear()
	for c in cells:
		_order.append([int(c[1]), int(c[2])])
	_qi = 0
	_stage = 0
	_t0 = Time.get_ticks_msec()
	started = _t0
	# 环带表：每环带覆盖哪些块（用于连续半径）
	var dmax := Vector2(float(px_w) * 0.5, float(px_h) * 0.5).length()
	_band_w = maxf(dmax / float(RADIAL_N), 0.001)
	_band_need.resize(RADIAL_N)
	_band_need.fill(0)
	for ty in ny:
		for tx in nx:
			var br: Vector2i = _tile_band(tx, ty)
			for b in range(br.x, br.y + 1):
				_band_need[b] += 1
	# 先把旧窗口已经烘好的重叠块搬过来（平移一屏能省约 40%）
	if _adopt != null:
		_steal_overlap()
		if tiles_done > 0:
			first_ready = true
			tex.update(img)
	_start_tile()


## 从 _adopt 搬重叠区：只搬“源窗口里已经烘好、且整块落在重叠区”的块
func _steal_overlap() -> void:
	var src = _adopt
	var sx := roundf((lon0 - src.lon0) / _dlon)   # 源图上的 texel 偏移
	var sy := roundf((src.lat0 - lat0) / _dlat)
	var keep: Array = []
	for t in _order:
		var tx := int(t[0])
		var ty := int(t[1])
		var x0 := tx * TILE
		var y0 := ty * TILE
		var tw := mini(TILE, px_w - x0)
		var th := mini(TILE, px_h - y0)
		var src_rect := Rect2i(x0 + int(sx), y0 + int(sy), tw, th)
		if src_rect.position.x < 0 or src_rect.position.y < 0 \
				or src_rect.end.x > src.px_w or src_rect.end.y > src.px_h:
			keep.append(t)
			continue
		if not src.area_done(src_rect):
			keep.append(t)
			continue
		img.blit_rect(src.img, src_rect, Vector2i(x0, y0))
		tile_state[ty * _nx + tx] = 1
		tiles_done += 1
	_order = keep


## 换视野中心时把“还没烘的块”按新中心重排（已烘的前 _qi 块不动）
func retarget(lon: float, lat: float) -> void:
	var cx := (lon - lon0) / _dlon
	var cy := (lat0 - lat) / _dlat
	if absf(cx - _cx) < float(TILE) and absf(cy - _cy) < float(TILE):
		return
	_cx = cx
	_cy = cy
	if _qi >= _order.size():
		return
	var rest: Array = _order.slice(_qi)
	rest.sort_custom(func(a, b): return _tile_dist2(a) < _tile_dist2(b))
	_order = _order.slice(0, _qi) + rest


func _tile_dist2(t: Array) -> float:
	var px := (float(int(t[0])) + 0.5) * float(TILE)
	var py := (float(int(t[1])) + 0.5) * float(TILE)
	return (px - _cx) * (px - _cx) + (py - _cy) * (py - _cy)


## 已烘区域“从中心算起的连续半径”（texel）。
## 按半径分 RADIAL_N 个环带统计完成比例再插值 —— 直接用块的矩形算，
## 半径一次会跳一个块（384 px），揭开就会一卡一卡。
func baked_radius() -> float:
	var got := PackedInt32Array()
	got.resize(RADIAL_N)
	got.fill(0)
	for ty in _ny:
		for tx in _nx:
			if tile_state[ty * _nx + tx] == 0:
				continue
			var br: Vector2i = _tile_band(tx, ty)
			for b in range(br.x, br.y + 1):
				got[b] += 1
	for b in RADIAL_N:
		var need: int = _band_need[b]
		if need == 0:
			continue
		var r0 := float(b) * _band_w
		if got[b] >= need:
			continue
		return r0 + _band_w * float(got[b]) / float(need)
	return 1e9


## 一块（tx,ty）覆盖的环带范围
func _tile_band(tx: int, ty: int) -> Vector2i:
	var x0 := float(tx * TILE)
	var x1 := float(mini((tx + 1) * TILE, px_w))
	var y0 := float(ty * TILE)
	var y1 := float(mini((ty + 1) * TILE, px_h))
	var dx := maxf(maxf(x0 - _cx, _cx - x1), 0.0)
	var dy := maxf(maxf(y0 - _cy, _cy - y1), 0.0)
	var dmin := sqrt(dx * dx + dy * dy)
	var dmx := 0.0
	for p in [Vector2(x0, y0), Vector2(x1, y0), Vector2(x0, y1), Vector2(x1, y1)]:
		dmx = maxf(dmx, p.distance_to(Vector2(_cx, _cy)))
	var b0: int = clampi(int(dmin / _band_w), 0, RADIAL_N - 1)
	var b1: int = clampi(int(dmx / _band_w), 0, RADIAL_N - 1)
	return Vector2i(b0, b1)


## 视口矩形是否完全落在窗口内（纯几何，不看烘没烘）
func geom_covers(r: Vector4) -> bool:
	return r.x >= lon0 and r.z <= lon1 and r.y <= lat0 and r.w >= lat1


func lon_per_texel() -> float:
	return _dlon


func done() -> bool:
	return tiles_done >= tiles_total


## 每帧调一次：推进一块。返回 true 表示这一帧有块合入（tex 已更新）
func poll() -> bool:
	if _gid == -1 or cancelled:
		return false
	if not WorkerThreadPool.is_group_task_completed(_gid):
		return false
	WorkerThreadPool.wait_for_group_task_completion(_gid)
	_gid = -1
	if cancelled:            # 阶段跑完就停，不再启动下一趟/下一块
		return false
	if _stage == 0:
		_stage = 1
		_gid = WorkerThreadPool.add_group_task(_pass_classify, _th, 8, false, "md_b")
		return false
	if _stage == 1:
		_stage = 2
		_gid = WorkerThreadPool.add_group_task(_pass_filter, _th, 8, false, "md_c")
		return false
	_commit_tile()
	if _qi < _order.size():
		_start_tile()
	else:
		ms = Time.get_ticks_msec() - _t0
	return true


## 放弃这个窗口：最多浪费正在跑的那一趟，不再启动新的
func cancel() -> void:
	cancelled = true


## 退出前等后台任务落地
func wait() -> void:
	if _gid != -1 and not WorkerThreadPool.is_group_task_completed(_gid):
		WorkerThreadPool.wait_for_group_task_completion(_gid)
	_gid = -1


func _start_tile() -> void:
	if _qi >= _order.size() or cancelled:
		return
	var t: Array = _order[_qi]
	_qi += 1
	_tx0 = int(t[0]) * TILE
	_ty0 = int(t[1]) * TILE
	_tw = mini(TILE, px_w - _tx0)
	_th = mini(TILE, px_h - _ty0)
	var aw := _tw + APRON * 2
	var ah := _th + APRON * 2
	_hgt.resize(aw * ah)
	_lid.resize(_tw * _th)
	_out.resize(_tw * _th * 4)
	_stage = 0
	_gid = WorkerThreadPool.add_group_task(_pass_height, ah, 8, false, "md_a")


## 阶段一：这一块（含四周余量）的高程，供阴影差分用
func _pass_height(ay: int) -> void:
	var aw := _tw + APRON * 2
	var lat: float = lat0 - (float(_ty0 + ay - APRON) + 0.5) * _dlat
	var base := ay * aw
	for ax in aw:
		var lon: float = lon0 + (float(_tx0 + ax - APRON) + 0.5) * _dlon
		_hgt[base + ax] = TG.dem_at(lon, lat)


## 阶段二：块内地貌编号 + 阴影 + 水线
func _pass_classify(y: int) -> void:
	var aw := _tw + APRON * 2
	var lat: float = lat0 - (float(_ty0 + y) + 0.5) * _dlat
	var km_x: float = maxf(_dlon * 111.32 * cos(deg_to_rad(lat)), 0.05)
	var km_y: float = maxf(_dlat * 110.54, 0.05)
	# 阴影用约 6 km 的差分尺度：直接用相邻格会把 2.4 km 底图的网格放大成竖条纹
	var st: int = clampi(int(round(6.0 / km_x)), 1, APRON - 1)
	var st_y: int = clampi(int(round(6.0 / km_y)), 1, APRON - 1)
	var row := y * _tw
	for x in _tw:
		var lon: float = lon0 + (float(_tx0 + x) + 0.5) * _dlon
		var ax := x + APRON
		var ay := y + APRON
		var h: float = _hgt[ay * aw + ax]
		var v: int = TG.landform_kind(lon, lat, h) & 0xFF
		_lid[row + x] = v
		# 阴影：中心差分（西北来光，和编号图路径同一套公式）
		var sxv: float = (_hgt[ay * aw + ax + st] - _hgt[ay * aw + ax - st]) / (2.0 * st * km_x)
		var syv: float = (_hgt[(ay + st_y) * aw + ax] - _hgt[(ay - st_y) * aw + ax]) / (2.0 * st_y * km_y)
		var shade: float = clampf(0.62 - (sxv * 0.55 + syv * 0.75) * 0.0030 * 2.2, 0.16, 1.0)
		var o := (row + x) * 4
		_out[o] = v
		_out[o + 1] = int(shade * 255.0)
		_out[o + 2] = 0
		_out[o + 3] = 255


## 阶段三：去斑 + 水线（都读完整的 _lid，避免行间竞争）
func _pass_filter(y: int) -> void:
	var row := y * _tw
	for x in _tw:
		var v: int = _lid[row + x]
		var l := _lid_at(x - 1, y, v)
		var rr := _lid_at(x + 1, y, v)
		var u := _lid_at(x, y - 1, v)
		var d := _lid_at(x, y + 1, v)
		var o := (row + x) * 4
		if l != v and rr != v and u != v and d != v:
			v = _vote_int(l, rr, u, d)
			_out[o] = v
		# 水线：水陆相邻的格子打标（陆地侧与水面侧各一圈）
		var water := v == 11
		if water != (l == 11) or water != (rr == 11) or water != (u == 11) or water != (d == 11):
			_out[o + 2] = 255


func _lid_at(x: int, y: int, fallback: int) -> int:
	if x < 0 or y < 0 or x >= _tw or y >= _th:
		return fallback
	return _lid[y * _tw + x]


static func _vote_int(a: int, b: int, c: int, d: int) -> int:
	if a == b or a == c or a == d:
		return a
	if b == c or b == d:
		return b
	if c == d:
		return c
	return a


func _commit_tile() -> void:
	var tile := Image.create_from_data(_tw, _th, false, Image.FORMAT_RGBA8, _out)
	img.blit_rect(tile, Rect2i(0, 0, _tw, _th), Vector2i(_tx0, _ty0))
	tex.update(img)
	tiles_done += 1
	tile_state[(_ty0 / TILE) * _nx + (_tx0 / TILE)] = 1
	first_ready = true


## 视口（经纬度矩形）对应的 texel 范围
func texel_rect(r: Vector4) -> Rect2i:
	var x0 := int(floor((r.x - lon0) / _dlon))
	var x1 := int(ceil((r.z - lon0) / _dlon))
	var y0 := int(floor((lat0 - r.y) / _dlat))
	var y1 := int(ceil((lat0 - r.w) / _dlat))
	return Rect2i(x0, y0, x1 - x0, y1 - y0)


## 这块 texel 范围是否全部烘好（范围必须完全落在窗口内，否则算没覆盖）
func area_done(r: Rect2i) -> bool:
	if r.position.x < 0 or r.position.y < 0 or r.end.x > px_w or r.end.y > px_h:
		return false
	var tx0: int = int(floor(float(r.position.x) / TILE))
	var tx1: int = int(floor(float(r.end.x - 1) / TILE))
	var ty0: int = int(floor(float(r.position.y) / TILE))
	var ty1: int = int(floor(float(r.end.y - 1) / TILE))
	for ty in range(ty0, ty1 + 1):
		for tx in range(tx0, tx1 + 1):
			if tile_state[ty * _nx + tx] == 0:
				return false
	return true
