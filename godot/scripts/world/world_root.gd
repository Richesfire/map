extends Node3D

## ==============================================================
## IAS 动作系统 × 地图模块 的接合层
##
## 做四件事：
##   1. 铺地图（立方体球 + 地形 + 撒点 + 碰撞）
##   2. 把玩家和马放到地表上
##   3. Backspace 切换「灵魂状态」：冻结玩家，换成自由飞行相机
##   4. M 开关大地图（地球仪），打开时冻结玩家并释放鼠标
##
## 玩家的动作/战斗/骑乘逻辑一行没改，全部原样运行。
##
## 输入必须走 _input 而不是 _unhandled_input：
## player.gd 在 _unhandled_input 里处理按键并且会把事件标记为已处理，
## 用 _unhandled_input 的话热键会被它抢先吃掉（这就是之前 Backspace 没反应的原因）。
## ==============================================================

## 每次改完都改这个，用来确认你运行的到底是不是最新代码
const BUILD_TAG := "2026-11-01 19:15 鼠标重捕+抵达提示+草修复"

@export_group("地图")
@export var start_lon := 108.71
@export var start_lat := 34.33
@export var tiles_x := 3
@export var tiles_z := 3
@export var world_seed := 209
@export var generate_scatter := true
@export_range(0, 4) var stream_radius := 1   # 0=不流式；1=常驻 3x3 跟着玩家跑

@export_group("灵魂状态")
@export var soul_speed := 90.0

var map: MapWorld
var player: Node3D
var horse: Node3D

var _soul_cam: Camera3D
var _player_cam: Camera3D
var _soul := false
var _map_open := false
var _warn_cd := 0
var _traveling := false
var _minimap: MapMinimap
var _hint: Label


func _ready() -> void:
	print("[World] BUILD_TAG = " + BUILD_TAG)
	var t0 := Time.get_ticks_msec()

	var cfg := MapConfig.new()
	map = MapWorld.new()
	map.name = "MapWorld"
	add_child(map)
	map.setup(cfg, world_seed, DesignatedTileRegistry.new())
	map.add_annotations(DemoAnnotations.build())

	# 场景还在装配，这时候不能改父子关系 —— 等一帧
	await get_tree().process_frame

	_lookup_nodes()
	_make_sun()

	var center := GeoSphere.lonlat_to_dir(start_lon, start_lat)
	# 流式模式下启动只建 1 块（约 0.7s），其余边跑边补；否则一次性建满
	var start_n := 1 if stream_radius > 0 else tiles_x
	map.build(center, start_n, start_n if stream_radius > 0 else tiles_z, generate_scatter)
	if stream_radius > 0:
		map.enable_streaming(stream_radius)
	if map.biome != null:
		var b := map.biome.biome_at(center)
		print("[World] 出生点生物群系 = %s（%s）" % [b, map.biome.name_of(b)])
	print("[World] 地形生成完成：%d ms" % (Time.get_ticks_msec() - t0))

	await get_tree().process_frame

	_fix_environment()
	_verify_collision()
	_snap_to_ground()
	_build_soul_camera()
	_build_minimap()
	_build_hint()

	_cli()

	# 趁黑屏把地球仪贴图先算好，第一次按 M 就不会卡
	if _minimap != null:
		await _minimap.prewarm_world_map()

	var wake := get_node_or_null("/root/Wake")
	if wake != null:
		wake.reveal()

	_maybe_capture()


## 每帧检查：该建的建，该扔的扔；顺便兜底防止人物掉进地里
func _process(_delta: float) -> void:
	if player == null or map == null or not map.is_built():
		return
	map.stream_update(player.position)

	# 外部程序（QQ 截图、输入法、录屏）会把鼠标从游戏手里抢走，
	# 还回来时 Godot 不会自动重捕 —— 表现就是鼠标撞边、视角不能无限转。
	# 所以每帧核对一次：该捕获却没收回来，就重新捕获。
	if _want_capture() and get_window().has_focus() and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	# 坠落救援：只在**真的掉下去了**（低于地表 20m）才介入。
	# 之前用 0.8m 做"实时纠正"是错的：粗版还没建碰撞的那几帧会反复触发，
	# 每帧把人往上瞬移 2m，骑马时会把马一起弹上天。
	if player.mount_horse != null:
		return          # 骑乘状态不纠正，交给物理
	var p: Vector3 = player.global_position
	var dir := GeoSphere.tangent_to_dir(map.region_frame, p.x, -p.z)
	var ground := map.render_position(dir).y
	# 诊断：人物和解析地面的高度差。正常应该在 ±0.5m 内；
	# 如果持续偏差很大，说明站的那块地块的碰撞跟看到的对不上。
	if absf(p.y - ground) > 1.5 and _warn_cd <= 0:
		_warn_cd = 120
		print("[Height] 人物 y=%.2f  解析地面=%.2f  差=%.2f  地块=%s" % [
			p.y, ground, p.y - ground, str(map.dir_to_tile(dir))])
	_warn_cd -= 1

	if p.y < ground - 20.0:
		player.global_position = Vector3(p.x, ground + 2.0, p.z)
		if player is CharacterBody3D:
			(player as CharacterBody3D).velocity = Vector3.ZERO
		print("[World] 人物掉出地表，已拉回 (y %.1f -> %.1f)" % [p.y, ground + 2.0])


## 窗口失焦（Alt+Tab、截图、点别的窗口）时一定要放开鼠标，
## 否则光标被游戏抓着，桌面上的鼠标会"消失"
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			if not _soul and not _map_open and player != null:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _lookup_nodes() -> void:
	var root := get_parent()
	if root == null:
		root = self
	player = root.get_node_or_null("Player")
	horse = root.get_node_or_null("Horse")
	_player_cam = root.get_node_or_null("CameraPivot/Camera3D")


## 他们场景里的太阳旋转是按 170m 小场景调的，在 1km 地形上照不亮，这里重建一个
func _make_sun() -> void:
	var root := get_parent()
	if root == null:
		return
	var sun: Node = root.get_node_or_null("DirectionalLight3D")
	if sun == null:
		sun = DirectionalLight3D.new()
		sun.name = "DirectionalLight3D"
		root.add_child(sun)
	if sun is DirectionalLight3D:
		var dl := sun as DirectionalLight3D
		dl.rotation_degrees = Vector3(-52.0, 35.0, 0.0)
		dl.light_energy = 1.3
		dl.light_color = Color(1.0, 0.96, 0.90)
		dl.shadow_enabled = true
		dl.directional_shadow_max_distance = 500.0
		dl.directional_shadow_blend_splits = true


## 他们原来的环境是按 170m 场景配的：fog_density=0.012 在 1km 尺度下会把地面糊成一片
func _fix_environment() -> void:
	var we := get_parent().get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return
	var env: Environment = we.environment
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.31, 0.47, 0.70)
	sky_mat.sky_horizon_color = Color(0.72, 0.78, 0.84)
	sky_mat.ground_bottom_color = Color(0.16, 0.15, 0.13)
	sky_mat.ground_horizon_color = Color(0.58, 0.60, 0.57)
	sky.sky_material = sky_mat
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.fog_density = 0.00022
	env.fog_light_color = Color(0.74, 0.79, 0.85)


## 校验物理高度和解析高度是否一致
func _verify_collision() -> void:
	var space := get_world_3d().direct_space_state
	for probe in [Vector2(180, -140), Vector2(300, 200), Vector2(-400, 350)]:
		var from := Vector3(probe.x, 400.0, probe.y)
		var q := PhysicsRayQueryParameters3D.create(from, Vector3(probe.x, -100.0, probe.y))
		var hit := space.intersect_ray(q)
		var dir := GeoSphere.tangent_to_dir(map.region_frame, probe.x, -probe.y)
		var expect := map.render_position(dir).y
		var got: float = hit.position.y if hit else -999.0
		print("[World] 碰撞校验 (%d,%d): 物理=%.2f 解析=%.2f 差=%.2f"
			% [probe.x, probe.y, got, expect, got - expect])


func _snap_to_ground() -> void:
	_snap_one(player, 2.0)
	_snap_one(horse, 1.0)


func _snap_one(n: Node3D, y_off: float) -> void:
	if n == null or map == null:
		return
	var p := n.position
	var dir := GeoSphere.tangent_to_dir(map.region_frame, p.x, -p.z)
	var pos := map.render_position(dir)
	n.position = Vector3(p.x, pos.y + y_off, p.z)
	if n is CharacterBody3D:
		(n as CharacterBody3D).velocity = Vector3.ZERO


func _build_soul_camera() -> void:
	_soul_cam = Camera3D.new()
	_soul_cam.name = "SoulCamera"
	_soul_cam.set_script(load("res://scripts/world/soul_camera.gd"))
	_soul_cam.set("move_speed", soul_speed)
	_soul_cam.fov = 72.0
	_soul_cam.near = 0.4
	_soul_cam.far = 6000.0
	_soul_cam.current = false
	_soul_cam.position = Vector3(0.0, 60.0, 40.0)
	_soul_cam.rotation_degrees = Vector3(-20.0, 0.0, 0.0)
	add_child(_soul_cam)


func _build_minimap() -> void:
	var layer := CanvasLayer.new()
	layer.name = "MapLayer"
	layer.layer = 1

	_minimap = MapMinimap.new()
	_minimap.name = "Minimap"
	_minimap.anchor_left = 1.0
	_minimap.anchor_right = 1.0
	_minimap.offset_left = -236.0
	_minimap.offset_right = -12.0
	_minimap.offset_top = 12.0
	_minimap.offset_bottom = 236.0
	layer.add_child(_minimap)
	add_child(layer)
	_minimap.setup(map, player)


func _build_hint() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HintLayer"
	layer.layer = 3
	_hint = Label.new()
	_hint.position = Vector2(18, 12)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_hint.add_theme_constant_override("outline_size", 5)
	_hint.text = "Backspace: 灵魂状态    M: 世界地图    " + BUILD_TAG
	layer.add_child(_hint)
	add_child(layer)


# ================================================================ 输入
func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var k := event as InputEventKey
	if not k.pressed or k.echo:
		return

	match k.keycode:
		KEY_BACKSPACE:
			_toggle_soul()
			get_viewport().set_input_as_handled()
		KEY_M:
			toggle_world_map()
			get_viewport().set_input_as_handled()
		KEY_ESCAPE:
			if _map_open:
				toggle_world_map()
				get_viewport().set_input_as_handled()
			elif _soul:
				_toggle_soul()
				get_viewport().set_input_as_handled()


# ================================================================ 灵魂状态
func _toggle_soul() -> void:
	_soul = not _soul
	_apply_player_active(not (_soul or _map_open))

	if _soul:
		# 从当前身体位置上方起飞
		var base := Vector3.ZERO
		if player != null:
			base = player.global_position
		_soul_cam.global_position = base + Vector3(0.0, 25.0, 30.0)
		_soul_cam.rotation_degrees = Vector3(-20.0, 0.0, 0.0)
		_soul_cam.current = true
	else:
		if _player_cam != null:
			_player_cam.current = true

	print("[World] 灵魂状态 = %s, 相机 = %s" % [_soul, _current_cam_name()])
	_update_hint()


func _apply_player_active(active: bool) -> void:
	if player != null:
		player.set_physics_process(active)
		player.set_process(active)
		player.set_process_input(active)
		player.set_process_unhandled_input(active)
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if (active and not _soul) else Input.MOUSE_MODE_VISIBLE


func _current_cam_name() -> String:
	if _soul_cam != null and _soul_cam.current:
		return "SoulCamera"
	if _player_cam != null and _player_cam.current:
		return "PlayerCamera"
	return "(none)"


# ================================================================ 世界地图
func toggle_world_map() -> void:
	if _minimap == null:
		return
	if _map_open:
		_minimap.close_world_map()
		_map_open = false
		_apply_player_active(not _soul)
		if _soul:
			_soul_cam.current = true
		elif _player_cam != null:
			_player_cam.current = true
	else:
		_minimap.open_world_map()
		var dlg := _minimap.get_dialog()
		if dlg != null and not dlg.travel_requested.is_connected(_on_travel):
			dlg.travel_requested.connect(_on_travel)
		_map_open = true
		_apply_player_active(false)
	print("[World] 世界地图 = %s" % _map_open)
	_update_hint()


func _update_hint() -> void:
	if _hint == null:
		return
	# 地图打开时把外面的提示藏掉，地球仪窗口自带提示，否则两行叠一起
	_hint.visible = not _map_open
	if _map_open:
		return
	elif _soul:
		_hint.text = "灵魂状态（自由飞行） — Backspace / Esc 回到身体 · M 世界地图"
	else:
		_hint.text = "Backspace: 灵魂状态    M: 世界地图    " + BUILD_TAG


# ================================================================ 命令行
func _cli() -> void:
	for a in OS.get_cmdline_user_args():
		match a:
			"--soul":
				_toggle_soul()
			"--map":
				toggle_world_map()
			"--test-soul":
				_test_soul()
			"--test-drag":
				_test_drag()
			"--test-travelui":
				_test_travelui()
			"--test-travelto":
				_test_travelto()
			"--test-stream":
				_test_stream()
			"--test-openclose":
				_test_openclose()
			"--test-ride":
				_test_ride()


## 无头验证灵魂状态来回切：进 -> 出 -> 进 -> 出
func _test_soul() -> void:
	for i in 4:
		_toggle_soul()
		await get_tree().process_frame
		await get_tree().process_frame


## 模拟骑马往前跑 6km（每帧 0.4m，约 24m/s），全程贴地，看地图会不会跟不上
func _test_ride() -> void:
	await get_tree().process_frame
	var start := player.position
	var max_ms := 0
	for i in 900:
		var before := Time.get_ticks_msec()
		player.position += Vector3(0.4, 0.0, -0.3)
		_snap_one(player, 2.0)
		await get_tree().process_frame
		max_ms = maxi(max_ms, Time.get_ticks_msec() - before)
	var d := (player.position - start).length()
	print("[Ride] 跑了 %.0f m，常驻 %d 块，单帧最长 %d ms" % [d, map.get_tiles().size(), max_ms])


## 开一次世界地图再关掉，看主世界环境有没有被污染
func _test_openclose() -> void:
	toggle_world_map()
	await get_tree().process_frame
	await get_tree().process_frame
	toggle_world_map()
	await get_tree().process_frame
	var we := get_parent().get_node_or_null("WorldEnvironment")
	if we != null and we.environment != null:
		var e: Environment = we.environment
		print("[EnvTest] bg_mode=%d sky=%s ambient_src=%d" % [
			e.background_mode, str(e.sky != null), e.ambient_light_source])


## 验证流式加载：把玩家推 2.5km，看地块是否跟着换
func _test_stream() -> void:
	await get_tree().process_frame
	var before := map.get_tiles().size()
	var n0 := map.get_tiles().size()
	player.position += Vector3(2500.0, 0.0, 0.0)
	for i in 200:
		await get_tree().process_frame
	print("[TestStream] 地块数 %d -> %d（半径 %d）" % [before, map.get_tiles().size(), map.stream_radius()])


## 合成鼠标事件，验证地球仪能不能转（走完整输入链路）
func _test_drag() -> void:
	toggle_world_map()
	await get_tree().process_frame
	await get_tree().process_frame
	var dlg := _minimap.get_dialog()
	if dlg == null:
		print("[TestDrag] 拿不到对话框")
		return
	var before: Vector3 = dlg.get_view()
	var center: Vector2 = get_viewport().get_visible_rect().size * 0.5

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = center
	down.global_position = center
	Input.parse_input_event(down)
	await get_tree().process_frame

	var mv := InputEventMouseMotion.new()
	mv.position = center + Vector2(80.0, 0.0)
	mv.global_position = mv.position
	mv.relative = Vector2(80.0, 0.0)
	Input.parse_input_event(mv)
	await get_tree().process_frame

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = mv.position
	up.global_position = mv.position
	Input.parse_input_event(up)
	await get_tree().process_frame

	var after: Vector3 = dlg.get_view()
	print("[TestDrag] 前 %s  后 %s  变化 %.5f" % [str(before), str(after), (after - before).length()])

	# 顺便验一下滚轮缩放
	var g := dlg.get_globe()
	if g != null:
		var z0: float = g.get_camera_z()
		g.zoom_by(4.0)
		print("[TestZoom] 相机 z: %.3f -> %.3f" % [z0, g.get_camera_z()])


func _maybe_capture() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	if out.is_empty():
		return
	for i in 80:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png(out)
	print("[World] screenshot -> " + out)
	get_tree().quit()


## 时间旅行：拖到哪落到哪。闭眼 -> 重建地图 -> 落地 -> 睁眼
func _on_travel(target_dir: Vector3) -> void:
	if _traveling:
		return
	_traveling = true
	print("[TravelTrace] 收到请求 %.2f,%.2f" % [GeoSphere.dir_to_lonlat(target_dir).x, GeoSphere.dir_to_lonlat(target_dir).y])

	_map_open = false
	_minimap.close_world_map()

	var wake := get_node_or_null("/root/Wake")
	if wake != null:
		await wake.cover()

	print("[TravelTrace] 闭眼完成，开始重建")
	map.travel_to(target_dir, 1)
	if _minimap != null:
		_minimap.refresh()
	await get_tree().process_frame
	_snap_to_ground()
	if _soul_cam != null:
		_soul_cam.global_position = player.global_position + Vector3(0.0, 25.0, 30.0)
	if _soul:
		_soul_cam.current = true
	elif _player_cam != null:
		_player_cam.current = true

	# 等几帧把落点周围的地块建出来，再睁眼
	for i in 12:
		await get_tree().process_frame

	if wake != null:
		await wake.reveal()
	print("[TravelTrace] 完成，当前群系=%s" % map.biome.biome_at(map.region_center_dir))
	_traveling = false
	var ll := GeoSphere.dir_to_lonlat(target_dir)
	var bname := "?"
	if map.biome != null:
		bname = map.biome.name_of(map.biome.biome_at(target_dir))
	print("[World] 已抵达 %.2f, %.2f  地形=%s" % [ll.x, ll.y, bname])
	if _hint != null:
		_hint.visible = true
		_hint.text = "已抵达 %.2f, %.2f   地形：%s" % [ll.x, ll.y, bname]
		var tw := get_tree().create_timer(4.0)
		tw.timeout.connect(_restore_hint)

	_apply_player_active(true)


## 直接传送到南极，检查生物群系和地形是否真的变了
func _test_travelto() -> void:
	var c0 := map.region_center_dir
	print("[TravelTest] 出发: %.2f,%.2f  群系=%s" % [GeoSphere.dir_to_lonlat(c0).x, GeoSphere.dir_to_lonlat(c0).y, map.biome.biome_at(c0)])
	var target := GeoSphere.lonlat_to_dir(-60.0, -5.0)
	print("[TravelTest] 目标: %.2f,%.2f  群系=%s" % [-60.0, -5.0, map.biome.biome_at(target)])
	map.travel_to(target, 1)
	await get_tree().process_frame
	var c1 := map.region_center_dir
	print("[TravelTest] 抵达: %.2f,%.2f  群系=%s" % [GeoSphere.dir_to_lonlat(c1).x, GeoSphere.dir_to_lonlat(c1).y, map.biome.biome_at(c1)])
	for i in 200:
		await get_tree().process_frame
		if map.get_tiles().size() >= 3:
			break
	_snap_to_ground()   # 测试里也要贴地
	for i in 120:
		await get_tree().process_frame
	print("[TravelTest] 地块数=%d  玩家pos=%s" % [map.get_tiles().size(), str(player.position)])
	for i in 30:
		await get_tree().process_frame
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			var f := a.substr(6)
			get_viewport().get_texture().get_image().save_png(f)
			print("[TravelShot] " + f)
			get_tree().quit()


## 合成真实操作：拖准星到球上 -> 按回车，验证 UI 这条链路
func _test_travelui() -> void:
	# 等预加载（开局那次开/关地图）跑完，否则测试事件会撞在一起
	for i in 400:
		await get_tree().process_frame
		var d0 := _minimap.get_dialog()
		if d0 != null and d0.is_ready_for_map():
			break
	toggle_world_map()
	for i in 6:
		await get_tree().process_frame
	var dlg := _minimap.get_dialog()
	if dlg == null:
		print("[UI] 拿不到对话框")
		return

	var from: Vector2 = dlg.pin_pos()
	var vp := get_viewport().get_visible_rect().size
	var to := Vector2(vp.x * 0.42, vp.y * 0.68)     # 球面左下方

	var down := InputEventMouseButton.new()
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.position = from
	down.global_position = from
	Input.parse_input_event(down)
	await get_tree().process_frame

	var mv := InputEventMouseMotion.new()
	mv.position = to
	mv.global_position = to
	mv.relative = to - from
	Input.parse_input_event(mv)
	await get_tree().process_frame

	var up := InputEventMouseButton.new()
	up.button_index = MOUSE_BUTTON_LEFT
	up.pressed = false
	up.position = to
	up.global_position = to
	Input.parse_input_event(up)
	await get_tree().process_frame

	var tgt: Vector3 = dlg.target_dir()
	print("[UI] 松手后目标 = %s" % ("(无)" if tgt == Vector3.ZERO else str(GeoSphere.dir_to_lonlat(tgt))))
	if tgt == Vector3.ZERO:
		print("[UI] 拖拽没打中球，链路止步于此")
		return

	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	Input.parse_input_event(enter)
	print("[UI] 已合成回车")

	for i in 120:
		await get_tree().process_frame
	var c := map.region_center_dir
	var ll := GeoSphere.dir_to_lonlat(c)
	print("[UI] 结束后中心 = %.2f,%.2f  群系=%s  地块=%d" % [ll.x, ll.y, map.biome.biome_at(c), map.get_tiles().size()])


## 当前是否应该抓着鼠标：只有正常游玩时才是
func _want_capture() -> bool:
	return player != null and not _soul and not _map_open and not _traveling


func _restore_hint() -> void:
	if _hint != null:
		_hint.text = "Backspace: 灵魂状态    M: 世界地图    " + BUILD_TAG
