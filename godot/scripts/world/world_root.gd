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
const BUILD_TAG := "2026-11-01 20:20 远景壳不再挖洞"

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
var _last_tiles_ready := -1
var exploration := Exploration.new()
var _exp_timer := 0.0
var _minimap: MapMinimap
var _compass: Compass
var _hint: Label


func _ready() -> void:
	print("[World] BUILD_TAG = " + BUILD_TAG)
	# 黑屏期间给玩家一点信息，别让开局干等
	var wake0 := get_node_or_null("/root/Wake")
	if wake0 != null:
		wake0.set_caption("正在生成脚下的土地")
	var t0 := Time.get_ticks_msec()

	var cfg := MapConfig.new()
	exploration.load_saved()
	map = MapWorld.new()
	map.name = "MapWorld"
	add_child(map)
	map.setup(cfg, world_seed, DesignatedTileRegistry.new())
	map.add_annotations(DemoAnnotations.build())

	# 场景还在装配，这时候不能改父子关系 —— 等一帧
	await get_tree().process_frame

	_lookup_nodes()
	_make_sun()

	# 测试用：--at=经度,纬度 直接在指定地点出生
	var slon := start_lon
	var slat := start_lat
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--at="):
			var parts := a.substr(5).split(",")
			if parts.size() == 2:
				slon = float(parts[0])
				slat = float(parts[1])
	var center := GeoSphere.lonlat_to_dir(slon, slat)
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
		wake.set_caption("")
		wake.reveal()

	_maybe_capture()


## 每帧检查：该建的建，该扔的扔；顺便兜底防止人物掉进地里
func _process(_delta: float) -> void:
	if player == null or map == null or not map.is_built():
		return
	map.stream_update(player.position)

	# 记足迹：每 0.5 秒把玩家周围 1 公里记为已探索
	if player != null and not _traveling:
		_exp_timer += _delta
		if _exp_timer >= 0.5:
			_exp_timer = 0.0
			var ll := GeoSphere.dir_to_lonlat(
					GeoSphere.tangent_to_dir(map.region_frame,
							player.position.x, -player.position.z))
			if exploration.mark_lonlat(ll.x, ll.y):
				exploration.save()

	# 新地块建成后重新贴地一次：
	# 粗版地形比精细版低（山丘上能差 2~3m），如果人物是在粗版期间落地的，
	# 精细版一出来他就被"埋"进去了。这里在每块建成时纠正一次，不是每帧纠。
	if map.tiles_ready != _last_tiles_ready:
		_last_tiles_ready = map.tiles_ready
		if not _soul and not _traveling:
			_snap_one(player, 0.2)

	# 外部程序（QQ 截图、输入法、录屏）会把鼠标从游戏手里抢走，
	# 还回来时 Godot 不会自动重捕 —— 表现就是鼠标撞边、视角不能无限转。
	# 所以每帧核对一次：该捕获却没收回来，就重新捕获。
	# 鼠标状态跟「窗口是不是前台」这个事实对齐：
	# 只要不是前台就一定是可见光标，避免游戏退出捕获后 Windows 那边还留着隐藏的光标。
	if not DisplayServer.window_is_focused() and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# 不再每帧重捕：那会和 QQ 截图等外部工具抢鼠标，导致它们退不出去。
	# 恢复捕获放在「获得焦点」和「在窗口内按下鼠标」这两处（见 _notification / _input）。

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
	layer.layer = 20    # 提到所有 HUD 之上，否则「F · 上马」会穿透地图

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
	_hint.position = Vector2(18, 52)
	_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_hint.add_theme_constant_override("outline_size", 5)
	_hint.text = "Backspace: 灵魂状态    M: 世界地图    " + BUILD_TAG
	layer.add_child(_hint)

	# ---- 顶部方向标
	_compass = Compass.new()
	_compass.name = "Compass"
	_compass.setup(player, _player_cam, map, map.annotations)
	_compass.anchor_left = 0.5
	_compass.anchor_right = 0.5
	_compass.offset_left = -310.0
	_compass.offset_right = 310.0
	_compass.offset_top = 6.0
	_compass.offset_bottom = 74.0
	layer.add_child(_compass)

	add_child(layer)


# ================================================================ 输入
func _input(event: InputEvent) -> void:
	# 点击窗口时把鼠标捕获拿回来（不每帧抢，避免打死外部截图工具）
	if event is InputEventMouseButton and event.pressed and _want_capture() and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
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
		# 灵魂出窍 = 相机原地脱体。**不抬高、不后退**：
		# 抬起来会让人以为"飞上去了"，而且看不到自己骑在马上。
		var cam_ok := false
		if _player_cam != null and player != null:
			# 相机得真的在人物后方，否则（比如刚进游戏就按）会照搬到身体内部
			cam_ok = _player_cam.global_position.distance_to(player.global_position) > 1.5
		if cam_ok:
			_soul_cam.global_transform = _player_cam.global_transform
		else:
			var base := Vector3.ZERO
			if player != null:
				base = player.global_position
			# 兜底：人物后上方 3.5m，不飞天
			var back: Vector3 = Vector3(0.0, 0.0, 3.5)
			if player != null:
				back = player.global_transform.basis.z * 3.5
			_soul_cam.global_position = base + back + Vector3.UP * 1.6
			_soul_cam.rotation_degrees = Vector3(-8.0, 0.0, 0.0)
		# 关键：把相机摆好之后，必须让脚本内部的角度跟着更新，
		# 不然第一下鼠标移动会按旧角度重算朝向，镜头瞬间跳走。
		if _soul_cam.has_method("sync_angles"):
			_soul_cam.sync_angles()
		_soul_cam.current = true
	else:
		if _player_cam != null:
			_player_cam.current = true

	_freeze_mount(_soul)

	print("[World] 灵魂状态 = %s, 相机 = %s" % [_soul, _current_cam_name()])
	_update_hint()


func _apply_player_active(active: bool) -> void:
	if player != null:
		player.set_physics_process(active)
		player.set_process(active)
		player.set_process_input(active)
		player.set_process_unhandled_input(active)
	# 灵魂状态下也锁定鼠标（否则要按住右键才能转视角）；只有开地图时才释放
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if (active or _soul) else Input.MOUSE_MODE_VISIBLE


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
			"--high":
				if _soul_cam != null:
					_soul_cam.global_position += Vector3(0.0, 260.0, 0.0)
					_soul_cam.rotation_degrees = Vector3(-32.0, _soul_cam.rotation_degrees.y, 0.0)
			"--map":
				toggle_world_map()
			"--test-soul":
				_test_soul()
			"--test-drag":
				_test_drag()
			"--test-travelui":
				_test_travelui()
			"--seed-explore":
				_seed_explore()
			"--red-detail":
				if _minimap.get_dialog() != null and _minimap.get_dialog()._globe != null:
					_minimap.get_dialog()._globe._verify_red = true
			"--test-zoom-ui":
				await _test_zoom_ui()
			"--probe-pixel":
				_probe_pixel()
				return
			"--bake-globe":
				_bake_globe()
				return
			"--test-mask":
				_test_mask()
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
	# 截图前如果要求开地图，就在预加载完成之后再开一次（预加载会开关一次地图）
	for a2 in OS.get_cmdline_user_args():
		if a2 == "--mapshot":
			toggle_world_map()
			break
	# 把探索记录交给地图，用于限制缩放
	if _minimap.get_dialog() != null:
		_minimap.get_dialog().explored_gate = exploration
		if _minimap.get_dialog()._globe != null:
			_minimap.get_dialog()._globe.refresh_fog(exploration)
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

	# 传送只同步建了中心 1 块地（±500m）。玩家原来的 x/z 可能离旧中心 1km 以上，
	# 沿用就会直接站到新地块外面 —— 那里没有碰撞，一睁眼就往下掉。
	# 所以把人拉回新地图中心，再贴地。
	if player != null:
		player.position = Vector3(0.0, player.position.y, 0.0)
	if horse != null:
		horse.position = Vector3(0.0, horse.position.y, 0.0)
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
	player.position = Vector3(1400.0, player.position.y, 900.0)   # 故意离中心很远
	var target := GeoSphere.lonlat_to_dir(30.0, 10.0)
	print("[TravelTest] 目标: %.2f,%.2f  群系=%s" % [-60.0, -5.0, map.biome.biome_at(target)])
	await _on_travel(target)
	await get_tree().process_frame
	var c1 := map.region_center_dir
	print("[TravelTest] 抵达: %.2f,%.2f  群系=%s" % [GeoSphere.dir_to_lonlat(c1).x, GeoSphere.dir_to_lonlat(c1).y, map.biome.biome_at(c1)])
	for i in 200:
		await get_tree().process_frame
		if map.get_tiles().size() >= 3:
			break
	_snap_to_ground()   # 测试里也要贴地
	var pd := GeoSphere.tangent_to_dir(map.region_frame, player.position.x, -player.position.z)
	var gh := map.render_position(pd).y
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
	print("[UI] 目标是陆地 = %s" % str(dlg._target_is_land()))
	print("[UI] 松手后目标 = %s" % ("(无)" if tgt == Vector3.ZERO else str(GeoSphere.dir_to_lonlat(tgt))))
	if tgt == Vector3.ZERO:
		print("[UI] 拖拽没打中球，链路止步于此")
		return

	var enter := InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.pressed = true
	Input.parse_input_event(enter)
	print("[UI] 已合成回车")

	for i in 60:
		await get_tree().process_frame
	print("[UI] 提示文字 = [%s]  还在地图里 = %s" % [dlg._notice, str(dlg.visible)])
	var c := map.region_center_dir
	var ll := GeoSphere.dir_to_lonlat(c)
	print("[UI] 结束后中心 = %.2f,%.2f  群系=%s  地块=%d" % [ll.x, ll.y, map.biome.biome_at(c), map.get_tiles().size()])


## 当前是否应该抓着鼠标：只有正常游玩时才是
func _want_capture() -> bool:
	return player != null and not _soul and not _map_open and not _traveling


func _restore_hint() -> void:
	if _hint != null:
		_hint.text = "Backspace: 灵魂状态    M: 世界地图    " + BUILD_TAG


## 用游戏里的掩膜读一批已知点，和 Python 侧的结果对照
func _test_mask() -> void:
	var pts := [
		["非洲中部", 20.0, 5.0], ["咸阳", 108.71, 34.33], ["撒哈拉", 25.0, 23.0],
		["纽约", -74.0, 40.7], ["印度", 78.0, 22.0], ["太平洋", -150.0, 0.0],
		["巴西", -60.0, -5.0], ["南极", 101.93, -81.18],
	]
	var bm: BiomeMap = map.biome
	if bm == null:
		print("[MaskTest] biome 为空")
		return
	for p in pts:
		var d := GeoSphere.lonlat_to_dir(float(p[1]), float(p[2]))
		print("[MaskTest] %-6s %8.2f,%7.2f -> %s" % [p[0], p[1], p[2], "陆地" if bm.is_land(d) else "海洋"])


## 灵魂状态下把坐骑冻住：玩家已经停更，马还在自己跑，会出现"人停在原地、马跑远了"
func _freeze_mount(freeze: bool) -> void:
	if player == null:
		return
	var h = player.get("mount_horse")
	if h == null or not is_instance_valid(h):
		return
	if freeze:
		h.set("speed", 0.0)
		h.set_physics_process(false)
		h.set_process(false)
	else:
		h.set_physics_process(true)
		h.set_process(true)


## 烘焙地球贴图：改了群系参数后跑一次，之后游戏直接读文件
func _bake_globe() -> void:
	var v := WorldGlobeView.new()
	v.world = map
	v.bake_to("res://data/globe_tex.png", 2048, 1024)
	v.free()
	get_tree().quit()


## 诊断：查某个经纬度在烘焙时会得到什么
func _probe_pixel() -> void:
	var bm: BiomeMap = map.biome
	if bm == null:
		print("[PROBE] biome 为空")
		return
	for lat in [-14.0, -15.5, -16.0, -16.5, -17.0, -18.0]:
		var lon := -150.0
		var d := GeoSphere.lonlat_to_dir(lon, lat)
		print("[PROBE] lon=%.1f lat=%.1f  is_land=%s  is_land_ll=%s  biome=%s  biome_ll=%s" % [
			lon, lat, str(bm.is_land(d)), str(bm.is_land_ll(lon, lat)),
			bm.biome_at(d), bm.biome_at_ll(d, lon, lat)])
	get_tree().quit()


## 调试用：在关中一带种一片足迹，方便看迷雾效果
func _seed_explore() -> void:
	for i in range(10750, 11050, 4):
		for j in range(3350, 3520, 4):
			exploration.cells["%d_%d" % [i, j]] = true
	exploration.save()
	print("[SEED] 足迹 %d 个" % exploration.count())


## 合成滚轮事件，验证放大到底有没有生效
func _test_zoom_ui() -> void:
	await get_tree().process_frame
	while _minimap.get_dialog() == null or not _minimap.get_dialog().is_ready_for_map():
		await get_tree().process_frame
	toggle_world_map()
	await get_tree().process_frame
	await get_tree().process_frame
	var dlg := _minimap.get_dialog()
	if dlg == null or dlg._globe == null:
		print("[ZOOMUI] 地图没打开")
		return
	var g := dlg._globe
	var center := g.center_screen()
	print("[ZOOMUI] 起始 zoom=%.2f fov=%.2f" % [g.get_zoom(), g._cam.fov])
	for i in 25:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_WHEEL_UP
		ev.pressed = true
		ev.position = center
		Input.parse_input_event(ev)
		await get_tree().process_frame
	print("[ZOOMUI] 25 格之后 zoom=%.2f fov=%.2f" % [g.get_zoom(), g._cam.fov])
	# 等绘制完成再取图，否则拿到的是黑帧
	await RenderingServer.frame_post_draw
	await get_tree().create_timer(3.0).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("res://_截图/95_合成滚轮.png")
	print("[ZOOMUI] 已截图")
	get_tree().quit()
