extends RefCounted
## 高倍地图细节层（流式）：把可见范围按屏幕 1/4 分辨率烘成一张 RGBA8，
## 分块（tile）在后台线程做，主线程每块合入并 tex.update()，所以是“边烘边出现”。
##
## 通道：R = 地貌编号，G = 阴影，B = 水线标记，A = 该 texel 已烘好（255）
## 颜色/符号/纸色仍全部在 map.gdshader 里算，风格只有一份。

const TG := preload("res://scripts/terrain_gen.gd")

const MIN_PX := 32
const MAX_PX := 4096      # 只做安全阀：正常窗口（含 4K）都不该触发；触发=texel 会变粗
const TILE := 16          # 逻辑块边长（texel）：中心 1×1、中间 3×3、外围 6×6 一起烘
const APRON := 8          # 阴影差分需要的四周余量（texel）

## 调试开关：main 启动时按命令行参数设一次（别在每个块里调 OS.get_cmdline_user_args）
static var dbg_state := false
static var dbg_bakelog := false
## 整张画布缓存：地形固定后，同一倍率+同一区域第二次打开直接读盘。
## 改分类器/去斑/水线规则时把 CACHE_VER +1（旧缓存作废）。
static var cache_on := true
const CACHE_VER := 2   # 2026-11-18：区域抖动从单层噪声改 fbm，旧缓存作废
const CACHE_DIR := "user://detail_cache"
static var cache_files := -1      # 目录里已有多少张（太多就不再写）

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
var tile_state := PackedByteArray()   # 每块是否已合入
var _chunks: Array = []
var _chunk_i := 0
var _target := Vector2(-1, -1)
var _all_done := false
var _nx := 0
var _ny := 0
var cancelled := false    # 被抛弃的窗口立刻停，别在后台抢线程
var _adopt = null   # 同缩放的旧窗口，重叠区直接搬

var _dlon := 0.0
var _dlat := 0.0
var _order: Array = []          # [[tx,ty], ...] 由近到远（_steal_overlap 按它搬重叠块）
var _gid := -1
var _stage := 0                 # 0=高程 1=分类 2=去斑
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
	if k < 0.999 and dbg_state:
		# 静默降分辨率是大方块的直接原因，必须留痕
		print("[细节] 画布超 MAX_PX 降分辨率：请求 %dx%d → %dx%d（texel 放大 %.1f 倍）"
				% [pw, ph, px_w, px_h, 1.0 / maxf(k, 0.001)])

	# 同缩放的旧窗口：把原点吸附到它的 texel 网格上，重叠区就能整块搬过来，
	# 吸附量不到 1 个 texel（4 屏幕像素），看不出来
	_adopt = null
	var d_new := (p_lon1 - p_lon0) / float(px_w)
	if adopt != null and not adopt.cancelled:
		var d_old: float = adopt.lon_per_texel()
		if absf(d_old / d_new - 1.0) < 0.01:
			# 向左/向上取整吸附，保证吸附后仍能覆盖请求范围；再按需补足 texel 数
			var req_lon1 := p_lon1
			var req_lat1 := p_lat1
			var nx := floorf((p_lon0 - adopt.lon0) / d_old)
			var ny := floorf((adopt.lat0 - p_lat0) / d_old)
			p_lon0 = adopt.lon0 + nx * d_old
			p_lat0 = adopt.lat0 - ny * d_old
			d_new = d_old
			px_w = maxi(px_w, int(ceil((req_lon1 - p_lon0) / d_new)))
			px_h = maxi(px_h, int(ceil((p_lat0 - req_lat1) / d_new)))
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
	_stage = 0
	# 先把旧窗口已经烘好的重叠块搬过来（平移一屏能省约 40%）
	if _adopt != null:
		_steal_overlap()
		if tiles_done > 0:
			first_ready = true
			tex.update(img)
	if _cache_try_load():
		_stage = 3
		if dbg_bakelog:
			print("[细节] 整图缓存命中 ", _cache_key())
		return
	_start_full()


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


## 视口矩形是否完全落在窗口内（纯几何，不看烘没烘）
## 容差要留够 3 个 texel：重叠复用会把新窗口的原点吸附到旧窗口的网格上，
## 最多偏半个 texel，而"窗口 == 屏幕"时这点偏移就足以让判定失败；
## 一失败就每帧作废重开，表现就是"永远只有粗版、从不从中间扩散"。
func geom_covers(r: Vector4) -> bool:
	var ex: float = maxf(absf(lon1 - lon0) * 0.002, _dlon * 3.0)
	var ey: float = maxf(absf(lat0 - lat1) * 0.002, _dlat * 3.0)
	return r.x >= lon0 - ex and r.z <= lon1 + ex and r.y <= lat0 + ey and r.w >= lat1 - ey


func lon_per_texel() -> float:
	return _dlon


func done() -> bool:
	return _all_done


## 每帧调一次：推进一块（三趟跑完才合入，所以一块要跨三帧）。
## 返回 true 表示这一帧有块合入（tex 已更新）。
func poll() -> bool:
	if cancelled:
		return false
	if _gid == -1:
		if _stage >= 3:
			return false
		_start_stage()
		return false
	if not WorkerThreadPool.is_group_task_completed(_gid):
		return false
	WorkerThreadPool.wait_for_group_task_completion(_gid)
	_gid = -1
	_stage += 1
	if _stage >= 3:
		_commit_full()
		_chunk_i += 1
		if _chunk_i < _chunks.size():
			_set_chunk(_chunk_i)
			return true
		_all_done = true
		_cache_save()
		return true
	_start_stage()
	return false


## 启动当前阶段（0=hgt 1=lid 2=filter）；整画布一次覆盖所有行
func _start_stage() -> void:
	match _stage:
		0:
			_gid = WorkerThreadPool.add_group_task(_pass_height, _th + APRON * 2, 8, false, "md_a")
		1:
			_gid = WorkerThreadPool.add_group_task(_pass_classify, _th, 8, false, "md_b")
		_:
			_gid = WorkerThreadPool.add_group_task(_pass_filter, _th, 8, false, "md_c")


## 放弃这个窗口：最多浪费正在跑的那一趟，不再启动新的
func cancel() -> void:
	cancelled = true


## 退出前等后台任务落地
func wait() -> void:
	if _gid != -1 and not WorkerThreadPool.is_group_task_completed(_gid):
		WorkerThreadPool.wait_for_group_task_completion(_gid)
	_gid = -1


## 三种块：按"离中心的距离"合并成 1×1 / 3×3 / 6×6 个逻辑块一起烘。
## 中心用小块（先快出画面），远处用大块（省掉调度开销）。
func start_full() -> void:
	_start_full()


func _start_full() -> void:
	var n := 9
	var cw := int(ceil(float(px_w) / float(n)))
	var ch := int(ceil(float(px_h) / float(n)))
	var mid := Vector2(float(n - 1) * 0.5, float(n - 1) * 0.5)
	var cells: Array = []
	for j in n:
		for i in n:
			cells.append([Vector2(float(i), float(j)).distance_to(mid), i, j])
	cells.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	_chunks.clear()
	for c in cells:
		var x0: int = int(c[1]) * cw
		var y0: int = int(c[2]) * ch
		var w := mini(cw, px_w - x0)
		var h := mini(ch, px_h - y0)
		if w > 0 and h > 0:
			_chunks.append(Rect2i(x0, y0, w, h))
	_chunk_i = 0
	_all_done = false
	_target = Vector2(float(px_w) * 0.5, float(px_h) * 0.5)
	_set_chunk(0)


func _set_chunk(i: int) -> void:
	var r: Rect2i = _chunks[i]
	_tx0 = r.position.x
	_ty0 = r.position.y
	_tw = r.size.x
	_th = r.size.y
	var aw0 := _tw + APRON * 2
	_hgt.resize(aw0 * (_th + APRON * 2))
	_lid.resize(_tw * _th)
	_out.resize(_tw * _th * 4)
	if dbg_bakelog:
		var cc := Vector2(float(_tx0 + _tw * 0.5), float(_ty0 + _th * 0.5))
		print("[chunk] n=", _chunk_i, "/", _chunks.size(), "  d=", int(cc.distance_to(_target)), "  rect=", _tx0, ",", _ty0, " ", _tw, "x", _th)
	_stage = 0
	_gid = -1
	_start_stage()


## 屏幕移动后：丢掉屏幕外的待烘块，并把剩余块按"离新屏幕中心最近"重排
func reorder_from(lon: float, lat: float, world: Vector4) -> void:
	if _chunks.is_empty() or _all_done:
		return
	var cx := (lon - lon0) / _dlon
	var cy := (lat0 - lat) / _dlat
	var r: Rect2i = texel_rect(world)
	_target = Vector2(cx, cy)
	# keep the in-flight chunk at its index, otherwise reorder drops it
	var keep: Array = []
	for i in mini(_chunk_i + 1, _chunks.size()):
		keep.append(_chunks[i])
	var rest: Array = []
	for i in range(_chunk_i + 1, _chunks.size()):
		var c: Rect2i = _chunks[i]
		var cc := Vector2(float(c.position.x + c.size.x * 0.5), float(c.position.y + c.size.y * 0.5))
		if cc.distance_to(Vector2(cx, cy)) > float(maxi(px_w, px_h)) * 1.2:
			continue
		rest.append(c)
	rest.sort_custom(func(a, b):
		var pa := Vector2(float(a.position.x + a.size.x * 0.5), float(a.position.y + a.size.y * 0.5))
		var pb := Vector2(float(b.position.x + b.size.x * 0.5), float(b.position.y + b.size.y * 0.5))
		var c2 := Vector2(cx, cy)
		return pa.distance_squared_to(c2) < pb.distance_squared_to(c2))
	_chunks = keep + rest
	if _chunk_i >= _chunks.size():
		_all_done = true


func _commit_full() -> void:
	var w := _tw
	var h := _th
	for i in _out.size():
		if i % 4 == 3:
			_out[i] = 255
	var im := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, _out)
	img.blit_rect(im, Rect2i(0, 0, w, h), Vector2i(_tx0, _ty0))
	tex.update(img)
	# 只标记「这一块」覆盖的 tile —— 以前这里 fill(1) 把整张画布标成已烘，
	# 导致第一块烘完前沿就满了（遮罩失效、tiles_done 从第一块起就是满值）。
	var tx0 := _tx0 / TILE
	var ty0 := _ty0 / TILE
	var tx1 := int(ceil(float(_tx0 + w) / float(TILE)))
	var ty1 := int(ceil(float(_ty0 + h) / float(TILE)))
	for ty in range(ty0, mini(ty1, _ny)):
		for tx in range(tx0, mini(tx1, _nx)):
			var idx := ty * _nx + tx
			if tile_state[idx] == 0:
				tile_state[idx] = 1
				tiles_done += 1
	first_ready = true


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


## 视口（经纬度矩形）对应的 texel 范围
## ---------------- 整图缓存 ----------------
func _cache_key() -> String:
	return "%s/v%d/%d/%0.5f_%0.5f_%dx%d.png" % [CACHE_DIR, CACHE_VER,
			int(round(1.0 / maxf(_dlon, 1e-9))), lon0, lat0, px_w, px_h]


func _cache_try_load() -> bool:
	if not cache_on:
		return false
	var path := _cache_key()
	if not FileAccess.file_exists(path):
		return false
	var im := Image.load_from_file(path)
	if im == null or im.is_empty():
		return false
	if im.get_width() != px_w or im.get_height() != px_h:
		return false
	if im.get_format() != Image.FORMAT_RGBA8:
		im.convert(Image.FORMAT_RGBA8)
	img = im
	tex = ImageTexture.create_from_image(img)
	tile_state.fill(1)
	tiles_done = tiles_total
	first_ready = true
	_all_done = true
	if dbg_state:
		print("[细节] 整图缓存命中 %s" % path)
	return true


func _cache_save() -> void:
	if not cache_on:
		return
	if cache_files < 0:
		var d := DirAccess.open(CACHE_DIR)
		cache_files = 0
		if d != null:
			for sub in d.get_directories():
				var d2 := DirAccess.open(CACHE_DIR + "/" + sub)
				if d2 != null:
					cache_files += d2.get_files().size()
	# 上限：别让 user:// 无限长（一张约 1-2 MB）
	if cache_files > 300:
		if dbg_state:
			print("[细节] 缓存已到 300 张，本次不再写入")
		return
	var path := _cache_key()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if img.save_png(path) != OK:
		return
	cache_files += 1


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
