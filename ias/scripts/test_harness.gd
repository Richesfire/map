extends Node
## 自检 / 基准 / 诊断（2026-11-16 从 main.gd 拆出来，约 690 行）。
##
## 不是独立场景：main.gd 在 `_th()` 里建一个实例挂成子节点，把 `m` 指回自己，
## 这里所有函数就都能读写 main 的成员（terrain / player / map_root / map_open / tab_sel ...）。
## 只用于 `--selftest / --bugtest / --citytest / --maptest / --seamtest / --sitestats /
## --demtest / --probe / --mapbench / --prev` 这些调试入口，正常游戏流程走不到。
##
## 命名注意：`m.` 前缀是故意的（main 的私有成员）；常量另起名字（Gen / Detail），
## 否则会和 main.gd 的同名 const 冲突。

const Gen := preload("res://scripts/terrain_gen.gd")

## main 节点（Node3D）。故意不标类型：要用的是 main 的私有成员，标成 Node/Node3D
## 会让静态检查报"方法/成员不存在"。
var m = null


func _map_bench() -> void:
	await get_tree().process_frame
	var t0 := Time.get_ticks_usec()
	for i in 60:
		m.map_root.queue_redraw()
		await get_tree().process_frame
	var dt := float(Time.get_ticks_usec() - t0) / 1000.0
	print("[基准] 60 帧总 %.0f ms，平均 %.1f ms/帧" % [dt, dt / 60.0])


## 高倍地图预览：按真实地形函数采样，输出 PNG（用于评估放大后的观感）
func _preview_tile(lon: float, lat: float, span: float, px: int, out_path: String) -> void:
	var t0 := Time.get_ticks_msec()
	var hs := PackedFloat32Array()
	hs.resize(px * px)
	var step := span / float(px)
	var lat_per_px := step
	var lon_per_px := step / maxf(cos(deg_to_rad(lat)), 0.05)
	for y in px:
		var py: float = lat + span * 0.5 - float(y) * lat_per_px
		for x in px:
			var px_lon: float = lon - span * 0.5 + float(x) * lon_per_px
			hs[y * px + x] = Gen.height_ll(px_lon, py, 0.0)
	var img := Image.create(px, px, false, Image.FORMAT_RGB8)
	var sun := Vector3(-0.55, 0.62, -0.56).normalized()
	for y in px:
		for x in px:
			var h: float = hs[y * px + x]
			var hx: float = hs[y * px + mini(x + 1, px - 1)]
			var hy: float = hs[mini(y + 1, px - 1) * px + x]
			var dzdx: float = (hx - h) / (step * 111320.0)
			var dzdy: float = (hy - h) / (step * 110540.0)
			var n := Vector3(-dzdx, 1.0, -dzdy).normalized()
			var sh: float = clampf(n.dot(sun), 0.0, 1.0)
			var px_lon: float = lon - span * 0.5 + float(x) * lon_per_px
			var py: float = lat + span * 0.5 - float(y) * lat_per_px
			var lk: int = Gen.landform_kind(px_lon, py, h)
			var c: Color
			if h < -8.0:
				c = Color(0.20, 0.28, 0.36)
			else:
				c = Gen.landform_color(lk)
			var light: float = 0.62 + sh * 0.62
			img.set_pixel(x, y, Color(c.r * light, c.g * light, c.b * light))
	var err := img.save_png(out_path)
	print("[预览] %s err=%d 用时 %d ms" % [out_path, err, Time.get_ticks_msec() - t0])
	get_tree().quit()


## 自测：跟随重建
func _selftest() -> void:
	await get_tree().process_frame
	var lon0: float = m.terrain.center_lon
	var lat0: float = m.terrain.center_lat
	var h_before: int = _hash_samples(800)
	var expect_lon: float = lon0 + 5000.0 / (111320.0 * cos(deg_to_rad(lat0)))
	m.player.global_position = Vector3(5000.0, m.terrain.height_xyz(5000.0, 0.0) + 3.0, 0.0)
	await get_tree().process_frame
	m._recentering = true
	await m._do_recenter(5000.0, 0.0)
	await get_tree().process_frame
	var ok_zero: bool = Vector2(m.player.global_position.x, m.player.global_position.z).length() < 1.0
	var ok_center: bool = absf(m.terrain.center_lon - expect_lon) < 0.0005
	var ok_collide: bool = m.terrain._body != null and m.terrain._body.get_child_count() > 0
	var ground: float = m.terrain.height_xyz(0.0, 0.0)
	var ok_ground: bool = absf(m.player.global_position.y - (ground + 3.0)) < 0.5
	var h_after: int = _hash_samples(800)
	var ok_det: bool = h_before == h_after
	print("[自测] 回原点=%s  中心推进=%s  碰撞存在=%s  落到地面=%s"
			% [ok_zero, ok_center, ok_collide, ok_ground])
	print("[自测] 中心 %.4f,%.4f -> %.4f,%.4f（期望 %.4f）"
			% [lon0, lat0, m.terrain.center_lon, m.terrain.center_lat, expect_lon])
	print("[自测] 重建后同一坐标校验和：%d / %d → %s"
			% [h_before, h_after, "一致" if ok_det else "不一致"])
	print("[自测] 结果：%s"
			% ("全部通过" if ok_zero and ok_center and ok_collide and ok_ground and ok_det else "有失败项"))
	get_tree().quit()


func _dump_relief(g: PackedFloat32Array, n: int, path: String, km_px: float) -> void:
	var cb := PackedByteArray()
	cb.resize(n * n * 3)
	var hmax := -99999.0
	for v in g:
		hmax = maxf(hmax, v)
	for iy in n:
		for ix in n:
			var i := iy * n + ix
			var h := g[i]
			var hx := g[iy * n + mini(ix + 1, n - 1)]
			var hy := g[mini(iy + 1, n - 1) * n + ix]
			var gx := (hx - h) / km_px
			var gy := (hy - h) / km_px
			var shade := clampf(0.70 - (gx * 0.60 + gy * 0.80) / 420.0, 0.18, 1.0)
			var c := Color(0.22, 0.31, 0.18)
			if h < -5.0:
				c = Color(0.20, 0.26, 0.32)
			else:
				var t := clampf(h / maxf(hmax, 1.0), 0.0, 1.0)
				c = Color(0.24, 0.34, 0.20).lerp(Color(0.78, 0.73, 0.58), clampf(t * 2.2, 0.0, 1.0))
				if h > 2200.0:
					c = c.lerp(Color(0.90, 0.90, 0.90), clampf((h - 2200.0) / 800.0, 0.0, 1.0))
			var i3 := i * 3
			cb[i3] = int(clampf(c.r * shade, 0.0, 1.0) * 255.0)
			cb[i3 + 1] = int(clampf(c.g * shade, 0.0, 1.0) * 255.0)
			cb[i3 + 2] = int(clampf(c.b * shade, 0.0, 1.0) * 255.0)
	var img := Image.create_from_data(n, n, false, Image.FORMAT_RGB8, cb)
	img.save_png(path)


## A/B/C 地形对照：第一个路径是真值（只用底图），后面是生成结果（底图+山体特征）
func _dem_test(paths: PackedStringArray) -> void:
	Gen.disable_overlay()
	var t0 := Time.get_ticks_msec()
	var lon_a := 112.0
	var lat_a := 37.0
	var lon_b := 115.5
	var lat_b := 40.2
	var n := 560
	var km_px := (lon_b - lon_a) * 111.32 * cos(deg_to_rad((lat_a + lat_b) * 0.5)) / float(n)

	var names: Array = []
	var grids: Array = []
	var peak_h: Array = []
	var peak_ll: Array = []
	for i in paths.size():
		var p: String = paths[i].strip_edges()
		var raw_only := p.begins_with("raw:")
		if raw_only:
			p = p.substr(4)
		if p == "":
			continue
		if not Gen.load_custom(p):
			print("[对比] 载入失败 ", p)
			continue
		var truth: bool = names.is_empty()
		var g := PackedFloat32Array()
		g.resize(n * n)
		var best := -99999.0
		var blon := lon_a
		var blat := lat_a
		for iy in n:
			var lat := lat_b - (float(iy) + 0.5) / float(n) * (lat_b - lat_a)
			for ix in n:
				var lon := lon_a + (float(ix) + 0.5) / float(n) * (lon_b - lon_a)
				var h: float = Gen.dem_at(lon, lat) if (truth or raw_only) else Gen.height_ll(lon, lat, 0.0)
				g[iy * n + ix] = h
				if h > best:
					best = h
					blon = lon
					blat = lat
		var nm: String = ("底图 " if raw_only else "") + p.get_file().get_basename()
		names.append(nm)
		grids.append(g)
		peak_h.append(best)
		peak_ll.append(Vector2(blon, blat))
		print("[对比] %-24s %s  最高 %.0f m @ %.3f,%.3f" % [nm, "真值" if truth else "生成", best, blon, blat])

	print("======== A/B/C 地形对照 ========")
	print("区域 %.1f-%.1fE  %.1f-%.1fN  网格 %d×%d（%.2f km/格）"
			% [lon_a, lon_b, lat_a, lat_b, n, n, km_px])
	var th: float = 0.0
	var tl: float = 0.0
	var tm: float = 0.0
	var tc: Array = [0, 0, 0]
	var truth_g: PackedFloat32Array = grids[0]
	for i in truth_g.size():
		var v := truth_g[i]
		var k := 0
		if v > 1200.0:
			k = 2
		elif v > 300.0:
			k = 1
		tc[k] += 1
	for vi in names.size():
		if vi == 0:
			continue
		var g: PackedFloat32Array = grids[vi]
		var rms := [0.0, 0.0, 0.0]
		for i in g.size():
			var v := truth_g[i]
			var k := 0
			if v > 1200.0:
				k = 2
			elif v > 300.0:
				k = 1
			var e: float = g[i] - v
			rms[k] += e * e
		var d := Vector2(peak_ll[vi].x - peak_ll[0].x, peak_ll[vi].y - peak_ll[0].y)
		print("%-24s 峰顶 %5.0f（真值 %5.0f，差 %+5.0f）  峰位偏差 %5.2f km"
				% [names[vi], peak_h[vi], peak_h[0], peak_h[vi] - peak_h[0],
				Gen.distance_m(peak_ll[vi].x, peak_ll[vi].y, peak_ll[0].x, peak_ll[0].y) / 1000.0])
		print("     RMS  山地(>1200m) %5.0f m   丘陵(300-1200m) %5.0f m   平原(<300m) %5.0f m"
				% [sqrt(rms[2] / maxf(tc[2], 1)), sqrt(rms[1] / maxf(tc[1], 1)), sqrt(rms[0] / maxf(tc[0], 1))])
		# 山地范围与走向（以 >1200m 为一阶矩）
		var cnt := 0
		var sx := 0.0
		var sy := 0.0
		var sxx := 0.0
		var syy := 0.0
		var sxy := 0.0
		for iy in n:
			var lat2 := lat_b - (float(iy) + 0.5) / float(n) * (lat_b - lat_a)
			for ix in n:
				if g[iy * n + ix] <= 1200.0:
					continue
				var lon2 := lon_a + (float(ix) + 0.5) / float(n) * (lon_b - lon_a)
				var X := (lon2 - lon_a) * 111.32 * cos(deg_to_rad(38.6))
				var Y := (lat2 - lat_a) * 110.54
				cnt += 1
				sx += X
				sy += Y
				sxx += X * X
				syy += Y * Y
				sxy += X * Y
		if cnt > 10:
			var mx := sx / float(cnt)
			var my := sy / float(cnt)
			var cxx := sxx / float(cnt) - mx * mx
			var cyy := syy / float(cnt) - my * my
			var cxy := sxy / float(cnt) - mx * my
			var ang := 0.5 * atan2(2.0 * cxy, cxx - cyy)
			# 方位角：正北为 0，顺时针
			var az := -rad_to_deg(ang)
			print("     山地(>1200m) 面积 %5.0f km²  质心 %.2f,%.2f  主轴方位 %4.0f°"
					% [float(cnt) * 0.54 * 0.54, lon_a + mx / (111.32 * cos(deg_to_rad(38.6))),
					lat_a + my / 110.54, az])

	var out_dir := "C:/Users/12980/Documents/deepseek-harness/default-workspace/demtest"
	DirAccess.make_dir_recursive_absolute(out_dir)
	for vi in names.size():
		var png := "%s/%d_%s.png" % [out_dir, vi, names[vi]]
		_dump_relief(grids[vi], n, png, km_px)
		print("[对比] 写出 ", png)
	print("[对比] 用时 %d ms" % (Time.get_ticks_msec() - t0))


## 近场补丁接缝自测
func _seam_test() -> void:
	print("======== 近场补丁接缝 ========")
	var lines := [
		["东边界 lat38", 38.0, 116.30, 116.70, true],
		["北边界 lon113", 113.0, 40.42, 40.70, false],
		["南边界 lon114", 114.0, 34.30, 34.70, false],
	]
	for spec in lines:
		var nm: String = spec[0]
		var fixed: float = spec[1]
		var a: float = spec[2]
		var b: float = spec[3]
		var along_lon: bool = spec[4]
		var n := 240
		var step_km := absf(b - a) / float(n - 1) * 111.32
		var prev := 0.0
		var maxstep := 0.0
		var at_t := 0.0
		var dmax := 0.0
		var dstep_max := 0.0
		var dprev := 0.0
		for i in n:
			var t := float(i) / float(n - 1)
			var lon := lerpf(a, b, t) if along_lon else fixed
			var lat := fixed if along_lon else lerpf(a, b, t)
			var h := Gen.macro_height(lon, lat)
			var d := h - Gen.macro_height_no_ov(lon, lat)
			dmax = maxf(dmax, absf(d))
			if i > 0:
				var st := absf(h - prev)
				if st > maxstep:
					maxstep = st
					at_t = t
				dstep_max = maxf(dstep_max, absf(d - dprev))
			prev = h
			dprev = d
		print("  %-14s 步长 %.0f m  最大相邻落差 %6.2f m（%.0f%%）  补丁增量 %.0f m，增量跳变 %.2f m"
				% [nm, step_km * 1000.0, maxstep, at_t * 100.0, dmax, dstep_max])
	# 补丁中心与外侧的高差（说明补丁确实在起作用）
	var probes := [
		["五台山顶", 113.58, 39.07],
		["恒山", 113.72, 39.67],
		["平原(114.6,38.6)", 114.6, 38.6],
		["补丁外(117.0,38.0)", 117.0, 38.0],
	]
	for pr in probes:
		var lon: float = pr[1]
		var lat: float = pr[2]
		print("  %-20s 最终 %.0f m  权重 %.2f"
				% [pr[0], Gen.height_ll(lon, lat, 0.0), Gen.overlay_weight(lon, lat)])
	print("==============================")
	get_tree().quit()


## 采样校验和：同一批坐标生成同一批高度 → 同一校验和
func _hash_samples(n: int = 4000) -> int:
	var acc := 0
	for i in n:
		var lon := -170.0 + fmod(float(i) * 7.319, 340.0)
		var lat := -55.0 + fmod(float(i) * 3.717, 110.0)
		var h := Gen.height_ll(lon, lat, 0.0)
		acc = ((acc * 31) + int(round(h * 100.0))) & 0x7FFFFFFF
	return acc


## 地图阴影 / 地形高度一致性：地图 39km/像素，只能比“同尺度剖面”
func _map_test() -> void:
	var imgs := Gen.bake_map(1024, 512)
	if imgs.size() < 3:
		return
	var hs: PackedFloat32Array = imgs[2]
	var mw := 1024
	var mh := 512
	print("======== 地图与地形一致性 ========")
	print("地图 %dx%d，赤道每像素约 %.0f km" % [mw, mh, 40075.0 / float(mw)])
	var lines := [
		["东向 lat37", 37.0, 100.0, 120.0, true],
		["东向 lat39", 39.0, 105.0, 120.0, true],
		["北向 lon113", 113.0, 30.0, 45.0, false],
	]
	for spec in lines:
		var nm: String = spec[0]
		var fixed: float = spec[1]
		var a0: float = spec[2]
		var a1: float = spec[3]
		var along_lon: bool = spec[4]
		var n := 200
		var s_map := 0.0
		var s_ter := 0.0
		var s_mm := 0.0
		var s_tt := 0.0
		var s_mt := 0.0
		var sum_abs := 0.0
		for i in n:
			var f := float(i) / float(n - 1)
			var lon := lerpf(a0, a1, f) if along_lon else fixed
			var lat := fixed if along_lon else lerpf(a0, a1, f)
			var px := clampi(int((lon + 180.0) / 360.0 * mw), 0, mw - 1)
			var py := clampi(int((90.0 - lat) / 180.0 * mh), 0, mh - 1)
			var hm: float = hs[py * mw + px]
			var ht: float = Gen.macro_height(lon, lat)
			s_map += hm
			s_ter += ht
			s_mm += hm * hm
			s_tt += ht * ht
			s_mt += hm * ht
			sum_abs += absf(hm - ht)
		var nf := float(n)
		var cov := s_mt / nf - (s_map / nf) * (s_ter / nf)
		var vm := s_mm / nf - (s_map / nf) * (s_map / nf)
		var vt := s_tt / nf - (s_ter / nf) * (s_ter / nf)
		var r := cov / sqrt(maxf(vm * vt, 0.0001))
		print("  %-12s 相关系数 %.4f   平均绝对差 %5.0f m" % [nm, r, sum_abs / nf])
	print("  （地图按点采样、地形含细节噪声，平均差主要来自 39km 采样）")
	print("================================")
	get_tree().quit()


## 关城点位与聚落海陆校验（headless，几秒出结果，不用开图）
func _site_stats() -> void:
	Gen.ensure_loaded()
	print("======== 关城 / 邑 / 要地 ========")
	for s in Gen.sites():
		var ll := Vector2(float(s["lon"]), float(s["lat"]))
		var h := Gen.dem_at(ll.x, ll.y)
		var lf := Gen.landform_kind(ll.x, ll.y, h)
		print("  %-6s %-3s (%.3f,%.3f) 高程 %5.0f m  %-6s  %s"
				% [String(s.get("name", "")), String(s.get("kind", "")), ll.x, ll.y, h,
					Gen.LF_NAMES[lf], "落水!" if m._on_water(ll.x, ll.y) else "陆地"])
	print("======== 汉书县（元始二年）========")
	var cty := Gen.counties()
	var wet := 0
	var lo := 999.0
	var hi := -999.0
	for c in cty:
		var cll: Vector2 = c["ll"]
		lo = minf(lo, cll.x)
		hi = maxf(hi, cll.x)
		if m._on_water(cll.x, cll.y):
			wet += 1
	print("  共 %d 处，经度 %.1f..%.1f，落水 %d 处" % [cty.size(), lo, hi, wet])
	for nm in ["长安县", "洛阳县", "雒阳县", "邯郸县", "成都县", "宛县", "临淄县", "番禺县"]:
		for c in cty:
			if String(c["n"]) == nm:
				var l2: Vector2 = c["ll"]
				print("  %-4s %.3f,%.3f  %s" % [nm, l2.x, l2.y, String(c["loc"])])
				break
	m._ensure_settlements()
	print("======== 聚落海陆校验 ========")
	print("  保留 %d / 剔除 %d（原始 %d）"
			% [m._settle.size(), m._settle_water.size(), m._settle.size() + m._settle_water.size()])
	var n := 0
	for w in m._settle_water:
		if n >= 15:
			break
		print("  剔除 %-10s (%.3f,%.3f) 高程 %.0f m"
				% [String(w["name"]), (w["ll"] as Vector2).x, (w["ll"] as Vector2).y, float(w["h"])])
		n += 1
	print("===============================")
	# 反向检查：留下来的点里还有多少在高程上是水面（判断规则有没有漏）
	var left_water: Array = []
	for it in m._settle_thin:
		var h2 := Gen.dem_at((it["ll"] as Vector2).x, (it["ll"] as Vector2).y)
		if h2 < 0.0:
			left_water.append([it, h2])
	print("  抽稀后仍在水面的点 %d 处" % left_water.size())
	for k in mini(10, left_water.size()):
		var it2: Dictionary = left_water[k][0]
		print("    遗留 %-10s (%.3f,%.3f) 高程 %.0f m"
				% [String(it2["name"]), (it2["ll"] as Vector2).x, (it2["ll"] as Vector2).y,
					float(left_water[k][1])])
	get_tree().quit()


## 城市保护范围自测
func _city_test() -> void:
	print("======== 城市保护范围 ========")
	var cs := Gen.cities()
	print("城市数 %d" % cs.size())
	for c in cs:
		var lon := float(c["lon"])
		var lat := float(c["lat"])
		var h := Gen.height_ll(lon, lat, 0.0)
		var w := Gen.city_blend(lon, lat).x
		print("  %s (%.3f,%.3f) 手工高程 %.0f  实际 %.0f  权重 %.2f"
				% [c["name"], lon, lat, float(c["height"]), h, w])
		# 城内 200 点起伏
		var mn := 99999.0
		var mx := -99999.0
		var acc := 0.0
		var n := 200
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for i in n:
			var a := rng.randf() * TAU
			var r := sqrt(rng.randf()) * float(c["radius"]) * 1000.0 * 0.9
			var ll := Gen.lonlat_of(cos(a) * r, sin(a) * r, lon, lat)
			var hh := Gen.height_ll(ll.x, ll.y, 0.0)
			mn = minf(mn, hh)
			mx = maxf(mx, hh)
			acc += hh
		print("    城内 %d 点：min %.2f  max %.2f  均值 %.2f  起伏 %.2f m"
				% [n, mn, mx, acc / float(n), mx - mn])
		# 边界过渡：沿正东方向每 50 m 采样
		var prev := 0.0
		var worst := 0.0
		for i in 241:
			var d := float(i) * 50.0
			var ll := Gen.lonlat_of(d, 0.0, lon, lat)
			var hh := Gen.height_ll(ll.x, ll.y, 0.0)
			if i > 0:
				worst = maxf(worst, absf(hh - prev))
			prev = hh
		print("    边界 12 km 剖面（50 m 步长）最大相邻落差 %.2f m" % worst)
		# 城墙范围内应无植被（按种子判定逻辑抽样）
		var blocked := 0
		for i in 400:
			var a2 := rng.randf() * TAU
			var r2 := sqrt(rng.randf()) * float(c["radius"]) * 1000.0 * 0.8
			var ll2 := Gen.lonlat_of(cos(a2) * r2, sin(a2) * r2, lon, lat)
			if Gen.city_blend(ll2.x, ll2.y).x > 0.3:
				blocked += 1
		print("    城内抽样 400 点中权重>0.3：%d（植被在这些点被跳过）" % blocked)
	print("==============================")
	get_tree().quit()


func _spawn_enemy(offset: Vector3) -> Node3D:
	var e: Node3D = load("res://scripts/enemy.gd").new()
	m.add_child(e)
	var x := offset.x
	var z := offset.z
	e.global_position = Vector3(x, m.terrain.height_xyz(x, z) + 1.5, z)
	e.setup(m.terrain, m.player)
	return e


func _bug_test() -> void:
	await get_tree().create_timer(0.4).timeout
	var ok := true

	# 1) 开图/关图后玩家输入要恢复
	m._open_map()
	await get_tree().process_frame
	m._close_map()
	await get_tree().process_frame
	var b1: bool = (m.player.map_open == false and m.map_open == false)
	ok = ok and b1
	print("[回归] 关图后 player.map_open=%s / map_open=%s → %s"
			% [m.player.map_open, m.map_open, "OK" if b1 else "FAIL"])

	# 1a1) TAB 轮盘：上移选“上”，按键重复不能把它打回地图
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	var ev := InputEventKey.new()
	ev.keycode = KEY_TAB
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	var mmu := InputEventMouseMotion.new()
	mmu.relative = Vector2(0.0, -80.0)
	Input.parse_input_event(mmu)
	await get_tree().process_frame
	var sel_up: int = m.tab_sel
	ev.echo = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	var sel_after_echo: int = m.tab_sel
	var b1a: bool = (sel_up == 0 and sel_after_echo == 0)
	ok = ok and b1a
	print("[回归] TAB 轮盘：上移选中 %d，重复按键后 %d → %s"
			% [sel_up, sel_after_echo, "OK" if b1a else "FAIL"])
	var evup := InputEventKey.new()
	evup.keycode = KEY_TAB
	evup.pressed = false
	Input.parse_input_event(evup)
	await get_tree().process_frame
	# 松开时选中"上"会打开角色界面（轮盘：上=角色 / 右=部队 / 左=背包），测试里先关掉
	var sheet_ok: bool = m.sheet_open
	ok = ok and sheet_ok
	print("[回归] 轮盘上=角色界面：sheet_open=%s → %s" % [sheet_ok, "OK" if sheet_ok else "FAIL"])
	if m.sheet_open:
		m._close_sheet()
	# 无头模式下鼠标捕获可能被忽略，这里显式再设一次，后面的俯仰测试依赖它
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await get_tree().physics_frame

	# 1a1b) TAB 轮盘斜划：先向上、再往左上甩 —— 应该能切到“左”
	# （以前只允许换到对面方向，相邻方向永远切不过去，手感像卡住）
	var evp2 := InputEventKey.new()
	evp2.keycode = KEY_TAB
	evp2.pressed = true
	Input.parse_input_event(evp2)
	await get_tree().process_frame
	var m_up2 := InputEventMouseMotion.new()
	m_up2.relative = Vector2(0.0, -90.0)
	Input.parse_input_event(m_up2)
	await get_tree().process_frame
	var s_up2: int = m.tab_sel
	var m_diag := InputEventMouseMotion.new()
	m_diag.relative = Vector2(-300.0, -96.0)
	Input.parse_input_event(m_diag)
	await get_tree().process_frame
	var s_left: int = m.tab_sel
	var b_diag: bool = (s_up2 == 0 and s_left == 3)
	ok = ok and b_diag
	print("[回归] 轮盘斜划：上→左上 选中 %d→%d → %s" % [s_up2, s_left, "OK" if b_diag else "FAIL"])
	var evr2 := InputEventKey.new()
	evr2.keycode = KEY_TAB
	evr2.pressed = false
	Input.parse_input_event(evr2)
	await get_tree().process_frame
	if m.sheet_open:
		m._close_sheet()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await get_tree().physics_frame

	# 1a2) 相机俯仰：鼠标上下要能改变俯仰，且相机高度跟着变
	var p0: float = m.player.pitch
	var cy0: float = m.player.cam.global_position.y
	var mmd := InputEventMouseMotion.new()
	mmd.relative = Vector2(0.0, -120.0)
	Input.parse_input_event(mmd)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var p1: float = m.player.pitch
	var cy1: float = m.player.cam.global_position.y
	var b1a2: bool = absf(p1 - p0) > 0.01 and absf(cy1 - cy0) > 0.05
	ok = ok and b1a2
	print("[回归] 相机俯仰：pitch %.3f → %.3f，相机高 %.2f → %.2f → %s"
			% [p0, p1, cy0, cy1, "OK" if b1a2 else "FAIL"])

	# 1b) 关图后鼠标回到锁定状态，视角能跟鼠标
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await get_tree().process_frame
	var yaw0: float = m.player.yaw
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(60.0, 0.0)
	Input.parse_input_event(mm)
	await get_tree().process_frame
	var b1b: bool = absf(m.player.yaw - yaw0) > 0.01
	ok = ok and b1b
	print("[回归] 关图后转视角：yaw %.4f → %.4f → %s"
			% [yaw0, m.player.yaw, "OK" if b1b else "FAIL"])

	# 1c) 看地图时不能盲走
	m._open_map()
	m.player.velocity = Vector3(5.0, 0.0, 0.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b1c: bool = absf(m.player.velocity.x) < 0.01 and absf(m.player.velocity.z) < 0.01
	m._close_map()
	await get_tree().process_frame
	ok = ok and b1c
	print("[回归] 开图时人物停住：vx=%.2f → %s" % [m.player.velocity.x, "OK" if b1c else "FAIL"])

	# 1e) 小地图要跟着玩家走
	m.player.global_position.x += 60.0
	await get_tree().create_timer(0.6).timeout
	var mp := Vector2(m.player.global_position.x, m.player.global_position.z)
	var b1e: bool = m._mini_pos.distance_to(mp) < 1.0
	ok = ok and b1e
	print("[回归] 小地图跟随：记录点距玩家 %.1f m → %s" % [m._mini_pos.distance_to(mp), "OK" if b1e else "FAIL"])

	# 1d) 旅行到陆地：落点在地面、不穿地
	var l0: float = m.terrain.center_lon + 0.3
	var a0: float = m.terrain.center_lat + 0.2
	m._travel_ll(Vector2(l0, a0))
	var waited := 0.0
	while m._traveling and waited < 25.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	await get_tree().process_frame
	var gh0: float = m.terrain.height_xyz(0.0, 0.0)
	var dy0: float = absf(m.player.global_position.y - gh0)
	# 旅行落地是“地面 +3 m 掉下来”，等它落到地面再量（最多 1 秒）
	for i in 60:
		if dy0 < 2.0:
			break
		await get_tree().process_frame
		gh0 = m.terrain.height_xyz(0.0, 0.0)
		dy0 = absf(m.player.global_position.y - gh0)
	var b1d: bool = dy0 < 2.0 and absf(m.terrain.center_lon - l0) < 0.001
	ok = ok and b1d
	print("[回归] 旅行落点：高差 %.2f m，中心 %.3f → %s" % [dy0, m.terrain.center_lon, "OK" if b1d else "FAIL"])

	# 1f) 敌人保持竖直
	var e1 := _spawn_enemy(Vector3(0.0, 0.0, -3.0))
	await get_tree().create_timer(0.5).timeout
	var rot := e1.rotation_degrees
	var b1f: bool = absf(rot.x) < 1.0 and absf(rot.z) < 1.0
	ok = ok and b1f
	print("[回归] 敌人姿态 pitch %.1f / roll %.1f → %s" % [rot.x, rot.z, "OK" if b1f else "FAIL"])
	e1.queue_free()
	await get_tree().process_frame

	# 3) 海上目标要被拦截
	var lon0: float = m.terrain.center_lon
	var lat0: float = m.terrain.center_lat
	m._travel_ll(Vector2(-150.0, 0.0))
	await get_tree().create_timer(0.5).timeout
	var b3: bool = absf(m.terrain.center_lon - lon0) < 0.001 and absf(m.terrain.center_lat - lat0) < 0.001
	ok = ok and b3
	print("[回归] 海上旅行拦截：中心 %.4f,%.4f（未变=%s）→ %s"
			% [m.terrain.center_lon, m.terrain.center_lat, b3, "OK" if b3 else "FAIL"])

	# 5) 灵魂模式（TAB 上箭头）
	var cam0: Vector3 = m.player.cam.global_position
	m.player.enter_soul()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b5: bool = m.player.soul and m.player.soul_pos.distance_to(cam0) < 1.0
	m.player.exit_soul()
	await get_tree().physics_frame
	var b5b: bool = not m.player.soul
	ok = ok and b5 and b5b
	print("[回归] 灵魂模式：脱离相机=%s 退出=%s → %s" % [b5, b5b, "OK" if b5 and b5b else "FAIL"])

	print("[回归] 结果：%s" % ("全部通过" if ok else "有失败项"))
	get_tree().quit()


## 山体特征层校验：对比“只用底图”和“底图+山体特征”的峰顶/山脚高程
func _probe() -> void:
	print("======== 地形真源校验 ========")
	var names := ["太行山", "五台山", "泰山", "秦岭", "祁连山", "天山", "喜马拉雅山", "阿尔卑斯山", "落基山"]
	print("%-12s %10s %10s %10s %10s" % ["山系", "底图峰顶", "最终峰顶", "山脚", "相对高差"])
	for nm in names:
		var st: Dictionary = Gen.feature_stats(nm)
		if st.is_empty():
			continue
		print("%-12s %10.0f %10.0f %10.0f %10.0f" % [
				nm, st["dem_peak"], st["peak"], st["foot"], st["peak"] - st["foot"]])
		print("             峰顶位置 %.2f, %.2f" % [st["lon"], st["lat"]])

	# 同一坐标重复采样必须完全一致（确定性）
	var a := Gen.height_ll(113.6, 37.6, 1.0)
	var b := Gen.height_ll(113.6, 37.6, 1.0)
	print("确定性：同一坐标两次采样 %.3f / %.3f → %s" % [a, b, "一致" if a == b else "不一致"])

	# 跨 LOD 细节淡出的连续性（太行山脚横切，10 公里内每 250 米一点）
	var worst := 0.0
	var prev := 0.0
	for i in 41:
		var r := float(i) * 250.0
		var h := Gen.height_xyz(r, 0.0, 113.72, 36.0, 1.0)
		if i > 0:
			worst = maxf(worst, absf(h - prev))
		prev = h
	print("连续性：10 公里横切最大相邻落差 %.2f 米" % worst)
	print("西向高度剖面（自 113.95,39.00）：")
	for i in 18:
		var r := float(i + 1) * 2000.0
		var ll := Gen.lonlat_of(-r, 0.0, 113.95, 39.00)
		print("  r=%3.0f km  lon %.2f  %6.0f m" % [r / 1000.0, ll.x, Gen.height_ll(ll.x, ll.y, 0.0)])
	print("==============================")
