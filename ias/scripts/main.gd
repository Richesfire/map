extends Node3D
## 主控：主菜单 → 游戏；小地图 + TAB 十字 + 大地图 + 世界时间

const TG := preload("res://scripts/terrain_gen.gd")

## 世界地图逻辑尺寸（屏幕矩形按它算；纹理可以更高清地拉伸上去）
const MAP_W := 2048
const MAP_H := 1024
## 启动先用这个分辨率快速出图，再在后台线程烘高清版
const MAP_BOOT_W := 1024
const MAP_BOOT_H := 512
const MAP_HI_W := 4096
const MAP_HI_H := 2048

## 时间：1 现实秒 = 1 游戏分钟（一天 24 现实分钟）
const TIME_SCALE := 1.0
## 行军速度（公里/天），快速旅行按它折算耗时
const MARCH_KM_PER_DAY := 45.0
## 玩家离网格中心超过这个距离就重建（碰撞跟着玩家走）
const RECENTER_R := 4000.0
## TAB 轮盘：中心死区（像素）与切换所需最小位移
const TAB_DEAD_ZONE := 45.0
const TAB_SWITCH_MIN := 70.0
const CLOCK_START := 8.0 * 60.0      # 前 209 年十月初一 辰时

enum St { MENU, GAME }

var state := St.MENU
var terrain: Node3D
var player: Node3D

var ui_layer: CanvasLayer
var menu_box: Control
var hud_minimap: Control
var compass: Control
var _compass_yaw := 1e9
var _compass_tex: GradientTexture2D
var tab_cross: Control
var map_root: Control
var clock_label: Label
var info_label: Label
var toast_label: Label
var toast_timer: Timer

var clock_min := CLOCK_START            # 游戏内分钟（连续）
var _clock_acc := 0.0
var _sun: DirectionalLight3D
var _debug_center := Vector2(INF, INF)
var _debug_fresh := false
var _debug_shot := ""
var _debug_shot_delay := 3.0
var _debug_mapzoom := 0.0
var _debug_yaw := INF
var _debug_air := 0.0
var _debug_hour := -1.0
var _debug_demtest := PackedStringArray()
var city_labels: Array = []
var soul_hint: Label
var _flash := 0.0
var _mini_pos := Vector2(1e9, 1e9)
var _mini_yaw := 999.0
var _traveling := false
var boot_layer: CanvasLayer
var boot_label: Label
var boot_bar: Control
var _boot_progress := 0.0
var _boot_spin := 0.0
var _recentering := false
var _map_thread: Thread
var _map_hi_done := false
var _map_hi: Array = []
var map_surface: ColorRect
var map_view: Control
var _vil_key := Vector2i(99999, 99999)
var _vil_cache: Array = []
var map_backdrop: TextureRect
var _map_shader_ok := false
var _map_mat: ShaderMaterial
var _lf_thread: Thread
var _lf_hi: Image
var _lf_done := false
var _dead := false

var tab_held := false
var tab_sel := -1
var tab_labels: Array = []                # 0上 1右 2下 3左；-1 = 未选
var _tab_acc := Vector2.ZERO
var _tab_locked := false
var map_open := false
var map_center := Vector2(113.72, 36.00)   # 地图中心经纬度
var map_zoom := 2.6
var pin_ll := Vector2(INF, INF)   # 旅行标：经纬度（钉在地图上）
var has_pin := false
var loading_box: Control = null
var dragging := false
var pin_drag := false
var _world_tex: ImageTexture = null
var _shade_tex: ImageTexture = null


func _ready() -> void:
	_parse_args()
	if OS.get_cmdline_user_args().has("--citytest"):
		_city_test()
		return
	if OS.get_cmdline_user_args().has("--maptest"):
		_map_test()
		return
	if OS.get_cmdline_user_args().has("--hash"):
		TG.ensure_loaded()
		print("[稳定] 校验和 %d" % _hash_samples())
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--nooverlay"):
		TG.disable_overlay()
	if OS.get_cmdline_user_args().has("--seamtest"):
		_seam_test()
		return
	if _debug_demtest.size() > 0:
		_dem_test(_debug_demtest)
		get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--probe"):
		_probe()
		get_tree().quit()
		return
	_show_boot("正在载入地形数据……")
	await get_tree().process_frame
	await get_tree().process_frame
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--bootshot="):
			_take_shot(a.substr(11), 0.4)
	await get_tree().process_frame
	_setup_world()
	_build_ui()
	_boot_text("正在烘焙世界地图……")
	await get_tree().process_frame
	_build_world_tex()
	var uargs := OS.get_cmdline_user_args()
	if uargs.has("--start") or uargs.has("--bugtest"):
		_boot_text("正在生成地形……")
		await get_tree().process_frame
		await get_tree().process_frame
		await _start_game()
		if uargs.has("--bugtest"):
			_bug_test()
		elif _debug_shot != "":
			_take_shot(_debug_shot, _debug_shot_delay)
	else:
		_hide_boot()
		if _debug_shot != "":
			_take_shot(_debug_shot, _debug_shot_delay)

	_bug_unused()


## 调试参数：--at lon,lat   --fresh   --shot 路径.png
func _parse_args() -> void:
	var ua := OS.get_cmdline_user_args()
	var i := 0
	while i < ua.size():
		var a: String = ua[i]
		if a.begins_with("--at="):
			var p := a.substr(5).split(",")
			if p.size() == 2:
				_debug_center = Vector2(float(p[0]), float(p[1]))
		elif a == "--fresh":
			_debug_fresh = true
		elif a.begins_with("--shot="):
			_debug_shot = a.substr(7)
		elif a.begins_with("--shotdelay="):
			_debug_shot_delay = float(a.substr(12))
		elif a.begins_with("--mapzoom="):
			_debug_mapzoom = float(a.substr(10))
		elif a.begins_with("--yaw="):
			_debug_yaw = float(a.substr(6))
		elif a.begins_with("--air="):
			_debug_air = float(a.substr(6))
		elif a.begins_with("--hour="):
			_debug_hour = float(a.substr(7))
		elif a.begins_with("--demtest="):
			_debug_demtest = a.substr(10).split(",")
		i += 1


func _build_ui() -> void:
	ui_layer = CanvasLayer.new()
	ui_layer.layer = 10
	add_child(ui_layer)

	# 主菜单
	menu_box = Control.new()
	menu_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui_layer.add_child(menu_box)

	# 背景：上深下浅的绢色渐变 + 四角压暗
	var grad := Gradient.new()
	grad.offsets = PackedFloat32Array([0.0, 0.55, 1.0])
	grad.colors = PackedColorArray([Color(0.07, 0.06, 0.05), Color(0.12, 0.10, 0.075), Color(0.20, 0.17, 0.12)])
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0.0, 0.0)
	gt.fill_to = Vector2(0.0, 1.0)
	gt.width = 8
	gt.height = 256
	var bg := TextureRect.new()
	bg.texture = gt
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_box.add_child(bg)

	var band := ColorRect.new()
	band.color = Color(0.30, 0.24, 0.15, 0.55)
	band.position = Vector2(118, 168)
	band.size = Vector2(3, 168)
	menu_box.add_child(band)

	var title := Label.new()
	title.text = "秦 末  ·  二〇九 B C"
	title.add_theme_font_size_override("font_size", 58)
	title.add_theme_color_override("font_color", Color(0.90, 0.82, 0.62))
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.65))
	title.add_theme_constant_override("shadow_offset_x", 3)
	title.add_theme_constant_override("shadow_offset_y", 3)
	title.position = Vector2(140, 160)
	menu_box.add_child(title)

	var sub := Label.new()
	sub.text = "长寿之人　·　关中咸阳，渭水之北"
	sub.add_theme_font_size_override("font_size", 20)
	sub.add_theme_color_override("font_color", Color(0.66, 0.58, 0.42))
	sub.position = Vector2(146, 246)
	menu_box.add_child(sub)

	var btn := Button.new()
	btn.text = "开 始 游 戏"
	btn.add_theme_font_size_override("font_size", 26)
	btn.add_theme_color_override("font_color", Color(0.92, 0.86, 0.70))
	btn.add_theme_color_override("font_hover_color", Color(1.0, 0.95, 0.80))
	btn.add_theme_color_override("font_pressed_color", Color(1.0, 0.95, 0.80))
	btn.position = Vector2(146, 320)
	btn.size = Vector2(240, 56)
	_style_button(btn)
	btn.pressed.connect(_start_game)
	menu_box.add_child(btn)

	var hint := Label.new()
	hint.text = "WASD 行走　·　左键挥砍　·　右键格挡　·　TAB 轮盘　·　M 地图"
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(0.55, 0.50, 0.40))
	hint.position = Vector2(146, 398)
	menu_box.add_child(hint)

	var ver := Label.new()
	ver.text = "地形数据：Terrarium 2.4km 全球 · 太行 300m 近场　｜　Godot 4.7"
	ver.add_theme_font_size_override("font_size", 13)
	ver.add_theme_color_override("font_color", Color(0.42, 0.38, 0.30))
	ver.position = Vector2(24, 24)
	menu_box.add_child(ver)

	# 小地图（右上）
	# 方位条（上古卷轴式罗盘）
	compass = Control.new()
	compass.set_anchors_preset(Control.PRESET_CENTER_TOP)
	compass.position = Vector2(-260, 6)
	compass.size = Vector2(520, 44)
	compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(compass)
	compass.draw.connect(_draw_compass)
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.18, 0.82, 1.0])
	g.colors = PackedColorArray([
		Color(0.05, 0.04, 0.03, 0.0), Color(0.05, 0.04, 0.03, 0.72),
		Color(0.05, 0.04, 0.03, 0.72), Color(0.05, 0.04, 0.03, 0.0)])
	_compass_tex = GradientTexture2D.new()
	_compass_tex.gradient = g
	_compass_tex.width = 256
	_compass_tex.height = 2
	_compass_tex.fill_from = Vector2(0, 0)
	_compass_tex.fill_to = Vector2(1, 0)
	compass.visible = false

	hud_minimap = Control.new()
	hud_minimap.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	hud_minimap.position = Vector2(-200, 16)
	hud_minimap.size = Vector2(180, 180)
	ui_layer.add_child(hud_minimap)
	hud_minimap.draw.connect(_draw_minimap)
	hud_minimap.visible = false

	# 世界时间 + 位置（左上）
	clock_label = Label.new()
	clock_label.add_theme_font_size_override("font_size", 26)
	clock_label.add_theme_color_override("font_color", Color(0.92, 0.84, 0.64))
	clock_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	clock_label.add_theme_constant_override("shadow_offset_x", 2)
	clock_label.add_theme_constant_override("shadow_offset_y", 2)
	clock_label.position = Vector2(24, 16)
	ui_layer.add_child(clock_label)

	info_label = Label.new()
	info_label.add_theme_font_size_override("font_size", 16)
	info_label.add_theme_color_override("font_color", Color(0.78, 0.74, 0.60))
	info_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	info_label.add_theme_constant_override("shadow_offset_x", 1)
	info_label.add_theme_constant_override("shadow_offset_y", 1)
	info_label.position = Vector2(26, 52)
	ui_layer.add_child(info_label)

	# 生命条（左下）

	# 来袭方向提示（定向格挡用）

	# 灵魂模式提示
	soul_hint = Label.new()
	soul_hint.set_anchors_preset(Control.PRESET_CENTER_TOP)
	soul_hint.position = Vector2(-260, 84)
	soul_hint.size = Vector2(520, 30)
	soul_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	soul_hint.add_theme_font_size_override("font_size", 18)
	soul_hint.add_theme_color_override("font_color", Color(0.72, 0.86, 0.95))
	soul_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	soul_hint.add_theme_constant_override("shadow_offset_x", 2)
	soul_hint.add_theme_constant_override("shadow_offset_y", 2)
	soul_hint.text = "灵魂模式 · 空格升 / Z 降 / 左键返回身体"
	soul_hint.visible = false
	ui_layer.add_child(soul_hint)

	# 受伤红屏

	# 提示条（旅行耗时等）
	toast_label = Label.new()
	toast_label.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	toast_label.position = Vector2(-260, -110)
	toast_label.size = Vector2(520, 40)
	toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast_label.add_theme_font_size_override("font_size", 24)
	toast_label.add_theme_color_override("font_color", Color(1.0, 0.92, 0.70))
	toast_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	toast_label.add_theme_constant_override("shadow_offset_x", 2)
	toast_label.add_theme_constant_override("shadow_offset_y", 2)
	toast_label.visible = false
	ui_layer.add_child(toast_label)

	toast_timer = Timer.new()
	toast_timer.one_shot = true
	toast_timer.wait_time = 4.5
	toast_timer.timeout.connect(func() -> void: toast_label.visible = false)
	add_child(toast_timer)

	# TAB 十字
	tab_cross = Control.new()
	tab_cross.set_anchors_preset(Control.PRESET_FULL_RECT)
	tab_cross.visible = false
	ui_layer.add_child(tab_cross)
	tab_cross.draw.connect(_draw_cross)

	var names := ["角色", "任务", "地图", "日志"]
	for nm in names:
		var lb := Label.new()
		lb.text = nm
		lb.add_theme_font_size_override("font_size", 26)
		lb.add_theme_color_override("font_color", Color(0.75, 0.68, 0.52))
		tab_cross.add_child(lb)
		tab_labels.append(lb)

	# 加载遮罩
	loading_box = Control.new()
	loading_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	loading_box.visible = false
	ui_layer.add_child(loading_box)
	var lbg := ColorRect.new()
	lbg.color = Color(0.06, 0.05, 0.04, 0.85)
	lbg.set_anchors_preset(Control.PRESET_FULL_RECT)
	loading_box.add_child(lbg)
	var ltxt := Label.new()
	ltxt.name = "Txt"
	ltxt.text = "正在前往……"
	ltxt.add_theme_font_size_override("font_size", 42)
	ltxt.add_theme_color_override("font_color", Color(0.88, 0.80, 0.60))
	ltxt.set_anchors_preset(Control.PRESET_CENTER)
	ltxt.position = Vector2(-120, -30)
	loading_box.add_child(ltxt)

	# 帐内背景：暗暖色渐变 + 四角压暗，遮住后面的三维世界
	map_backdrop = TextureRect.new()
	map_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_backdrop.stretch_mode = TextureRect.STRETCH_SCALE
	map_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	var bg_grad := Gradient.new()
	bg_grad.offsets = PackedFloat32Array([0.0, 0.5, 1.0])
	bg_grad.colors = PackedColorArray([
		Color(0.22, 0.15, 0.10), Color(0.11, 0.075, 0.05), Color(0.035, 0.028, 0.020)])
	var bg_tex := GradientTexture2D.new()
	bg_tex.gradient = bg_grad
	bg_tex.fill = GradientTexture2D.FILL_RADIAL
	bg_tex.fill_from = Vector2(0.5, 0.42)
	bg_tex.fill_to = Vector2(1.1, 0.42)
	bg_tex.width = 256
	bg_tex.height = 256
	map_backdrop.texture = bg_tex
	map_backdrop.visible = false
	ui_layer.add_child(map_backdrop)

	# 卷轴内容区（裁剪，超出部分不显示）
	map_view = Control.new()
	map_view.clip_contents = true
	map_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(map_view)

	# 大地图：着色器直绘（逐像素读高程），失败再退回烘焙纹理
	map_surface = ColorRect.new()
	map_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_surface.visible = false
	map_view.add_child(map_surface)
	_setup_map_shader()

	# 大地图（标记/经纬网/边框画在这一层，位于 map_surface 之上）
	map_root = Control.new()
	map_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_root.visible = false
	map_root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	ui_layer.add_child(map_root)
	map_root.draw.connect(_draw_map)
	for c in TG.cities():
		var lb := Label.new()
		lb.text = String(c["name"])
		lb.add_theme_font_size_override("font_size", 18)
		lb.add_theme_color_override("font_color", Color(0.30, 0.20, 0.12))
		lb.visible = false
		map_root.add_child(lb)
		lb.visible = false
		city_labels.append(lb)


func _style_button(b: Button) -> void:
	var n := StyleBoxFlat.new()
	n.bg_color = Color(0.17, 0.14, 0.10, 0.94)
	n.border_color = Color(0.52, 0.42, 0.25)
	n.set_border_width_all(2)
	var h := n.duplicate()
	h.bg_color = Color(0.26, 0.21, 0.14, 0.96)
	h.border_color = Color(0.78, 0.64, 0.38)
	var p := n.duplicate()
	p.bg_color = Color(0.32, 0.25, 0.15, 0.98)
	p.border_color = Color(0.90, 0.76, 0.45)
	b.add_theme_stylebox_override("normal", n)
	b.add_theme_stylebox_override("hover", h)
	b.add_theme_stylebox_override("pressed", p)
	b.add_theme_stylebox_override("focus", h)


func _on_build_progress(p: float) -> void:
	_boot_set(0.05 + p * 0.78)


func _start_game() -> void:
	state = St.GAME
	menu_box.visible = false
	hud_minimap.visible = true
	var t0 := Time.get_ticks_msec()

	_show_boot("正在生成地形……")
	_boot_set(0.03)
	await get_tree().process_frame
	await get_tree().process_frame

	terrain = load("res://scripts/terrain.gd").new()
	add_child(terrain)

	var sv := {} if _debug_fresh else _load_game()
	var need_rebuild := false
	if sv.has("lon"):
		terrain.center_lon = float(sv["lon"])
		terrain.center_lat = float(sv["lat"])
		clock_min = float(sv.get("t", CLOCK_START))
		need_rebuild = true
		print("[存档] 已恢复 %.2f, %.2f" % [terrain.center_lon, terrain.center_lat])
	else:
		print("[存档] 新游戏")
	if _debug_center.x != INF:
		terrain.center_lon = _debug_center.x
		terrain.center_lat = _debug_center.y
		need_rebuild = true
		print("[调试] 地形中心 -> %.3f, %.3f" % [terrain.center_lon, terrain.center_lat])
	await terrain.build(_on_build_progress)
	_boot_text("正在布置植被……")
	_boot_set(0.88)
	await get_tree().process_frame
	terrain._build_vegetation()
	_boot_set(0.96)
	await get_tree().process_frame

	player = load("res://scripts/player.gd").new()
	add_child(player)
	player.setup(terrain)
	if sv.has("yaw"):
		player.yaw = float(sv["yaw"])
	if _debug_yaw != INF:
		player.yaw = _debug_yaw
	if _debug_air > 0.0:
		player.global_position.y += _debug_air
		player.set_physics_process(false)   # 调试悬停：不落地
	if _debug_hour >= 0.0:
		clock_min = _debug_hour * 60.0
	if _debug_mapzoom > 0.0:
		map_zoom = _debug_mapzoom
	if OS.get_cmdline_user_args().has("--map"):
		_open_map()
	if OS.get_cmdline_user_args().has("--selftest"):
		_selftest()
	if sv.has("soul"):
		player.soul = bool(sv["soul"])

	# 每 30 秒自动存
	var tmr := Timer.new()
	tmr.wait_time = 30.0
	tmr.autostart = true
	tmr.timeout.connect(_save_game)
	add_child(tmr)

	_update_hud()
	_update_sun()
	_hide_boot()
	# 开局直接接管鼠标，不用再点一下
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	print("[游戏] 开始，用时 %d ms" % (Time.get_ticks_msec() - t0))


# ---------------- 输入 ----------------
func _input(e: InputEvent) -> void:
	if state != St.GAME:
		return

	if e is InputEventKey:
		var k := e as InputEventKey
		if k.keycode == KEY_TAB:
			if k.echo:
				return
			tab_held = k.pressed
			tab_cross.visible = k.pressed
			if player != null:
				player.look_locked = k.pressed
			if k.pressed:
				# 按下时不预选任何方向：不动鼠标松开就什么都不触发
				tab_sel = -1
				_tab_acc = Vector2.ZERO
				_tab_locked = false
				_layout_tab()
			else:
				if tab_sel == 2:
					_open_map()
				elif tab_sel == 0:
					# 策划案 7.5：轮盘上箭头进入灵魂观察模式
					if player != null:
						player.enter_soul()
				elif tab_sel == 1:
					print("[菜单] 右：待实现（任务/势力）")
				elif tab_sel == 3:
					print("[菜单] 左：待实现（日志/说明）")
			tab_cross.queue_redraw()
		elif k.keycode == KEY_ESCAPE and k.pressed:
			# 先释放鼠标；已经释放时再关地图
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				_close_map()

	if tab_held and e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		# 中心死区：累积位移不够就不选；已选方向后要转足够角度才换
		_tab_acc += mm.relative
		var l := _tab_acc.length()
		if l < TAB_DEAD_ZONE:
			if tab_sel != -1:
				tab_sel = -1
				_layout_tab()
				tab_cross.queue_redraw()
		else:
			var d := _dir_of(_tab_acc)
			var changed := false
			if tab_sel == -1:
				tab_sel = d
				_tab_locked = true
				changed = true
			elif tab_sel != d and l > TAB_SWITCH_MIN and _tab_gap(tab_sel, d) > 1:
				tab_sel = d
				changed = true
			if changed:
				_layout_tab()
				tab_cross.queue_redraw()

	if map_open:
		_map_input(e)


## 两个方向之间隔了几个方位（0 同向 / 1 相邻 / 2 相反）
func _tab_gap(a: int, b: int) -> int:
	var d: int = absi(a - b)
	return mini(d, 4 - d)


func _dir_of(d: Vector2) -> int:
	if absf(d.x) > absf(d.y):
		return 1 if d.x > 0 else 3
	return 0 if d.y < 0 else 2


func _open_map() -> void:
	map_open = true
	if compass != null:
		compass.visible = false
	map_root.visible = true
	if map_backdrop != null:
		map_backdrop.visible = true
	pin_drag = false
	if terrain != null:
		map_center = Vector2(terrain.center_lon, terrain.center_lat)
	_clamp_map_center()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	player.map_open = true
	map_root.queue_redraw()


func _close_map() -> void:
	if not map_open:
		return
	map_open = false
	map_root.visible = false
	if map_backdrop != null:
		map_backdrop.visible = false
	if map_surface != null:
		map_surface.visible = false
	pin_drag = false
	dragging = false
	if player != null:
		player.map_open = false
	# 回到游戏就把鼠标锁回去，否则关图后摄像机不跟鼠标
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _map_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			pin_drag = mb.pressed
			if mb.pressed:
				pin_ll = _screen_to_lonlat(mb.position)
				has_pin = true
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			map_zoom = clampf(map_zoom * 1.25, _zoom_min(), 4000.0)
			_clamp_map_center()
			map_root.queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			map_zoom = clampf(map_zoom / 1.25, _zoom_min(), 4000.0)
			_clamp_map_center()
			map_root.queue_redraw()
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if dragging:
			var ppd := (MAP_W * map_zoom) / 360.0
			var ppy := (MAP_H * map_zoom) / 180.0
			map_center.x -= mm.relative.x / ppd
			map_center.y += mm.relative.y / ppy
			# 地图边界最多停在屏幕中心：中心经度不能越出 [-180+半屏, 180-半屏]
			_clamp_map_center()
			map_root.queue_redraw()
		if pin_drag:
			pin_ll = _screen_to_lonlat(mm.position)
			if Input.mouse_mode != Input.MOUSE_MODE_HIDDEN:
				Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
			map_root.queue_redraw()
	elif e is InputEventKey and e.pressed and (e.keycode == KEY_ENTER or e.keycode == KEY_SPACE):
		if has_pin and not pin_drag:
			_travel_ll(pin_ll)


func _travel_ll(ll: Vector2) -> void:
	if _traveling:
		return
	if TG.is_water(ll.x, ll.y):
		toast("那里是海面，无法前往")
		return
	_traveling = true
	_close_map()
	var dist_km := TG.distance_m(terrain.center_lon, terrain.center_lat, ll.x, ll.y) / 1000.0
	var days := maxf(dist_km / MARCH_KM_PER_DAY, 0.5)
	_show_boot("正在前往……行程 %d 公里，约 %s 日" % [int(round(dist_km)), _cn(int(round(days)))])
	_boot_set(0.02)
	await get_tree().process_frame
	await get_tree().process_frame

	# 快速旅行消耗的是游戏时间，不是无代价传送
	clock_min += days * 1440.0
	terrain.center_lon = ll.x
	terrain.center_lat = ll.y
	await terrain.build(_on_build_progress)
	_boot_text("正在布置植被……")
	_boot_set(0.9)
	await get_tree().process_frame
	terrain._build_vegetation()
	player.soul = false
	player.global_position = Vector3(0, terrain.height_xyz(0, 0) + 3.0, 0)
	_update_hud()
	_update_sun()
	toast("行 %d 公里，历时 %s 日" % [int(round(dist_km)), _cn(int(round(days)))])
	print("[旅行] -> %.2f, %.2f（%.0f 公里，%.1f 日）" % [ll.x, ll.y, dist_km, days])

	# 跨区域旅行：旧区域的敌兵不保留
	_mini_pos = Vector2(1e9, 1e9)
	_traveling = false

	_hide_boot()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await get_tree().process_frame


# ---------------- 绘制 ----------------
## 方位条：以正北为 0，顺时针。视野约 ±110°
func _draw_compass() -> void:
	if player == null:
		return
	var w: float = compass.size.x
	var h: float = compass.size.y
	var cx := w * 0.5
	var cy := h * 0.5
	var ppd := 2.4          # 像素 / 度
	var heading := fposmod(-rad_to_deg(player.yaw), 360.0)

	# 底板（两端渐隐）
	compass.draw_texture_rect(_compass_tex, Rect2(0, 4, w, h - 4), false)
	compass.draw_line(Vector2(cx - 210, h - 2), Vector2(cx + 210, h - 2), Color(0.72, 0.62, 0.40, 0.40), 1.0)

	var font: Font = compass.get_theme_default_font()
	var fsz := 13

	# 刻度：每 15° 一根，45° 的写方位名
	for deg in range(0, 360, 15):
		var d := fposmod(float(deg) - heading + 180.0, 360.0) - 180.0
		if absf(d) > 100.0:
			continue
		var x := cx + d * ppd
		var major := deg % 45 == 0
		var col := Color(0.92, 0.84, 0.62, 0.92 if major else 0.45)
		var len := 7.0 if major else 4.0
		compass.draw_line(Vector2(x, h - 4), Vector2(x, h - 4 - len), col, 1.5 if major else 1.0)
		if major:
			var nm: String = ["北", "东北", "东", "东南", "南", "西南", "西", "西北"][deg / 45]
			var ts: Vector2 = font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz)
			compass.draw_string(font, Vector2(x - ts.x * 0.5, h - 14), nm,
					HORIZONTAL_ALIGNMENT_LEFT, -1, fsz, Color(0.95, 0.88, 0.68, 0.95))

	# 中心指示
	compass.draw_colored_polygon(PackedVector2Array([
		Vector2(cx, h - 2), Vector2(cx - 5, h + 5), Vector2(cx + 5, h + 5)]),
		Color(0.96, 0.82, 0.48))
	compass.draw_line(Vector2(cx, 4), Vector2(cx, h - 4), Color(0.96, 0.82, 0.48, 0.35), 1.0)

	# 地标：城市 + 旅行标
	var marks: Array = []
	if terrain != null:
		for c in TG.cities():
			marks.append([Vector2(float(c["lon"]), float(c["lat"])), Color(0.90, 0.72, 0.38), str(c["name"])])

	for m in marks:
		var ll: Vector2 = m[0]
		var dx: float = (ll.x - terrain.center_lon) * 111320.0 * cos(deg_to_rad(terrain.center_lat))
		var dz: float = -(ll.y - terrain.center_lat) * 110540.0
		var brg := fposmod(rad_to_deg(atan2(dx, -dz)), 360.0)
		var d2 := fposmod(brg - heading + 180.0, 360.0) - 180.0
		if absf(d2) > 105.0:
			continue
		var mx := cx + d2 * ppd
		compass.draw_colored_polygon(PackedVector2Array([
			Vector2(mx, 5), Vector2(mx + 4, 10), Vector2(mx, 15), Vector2(mx - 4, 10)]), m[1])


## 左右卷轴（轴杆 + 轴头 + 绢边）
func _draw_scroll_rollers(sr: Rect2) -> void:
	var rod_w := 22.0
	var over := 26.0        # 轴杆上下伸出
	for side in 2:
		var x := sr.position.x - rod_w + (sr.size.x + rod_w * 2.0) * float(side) if side == 1 else sr.position.x - rod_w
		# 轴杆
		var top := sr.position.y - over
		var bot := sr.position.y + sr.size.y + over
		map_root.draw_rect(Rect2(x, top, rod_w, bot - top), Color(0.30, 0.22, 0.14))
		map_root.draw_rect(Rect2(x + 3, top, rod_w - 6, bot - top), Color(0.42, 0.31, 0.19))
		map_root.draw_rect(Rect2(x + 8, top, 4, bot - top), Color(0.52, 0.40, 0.24, 0.7))
		# 轴头
		for yy in [top - 8.0, bot]:
			map_root.draw_rect(Rect2(x - 4, yy, rod_w + 8, 12), Color(0.26, 0.19, 0.12))
			map_root.draw_rect(Rect2(x - 4, yy, rod_w + 8, 12), Color(0.60, 0.47, 0.27), false, 1.5)
	# 绢边（内阴影，让内容像画在卷面上）
	map_root.draw_rect(Rect2(sr.position, Vector2(10, sr.size.y)), Color(0.30, 0.23, 0.14, 0.25))
	map_root.draw_rect(Rect2(Vector2(sr.position.x + sr.size.x - 10, sr.position.y), Vector2(10, sr.size.y)), Color(0.30, 0.23, 0.14, 0.25))


## 聚落层：城市画平面简图，村庄随缩放渐显
func _draw_settlements(sr: Rect2) -> void:
	if terrain == null:
		return
	# 城市：平面简图（城墙 + 十字街 + 街区）
	for ct in TG.cities():
		var lon := float(ct["lon"])
		var lat := float(ct["lat"])
		var p := _lonlat_to_screen_off(Vector2(lon, lat), 0.0)
		if not sr.has_point(p):
			continue
		var sz: float = clampf(6.0 + map_zoom * 2.2, 10.0, 34.0)
		var half := Vector2(sz, sz) * 0.5
		var r := Rect2(p - half, Vector2(sz, sz))
		map_root.draw_rect(r, Color(0.72, 0.62, 0.42, 0.85))
		map_root.draw_rect(r, Color(0.26, 0.18, 0.10), false, maxf(sz * 0.10, 1.5))
		# 十字街
		map_root.draw_line(Vector2(p.x - half.x + 1.5, p.y), Vector2(p.x + half.x - 1.5, p.y), Color(0.30, 0.21, 0.12, 0.85), maxf(sz * 0.06, 1.0))
		map_root.draw_line(Vector2(p.x, p.y - half.y + 1.5), Vector2(p.x, p.y + half.y - 1.5), Color(0.30, 0.21, 0.12, 0.85), maxf(sz * 0.06, 1.0))

	# 村庄：放大后才出现
	var vfade := clampf((map_zoom - 3.2) / 3.0, 0.0, 1.0)
	if vfade <= 0.02:
		return
	var vlist := _villages_for_view(sr)
	for v in vlist:
		var p2 := _lonlat_to_screen_off(v, 0.0)
		if not sr.has_point(p2):
			continue
		var s2: float = clampf(2.0 + map_zoom * 0.35, 2.0, 5.5)
		map_root.draw_rect(Rect2(p2 - Vector2(s2, s2) * 0.5, Vector2(s2, s2)), Color(0.34, 0.24, 0.14, 0.85 * vfade))


## 当前视野内的村庄（确定性生成 + 缓存）
func _villages_for_view(sr: Rect2) -> Array:
	var step := 0.16
	var key := Vector2i(int(floor(map_center.x / step)) * 97 + int(map_zoom * 4.0),
			int(floor(map_center.y / step)) * 97 + int(map_zoom * 4.0))
	if key != _vil_key:
		_vil_key = key
		_vil_cache = []
		var half_lon: float = (sr.size.x * 0.5) / ((MAP_W * map_zoom) / 360.0)
		var half_lat: float = (sr.size.y * 0.5) / ((MAP_H * map_zoom) / 180.0)
		var lon0 := map_center.x - half_lon
		var lon1 := map_center.x + half_lon
		var lat0 := map_center.y - half_lat
		var lat1 := map_center.y + half_lat
		var thr := clampf(0.55 + (lon1 - lon0) / 70.0, 0.62, 0.93)
		var lon := lon0
		var row := 0
		while lon < lon1 and _vil_cache.size() < 400:
			var lat := lat0 + (step * 0.5 if row % 2 == 1 else 0.0)
			while lat < lat1:
				var hv := TG._vnoise(lon * 9.7 + 3.1, lat * 9.7 - 1.7, 4711)
				if hv > thr:
					var jx := (TG._vnoise(lon * 41.0, lat * 41.0, 91) - 0.5) * step * 1.6
					var jy := (TG._vnoise(lon * 37.0, lat * 37.0, 92) - 0.5) * step * 1.6
					var vlon := lon + jx
					var vlat := lat + jy
					var hh := TG.macro_height(vlon, vlat)
					if hh > 3.0 and hh < 2400.0:
						_vil_cache.append(Vector2(vlon, vlat))
				lat += step
			lon += step
			row += 1
	return _vil_cache


func _draw_minimap() -> void:
	var c := Vector2(90.0, 90.0)
	var R := 88.0
	# 漆底
	hud_minimap.draw_circle(c, R + 3.0, Color(0.12, 0.10, 0.07, 0.97))

	if terrain != null:
		var n := 26
		var span := 1200.0
		var cell := span * 2.0 / float(n)
		var ppm := R / span
		var pcx: float = player.global_position.x if player != null else 0.0
		var pcz: float = player.global_position.z if player != null else 0.0
		var lim := span * 0.97
		for gy in n:
			for gx in n:
				var wx := (float(gx) - float(n) * 0.5 + 0.5) * cell
				var wz := (float(gy) - float(n) * 0.5 + 0.5) * cell
				if wx * wx + wz * wz > lim * lim:
					continue
				var ll: Vector2 = terrain.lonlat_of(pcx + wx, pcz + wz)
				var hh: float = TG.dem_at(ll.x, ll.y)
				var lk: int = TG.landform_kind(ll.x, ll.y, hh)
				var col := Color(0.26, 0.33, 0.40) if hh < -8.0 else TG.landform_color(lk)
				var lum := 0.70 + clampf((hh + 300.0) / 4200.0, 0.0, 1.0) * 0.50
				col = Color(col.r * lum, col.g * lum, col.b * lum)
				var p := c + Vector2(wx, wz) * ppm
				var sz: float = maxf(cell * ppm + 0.7, 2.2)
				hud_minimap.draw_rect(Rect2(p - Vector2(sz * 0.5, sz * 0.5), Vector2(sz, sz)), col)

		# 城市
		for ct in TG.cities():
			var cx: float = (float(ct["lon"]) - terrain.center_lon) * 111320.0 * cos(deg_to_rad(terrain.center_lat))
			var cz: float = -(float(ct["lat"]) - terrain.center_lat) * 110540.0
			var lx := (cx - pcx) * ppm
			var lz := (cz - pcz) * ppm
			if Vector2(lx, lz).length() < R - 12.0:
				var cp := c + Vector2(lx, lz)
				hud_minimap.draw_rect(Rect2(cp - Vector2(3.5, 3.5), Vector2(7, 7)), Color(0.30, 0.17, 0.09))
				hud_minimap.draw_rect(Rect2(cp - Vector2(3.5, 3.5), Vector2(7, 7)), Color(0.92, 0.78, 0.44), false, 1.5)

	# 青铜外环（先秦铜镜感）
	hud_minimap.draw_arc(c, R + 2.0, 0.0, TAU, 80, Color(0.40, 0.36, 0.22, 0.95), 4.0)
	hud_minimap.draw_arc(c, R + 0.6, 0.0, TAU, 80, Color(0.78, 0.66, 0.36, 0.85), 1.4)
	hud_minimap.draw_arc(c, R - 2.2, 0.0, TAU, 80, Color(0.16, 0.13, 0.09, 0.95), 1.6)

	# 四方位刻度
	for k in 4:
		var a := TAU * float(k) / 4.0 - PI * 0.5
		var inner := c + Vector2(cos(a), sin(a)) * (R - 5.0)
		var outer := c + Vector2(cos(a), sin(a)) * (R + 4.0)
		hud_minimap.draw_line(inner, outer, Color(0.86, 0.74, 0.42, 0.9), 1.6)

	var afont: Font = ThemeDB.fallback_font
	hud_minimap.draw_string(afont, c + Vector2(-7, -R + 15), "北", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.92, 0.82, 0.54))

	# 玩家：朝北固定的箭头（北朝上，箭头随视角转）
	var yawv: float = float(player.yaw) if player != null else 0.0
	var f := Vector2(-sin(yawv), -cos(yawv))
	var r := Vector2(-f.y, f.x)
	var tip := c + f * 10.0
	var bl := c - f * 5.0 + r * 6.0
	var br := c - f * 5.0 - r * 6.0
	hud_minimap.draw_colored_polygon(PackedVector2Array([tip, bl, br]), Color(0.98, 0.88, 0.50))
	hud_minimap.draw_polyline(PackedVector2Array([tip, bl, br, tip]), Color(0.32, 0.20, 0.09), 1.6)



func _draw_cross() -> void:
	var vs := get_viewport().get_visible_rect().size
	var c := vs * 0.5

	# 背景压暗
	tab_cross.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.0, 0.0, 0.0, 0.35))

	var names := ["角色", "任务", "地图", "日志"]
	var sz := Vector2(150, 96)
	var gap := 12.0
	var centers := [
		c + Vector2(0, -(sz.y * 0.5 + gap)),      # 上
		c + Vector2(sz.x * 0.5 + gap, 0),         # 右
		c + Vector2(0, sz.y * 0.5 + gap),         # 下
		c + Vector2(-(sz.x * 0.5 + gap), 0),      # 左
	]

	for i in 4:
		var r := Rect2(centers[i] - sz * 0.5, sz)
		var on: bool = (i == tab_sel and tab_sel >= 0)
		var base := Color(0.16, 0.14, 0.11, 0.92)
		var edge := Color(0.45, 0.36, 0.22, 0.9)
		var txt := Color(0.72, 0.66, 0.52)
		if on:
			base = Color(0.30, 0.22, 0.12, 0.96)
			edge = Color(0.95, 0.80, 0.42)
			txt = Color(1.0, 0.93, 0.72)
			r = r.grow(6.0)
		tab_cross.draw_rect(r, base)
		tab_cross.draw_rect(r, edge, false, 2.0 if not on else 3.0)

	# 中心圆
	tab_cross.draw_circle(c, 34, Color(0.12, 0.11, 0.09, 0.95))
	tab_cross.draw_arc(c, 34, 0, TAU, 32, Color(0.55, 0.44, 0.26), 2.0)

	# 文字（用 draw_string 需要字体，这里用 ColorRect 无字体 → 改用 hint_text）
	# 没有字体资源时，用简单的方块示意：在选中块内画两条竖线代表文字
	for i in 4:
		var on2: bool = (i == tab_sel and tab_sel >= 0)
		var col := Color(1.0, 0.93, 0.72, 0.9) if on2 else Color(0.7, 0.64, 0.5, 0.7)
		var cc: Vector2 = centers[i]
		for k in 3:
			var w := 46.0 - float(k) * 10.0
			tab_cross.draw_rect(Rect2(cc + Vector2(-w * 0.5, -12.0 + float(k) * 12.0),
					Vector2(w, 3.0)), col)


## 缩放下限：地图至少要占屏幕一半高
## 地图边界最多停在屏幕中心：中心不能越出 [-180+半屏, 180-半屏]
func _clamp_map_center() -> void:
	var vs := get_viewport().get_visible_rect().size
	var ppd := (MAP_W * map_zoom) / 360.0
	var ppy := (MAP_H * map_zoom) / 180.0
	var half_lon := (vs.x * 0.5) / ppd
	var half_lat := (vs.y * 0.5) / ppy
	# A：地图边缘最多拖到屏幕中心（地图最多一半移出屏幕），随缩放自然变化
	map_center.x = clampf(map_center.x, -180.0, 180.0)
	map_center.y = clampf(map_center.y, -90.0, 90.0)


func _zoom_min() -> float:
	var vs := get_viewport().get_visible_rect().size
	return maxf(0.35, (vs.y * 0.5) / float(MAP_H))


func _zoom_text() -> String:
	if map_zoom >= 100.0:
		return str(int(round(map_zoom)))
	return "%.1f" % map_zoom


func _draw_map() -> void:
	var vs := get_viewport().get_visible_rect().size
	if not _map_shader_ok:
		map_root.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.42, 0.38, 0.28))

	# 卷轴区域：左右各留出卷轴和边缘
	var sc_x := 78.0
	var sc_y := 44.0
	var scroll_rect := Rect2(sc_x, sc_y, vs.x - sc_x * 2.0, vs.y - sc_y * 2.0)
	map_view.position = scroll_rect.position
	map_view.size = scroll_rect.size

	var w := MAP_W * map_zoom
	var h := MAP_H * map_zoom
	var ppd := w / 360.0

	# 一张完整地图（不再左右复制）
	var x0 := vs.x * 0.5 + (-180.0 - map_center.x) * ppd
	var y0 := vs.y * 0.5 - (90.0 - map_center.y) * (h / 180.0)
	var rect := Rect2(Vector2(x0, y0), Vector2(w, h))
	if _map_shader_ok:
		map_surface.visible = true
		# 相对裁剪容器定位
		map_surface.position = rect.position - scroll_rect.position
		map_surface.size = rect.size
		_map_mat.set_shader_parameter("shade_alpha",
				clampf((map_zoom - 1.2) / 5.0, 0.0, 1.0) * 0.72)
	else:
		if _world_tex != null:
			map_root.draw_texture_rect(_world_tex, rect, false)
		if _shade_tex != null:
			var a := clampf((map_zoom - 1.2) / 5.0, 0.0, 1.0) * 0.72
			if a > 0.01:
				map_root.draw_texture_rect(_shade_tex, rect, false, Color(0.32, 0.29, 0.24, a))

	# 经纬网（墨线）
	var y_top := vs.y * 0.5 - (90.0 - map_center.y) * (h / 180.0)
	var y_bot := y_top + h
	for lon in range(-180, 181, 30):
		var gx := _lonlat_to_screen_off(Vector2(float(lon), 0.0), 0.0).x
		if gx > 62.0 and gx < vs.x - 62.0:
			map_root.draw_line(Vector2(gx, maxf(y_top, 26.0)), Vector2(gx, minf(y_bot, vs.y - 26.0)),
					Color(0.34, 0.27, 0.17, 0.18), 1.0)
	for lat in range(-60, 61, 30):
		var gy := vs.y * 0.5 - (float(lat) - map_center.y) * (h / 180.0)
		if gy > 26.0 and gy < vs.y - 26.0:
			map_root.draw_line(Vector2(62, gy), Vector2(vs.x - 62, gy),
					Color(0.34, 0.27, 0.17, 0.18), 1.0)

	# 标题与缩放读数
	map_root.draw_string(ThemeDB.fallback_font, Vector2(vs.x * 0.5 - 44, 44), "天下舆图",
			HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(0.86, 0.78, 0.60))
	map_root.draw_string(ThemeDB.fallback_font, Vector2(vs.x - 132, vs.y - 36), "×%s" % _zoom_text(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.72, 0.64, 0.48))

	_draw_scroll_rollers(scroll_rect)
	_draw_settlements(scroll_rect)

	# 玩家位置
	if terrain != null:
		var pp := _lonlat_to_screen_off(Vector2(terrain.center_lon, terrain.center_lat), 0.0)
		if pp.x > -12 and pp.x < vs.x + 12:
			map_root.draw_circle(pp, 5.0, Color(0.85, 0.25, 0.15))
			map_root.draw_arc(pp, 8.0, 0.0, TAU, 20, Color(0.55, 0.12, 0.08), 1.5)

	# 卷轴边框
	map_root.draw_rect(Rect2(0, 0, vs.x, 26), Color(0.34, 0.24, 0.15))
	map_root.draw_rect(Rect2(0, vs.y - 26, vs.x, 26), Color(0.34, 0.24, 0.15))
	map_root.draw_rect(Rect2(61, 26, vs.x - 122, vs.y - 52), Color(0.70, 0.62, 0.45), false, 3.0)

	# 手工城市标记（每份可见副本都画；标签放在最靠近屏幕中心的那份）
	# 旅行标（同样按副本绘制，跨循环边界不丢标记）
	if has_pin:
		var ps := _lonlat_to_screen_off(pin_ll, 0.0)
		if ps.x > -20 and ps.x < vs.x + 20 and ps.y > -20 and ps.y < vs.y + 20:
			map_root.draw_arc(ps, 13, 0, TAU, 24, Color(0.42, 0.22, 0.10), 2.0)
			map_root.draw_circle(ps, 3.0, Color(0.42, 0.22, 0.10))


## 经纬度 -> 屏幕（off 用于三份副本：-360 / 0 / +360）
func _lonlat_to_screen_off(ll: Vector2, off: float) -> Vector2:
	var vs := get_viewport().get_visible_rect().size
	var ppd := (MAP_W * map_zoom) / 360.0
	var ppy := (MAP_H * map_zoom) / 180.0
	return Vector2(vs.x * 0.5 + (ll.x + off - map_center.x) * ppd,
			vs.y * 0.5 - (ll.y - map_center.y) * ppy)


## 经纬度 -> 屏幕（以地图中心为基准）
func _lonlat_to_screen(ll: Vector2) -> Vector2:
	var vs := get_viewport().get_visible_rect().size
	var ppd := (MAP_W * map_zoom) / 360.0
	var ppy := (MAP_H * map_zoom) / 180.0
	return Vector2(vs.x * 0.5 + (ll.x - map_center.x) * ppd,
			vs.y * 0.5 - (ll.y - map_center.y) * ppy)


## 屏幕 -> 经纬度
func _screen_to_lonlat(p: Vector2) -> Vector2:
	var vs := get_viewport().get_visible_rect().size
	var ppd := (MAP_W * map_zoom) / 360.0
	var ppy := (MAP_H * map_zoom) / 180.0
	var lon: float = map_center.x + (p.x - vs.x * 0.5) / ppd
	var lat: float = map_center.y - (p.y - vs.y * 0.5) / ppy
	lon = wrapf(lon + 180.0, 0.0, 360.0) - 180.0
	return Vector2(lon, clampf(lat, -85.0, 85.0))

## 天空 + 太阳 + 雾
func _setup_world() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var psm := ProceduralSkyMaterial.new()
	psm.sky_top_color = Color(0.32, 0.48, 0.72)
	psm.sky_horizon_color = Color(0.78, 0.80, 0.76)
	psm.ground_bottom_color = Color(0.24, 0.22, 0.18)
	psm.ground_horizon_color = Color(0.72, 0.70, 0.62)
	sky.sky_material = psm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.fog_enabled = true
	env.fog_light_color = Color(0.76, 0.80, 0.86)
	env.fog_density = 0.000012
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-42.0, -128.0, 0.0)
	sun.light_energy = 1.35
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 420.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 2.4
	sun.shadow_blur = 1.0
	sun.shadow_opacity = 0.9
	add_child(sun)
	_sun = sun
	print("[世界] 天空 + 太阳已建")


## 世界地图底图 + 地势阴影：从“最终地形”（2.4km 底图 + 山体特征）烘焙
## 不再直接读 dem.bin，保证地图山脊与场景里的是同一座山
func _setup_map_shader() -> void:
	var sh: Shader = load("res://shaders/map.gdshader")
	if sh == null:
		print("[地图] 着色器缺失，退回烘焙纹理")
		return
	var f := FileAccess.open("res://data/dem_map.bin", FileAccess.READ)
	if f == null:
		print("[地图] 缺少 dem_map.bin，退回烘焙纹理")
		return
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var img := Image.create_from_data(8192, 4096, false, Image.FORMAT_R16, bytes)
	if img == null:
		print("[地图] 高程纹理创建失败，退回烘焙纹理")
		return
	var dem_tex := ImageTexture.create_from_image(img)

	var n := FastNoiseLite.new()
	n.frequency = 0.012
	n.fractal_octaves = 3
	var nt := NoiseTexture2D.new()
	nt.width = 256
	nt.height = 256
	nt.seamless = true
	nt.noise = n

	_map_mat = ShaderMaterial.new()
	_map_mat.shader = sh
	_map_mat.set_shader_parameter("dem_tex", dem_tex)
	_map_mat.set_shader_parameter("dem_size", Vector2(8192.0, 4096.0))
	_map_mat.set_shader_parameter("noise_tex", nt)
	_map_mat.set_shader_parameter("shade_gain", 1.0)
	# 地貌配色图：先 512x256 快速出图，再在线程里烘 1024x512 替换
	var bimg := _bake_landform_color(512, 256)
	_map_mat.set_shader_parameter("biome_tex", ImageTexture.create_from_image(bimg))
	_lf_thread = Thread.new()
	_lf_thread.start(func() -> void: _lf_hi = _bake_landform_color(1024, 512))
	map_surface.material = _map_mat
	_map_shader_ok = true
	print("[地图] 着色器直绘就绪（%d MB 高程纹理）" % int(bytes.size() / 1048576))


func _build_world_tex() -> void:
	var t0 := Time.get_ticks_msec()
	var imgs: Array = TG.bake_map(MAP_BOOT_W, MAP_BOOT_H)
	if imgs.is_empty():
		print("[地图] 没有高程数据，跳过烘焙")
		return
	(imgs[0] as Image).generate_mipmaps()
	(imgs[1] as Image).generate_mipmaps()
	_world_tex = ImageTexture.create_from_image(imgs[0])
	_shade_tex = ImageTexture.create_from_image(imgs[1])
	print("[地图] 快速版 %dx%d，用时 %d ms" % [MAP_BOOT_W, MAP_BOOT_H, Time.get_ticks_msec() - t0])
	if _map_shader_ok:
		print("[地图] 着色器直绘，跳过烘焙纹理")
		return
	# 高清版放后台线程烘，烘完替换；测试模式下不烘，保证回归计时稳定
	var args := OS.get_cmdline_user_args()
	if args.has("--bugtest") or args.has("--selftest") or args.has("--combattest") or args.has("--citytest"):
		print("[地图] 测试模式：跳过高清烘焙")
		return
	_map_thread = Thread.new()
	var t_hi := Time.get_ticks_msec()
	_map_thread.start(func() -> void:
		var t1 := Time.get_ticks_msec()
		_map_hi = TG.bake_map(MAP_HI_W, MAP_HI_H)
		print("[地图] 高清烘焙耗时 %d ms" % (Time.get_ticks_msec() - t1)))


## 按地貌类型烘焙配色图（地图用）
func _bake_landform_color(bw: int, bh: int) -> Image:
	var cbuf := PackedByteArray()
	cbuf.resize(bw * bh * 3)
	for by in bh:
		var blat: float = 90.0 - (float(by) + 0.5) / float(bh) * 180.0
		for bx in bw:
			var blon: float = -180.0 + (float(bx) + 0.5) / float(bw) * 360.0
			var bhgt: float = TG.macro_height(blon, blat)
			var c: Color
			if bhgt < -8.0:
				c = Color(0.26, 0.33, 0.40)
			else:
				c = TG.landform_color(TG.landform_kind(blon, blat, bhgt))
			var i3 := (by * bw + bx) * 3
			cbuf[i3] = int(clampf(c.r, 0.0, 1.0) * 255.0)
			cbuf[i3 + 1] = int(clampf(c.g, 0.0, 1.0) * 255.0)
			cbuf[i3 + 2] = int(clampf(c.b, 0.0, 1.0) * 255.0)
	return Image.create_from_data(bw, bh, false, Image.FORMAT_RGB8, cbuf)


func _poll_lf_thread() -> void:
	if _lf_thread == null or _lf_done:
		return
	if _lf_thread.is_alive():
		return
	_lf_thread.wait_to_finish()
	_lf_done = true
	if _lf_hi != null and not _lf_hi.is_empty() and _map_mat != null:
		_map_mat.set_shader_parameter("biome_tex", ImageTexture.create_from_image(_lf_hi))
		if map_open:
			map_root.queue_redraw()
		print("[地图] 高清地貌配色就绪")


func _poll_map_thread() -> void:
	if _map_thread == null or _map_hi_done:
		return
	if _map_thread.is_alive():
		return
	_map_thread.wait_to_finish()
	_map_hi_done = true
	if _map_hi.size() >= 2:
		(_map_hi[0] as Image).generate_mipmaps()
		(_map_hi[1] as Image).generate_mipmaps()
		_world_tex = ImageTexture.create_from_image(_map_hi[0])
		_shade_tex = ImageTexture.create_from_image(_map_hi[1])
		print("[地图] 高清版 %dx%d 就绪" % [MAP_HI_W, MAP_HI_H])
		if map_open:
			map_root.queue_redraw()
	_map_hi = []

## ---------------- 存档 ----------------
const SAVE_PATH := "user://save.json"


func _save_game() -> void:
	if _debug_fresh:
		return
	if not is_inside_tree() or terrain == null or player == null:
		return
	if not player.is_inside_tree():
		return
	var d := {
		"lon": terrain.center_lon,
		"lat": terrain.center_lat,
		"t": clock_min,
		"x": player.global_position.x,
		"y": player.global_position.y,
		"z": player.global_position.z,
		"yaw": player.yaw,
		"soul": player.soul,
	}
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(d))
		f.close()


func _load_game() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var f := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var txt := f.get_as_text()
	f.close()
	var js: Variant = JSON.parse_string(txt)
	return js if js != null else {}


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_save_game()

func _layout_tab() -> void:
	var vs := get_viewport().get_visible_rect().size
	var c := vs * 0.5
	var sz := Vector2(150, 96)
	var gap := 12.0
	var offs := [
		Vector2(0, -(sz.y * 0.5 + gap)),
		Vector2(sz.x * 0.5 + gap, 0),
		Vector2(0, sz.y * 0.5 + gap),
		Vector2(-(sz.x * 0.5 + gap), 0),
	]
	for i in tab_labels.size():
		var lb: Label = tab_labels[i]
		var p: Vector2 = c + offs[i]
		lb.size = Vector2(120, 40)
		lb.position = p - Vector2(60, 20)
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		var on := (i == tab_sel and tab_sel >= 0)
		lb.add_theme_color_override("font_color",
				Color(1.0, 0.93, 0.72) if on else Color(0.70, 0.64, 0.50))
		lb.add_theme_font_size_override("font_size", 30 if on else 24)

## 玩家走远后把网格重新居中到玩家脚下：网格永远在原点，玩家归零，
## 于是最密的一圈、碰撞、植被始终围着玩家（对应“跟随重建”）。
func _maybe_recenter() -> void:
	if _recentering or terrain == null or player == null or player.soul or map_open:
		return
	var px: float = player.global_position.x
	var pz: float = player.global_position.z
	if px * px + pz * pz < RECENTER_R * RECENTER_R:
		return
	_recentering = true
	_do_recenter(px, pz)


func _do_recenter(px: float, pz: float) -> void:
	var t0 := Time.get_ticks_msec()
	_show_boot("正在扩展地形……")
	_boot_set(0.04)
	await get_tree().process_frame
	var clat: float = terrain.center_lat
	terrain.center_lon = wrapf(terrain.center_lon + px / (111320.0 * cos(deg_to_rad(clat))) + 180.0, 0.0, 360.0) - 180.0
	terrain.center_lat = clampf(clat - pz / 110540.0, -85.0, 85.0)
	await terrain.build(_on_build_progress)
	_boot_text("正在布置植被……")
	_boot_set(0.9)
	await get_tree().process_frame
	terrain._build_vegetation()
	# 世界坐标整体平移：其它实体要跟玩家一起挪，否则会悬在半空/埋进地下
	player.global_position = Vector3(0.0, terrain.height_xyz(0, 0) + 3.0, 0.0)
	player.velocity = Vector3.ZERO
	_mini_pos = Vector2(1e9, 1e9)
	_update_hud()
	_hide_boot()
	_recentering = false
	print("[地形] 跟随重建 -> %.3f, %.3f，用时 %d ms"
			% [terrain.center_lon, terrain.center_lat, Time.get_ticks_msec() - t0])


## 掉出地形时救回原点
func _rescue() -> void:
	if player == null or terrain == null:
		return
	var gh: float = terrain.height_xyz(player.global_position.x, player.global_position.z)
	if player.global_position.y < gh - 40.0:
		player.global_position = Vector3(0.0, terrain.height_xyz(0, 0) + 3.0, 0.0)
		print("[救回] 玩家回到地面")


# =====================================================================
#  世界时间
# =====================================================================
const MONTH_NAMES := ["正月", "二月", "三月", "四月", "五月", "六月",
		"七月", "八月", "九月", "十月", "十一月", "十二月"]
const SHICHEN := ["子", "丑", "寅", "卯", "辰", "巳", "午", "未", "申", "酉", "戌", "亥"]
const DIGITS := ["零", "一", "二", "三", "四", "五", "六", "七", "八", "九"]


func _cn(n: int) -> String:
	if n <= 0:
		return "零"
	if n < 10:
		return DIGITS[n]
	if n < 20:
		return "十" + (DIGITS[n % 10] if n % 10 > 0 else "")
	if n < 100:
		if n % 10 == 0:
			return DIGITS[int(n / 10)] + "十"
		return DIGITS[int(n / 10)] + "十" + DIGITS[n % 10]
	return str(n)


func _clock_text() -> String:
	var total := maxf(clock_min, 0.0)
	var day_i := int(total / 1440.0)
	var hour := fmod(total, 1440.0) / 60.0
	var day := day_i % 30 + 1
	var month := (day_i / 30) % 12 + 1
	var year := 209 - int(day_i / 360)
	var shi := int(floor((hour + 1.0) / 2.0)) % 12
	return "公元前 %d 年 %s %s · %s时" % [year, MONTH_NAMES[month - 1], _cn(day), SHICHEN[shi]]


func _process(delta: float) -> void:
	if boot_bar != null:
		_boot_spin += delta * 3.4
		boot_bar.queue_redraw()
	_poll_map_thread()
	_poll_lf_thread()
	if state != St.GAME:
		return
	if compass != null and player != null:
		compass.visible = true
		if absf(player.yaw - _compass_yaw) > 0.0004:
			_compass_yaw = player.yaw
			compass.queue_redraw()
	clock_min += delta * TIME_SCALE
	_clock_acc += delta
	if _clock_acc < 0.25:
		return
	_clock_acc = 0.0
	_update_hud()
	_update_sun()
	if hud_minimap != null and player != null:
		var pp := Vector2(player.global_position.x, player.global_position.z)
		if pp.distance_to(_mini_pos) > 12.0 or absf(player.yaw - _mini_yaw) > 0.08:
			_mini_pos = pp
			_mini_yaw = player.yaw
			hud_minimap.queue_redraw()
	_flash = maxf(_flash - delta * 1.8, 0.0)
	_maybe_recenter()
	_rescue()


func _update_hud() -> void:
	if clock_label == null or terrain == null:
		return
	clock_label.text = _clock_text()
	var clon: float = terrain.center_lon
	var clat: float = terrain.center_lat
	var h: float = TG.macro_height(clon, clat)
	var b: int = TG.biome_at(clon, clat, h)
	var lf: int = TG.landform_kind(clon, clat, h)
	info_label.text = "东经 %.2f°  北纬 %.2f°   海拔 %d 米   %s · %s" % [
			clon, clat, int(round(h)), TG.biome_name(b), TG.LF_NAMES[clampi(lf, 0, TG.LF_COUNT - 1)]]


## 太阳按时辰走：6:00 东升，18:00 西落，夜里只剩一点冷光
func _update_sun() -> void:
	if _sun == null:
		return
	var hour := fmod(maxf(clock_min, 0.0), 1440.0) / 60.0
	var t := clampf((hour - 6.0) / 12.0, 0.0, 1.0)
	var elev := sin(t * PI) * 62.0
	var az := -90.0 + t * 180.0
	_sun.rotation_degrees = Vector3(-maxf(elev, 2.0), az, 0.0)
	var day := clampf(elev / 20.0, 0.0, 1.0)
	_sun.light_energy = lerpf(0.06, 1.35, day)
	_sun.light_color = Color(1.0, 0.96, 0.88).lerp(Color(0.55, 0.62, 0.85), 1.0 - day)
	_sun.shadow_enabled = day > 0.05


func toast(s: String) -> void:
	if toast_label == null:
		return
	toast_label.text = s
	toast_label.visible = true
	toast_timer.start()


# =====================================================================
#  调试 / 验证
# =====================================================================
## 自测：跟随重建
func _selftest() -> void:
	await get_tree().process_frame
	var lon0: float = terrain.center_lon
	var lat0: float = terrain.center_lat
	var h_before: int = _hash_samples(800)
	var expect_lon: float = lon0 + 5000.0 / (111320.0 * cos(deg_to_rad(lat0)))
	player.global_position = Vector3(5000.0, terrain.height_xyz(5000.0, 0.0) + 3.0, 0.0)
	await get_tree().process_frame
	_recentering = true
	await _do_recenter(5000.0, 0.0)
	await get_tree().process_frame
	var ok_zero: bool = Vector2(player.global_position.x, player.global_position.z).length() < 1.0
	var ok_center: bool = absf(terrain.center_lon - expect_lon) < 0.0005
	var ok_collide: bool = terrain._body != null and terrain._body.get_child_count() > 0
	var ground: float = terrain.height_xyz(0.0, 0.0)
	var ok_ground: bool = absf(player.global_position.y - (ground + 3.0)) < 0.5
	var h_after: int = _hash_samples(800)
	var ok_det: bool = h_before == h_after
	print("[自测] 回原点=%s  中心推进=%s  碰撞存在=%s  落到地面=%s"
			% [ok_zero, ok_center, ok_collide, ok_ground])
	print("[自测] 中心 %.4f,%.4f -> %.4f,%.4f（期望 %.4f）"
			% [lon0, lat0, terrain.center_lon, terrain.center_lat, expect_lon])
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
	TG.disable_overlay()
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
		if not TG.load_custom(p):
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
				var h: float = TG.dem_at(lon, lat) if (truth or raw_only) else TG.height_ll(lon, lat, 0.0)
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
				TG.distance_m(peak_ll[vi].x, peak_ll[vi].y, peak_ll[0].x, peak_ll[0].y) / 1000.0])
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
		["北边界 lon113", 113.0, 40.30, 40.70, false],
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
			var h := TG.macro_height(lon, lat)
			var d := h - TG.macro_height_no_ov(lon, lat)
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
				% [pr[0], TG.height_ll(lon, lat, 0.0), TG.overlay_weight(lon, lat)])
	print("==============================")
	get_tree().quit()


## 采样校验和：同一批坐标生成同一批高度 → 同一校验和
func _hash_samples(n: int = 4000) -> int:
	var acc := 0
	for i in n:
		var lon := -170.0 + fmod(float(i) * 7.319, 340.0)
		var lat := -55.0 + fmod(float(i) * 3.717, 110.0)
		var h := TG.height_ll(lon, lat, 0.0)
		acc = ((acc * 31) + int(round(h * 100.0))) & 0x7FFFFFFF
	return acc


## 地图阴影 / 地形高度一致性：地图 39km/像素，只能比“同尺度剖面”
func _map_test() -> void:
	var imgs := TG.bake_map(1024, 512)
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
			var ht: float = TG.macro_height(lon, lat)
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


## 城市保护范围自测
func _city_test() -> void:
	print("======== 城市保护范围 ========")
	var cs := TG.cities()
	print("城市数 %d" % cs.size())
	for c in cs:
		var lon := float(c["lon"])
		var lat := float(c["lat"])
		var h := TG.height_ll(lon, lat, 0.0)
		var w := TG.city_blend(lon, lat).x
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
			var ll := TG.lonlat_of(cos(a) * r, sin(a) * r, lon, lat)
			var hh := TG.height_ll(ll.x, ll.y, 0.0)
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
			var ll := TG.lonlat_of(d, 0.0, lon, lat)
			var hh := TG.height_ll(ll.x, ll.y, 0.0)
			if i > 0:
				worst = maxf(worst, absf(hh - prev))
			prev = hh
		print("    边界 12 km 剖面（50 m 步长）最大相邻落差 %.2f m" % worst)
		# 城墙范围内应无植被（按种子判定逻辑抽样）
		var blocked := 0
		for i in 400:
			var a2 := rng.randf() * TAU
			var r2 := sqrt(rng.randf()) * float(c["radius"]) * 1000.0 * 0.8
			var ll2 := TG.lonlat_of(cos(a2) * r2, sin(a2) * r2, lon, lat)
			if TG.city_blend(ll2.x, ll2.y).x > 0.3:
				blocked += 1
		print("    城内抽样 400 点中权重>0.3：%d（植被在这些点被跳过）" % blocked)
	print("==============================")
	get_tree().quit()


func _spawn_enemy(offset: Vector3) -> Node3D:
	var e: Node3D = load("res://scripts/enemy.gd").new()
	add_child(e)
	var x := offset.x
	var z := offset.z
	e.global_position = Vector3(x, terrain.height_xyz(x, z) + 1.5, z)
	e.setup(terrain, player)
	return e


func _bug_test() -> void:
	await get_tree().create_timer(0.4).timeout
	var ok := true

	# 1) 开图/关图后玩家输入要恢复
	_open_map()
	await get_tree().process_frame
	_close_map()
	await get_tree().process_frame
	var b1: bool = (player.map_open == false and map_open == false)
	ok = ok and b1
	print("[回归] 关图后 player.map_open=%s / map_open=%s → %s"
			% [player.map_open, map_open, "OK" if b1 else "FAIL"])

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
	var sel_up: int = tab_sel
	ev.echo = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	var sel_after_echo: int = tab_sel
	var b1a: bool = (sel_up == 0 and sel_after_echo == 0)
	ok = ok and b1a
	print("[回归] TAB 轮盘：上移选中 %d，重复按键后 %d → %s"
			% [sel_up, sel_after_echo, "OK" if b1a else "FAIL"])
	var evup := InputEventKey.new()
	evup.keycode = KEY_TAB
	evup.pressed = false
	Input.parse_input_event(evup)
	await get_tree().process_frame
	# 松开时选中“上”会进入灵魂模式（策划案 7.5），测试里先退出来
	player.exit_soul()
	await get_tree().physics_frame

	# 1a2) 相机俯仰：鼠标上下要能改变俯仰，且相机高度跟着变
	var p0: float = player.pitch
	var cy0: float = player.cam.global_position.y
	var mmd := InputEventMouseMotion.new()
	mmd.relative = Vector2(0.0, -120.0)
	Input.parse_input_event(mmd)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var p1: float = player.pitch
	var cy1: float = player.cam.global_position.y
	var b1a2: bool = absf(p1 - p0) > 0.01 and absf(cy1 - cy0) > 0.05
	ok = ok and b1a2
	print("[回归] 相机俯仰：pitch %.3f → %.3f，相机高 %.2f → %.2f → %s"
			% [p0, p1, cy0, cy1, "OK" if b1a2 else "FAIL"])

	# 1b) 关图后鼠标回到锁定状态，视角能跟鼠标
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await get_tree().process_frame
	var yaw0: float = player.yaw
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(60.0, 0.0)
	Input.parse_input_event(mm)
	await get_tree().process_frame
	var b1b: bool = absf(player.yaw - yaw0) > 0.01
	ok = ok and b1b
	print("[回归] 关图后转视角：yaw %.4f → %.4f → %s"
			% [yaw0, player.yaw, "OK" if b1b else "FAIL"])

	# 1c) 看地图时不能盲走
	_open_map()
	player.velocity = Vector3(5.0, 0.0, 0.0)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b1c: bool = absf(player.velocity.x) < 0.01 and absf(player.velocity.z) < 0.01
	_close_map()
	await get_tree().process_frame
	ok = ok and b1c
	print("[回归] 开图时人物停住：vx=%.2f → %s" % [player.velocity.x, "OK" if b1c else "FAIL"])

	# 1e) 小地图要跟着玩家走
	player.global_position.x += 60.0
	await get_tree().create_timer(0.6).timeout
	var mp := Vector2(player.global_position.x, player.global_position.z)
	var b1e: bool = _mini_pos.distance_to(mp) < 1.0
	ok = ok and b1e
	print("[回归] 小地图跟随：记录点距玩家 %.1f m → %s" % [_mini_pos.distance_to(mp), "OK" if b1e else "FAIL"])

	# 1d) 旅行到陆地：落点在地面、不穿地
	var l0: float = terrain.center_lon + 0.3
	var a0: float = terrain.center_lat + 0.2
	_travel_ll(Vector2(l0, a0))
	var waited := 0.0
	while _traveling and waited < 25.0:
		await get_tree().create_timer(0.25).timeout
		waited += 0.25
	await get_tree().process_frame
	var gh0: float = terrain.height_xyz(0.0, 0.0)
	var dy0: float = absf(player.global_position.y - gh0)
	var b1d: bool = dy0 < 2.0 and absf(terrain.center_lon - l0) < 0.001
	ok = ok and b1d
	print("[回归] 旅行落点：高差 %.2f m，中心 %.3f → %s" % [dy0, terrain.center_lon, "OK" if b1d else "FAIL"])

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
	var lon0: float = terrain.center_lon
	var lat0: float = terrain.center_lat
	_travel_ll(Vector2(-150.0, 0.0))
	await get_tree().create_timer(0.5).timeout
	var b3: bool = absf(terrain.center_lon - lon0) < 0.001 and absf(terrain.center_lat - lat0) < 0.001
	ok = ok and b3
	print("[回归] 海上旅行拦截：中心 %.4f,%.4f（未变=%s）→ %s"
			% [terrain.center_lon, terrain.center_lat, b3, "OK" if b3 else "FAIL"])

	# 5) 灵魂模式（TAB 上箭头）
	var cam0: Vector3 = player.cam.global_position
	player.enter_soul()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var b5: bool = player.soul and player.soul_pos.distance_to(cam0) < 1.0
	player.exit_soul()
	await get_tree().physics_frame
	var b5b: bool = not player.soul
	ok = ok and b5 and b5b
	print("[回归] 灵魂模式：脱离相机=%s 退出=%s → %s" % [b5, b5b, "OK" if b5 and b5b else "FAIL"])

	print("[回归] 结果：%s" % ("全部通过" if ok else "有失败项"))
	get_tree().quit()


func _show_boot(text: String) -> void:
	if boot_layer != null:
		boot_label.text = text
		return
	boot_layer = CanvasLayer.new()
	boot_layer.layer = 200
	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.048, 0.040)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	boot_layer.add_child(bg)

	boot_label = Label.new()
	boot_label.text = text
	boot_label.add_theme_font_size_override("font_size", 24)
	boot_label.add_theme_color_override("font_color", Color(0.88, 0.80, 0.62))
	boot_label.set_anchors_preset(Control.PRESET_CENTER)
	boot_label.position = Vector2(-220, 40)
	boot_label.size = Vector2(440, 40)
	boot_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boot_layer.add_child(boot_label)

	boot_bar = Control.new()
	boot_bar.set_anchors_preset(Control.PRESET_CENTER)
	boot_bar.position = Vector2(-220, -40)
	boot_bar.size = Vector2(440, 60)
	boot_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	boot_layer.add_child(boot_bar)
	boot_bar.draw.connect(_draw_boot)

	# 标题
	var ttl := Label.new()
	ttl.text = "长 寿 之 人"
	ttl.add_theme_font_size_override("font_size", 40)
	ttl.add_theme_color_override("font_color", Color(0.90, 0.82, 0.62))
	ttl.set_anchors_preset(Control.PRESET_CENTER)
	ttl.position = Vector2(-200, -170)
	ttl.size = Vector2(400, 56)
	ttl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	boot_layer.add_child(ttl)
	add_child(boot_layer)


func _draw_boot() -> void:
	if boot_bar == null:
		return
	var w := 380.0
	var x := (440.0 - w) * 0.5
	var y := 34.0
	# 进度条
	boot_bar.draw_rect(Rect2(x, y, w, 8.0), Color(0.16, 0.13, 0.09, 0.95))
	boot_bar.draw_rect(Rect2(x + 1, y + 1, (w - 2) * clampf(_boot_progress, 0.0, 1.0), 6.0),
			Color(0.78, 0.62, 0.32))
	boot_bar.draw_rect(Rect2(x, y, w, 8.0), Color(0.52, 0.42, 0.25, 0.9), false, 1.0)
	# 转圈
	var c := Vector2(220.0, 8.0)
	boot_bar.draw_arc(c, 14.0, _boot_spin, _boot_spin + 2.2, 24, Color(0.85, 0.72, 0.45), 3.0)
	boot_bar.draw_arc(c, 14.0, 0.0, TAU, 32, Color(0.30, 0.24, 0.16), 1.5)


func _boot_text(text: String) -> void:
	if boot_label != null:
		boot_label.text = text


func _boot_set(p: float) -> void:
	_boot_progress = clampf(p, 0.0, 1.0)
	if boot_bar != null:
		boot_bar.queue_redraw()


func _hide_boot() -> void:
	if boot_layer != null:
		boot_layer.queue_free()
		boot_layer = null
		boot_label = null
		boot_bar = null
	_boot_progress = 0.0


func _bug_unused() -> void:
	pass


func _take_shot(path: String, delay: float = 3.0) -> void:
	await get_tree().create_timer(delay).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[截图] %s err=%d" % [path, err])
	get_tree().quit()


## 山体特征层校验：对比“只用底图”和“底图+山体特征”的峰顶/山脚高程
func _probe() -> void:
	print("======== 地形真源校验 ========")
	var names := ["太行山", "五台山", "泰山", "秦岭", "祁连山", "天山", "喜马拉雅山", "阿尔卑斯山", "落基山"]
	print("%-12s %10s %10s %10s %10s" % ["山系", "底图峰顶", "最终峰顶", "山脚", "相对高差"])
	for nm in names:
		var st: Dictionary = TG.feature_stats(nm)
		if st.is_empty():
			continue
		print("%-12s %10.0f %10.0f %10.0f %10.0f" % [
				nm, st["dem_peak"], st["peak"], st["foot"], st["peak"] - st["foot"]])
		print("             峰顶位置 %.2f, %.2f" % [st["lon"], st["lat"]])

	# 同一坐标重复采样必须完全一致（确定性）
	var a := TG.height_ll(113.6, 37.6, 1.0)
	var b := TG.height_ll(113.6, 37.6, 1.0)
	print("确定性：同一坐标两次采样 %.3f / %.3f → %s" % [a, b, "一致" if a == b else "不一致"])

	# 跨 LOD 细节淡出的连续性（太行山脚横切，10 公里内每 250 米一点）
	var worst := 0.0
	var prev := 0.0
	for i in 41:
		var r := float(i) * 250.0
		var h := TG.height_xyz(r, 0.0, 113.72, 36.0, 1.0)
		if i > 0:
			worst = maxf(worst, absf(h - prev))
		prev = h
	print("连续性：10 公里横切最大相邻落差 %.2f 米" % worst)
	print("西向高度剖面（自 113.95,39.00）：")
	for i in 18:
		var r := float(i + 1) * 2000.0
		var ll := TG.lonlat_of(-r, 0.0, 113.95, 39.00)
		print("  r=%3.0f km  lon %.2f  %6.0f m" % [r / 1000.0, ll.x, TG.height_ll(ll.x, ll.y, 0.0)])
	print("==============================")


func _exit_tree() -> void:
	if _lf_thread != null and _lf_thread.is_alive():
		_lf_thread.wait_to_finish()
	if _map_thread != null and _map_thread.is_alive():
		_map_thread.wait_to_finish()
