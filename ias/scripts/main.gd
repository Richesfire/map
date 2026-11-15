extends Node3D
## 主控：主菜单 → 游戏；小地图 + TAB 十字 + 大地图 + 世界时间

const TG := preload("res://scripts/terrain_gen.gd")
const MapDetail := preload("res://scripts/map_detail.gd")

## 世界地图逻辑尺寸（屏幕矩形按它算；纹理可以更高清地拉伸上去）
const LAT_LIMIT := 85.0      # 裁掉极区（等距圆柱在极点会拉伸）
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
var _debug_shots: Array = []
var _preview_args: Array = []
var city_panel: Control
var city_tip: Control
var _panel_city: Dictionary = {}
var _panel_village: Dictionary = {}
var _panel_site: Dictionary = {}
var _debug_citypanel := ""
var _debug_sitepanel := ""
var _debug_mapcenter := Vector2(INF, INF)
var _debug_mapzoom := 0.0
var _debug_yaw := INF
var _debug_air := 0.0
var _debug_air_y := 0.0
var _debug_pitch := 0.0
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
var _hydro_r: Array = []
var _hydro_l: Array = []
var _hydro_loaded := false
var map_hydro: Control
var _riv_list: Array = []
var _lake_list: Array = []
var _hydro_grid: Dictionary = {}
var _settle: Array = []
var _settle_thin: Array = []
var _settle_idx: Dictionary = {}
var _settle_loaded := false
var _settle_water: Array = []
var _city_links: Array = []
var _tm := {}
var _tm_n := 0
var _content_w := 1.0
var _content_h := 1.0
var _vil_cache: Array = []
var _hover: Dictionary = {}
var _pin_probed := false
var map_backdrop: TextureRect
var _map_shader_ok := false
var _map_mat: ShaderMaterial
var _dead := false

var tab_held := false
var tab_sel := -1
var tab_labels: Array = []                # 0上 1右 2下 3左；-1 = 未选
var _tab_acc := Vector2.ZERO
var _tab_locked := false
var map_open := false
var map_center := Vector2(113.72, 36.00)   # 地图中心经纬度
var map_zoom := 1.0
var pin_ll := Vector2(INF, INF)   # 旅行标：经纬度（钉在地图上）
var has_pin := false
var loading_box: Control = null
var dragging := false
var pin_drag := false
var _world_tex: ImageTexture = null
var _shade_tex: ImageTexture = null

# —— 高倍细节层：zoom 大时按真源现烘“可见屏幕+外扩”，分块流式填进来 ——
const DETAIL_ZOOM := 60.0     # 到这个倍率才启用（编号图一格约 5.5 px 以上）
const DETAIL_SCALE := 2.0     # 细档：2 屏幕像素 / texel（90 倍以上用，基本不糊）
const DETAIL_SCALE_CO := 2.0  # 粗档也用 2 屏幕像素 / texel
const DETAIL_KEEP := 4        # 缓存几个窗口（拖回去直接命中）
const DETAIL_MARGIN := 8.0    # 边缘多烘几像素，避免采样到边界
var _detail: MapDetail = null       # 正在烘/最近烘好的窗口
var _detail_shown := false
var _detail_off := false
var _detail_dbg := 0
var _pan_test := Vector2.ZERO       # --pan=dx,dy：开图 5 秒后平移这么多像素（测流式）
var _zoom_test := 0.0               # --zoomto=Z：开图 5 秒后切到这个倍率
var _pan_acc := 0.0
var _vel_px := Vector2.ZERO
var _prev_center := Vector2(1e9, 1e9)
var _prof_t := 0.0
var _bb_d = null
var _bb_t0 := 0
var _prof_max := 0.0


func _ready() -> void:
	_parse_args()
	if OS.get_cmdline_user_args().has("--bakebench"):
		_bb_d = MapDetail.new()
		_bb_d.setup(100.0, 27.0, 106.0, 23.0, 920, 570)
		_bb_t0 = Time.get_ticks_msec()
		return
	if OS.get_cmdline_user_args().has("--citytest"):
		_city_test()
		return
	if OS.get_cmdline_user_args().has("--maptest"):
		_map_test()
		return
	if OS.get_cmdline_user_args().has("--sitestats"):
		_site_stats()
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
	if not _preview_args.is_empty():
		_preview_tile(float(_preview_args[0]), float(_preview_args[1]), float(_preview_args[2]),
				int(_preview_args[3]), String(_preview_args[4]))
		return
	if uargs.has("--start") or uargs.has("--bugtest"):
		_boot_text("正在生成地形……")
		await get_tree().process_frame
		await get_tree().process_frame
		await _start_game()
		print("[启动] 世界就绪 %d ms" % Time.get_ticks_msec())
		if uargs.has("--bugtest"):
			_bug_test()
		elif _debug_shot != "":
			_take_shot(_debug_shot, _debug_shot_delay)
		_run_shots()
		if uargs.has("--mapbench"):
			_map_bench()
	else:
		_hide_boot()
		if _debug_shot != "":
			_take_shot(_debug_shot, _debug_shot_delay)
		_run_shots()

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
		elif a.begins_with("--mapcenter="):
			var mc := a.substr(12).split(",")
			if mc.size() == 2:
				_debug_mapcenter = Vector2(float(mc[0]), float(mc[1]))
		elif a.begins_with("--citypanel="):
			_debug_citypanel = a.substr(12)
		elif a.begins_with("--sitepanel="):
			_debug_sitepanel = a.substr(12)
		elif a.begins_with("--preview="):
			var pp := a.substr(10).split(",")
			if pp.size() == 5:
				_preview_args = [float(pp[0]), float(pp[1]), float(pp[2]), int(pp[3]), pp[4]]
		elif a.begins_with("--shots="):
			for item in a.substr(8).split("|", false):
				var bits := item.split("@")
				if bits.size() == 2:
					_debug_shots.append([bits[0], float(bits[1])])
		elif a.begins_with("--mapzoom="):
			_debug_mapzoom = float(a.substr(10))
		elif a == "--nodetail":
			_detail_off = true
		elif a.begins_with("--dbgdetail="):
			_detail_dbg = int(a.substr(12))
		elif a.begins_with("--yaw="):
			_debug_yaw = float(a.substr(6))
		elif a.begins_with("--air="):
			_debug_air = float(a.substr(6))
		elif a.begins_with("--pitch="):
			_debug_pitch = float(a.substr(8))
		elif a.begins_with("--hour="):
			_debug_hour = float(a.substr(7))
		elif a.begins_with("--demtest="):
			_debug_demtest = a.substr(10).split(",")
		elif a.begins_with("--pan="):
			var pp := a.substr(6).split(",")
			if pp.size() == 2:
				_pan_test = Vector2(float(pp[0]), float(pp[1]))
		elif a.begins_with("--zoomto="):
			_zoom_test = float(a.substr(9))
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
	band.color = Color(0.42, 0.24, 0.15, 0.55)
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
	ver.add_theme_color_override("font_color", Color(0.42, 0.38, 0.42))
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

	# 目的地面板（点城市后弹出）
	city_panel = Control.new()
	city_panel.anchor_left = 0.5
	city_panel.anchor_top = 0.5
	city_panel.anchor_right = 0.5
	city_panel.anchor_bottom = 0.5
	city_panel.offset_left = -150.0
	city_panel.offset_top = -86.0
	city_panel.offset_right = 150.0
	city_panel.offset_bottom = 86.0
	city_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	city_panel.visible = false
	ui_layer.add_child(city_panel)
	var cp_bg := Panel.new()
	cp_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	var cp_st := StyleBoxFlat.new()
	cp_st.bg_color = Color(0.12, 0.10, 0.07, 0.97)
	cp_st.border_color = Color(0.62, 0.50, 0.28)
	cp_st.set_border_width_all(2)
	cp_st.set_corner_radius_all(3)
	cp_bg.add_theme_stylebox_override("panel", cp_st)
	city_panel.add_child(cp_bg)
	var cp_title := Label.new()
	cp_title.name = "Title"
	cp_title.position = Vector2(0, 12)
	cp_title.size = Vector2(300, 34)
	cp_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cp_title.add_theme_font_size_override("font_size", 22)
	cp_title.add_theme_color_override("font_color", Color(0.94, 0.84, 0.58))
	city_panel.add_child(cp_title)
	# 副标题：关城/邑的类别与年代（城市与村庄留空）
	var cp_sub := Label.new()
	cp_sub.name = "Sub"
	cp_sub.position = Vector2(0, 46)
	cp_sub.size = Vector2(300, 16)
	cp_sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cp_sub.clip_text = true
	cp_sub.add_theme_font_size_override("font_size", 12)
	cp_sub.add_theme_color_override("font_color", Color(0.74, 0.66, 0.50))
	city_panel.add_child(cp_sub)
	for i in 2:
		var b := Button.new()
		b.name = "Opt%d" % i
		b.position = Vector2(24, 62 + i * 46)
		b.size = Vector2(252, 38)
		b.add_theme_font_size_override("font_size", 17)
		b.add_theme_color_override("font_color", Color(0.90, 0.82, 0.60))
		var bs := StyleBoxFlat.new()
		bs.bg_color = Color(0.20, 0.16, 0.11, 0.95)
		bs.border_color = Color(0.46, 0.37, 0.22)
		bs.set_border_width_all(1)
		b.add_theme_stylebox_override("normal", bs)
		var bh := bs.duplicate() as StyleBoxFlat
		bh.bg_color = Color(0.42, 0.24, 0.15, 0.98)
		bh.border_color = Color(0.72, 0.58, 0.32)
		b.add_theme_stylebox_override("hover", bh)
		b.add_theme_stylebox_override("pressed", bh)
		city_panel.add_child(b)
	city_panel.get_node("Opt0").pressed.connect(func() -> void: _city_go("street"))
	city_panel.get_node("Opt1").pressed.connect(func() -> void: _city_go("yamen"))
	city_panel.visible = false

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

	# 水系层（裁剪到内容区，单次绘制）
	map_hydro = Control.new()
	map_hydro.clip_contents = true
	map_hydro.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_hydro.draw.connect(_draw_hydro_layer)
	map_hydro.visible = false
	ui_layer.add_child(map_hydro)

	# 卷轴内容区（裁剪，超出部分不显示）
	map_view = Control.new()
	map_view.clip_contents = true
	map_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(map_view)

	# 大地图：着色器直绘（逐像素读高程），失败再退回烘焙纹理
	map_surface = ColorRect.new()
	map_surface.color = Color(0.26, 0.33, 0.40, 1.0)   # 边缘 1px 用海色，避免白线
	map_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_surface.visible = false
	map_view.add_child(map_surface)
	if map_hydro != null:
		ui_layer.move_child(map_hydro, map_view.get_index() + 1)
	_setup_map_shader()

	# 大地图（标记/经纬网/边框画在这一层，位于 map_surface 之上）
	map_root = Control.new()
	map_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	map_root.visible = false
	map_root.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	map_root.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED   # 布纹用平铺贴图画
	ui_layer.add_child(map_root)
	map_root.draw.connect(_draw_map)
	for c in TG.cities():
		var lb := Label.new()
		lb.text = String(c["name"])
		lb.add_theme_font_size_override("font_size", 18)
		lb.add_theme_color_override("font_color", Color(0.42, 0.20, 0.12))
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
	# 加载完再进游戏：地形和植被都就位之后才把玩家放进去。
	# （试过"先粗后细"的渐进加载，能操作时间压到 2.8 s，但进游戏那几秒是半成品画面，
	#   反而更难受 —— 玩家看到的应该是一个完整的世界，宁可等加载条。）
	await terrain.build(_on_build_progress)
	_boot_text("正在布置植被……")
	_boot_set(0.88)
	await get_tree().process_frame
	await terrain._build_vegetation(_on_build_progress)
	_boot_set(0.98)
	await get_tree().process_frame

	player = load("res://scripts/player.gd").new()
	add_child(player)
	player.setup(terrain)
	if sv.has("yaw"):
		player.yaw = float(sv["yaw"])
	if _debug_yaw != INF:
		player.yaw = _debug_yaw
	if _debug_air > 0.0:
		_debug_air_y = player.global_position.y + _debug_air   # 调试悬停目标高度
		# 不能关 physics_process：相机跟随在 _update_cam 里，关了就成了固定机位
		if _debug_pitch > 0.0:
			player.pitch = -deg_to_rad(_debug_pitch)   # 俯视看地形结构（度）
			player.soul_pitch = -deg_to_rad(_debug_pitch)
	if _debug_hour >= 0.0:
		clock_min = _debug_hour * 60.0
	if _debug_mapzoom > 0.0:
		map_zoom = _debug_mapzoom
	if OS.get_cmdline_user_args().has("--map"):
		_open_map()
	if _debug_mapcenter.x != INF:
		map_center = _debug_mapcenter
		_clamp_map_center()
	if OS.get_cmdline_user_args().has("--hitcenter"):
		# 调试：直接打开离地图中心最近的聚落面板
		var best: Dictionary = {}
		var bd := 9.0
		for v in _settlements_in(map_center.x - 3.0, map_center.y - 3.0,
				map_center.x + 3.0, map_center.y + 3.0, 4):
			var d: float = (v["ll"] as Vector2).distance_to(map_center)
			if d < bd:
				bd = d
				best = v
		if not best.is_empty():
			_open_village_panel({"ll": best["ll"], "name": best["name"], "kind": "village"})
	if _debug_citypanel != "":
		var idx := int(_debug_citypanel)
		var cs := TG.cities()
		if idx >= 0 and idx < cs.size():
			_open_city_panel(cs[idx])
	if _debug_sitepanel != "":
		var si := int(_debug_sitepanel)
		var ss := TG.sites()
		if si >= 0 and si < ss.size():
			_open_site_panel({"ll": Vector2(float(ss[si]["lon"]), float(ss[si]["lat"])),
					"site": ss[si]})
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
	if map_hydro != null:
		map_hydro.visible = true
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
	if city_panel != null:
		city_panel.visible = false
	if map_hydro != null:
		map_hydro.visible = false
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
			if mb.pressed:
				var hit := _city_hit(mb.position)
				if not hit.is_empty():
					_open_city_panel(hit)
					return
				# 关城/邑的点位优先于现代聚落（同一处常有 GeoNames 的现代村镇）
				var sh := _site_hit(mb.position)
				if not sh.is_empty():
					_open_site_panel(sh)
					return
				var vh := _village_hit(mb.position)
				if not vh.is_empty():
					_open_village_panel(vh)
					return
				_close_city_panel()
			dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			pin_drag = mb.pressed
			if mb.pressed:
				if not _hover.is_empty():
					_hover = {}
					map_root.queue_redraw()
				pin_ll = _screen_to_lonlat(mb.position)
				has_pin = true
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_zoom_at(map_zoom * 1.25)
			map_root.queue_redraw()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_zoom_at(map_zoom / 1.25)
			map_root.queue_redraw()
	elif e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if not dragging and not pin_drag:
			var hc := _city_hit(mm.position)
			var hv: Dictionary = {}
			if not hc.is_empty():
				hv = {"kind": "city", "ll": Vector2(float(hc["lon"]), float(hc["lat"]))}
			else:
				var sh := _site_hit(mm.position)
				if not sh.is_empty():
					hv = {"kind": "site", "ll": sh["ll"]}
				else:
					var vs_hit := _village_hit(mm.position)
					if not vs_hit.is_empty():
						hv = {"kind": "settle", "ll": vs_hit["ll"]}
			var same: bool = hv.is_empty() == _hover.is_empty()
			if same and not hv.is_empty():
				same = (hv["ll"] as Vector2).is_equal_approx(_hover["ll"])
			if not same:
				_hover = hv
				map_root.queue_redraw()
		if dragging:
			var sc := _map_scale()
			map_center.x -= mm.relative.x / sc.x
			map_center.y += mm.relative.y / sc.y
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
	await terrain._build_vegetation(_on_build_progress)
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


## 左右轴杆：接到布帛两侧
func _draw_scroll_rollers(sr: Rect2) -> void:
	var rod_w: float = clampf(20.0 * map_zoom, 12.0, 120.0)
	var over: float = clampf(10.0 * map_zoom, 6.0, 70.0)
	for side in 2:
		var x: float = sr.position.x - rod_w if side == 0 else sr.position.x + sr.size.x
		var top := sr.position.y - over
		var bot := sr.position.y + sr.size.y + over
		map_root.draw_rect(Rect2(x, top, rod_w, bot - top), Color(0.28, 0.21, 0.13))
		map_root.draw_rect(Rect2(x + 3, top, rod_w - 6, bot - top), Color(0.40, 0.42, 0.18))
		map_root.draw_rect(Rect2(x + 7, top, 3, bot - top), Color(0.52, 0.40, 0.24, 0.7))
		for yy in [top - 7.0, bot]:
			map_root.draw_rect(Rect2(x - 3, yy, rod_w + 6, 11), Color(0.24, 0.18, 0.11))
			map_root.draw_rect(Rect2(x - 3, yy, rod_w + 6, 11), Color(0.58, 0.46, 0.26), false, 1.4)


## 布纹平铺纹理（1 格 = 8px，只画一条线）。以前用 while 循环每 7px 画一条线，
## 高倍时卷轴宽 17 万像素 → 两万五千条线 → 开图首帧 48 ms。
static var _brocade_v: ImageTexture
static var _brocade_h: ImageTexture


func _brocade_tex(vertical: bool) -> ImageTexture:
	if vertical and _brocade_v != null:
		return _brocade_v
	if not vertical and _brocade_h != null:
		return _brocade_h
	var img := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var c := Color(0.54, 0.43, 0.27, 0.42) if vertical else Color(0.70, 0.58, 0.40, 0.22)
	for i in 8:
		if vertical:
			img.set_pixel(0, i, c)
		else:
			img.set_pixel(i, 0, c)
	var t := ImageTexture.create_from_image(img)
	if vertical:
		_brocade_v = t
	else:
		_brocade_h = t
	return t


## 布帛：左右宽、上下窄，四块拼接，不加内框
func _draw_brocade(sr: Rect2, pad_x: float, pad_y: float) -> void:
	var cloth := Color(0.60, 0.49, 0.32)
	map_root.draw_rect(Rect2(sr.position, Vector2(sr.size.x, pad_y)), cloth)
	map_root.draw_rect(Rect2(sr.position + Vector2(0, sr.size.y - pad_y), Vector2(sr.size.x, pad_y)), cloth)
	map_root.draw_rect(Rect2(sr.position + Vector2(0, pad_y), Vector2(pad_x, sr.size.y - pad_y * 2.0)), cloth)
	map_root.draw_rect(Rect2(sr.position + Vector2(sr.size.x - pad_x, pad_y), Vector2(pad_x, sr.size.y - pad_y * 2.0)), cloth)

	# 上下两条布纹（竖线）+ 左右两条布纹（横线）
	map_root.draw_texture_rect(_brocade_tex(true),
			Rect2(sr.position, Vector2(sr.size.x, pad_y)), true)
	map_root.draw_texture_rect(_brocade_tex(true),
			Rect2(sr.position + Vector2(0, sr.size.y - pad_y), Vector2(sr.size.x, pad_y)), true)
	map_root.draw_texture_rect(_brocade_tex(false),
			Rect2(sr.position + Vector2(0, pad_y), Vector2(pad_x, sr.size.y - pad_y * 2.0)), true)
	map_root.draw_texture_rect(_brocade_tex(false),
			Rect2(sr.position + Vector2(sr.size.x - pad_x, pad_y),
					Vector2(pad_x, sr.size.y - pad_y * 2.0)), true)

	map_root.draw_rect(sr, Color(0.22, 0.16, 0.10, 0.9), false, 2.0)


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
		# 真实尺寸换算：咸阳城墙约 3.7km 见方
		var km_per_px: float = 40075.0 * maxf(cos(deg_to_rad(lat)), 0.05) / (_map_scale().x * 360.0)
		var sz: float = clampf(3.7 / km_per_px, 9.0, 260.0)
		var half := Vector2(sz, sz) * 0.5
		var r := Rect2(p - half, Vector2(sz, sz))
		map_root.draw_rect(r, Color(0.72, 0.62, 0.42, 0.85))
		map_root.draw_rect(r, Color(0.26, 0.18, 0.10), false, maxf(sz * 0.10, 1.5))
		if not _hover.is_empty() and String(_hover.get("kind", "")) == "city" \
				and (_hover["ll"] as Vector2).is_equal_approx(Vector2(float(ct["lon"]), float(ct["lat"]))):
			map_root.draw_arc(p, sz * 0.85, 0.0, TAU, 24, Color(0.98, 0.84, 0.44, 0.95), 2.0)
		# 城门（够大才画；不写"南/东/北/西"，地图上不落文字）
		if sz >= 40.0:
			for g in _city_gates(ct):
				var gp := _lonlat_to_screen_off(g["ll"], 0.0)
				var gpix: float = clampf(sz * 0.09, 2.0, 5.0)
				map_root.draw_rect(Rect2(gp - Vector2(gpix, gpix) * 0.5, Vector2(gpix, gpix) * 1.6),
						Color(0.52, 0.34, 0.18))
		# 十字街
		map_root.draw_line(Vector2(p.x - half.x + 1.5, p.y), Vector2(p.x + half.x - 1.5, p.y), Color(0.42, 0.21, 0.12, 0.85), maxf(sz * 0.06, 1.0))
		map_root.draw_line(Vector2(p.x, p.y - half.y + 1.5), Vector2(p.x, p.y + half.y - 1.5), Color(0.42, 0.21, 0.12, 0.85), maxf(sz * 0.06, 1.0))

	# 村庄：放大后才出现
	var vfade := clampf((map_zoom - 15.0) / 3.0, 0.0, 1.0)
	if vfade <= 0.02:
		return
	var vlist := _villages_for_view(sr)
	for v in vlist:
		var p2 := _lonlat_to_screen_off(v["ll"], 0.0)
		if not sr.has_point(p2):
			continue
		var lvl := int(v["lvl"])
		var s2: float = [0.0, 5.0, 4.4, 4.0, 3.0][clampi(lvl, 1, 4)]
		s2 *= clampf(0.8 + map_zoom * 0.02, 0.8, 1.4)
		var hov: bool = not _hover.is_empty() and String(_hover.get("kind", "")) == "settle" \
				and (_hover["ll"] as Vector2).is_equal_approx(v["ll"] as Vector2)
		if hov:
			map_root.draw_circle(p2, s2 + 3.5, Color(0.96, 0.82, 0.42, 0.95 * vfade))
		var ink := Color(0.30, 0.20, 0.11, 0.92 * vfade)
		var gold := Color(0.78, 0.64, 0.38, 0.85 * vfade)
		if lvl <= 2:
			map_root.draw_arc(p2, s2, 0.0, TAU, 16, ink, 1.6)
			map_root.draw_circle(p2, maxf(s2 * 0.36, 1.2), ink)
		elif lvl == 3:
			var half := Vector2(s2 * 0.60, s2 * 0.60)
			map_root.draw_rect(Rect2(p2 - half, half * 2.0), ink)
		else:
			map_root.draw_circle(p2, maxf(s2 * 0.5, 1.0), ink)


## 秦汉关城 / 邑 / 要地（data/sites_han.json，史书点名的第三层点位）
## 地图上**不落文字**，只画朱砂色 + 米色描边的舆图符号（底图村庄是褐色小方块/圆环，
## 不带描边的话分不出来）；名字和年代走点击面板，悬停只用高亮表示"这个是可点的"。
func _draw_sites(cr: Rect2) -> void:
	var list := TG.sites()
	if list.is_empty():
		return
	var fade := clampf((map_zoom - 2.0) / 4.0, 0.0, 1.0)
	if fade <= 0.01:
		return
	var sz := clampf(3.0 + map_zoom * 0.05, 3.0, 7.5)
	for s in list:
		var ll := Vector2(float(s["lon"]), float(s["lat"]))
		var p := _lonlat_to_screen_off(ll, 0.0)
		if not cr.grow(12.0).has_point(p):
			continue
		var hov: bool = not _hover.is_empty() and String(_hover.get("kind", "")) == "site" \
				and (_hover["ll"] as Vector2).is_equal_approx(ll)
		if hov:
			# 悬停：金盘 + 一圈亮边，符号本身也放大一点（盘别太大，免得盖住旁边那一丛点位）
			map_root.draw_circle(p, sz + 4.5, Color(0.96, 0.82, 0.42, 0.85 * fade))
			map_root.draw_arc(p, sz + 6.5, 0.0, TAU, 20, Color(0.99, 0.90, 0.55, 0.90 * fade), 1.4)
			_site_marker(p, String(s.get("kind", "要地")), sz * 1.2, fade)
		else:
			_site_marker(p, String(s.get("kind", "要地")), sz, fade)


## 关 / 城 / 邑 / 要地的舆图符号（画在屏幕坐标 p 上，s 为半径像素）
## 朱砂底 + 米色描边：底图上的村庄是褐色小方块/圆环，只靠颜色深浅分不开。
func _site_marker(p: Vector2, kind: String, s: float, a: float) -> void:
	var ink := Color(0.44, 0.15, 0.11, 0.95 * a)
	var cream := Color(0.93, 0.89, 0.76, 0.80 * a)
	match kind:
		"城":
			var r2 := Rect2(p - Vector2(s, s), Vector2(s, s) * 2.0)
			map_root.draw_rect(Rect2(r2.position - Vector2(1.2, 1.2), r2.size + Vector2(2.4, 2.4)),
					cream, false, 2.4)
			map_root.draw_rect(r2, ink)
		"关":
			# 关门：两根立柱 + 门楣 + 一道横挡
			var w := s * 0.85
			var hh := s * 1.05
			var seg := [
				[Vector2(-w, hh), Vector2(-w, -hh)], [Vector2(w, hh), Vector2(w, -hh)],
				[Vector2(-w, -hh), Vector2(w, -hh)],
				[Vector2(-w * 0.45, -hh * 0.35), Vector2(w * 0.45, -hh * 0.35)],
			]
			for g in seg:
				map_root.draw_line(p + (g[0] as Vector2), p + (g[1] as Vector2), cream, 3.4)
			for g in seg:
				map_root.draw_line(p + (g[0] as Vector2), p + (g[1] as Vector2), ink, 1.7)
		"邑":
			map_root.draw_arc(p, s, 0.0, TAU, 16, cream, 3.6)
			map_root.draw_arc(p, s, 0.0, TAU, 16, ink, 1.6)
			map_root.draw_circle(p, maxf(s * 0.30, 0.8), ink)
		_:
			# 要地：实心三角（先用放大的米色三角描边）
			var big := PackedVector2Array([
				p + Vector2(0.0, -s * 1.1), p + Vector2(s, s * 0.85), p + Vector2(-s, s * 0.85)])
			var under := PackedVector2Array([
				p + Vector2(0.0, -s * 1.45), p + Vector2(s * 1.35, s * 1.15),
				p + Vector2(-s * 1.35, s * 1.15)])
			map_root.draw_colored_polygon(under, cream)
			map_root.draw_colored_polygon(big, ink)


## 点选关城/邑/要地
func _site_hit(pos: Vector2) -> Dictionary:
	if map_zoom < 2.0:
		return {}
	for s in TG.sites():
		var ll := Vector2(float(s["lon"]), float(s["lat"]))
		var p := _lonlat_to_screen_off(ll, 0.0)
		if p.distance_to(pos) < 12.0:
			return {"ll": ll, "site": s}
	return {}


## 当前视野内的村庄（确定性生成 + 缓存）
## 加载真实聚落（GeoNames 中国，县城及以上 + 人口>3000 的镇）
func _ensure_settlements() -> void:
	if _settle_loaded:
		return
	_settle_loaded = true
	var f := FileAccess.open("res://data/settlements.json", FileAccess.READ)
	if f == null:
		return
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d == null:
		return
	var thin_cells: Dictionary = {}
	# 海陆校验要用掩膜/底图高程，先确保真源已加载（不然 is_water 恒为 false）
	TG.ensure_loaded()
	var dropped_water := 0
	for p in d.get("places", []):
		var lon := float(p["lon"])
		var lat := float(p["lat"])
		# 落在城池范围内的聚落：沿径向推到城外，不删除
		for c in TG.cities():
			var clon := float(c["lon"])
			var clat := float(c["lat"])
			var dx: float = (lon - clon) * maxf(cos(deg_to_rad(lat)), 0.05)
			var dy: float = lat - clat
			var dist: float = Vector2(dx, dy).length()
			var lim: float = (float(c["radius"]) + 1.5) / 111.0
			if dist < lim:
				var ang := atan2(dy, dx)
				if dist < 1e-6:
					ang = 0.0
				var push: float = lim * 1.15
				lon = clon + (cos(ang) * push) / maxf(cos(deg_to_rad(clat)), 0.05)
				lat = clat + sin(ang) * push
		# 海陆校验：GeoNames 里有落在海面的点（离岸/坐标误差），推到城外之后也要复查
		if _on_water(lon, lat):
			dropped_water += 1
			if _settle_water.size() < 200:
				_settle_water.append({"ll": Vector2(lon, lat), "name": String(p["n"]),
						"h": TG.dem_at(lon, lat)})
			continue
		var item := {"ll": Vector2(lon, lat), "name": String(p["n"]),
				"lvl": int(p["l"]), "pop": int(p["p"])}
		_settle.append(item)
		# 静态抽稀（0.20°，与视野无关）：保证同一倍率下拖动点位不变
		var cell := Vector2i(int(floor(lon / 0.20)), int(floor(lat / 0.20)))
		var keep := true
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				if thin_cells.has(Vector2i(cell.x + dx, cell.y + dy)):
					keep = false
					break
			if not keep:
				break
		if not keep:
			continue
		thin_cells[cell] = true
		_settle_thin.append(item)
		var key := Vector2i(int(floor(lon / 0.5)), int(floor(lat / 0.5)))
		if not _settle_idx.has(key):
			_settle_idx[key] = []
		(_settle_idx[key] as Array).append(item)
	print("[地图] 真实聚落 %d 处（抽稀 %d，海陆校验剔除 %d）"
			% [_settle.size(), _settle_thin.size(), dropped_water])


## 海陆校验：两份数据互相印证，单看任一份都会误杀。
##   · 高程 < -20 m：深水，掩膜再粗也够判了；
##   · 高程 < 0.5 m 且掩膜判水：浅海/河口（掩膜是 4096，约 10 km 一格，
##     会把崇明、长山这种小岛整格判成水，所以必须让高程同意）。
## 珠三角这种低洼地高程会到 -5 m 上下，但掩膜是陆地，按这条规则不会被误删。
func _on_water(lon: float, lat: float) -> bool:
	var h := TG.dem_at(lon, lat)
	if h < -20.0:
		return true
	return h < 0.5 and TG.is_water(lon, lat)


## 视野内的真实聚落（按分数级别过滤）
func _settlements_in(lon0: float, lat0: float, lon1: float, lat1: float, max_lvl: int) -> Array:
	_ensure_settlements()
	var out: Array = []
	var gx0 := int(floor(lon0 / 0.5))
	var gx1 := int(floor(lon1 / 0.5))
	var gy0 := int(floor(lat0 / 0.5))
	var gy1 := int(floor(lat1 / 0.5))
	for gy in range(gy0, gy1 + 1):
		for gx in range(gx0, gx1 + 1):
			var key := Vector2i(gx, gy)
			if not _settle_idx.has(key):
				continue
			for it in _settle_idx[key]:
				var ll: Vector2 = it["ll"]
				if ll.x < lon0 or ll.x > lon1 or ll.y < lat0 or ll.y > lat1:
					continue
				if int(it["lvl"]) > max_lvl:
					continue
				out.append(it)
	out.sort_custom(func(a, b) -> bool: return int(a["lvl"]) < int(b["lvl"]))
	return out


## 村庄：真实聚落数据，按缩放分级显示
func _villages_for_view(sr: Rect2) -> Array:
	if map_zoom < 15.0:
		return []
	var vs3 := get_viewport().get_visible_rect().size
	var sc3 := _map_scale()
	var half_lon: float = (vs3.x * 0.5) / sc3.x
	var half_lat: float = (vs3.y * 0.5) / sc3.y
	var key := Vector2i(int(floor(map_center.x / 0.2)) * 131 + int(map_zoom * 2.0),
			int(floor(map_center.y / 0.2)))
	if key == _vil_key:
		return _vil_cache
	_vil_key = key
	_vil_cache = _settlements_in(map_center.x - half_lon, map_center.y - half_lat,
			map_center.x + half_lon, map_center.y + half_lat, 4)
	return _vil_cache


## 单点评估：返回 {ll, name, kind} 或空
func _village_try(lon: float, lat: float, hv: float) -> Dictionary:
	var h := TG.dem_at(lon, lat)
	if h <= 3.0 or h > 2400.0:
		return {}
	var lf := TG.landform_kind(lon, lat, h)
	# 地貌基础分（荒漠/冰川/陡山几乎不落村）
	var sc := 0.0
	match lf:
		TG.LF_PLAIN, TG.LF_VALLEY, TG.LF_DELTA, TG.LF_COAST:
			sc += 2.5
		TG.LF_STEPPE, TG.LF_HILL, TG.LF_BASIN, TG.LF_HILL_RED, TG.LF_HILL_LOESS, TG.LF_HILL_DANXIA:
			sc += 1.6
		TG.LF_FOREST, TG.LF_WETLAND:
			sc += 0.9
		TG.LF_MOUNTAIN, TG.LF_KARST, TG.LF_MTN_GRANITE, TG.LF_MTN_KARST, TG.LF_MTN_VOLCANIC, TG.LF_MTN_LOESS:
			sc -= 0.6
		TG.LF_DESERT, TG.LF_DESERT_SAND, TG.LF_YARDANG, TG.LF_DESERT_SALT, TG.LF_DESERT_GOBI, TG.LF_DUNE:
			sc -= 2.5
		TG.LF_ICE, TG.LF_GLACIAL, TG.LF_MTN_ICE:
			sc -= 4.0
	# 近水
	var w := _water_near(lon, lat)
	if w < 0.04:
		sc += 3.2
	elif w < 0.15:
		sc += 1.6
	elif w > 0.5:
		sc -= 1.2
	# 坡度（4 邻域差分，度）
	var d := 0.02
	var dx := (TG.dem_at(lon + d, lat) - TG.dem_at(lon - d, lat)) / (2.0 * d * 111320.0)
	var dy := (TG.dem_at(lon, lat + d) - TG.dem_at(lon, lat - d)) / (2.0 * d * 110540.0)
	var slope := rad_to_deg(atan(sqrt(dx * dx + dy * dy)))
	if slope < 8.0:
		sc += 1.0
	elif slope > 15.0:
		sc -= 2.0
	# 城市距离
	var cd := 9.0
	for c in TG.cities():
		var ddx: float = (float(c["lon"]) - lon) * cos(deg_to_rad(lat))
		var ddy: float = float(c["lat"]) - lat
		cd = minf(cd, sqrt(ddx * ddx + ddy * ddy))
	if cd < 0.3:
		sc += 2.0
	elif cd < 1.0:
		sc += 1.0
	# 随机扰动 + 密度门限（hv 决定“这格有没有人”）
	var need := 3.4 - (hv - 0.5) * 2.0
	if sc < need:
		return {}
	# 最小间距 0.42°
	for v2 in _vil_cache:
		var p2: Vector2 = v2["ll"]
		var ex: float = (p2.x - lon) * maxf(cos(deg_to_rad(lat)), 0.05)
		if absf(ex) > 0.42 or absf(p2.y - lat) > 0.42:
			continue
		if Vector2(ex, p2.y - lat).length() < 0.42:
			return {}

	var kind := "plain"
	if w < 0.15:
		kind = "water"
	elif lf in [TG.LF_MOUNTAIN, TG.LF_KARST, TG.LF_MTN_GRANITE, TG.LF_MTN_KARST, TG.LF_MTN_VOLCANIC, TG.LF_MTN_LOESS]:
		kind = "mount"
	var nm := _village_name_for(lon, lat, kind, cd)
	return {"ll": Vector2(lon, lat), "name": nm, "kind": kind}


## 按地景取名：近水用 津/泽/陂，山地用 岭/峪/原，平原用 里/亭/乡
func _village_name_for(lon: float, lat: float, kind: String, city_d: float) -> String:
	var xings := ["王", "李", "张", "赵", "刘", "陈", "杨", "周", "吴", "徐", "孙", "马", "朱", "郭", "何", "高"]
	var h1: float = TG._vnoise(lon * 13.0, lat * 13.0, 3311)
	var h2: float = TG._vnoise(lon * 29.0, lat * 29.0, 7717)
	var xing: String = xings[int(h1 * 15.999)]
	if kind == "water":
		var wl: Array = ["津", "泽", "陂", "渡", "浦"]
		return xing + wl[int(h2 * 4.999)]
	if kind == "mount":
		var ml: Array = ["岭", "峪", "原", "坡"]
		return xing + ml[int(h2 * 3.999)]
	if city_d < 0.5:
		return xing + "亭"
	return xing + ("里" if h2 < 0.55 else "乡")


## 江河湖泊：加载时预处理，绘制时按可见范围逐条画
func _draw_hydro_layer() -> void:
	if OS.get_cmdline_user_args().has("--nohydro"):
		return
	_ensure_hydro()
	var fade := clampf((map_zoom - 1.0) / 1.6, 0.0, 1.0)
	if fade <= 0.01:
		return
	var vs := get_viewport().get_visible_rect().size
	var pr := _proj()
	var ppd: float = pr[0]
	var ppy: float = pr[1]
	var tf := Transform2D(Vector2(ppd, 0.0), Vector2(0.0, -ppy),
			Vector2(vs.x * 0.5 - float(pr[2]) * ppd - map_hydro.position.x,
					vs.y * 0.5 + float(pr[3]) * ppy - map_hydro.position.y))
	map_hydro.draw_set_transform_matrix(tf)
	var lon0: float = float(pr[2]) - (vs.x * 0.5 + 40.0) / ppd
	var lon1: float = float(pr[2]) + (vs.x * 0.5 + 40.0) / ppd
	var lat0: float = float(pr[3]) - (vs.y * 0.5 + 40.0) / ppy
	var lat1: float = float(pr[3]) + (vs.y * 0.5 + 40.0) / ppy
	for r in _riv_list:
		var bb: Rect2 = r["bb"]
		if bb.end.x < lon0 or bb.position.x > lon1 or bb.end.y < lat0 or bb.position.y > lat1:
			continue
		var major: bool = int(r["r"]) <= 3
		var col := Color(0.26, 0.34, 0.40, (0.62 if major else 0.42) * fade)
		map_hydro.draw_polyline(r["p"], col, (3.0 if major else 1.6) / ppd)
	var lake_col := Color(0.42, 0.38, 0.42, 0.9 * fade)
	for l in _lake_list:
		var bb2: Rect2 = l["bb"]
		if bb2.end.x < lon0 or bb2.position.x > lon1 or bb2.end.y < lat0 or bb2.position.y > lat1:
			continue
		map_hydro.draw_polyline(l["p"], lake_col, 2.0 / ppd)
	map_hydro.draw_set_transform_matrix(Transform2D.IDENTITY)


## 加载水系并建 0.5° 空间网格（供村庄近水判定）
func _ensure_hydro() -> void:
	if _hydro_loaded:
		return
	_hydro_loaded = true
	var f := FileAccess.open("res://data/hydro.json", FileAccess.READ)
	if f == null:
		return
	var d: Variant = JSON.parse_string(f.get_as_text())
	if d == null:
		return
	for r in d.get("rivers", []):
		var pts: Array = r["p"]
		var pa := PackedVector2Array()
		var mn := Vector2(999, 999)
		var mx := Vector2(-999, -999)
		for p in pts:
			var v := Vector2(float(p[0]), float(p[1]))
			pa.append(v)
			mn.x = minf(mn.x, v.x)
			mn.y = minf(mn.y, v.y)
			mx.x = maxf(mx.x, v.x)
			mx.y = maxf(mx.y, v.y)
		if pa.size() >= 2:
			_riv_list.append({"bb": Rect2(mn, mx - mn), "p": pa, "r": int(r["r"])})
	for l in d.get("lakes", []):
		var lp := PackedVector2Array()
		var mn2 := Vector2(999, 999)
		var mx2 := Vector2(-999, -999)
		for p in l["p"]:
			var v2 := Vector2(float(p[0]), float(p[1]))
			lp.append(v2)
			mn2.x = minf(mn2.x, v2.x)
			mn2.y = minf(mn2.y, v2.y)
			mx2.x = maxf(mx2.x, v2.x)
			mx2.y = maxf(mx2.y, v2.y)
		if lp.size() >= 3:
			lp.append(lp[0])
			_lake_list.append({"bb": Rect2(mn2, mx2 - mn2), "p": lp})
	# 河点网格（抽样每 3 个点一个）
	for r in _riv_list:
		var pa2: PackedVector2Array = r["p"]
		var i := 0
		while i < pa2.size():
			var p2: Vector2 = pa2[i]
			var key := Vector2i(int(floor(p2.x / 0.5)), int(floor(p2.y / 0.5)))
			if not _hydro_grid.has(key):
				_hydro_grid[key] = PackedVector2Array()
			var arr: PackedVector2Array = _hydro_grid[key]
			arr.append(p2)
			_hydro_grid[key] = arr
			i += 3
	print("[地图] 水系 %d 条，湖泊 %d" % [_riv_list.size(), _lake_list.size()])


## 到最近河/湖的近似距离（度）
func _water_near(lon: float, lat: float) -> float:
	var cx := int(floor(lon / 0.5))
	var cy := int(floor(lat / 0.5))
	var best := 9.0
	for gy in range(cy - 1, cy + 2):
		for gx in range(cx - 1, cx + 2):
			var key := Vector2i(gx, gy)
			if not _hydro_grid.has(key):
				continue
			for p in _hydro_grid[key]:
				var dx: float = (float(p.x) - lon) * maxf(cos(deg_to_rad(lat)), 0.05)
				var dy: float = float(p.y) - lat
				var dd: float = sqrt(dx * dx + dy * dy)
				if dd < best:
					best = dd
	return best


func _line_bbox(pts: Array) -> Rect2:
	var mn := Vector2(999, 999)
	var mx := Vector2(-999, -999)
	for p in pts:
		mn.x = minf(mn.x, float(p[0]))
		mn.y = minf(mn.y, float(p[1]))
		mx.x = maxf(mx.x, float(p[0]))
		mx.y = maxf(mx.y, float(p[1]))
	return Rect2(mn, mx - mn)


## 城门位置：城墙四边中点（经纬度）
func _city_gates(c: Dictionary) -> Array:
	var lon := float(c["lon"])
	var lat := float(c["lat"])
	var r_km := float(c["radius"])
	var dlat := r_km / 110.54
	var dlon := r_km / (111.32 * maxf(cos(deg_to_rad(lat)), 0.05))
	return [
		{"name": "北门", "ll": Vector2(lon, lat + dlat)},
		{"name": "东门", "ll": Vector2(lon + dlon, lat)},
		{"name": "南门", "ll": Vector2(lon, lat - dlat)},
		{"name": "西门", "ll": Vector2(lon - dlon, lat)},
	]


## 点选村庄
func _village_hit(pos: Vector2) -> Dictionary:
	if map_zoom < 12.0:
		return {}
	for v in _villages_for_view(Rect2(Vector2.ZERO, get_viewport().get_visible_rect().size)):
		var p := _lonlat_to_screen_off(v["ll"], 0.0)
		if p.distance_to(pos) < 14.0:
			return {"ll": v["ll"], "name": String(v["name"]), "kind": String(v.get("kind", "village"))}
	return {}


## 点选城市：命中图标范围
func _city_hit(pos: Vector2) -> Dictionary:
	for c in TG.cities():
		var lat := float(c["lat"])
		var km_per_px: float = 40075.0 * maxf(cos(deg_to_rad(lat)), 0.05) / (_map_scale().x * 360.0)
		var sz: float = clampf(3.7 / km_per_px, 9.0, 260.0)
		var p := _lonlat_to_screen_off(Vector2(float(c["lon"]), lat), 0.0)
		if p.distance_to(pos) < maxf(sz * 0.75, 12.0):
			return c
	return {}


## 命中测试：鼠标附近是否有城门（只在高倍下）
func _gate_hit(pos: Vector2) -> Dictionary:
	for c in TG.cities():
		var p := _lonlat_to_screen_off(Vector2(float(c["lon"]), float(c["lat"])), 0.0)
		var km_per_px: float = 40075.0 * maxf(cos(deg_to_rad(float(c["lat"]))), 0.05) / (_map_scale().x * 360.0)
		var sz: float = clampf(3.7 / km_per_px, 9.0, 260.0)
		if sz < 40.0:
			continue
		for g in _city_gates(c):
			var gp := _lonlat_to_screen_off(g["ll"], 0.0)
			if gp.distance_to(pos) < maxf(10.0, sz * 0.16):
				return {"ll": g["ll"], "label": "%s·%s" % [String(c["name"]), String(g["name"])]}
	return {}


## 官道：村庄连到最近城池（微弯，赭色）
func _draw_roads(cr: Rect2) -> void:
	if terrain == null:
		return
	var fade := clampf((map_zoom - 1.4) / 1.6, 0.0, 1.0)
	if fade <= 0.02:
		return
	var cities := TG.cities()
	if cities.is_empty():
		return
	var col := Color(0.42, 0.27, 0.14, 0.55 * fade)
	# 城际官道：每座城连最近的 2 座（链接表只算一次）
	if _city_links.is_empty():
		var seen: Dictionary = {}
		for i in cities.size():
			var a := Vector2(float(cities[i]["lon"]), float(cities[i]["lat"]))
			var ds: Array = []
			for j in cities.size():
				if i == j:
					continue
				var b := Vector2(float(cities[j]["lon"]), float(cities[j]["lat"]))
				ds.append([a.distance_to(b), j])
			ds.sort_custom(func(x, y): return x[0] < y[0])
			for k in mini(2, ds.size()):
				var key := Vector2i(mini(i, int(ds[k][1])), maxi(i, int(ds[k][1])))
				if seen.has(key):
					continue
				seen[key] = true
				_city_links.append(key)
	for key in _city_links:
		var i2: int = key.x
		var j2: int = key.y
		var p1 := _lonlat_to_screen_off(Vector2(float(cities[i2]["lon"]), float(cities[i2]["lat"])), 0.0)
		var p2 := _lonlat_to_screen_off(Vector2(float(cities[j2]["lon"]), float(cities[j2]["lat"])), 0.0)
		if not (cr.grow(30.0).has_point(p1) or cr.grow(30.0).has_point(p2)):
			continue
		var dv := p2 - p1
		var midv := (p1 + p2) * 0.5 + Vector2(-dv.y, dv.x).normalized() * (p1.distance_to(p2) * 0.05)
		map_root.draw_polyline(PackedVector2Array([p1, midv, p2]), Color(0.40, 0.25, 0.12, 0.65 * fade), 2.0)

	# 官道：镇→县→州→城，逐级汇聚；跨水不连
	var vlist := _villages_for_view(cr) if map_zoom >= 15.0 else []
	if not vlist.is_empty():
		var all_pts: Array = []
		for v in vlist:
			all_pts.append({"ll": v["ll"], "lvl": int(v["lvl"])})
		for c in cities:
			all_pts.append({"ll": Vector2(float(c["lon"]), float(c["lat"])), "lvl": 0})
		var drawn := 0
		for i in all_pts.size():
			if drawn >= 160:
				break
			var a: Vector2 = all_pts[i]["ll"]
			var al: int = all_pts[i]["lvl"]
			if al == 0:
				continue
			var bi := -1
			var best := 2.0
			for j in all_pts.size():
				if int(all_pts[j]["lvl"]) >= al:
					continue
				var b: Vector2 = all_pts[j]["ll"]
				var dd := Vector2((b.x - a.x) * cos(deg_to_rad(a.y)), b.y - a.y).length()
				if dd < best:
					best = dd
					bi = j
			if bi < 0:
				continue
			var b2: Vector2 = all_pts[bi]["ll"]
			var wet := false
			for k in [0.3, 0.5, 0.7]:
				var mp: Vector2 = a.lerp(b2, k)
				if TG.dem_at(mp.x, mp.y) < -8.0:
					wet = true
					break
			if wet:
				continue
			var pa := _lonlat_to_screen_off(a, 0.0)
			var pb := _lonlat_to_screen_off(b2, 0.0)
			if not (cr.grow(30.0).has_point(pa) or cr.grow(30.0).has_point(pb)):
				continue
			var dvv := pb - pa
			var midv := (pa + pb) * 0.5 + Vector2(-dvv.y, dvv.x).normalized() * (pa.distance_to(pb) * 0.04)
			map_root.draw_polyline(PackedVector2Array([pa, midv, pb]),
					Color(0.40, 0.26, 0.13, 0.5 * fade), 1.3)
			drawn += 1



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
				hud_minimap.draw_rect(Rect2(cp - Vector2(3.5, 3.5), Vector2(7, 7)), Color(0.42, 0.17, 0.09))
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
			base = Color(0.42, 0.22, 0.12, 0.96)
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
## 拖动限制：只有一条 —— 屏幕中心必须落在地图内容区里。
## 换成人话：地图内容区的四条边界，最多只能拉到屏幕正中，再往里就停住。
## 不设"回到中心"、不设倍率阈值，0.7 倍和 120 倍用的是同一条规则。
func _clamp_map_center() -> void:
	map_center.x = clampf(map_center.x, -180.0, 180.0)
	map_center.y = clampf(map_center.y, -LAT_LIMIT, LAT_LIMIT)


func _zoom_min() -> float:
	return 0.7


func _zoom_text() -> String:
	if map_zoom >= 100.0:
		return str(int(round(map_zoom)))
	return "%.1f" % map_zoom


## 以鼠标位置为轴心缩放
func _zoom_at(target_zoom: float) -> void:
	var vs := get_viewport().get_visible_rect().size
	var mp := get_viewport().get_mouse_position()
	# 先记下鼠标下的经纬度（用旧缩放）
	var sc0 := _map_scale()
	var before := Vector2(map_center.x + (mp.x - vs.x * 0.5) / sc0.x,
			map_center.y - (mp.y - vs.y * 0.5) / sc0.y)
	map_zoom = clampf(target_zoom, _zoom_min(), 120.0)
	var sc1 := _map_scale()
	var after := Vector2(map_center.x + (mp.x - vs.x * 0.5) / sc1.x,
			map_center.y - (mp.y - vs.y * 0.5) / sc1.y)
	map_center.x += before.x - after.x
	map_center.y += before.y - after.y
	_clamp_map_center()
	map_root.queue_redraw()



## 扩散范围：屏幕四周各外扩 120 px（超出不扩散）
func _zoom_rect() -> Vector4:
	var vs := get_viewport().get_visible_rect().size
	var sc := _map_scale()
	var hw := vs.x * 0.5 + 120.0
	var hh := vs.y * 0.5 + 120.0
	return Vector4(
			map_center.x - hw / sc.x,
			map_center.y + hh / sc.y,
			map_center.x + hw / sc.x,
			map_center.y - hh / sc.y)

## 细节层覆盖范围：可见屏幕四角换算成经纬度，四周各外扩「一屏」。
## 超出这个范围的既不烘也不扩散。
const DETAIL_OUT_PAD := 1.0

func _detail_view() -> Vector4:
	var vs := get_viewport().get_visible_rect().size
	var sc := _map_scale()
	var hw := vs.x * 0.5 + 120.0
	var hh := vs.y * 0.5 + 120.0
	return Vector4(
			map_center.x + (-hw) / sc.x,
			map_center.y + hh / sc.y,
			map_center.x + hw / sc.x,
			map_center.y - hh / sc.y)


## 屏幕实际可见范围（不含外扩），用来判断“够不够覆盖”
func _detail_core() -> Vector4:
	var vs := get_viewport().get_visible_rect().size
	var sc := _map_scale()
	return Vector4(
			map_center.x + (-DETAIL_MARGIN - vs.x * 0.5) / sc.x,
			map_center.y + (DETAIL_MARGIN + vs.y * 0.5) / sc.y,
			map_center.x + (DETAIL_MARGIN + vs.x * 0.5) / sc.x,
			map_center.y - (DETAIL_MARGIN + vs.y * 0.5) / sc.y)


## ── 高倍细节层：一块“跟着视野走的画布”（新实现，旧的在下面标了 legacy）──
## 状态只有两个：按倍率缓存的画布（最近 4 个）+ 每块画布自己的 reveal_r。
## 不变量：
##   I1 画布永远覆盖当前屏幕：同倍率下不够大就当场长大（旧内容整块搬，不重烘、不淡出）
##   I2 同一倍率的 texel 网格永不改变，只有换倍率才换画布
##   I3 已烘好的 texel 永不丢弃（只在整屏烘完后裁回一屏）
##   I4 reveal_r 只跟“当前屏幕中心 + 已烘前沿”有关，前沿每次现算
## ── 高倍细节层：只有"实时屏幕中心 + 阈值 + 一个半径" ────────────────────
## 规则（就这几条，没有别的分支）：
##   1. zoom < 45：细版整体渐隐，粗版渐显，淡完释放画布
##   2. zoom >= 45：从**实时屏幕中心**开始，R 以 450 px/s 向外扩散
##   3. 拖动：中心每帧现算，烘的优先级跟着变，R 继续推进（不重置）
##   4. 换倍率 / 换地方：一律 R = 0 重新从中心扩散 —— **即使那块地已经烘过**
##      （缓存只用来省烘，绝不影响"看到的永远是扩散"，保证一致性）
##   5. 画布只为一件事长大：覆盖当前屏幕（已烘好的块整块搬过来，不重烘）
const REVEAL_PX_S := 450.0
const CLOUD_CX_PX_S := 1200.0   # 云雾中心追赶屏幕中心的速度（够快，不会露出没烘的地方）
const REVEAL_BAND := 280.0    # >= 2/3 块（384px），把块的硬边吃掉
const REVEAL_TRAIL := 150.0
const DETAIL_FADE_S := 0.18
const DETAIL_KEEP_ZOOM := 3         # 缓存几个倍率的烘焙结果（只省烘）

var _canvas: MapDetail = null       # 当前显示的画布
var _canvases := {}                 # zoom_key -> MapDetail（烘焙缓存）
var _canvas_order: Array = []
var _cur_zk := -1
var _canvas_zoom := 0.0
var _canvas_ds := 8.0     # 当前画布用的 texel 尺寸（4 或 8）
var _pending_zk := -1               # 防抖：等待停稳的目标倍率
var _zk_settle := 0.0
var _reveal_r := 0.0
var _fade := 0.0                    # 0 = 粗版，1 = 细版
var _cloud_ll := Vector2.ZERO     # 云雾中心（地图经纬度）
var _ring_c := Vector2.ZERO         # 揭开圆心（屏幕像素，带路径预估）
var _detail_vel := Vector2.ZERO     # 屏幕中心的移动速度（像素/秒，平滑后）
var _pred_lon := 0.0
var _pred_lat := 0.0
var _last_center := Vector2(1e9, 1e9)
var _st_dbg := 0.0


func _detail_tick(delta: float) -> void:
	if _map_mat == null or _detail_off:
		return
	if OS.get_cmdline_user_args().has("--dbgstate"):
		_st_dbg += delta
		if _st_dbg > 0.5:
			_st_dbg = 0.0
			print("[状态] fade=%.2f R=%.0f zk=%d canvas=%s tiles=%d/%d zoom=%.1f"
					% [_fade, _reveal_r, _cur_zk, str(_canvas != null),
					-1 if _canvas == null else _canvas.tiles_done,
					-1 if _canvas == null else _canvas.tiles_total, map_zoom])
	# 屏幕中心的移动速度（平滑）+ 往前探的预测中心：
	# 不直接拿每一帧的 map_center 去用，否则扩散会跟着鼠标一跳一跳
	var sc0 := _map_scale()
	if _last_center.x > 1e8:
		_last_center = map_center
		_pred_lon = map_center.x
		_pred_lat = map_center.y
	var dvx := (map_center.x - _last_center.x) * sc0.x / maxf(delta, 0.001)
	var dvy := -(map_center.y - _last_center.y) * sc0.y / maxf(delta, 0.001)
	_detail_vel = _detail_vel.lerp(Vector2(dvx, dvy), clampf(delta * 12.0, 0.0, 1.0))
	_last_center = map_center
	_pred_lon = map_center.x + _detail_vel.x * 0.18 / maxf(sc0.x, 0.0001)
	_pred_lat = map_center.y - _detail_vel.y * 0.18 / maxf(sc0.y, 0.0001)
	# 阈值以下：细版渐隐，粗版渐显
	if not map_open or map_zoom < DETAIL_ZOOM:
		if _fade > 0.0:
			_fade = maxf(0.0, _fade - delta / DETAIL_FADE_S)
			_push_detail_uniforms()
			if _fade <= 0.0:
				_map_mat.set_shader_parameter("detail_on", 0.0)
				_canvas = null
				_cur_zk = -1
				_reveal_r = 0.0
		return
	# 阈值以上：换倍率（或刚跨过阈值）→ 一律 R=0 重新扩散
	# 两套固定数据：45-90 倍用 8px/texel 的粗档，90 倍以上用 4px/texel 的细档。
	# 带内缩放永不重建（只换用另一套），跨 60 才首次建。
	var zk := int(round(map_zoom * 10.0))
	var want_ds := DETAIL_SCALE if map_zoom >= 90.0 else DETAIL_SCALE_CO
	if _canvas == null:
		_canvas_ds = want_ds
		_canvas = _canvas_for(zk)
		_cur_zk = zk
		_canvas_zoom = map_zoom
		_fade = 0.0
		_bind_canvas(_canvas)
	elif want_ds != _canvas_ds:
		# 否则继续显示旧的（最多被拉伸），避免"切过去一片空"的回退
		var cand := _canvas_for(zk)
		if cand.first_ready:
			_canvas_ds = want_ds
			_canvas = cand
			_cur_zk = zk
			_canvas_zoom = map_zoom
			_bind_canvas(_canvas)
	# 画布只长大、不重建：保留所有已烘 texel，只补烘新露出的条带
	# 流式预烘：把要烘的区域按移动方向往前推 0.4 秒位移（最多半屏），
	# 屏幕到达前数据已经烘好，移动时看不到粗版边界。
	var scv := _map_scale()
	if _prev_center.x > 1e8:
		_prev_center = map_center
	var vpx := Vector2((map_center.x - _prev_center.x) * scv.x,
			-(map_center.y - _prev_center.y) * scv.y) / maxf(delta, 0.001)
	_vel_px = _vel_px.lerp(vpx, clampf(delta * 8.0, 0.0, 1.0))
	_prev_center = map_center
	var vsv := get_viewport().get_visible_rect().size
	var ahead := _vel_px * 0.4
	ahead.x = clampf(ahead.x, -vsv.x * 0.5, vsv.x * 0.5)
	ahead.y = clampf(ahead.y, -vsv.y * 0.5, vsv.y * 0.5)
	var base := _detail_view()
	var core := Vector4(base.x + ahead.x / scv.x, base.y - ahead.y / scv.y,
			base.z + ahead.x / scv.x, base.w - ahead.y / scv.y)
	# 只有超出画布 16 texel 以上才长大，避免拖动时每帧重建（重建瞬间会闪粗版）
	var pad16: float = (_canvas.lon_per_texel() * 16.0) if _canvas != null else 0.0
	var core_in := Vector4(core.x + pad16, core.y - pad16, core.z - pad16, core.w + pad16)
	if not _canvas.geom_covers(core_in):
		_grow_canvas(core)
	if not _canvas.done():
		_canvas.reorder_from(map_center.x + ahead.x / scv.x,
				map_center.y - ahead.y / scv.y, core)
		_canvas.poll()
	# 云雾中心存**地图坐标**，只在推 uniform 时换算成屏幕像素：
	# 窗口变了它也不会跳到新中心，而是接着旧位置继续长。
	var sc_c := _map_scale()
	if _reveal_r <= 0.5:
		_cloud_ll = map_center                 # 首次跨过阈值：直接落在屏幕中心
	else:
		var dl := map_center.x - _cloud_ll.x
		var dp := map_center.y - _cloud_ll.y
		var dpix := Vector2(dl * sc_c.x, -dp * sc_c.y)
		var step := CLOUD_CX_PX_S * delta
		if dpix.length() <= maxf(step, 0.001):
			_cloud_ll = map_center
		elif dpix.length() > 0.0001:
			var k2 := step / dpix.length()
			_cloud_ll.x += dl * k2
			_cloud_ll.y += dp * k2
	_pred_lon = _cloud_ll.x
	_pred_lat = _cloud_ll.y
	var vs := get_viewport().get_visible_rect().size
	_ring_c = vs * 0.5 + Vector2((_cloud_ll.x - map_center.x) * sc_c.x,
			-(_cloud_ll.y - map_center.y) * sc_c.y)
	# 不做云雾、不做半径、不做区域限制：烘好一块就整块显示，速度只取决于烘焙吞吐
	_fade = minf(1.0, _fade + delta / DETAIL_FADE_S)
	_push_detail_uniforms()


## 把矩形按倍数向外扩（画布长大时留出余量）
func _expand_rect(r: Vector4, k: float) -> Vector4:
	var cx := (r.x + r.z) * 0.5
	var cy := (r.y + r.w) * 0.5
	var hw := (r.z - r.x) * 0.5 * k
	var hh := (r.y - r.w) * 0.5 * k
	return Vector4(cx - hw, cy + hh, cx + hw, cy - hh)


func _canvas_for(zk: int) -> MapDetail:
	if _canvases.has(zk):
		_canvas_order.erase(zk)
		_canvas_order.push_front(zk)
		return _canvases[zk]
	var vr := _detail_view()
	var sc := _map_scale()
	# texel 数按"区域大小"算（不是按屏幕），保证每个 texel 恒为 DETAIL_SCALE 屏幕像素
	var wpx: float = (vr.z - vr.x) * sc.x
	var hpx: float = (vr.y - vr.w) * sc.y
	var c := MapDetail.new()
	c.setup(vr.x, vr.y, vr.z, vr.w,
			int(ceil(wpx / float(_canvas_ds))),
			int(ceil(hpx / float(_canvas_ds))), _canvas)
	_canvases[zk] = c
	_canvas_order.push_front(zk)
	while _canvas_order.size() > DETAIL_KEEP_ZOOM:
		var old: int = _canvas_order.pop_back()
		if _canvases.has(old) and _canvases[old] != _canvas:
			_canvases.erase(old)
	return c


## 把画布长大到能盖住 core：新画布照抄旧画布已烘好的块（blit，不重烘），R 不变
func _grow_canvas(core: Vector4) -> void:
	var u0 := minf(_canvas.lon0, core.x)
	var u1 := maxf(_canvas.lon1, core.z)
	var v0 := maxf(_canvas.lat0, core.y)      # 北
	var v1 := minf(_canvas.lat1, core.w)      # 南
	# 像素数用画布自己的 dlon 算（不能用当前缩放，否则尺度会被带偏）
	var dlon: float = _canvas.lon_per_texel()
	var pw := int(ceil((u1 - u0) / dlon))
	var ph := int(ceil((v0 - v1) / dlon))
	# 画布长大：R 不动（只增不减），新条带从旧边界接着往外长
	var c := MapDetail.new()
	c.setup(u0, v0, u1, v1, pw, ph, _canvas)
	if not c.geom_covers(core):
		# 继承后没盖住请求区域：退化成精确画布（不继承），避免每帧反复长大
		c = MapDetail.new()
		c.setup(core.x, core.y, core.z, core.w, pw, ph)
	_canvases[_cur_zk] = c
	_canvas = c
	_bind_canvas(c)


func _bind_canvas(c: MapDetail) -> void:
	_map_mat.set_shader_parameter("detail_tex", c.tex)
	_map_mat.set_shader_parameter("detail_org", Vector2(c.ox, c.oy))
	_map_mat.set_shader_parameter("detail_span", Vector2(c.sx, c.sy))
	_map_mat.set_shader_parameter("detail_on", 1.0)
	_detail_shown = true
	_push_detail_uniforms()


func _push_detail_uniforms() -> void:
	_map_mat.set_shader_parameter("detail_reveal", _reveal_r)
	_map_mat.set_shader_parameter("detail_band", REVEAL_BAND)
	_map_mat.set_shader_parameter("detail_fade", _fade)

## 调试：--pan=dx,dy / --zoomto=Z 开图 5 秒后动一次（测流式重烘 / 缩放降级）
func _pan_probe(delta: float) -> void:
	if not map_open:
		return
	if _pan_test == Vector2.ZERO and _zoom_test <= 0.0:
		return
	_pan_acc += delta
	if _pan_acc < 5.0:
		return
	if _zoom_test > 0.0:
		map_zoom = clampf(_zoom_test, _zoom_min(), 120.0)
		_clamp_map_center()
		print("[缩放] 切到 %.2f" % map_zoom)
		_zoom_test = 0.0
	if _pan_test != Vector2.ZERO:
		var sc := _map_scale()
		map_center.x += _pan_test.x / sc.x
		map_center.y -= _pan_test.y / sc.y
		_clamp_map_center()
		print("[平移] 拖了 %.0f,%.0f 像素" % [_pan_test.x, _pan_test.y])
		_pan_test = Vector2.ZERO
	map_root.queue_redraw()


## 临时基准：连续重绘地图，测每帧耗时
## 打开城市目的地面板
func _open_city_panel(c: Dictionary) -> void:
	_panel_city = c
	var title: Label = city_panel.get_node("Title")
	title.text = String(c["name"])
	(city_panel.get_node("Opt0") as Button).text = "街道"
	var b1 := city_panel.get_node("Opt1") as Button
	b1.text = "府衙"
	b1.visible = true
	(city_panel.get_node("Sub") as Label).text = ""
	# 面板必须在地图图层之上
	if ui_layer != null and city_panel.get_parent() == ui_layer:
		ui_layer.move_child(city_panel, ui_layer.get_child_count() - 1)
	city_panel.visible = true
	map_root.queue_redraw()


## 打开村庄面板（只有一个“进村”）
func _open_village_panel(v: Dictionary) -> void:
	_panel_city = {}
	_panel_village = v
	var title: Label = city_panel.get_node("Title")
	title.text = String(v["name"])
	(city_panel.get_node("Opt0") as Button).text = "进村"
	(city_panel.get_node("Opt1") as Button).visible = false
	(city_panel.get_node("Sub") as Label).text = ""
	if ui_layer != null and city_panel.get_parent() == ui_layer:
		ui_layer.move_child(city_panel, ui_layer.get_child_count() - 1)
	city_panel.visible = true
	map_root.queue_redraw()


func _close_city_panel() -> void:
	city_panel.visible = false
	_panel_city = {}
	_panel_village = {}
	_panel_site = {}
	if city_panel != null:
		(city_panel.get_node("Opt1") as Button).visible = true
		(city_panel.get_node("Sub") as Label).text = ""


## 打开关城/邑/要地面板（史料点名的点位，只提供“前往”）
func _open_site_panel(hit: Dictionary) -> void:
	var s: Dictionary = hit["site"]
	_panel_city = {}
	_panel_village = {}
	_panel_site = s
	var title: Label = city_panel.get_node("Title")
	title.text = String(s.get("name", ""))
	var era := int(s.get("era", 0))
	var era_txt := ("前%d年" % -era) if era < 0 else ("%d 年" % era)
	var sub: Label = city_panel.get_node("Sub")
	sub.text = "%s · %s" % [String(s.get("kind", "要地")), era_txt]
	(city_panel.get_node("Opt0") as Button).text = "前往"
	(city_panel.get_node("Opt1") as Button).visible = false
	if ui_layer != null and city_panel.get_parent() == ui_layer:
		ui_layer.move_child(city_panel, ui_layer.get_child_count() - 1)
	city_panel.visible = true
	map_root.queue_redraw()


## 街道 = 城中心；府衙 = 城北偏内
func _city_go(what: String) -> void:
	if not _panel_site.is_empty():
		var sll := Vector2(float(_panel_site["lon"]), float(_panel_site["lat"]))
		var sn := String(_panel_site["name"])
		_close_city_panel()
		toast("前往 %s" % sn)
		_travel_ll(sll)
		return
	if not _panel_village.is_empty():
		var vll: Vector2 = _panel_village["ll"]
		var vn := String(_panel_village["name"])
		_close_city_panel()
		toast("前往 %s" % vn)
		_travel_ll(vll)
		return
	if _panel_city.is_empty():
		return
	var lon := float(_panel_city["lon"])
	var lat := float(_panel_city["lat"])
	var r := float(_panel_city["radius"])
	if what == "yamen":
		lat += (r * 0.35) / 110.54
	var nm := String(_panel_city["name"])
	_close_city_panel()
	toast("前往 %s · %s" % [nm, "府衙" if what == "yamen" else "街道"])
	_travel_ll(Vector2(lon, lat))


func _map_bench() -> void:
	await get_tree().process_frame
	var t0 := Time.get_ticks_usec()
	for i in 60:
		map_root.queue_redraw()
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
			hs[y * px + x] = TG.height_ll(px_lon, py, 0.0)
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
			var lk: int = TG.landform_kind(px_lon, py, h)
			var c: Color
			if h < -8.0:
				c = Color(0.20, 0.28, 0.36)
			else:
				c = TG.landform_color(lk)
			var light: float = 0.62 + sh * 0.62
			img.set_pixel(x, y, Color(c.r * light, c.g * light, c.b * light))
	var err := img.save_png(out_path)
	print("[预览] %s err=%d 用时 %d ms" % [out_path, err, Time.get_ticks_msec() - t0])
	get_tree().quit()


func _draw_map() -> void:
	var vs := get_viewport().get_visible_rect().size
	if not _map_shader_ok:
		map_root.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.42, 0.38, 0.28))

	# 卷轴版式：内容居中，布帛左右宽、上下窄
	# 整张卷轴按 map_zoom 一起缩放，内容恒为 2:1
	var base := _sheet_base(vs)
	var content_w: float = base.x * 0.76 * map_zoom
	var content_h: float = content_w * (LAT_LIMIT * 2.0) / 360.0
	var sheet_w: float = content_w / 0.76
	var sheet_h: float = content_h / 0.92
	var pad_x: float = (sheet_w - content_w) * 0.5
	var pad_y: float = (sheet_h - content_h) * 0.5
	# 整张卷轴按世界坐标摆放：平移时布帛/轴杆/地图一起走
	var ppd2: float = content_w / 360.0
	# 内容区画的是 ±LAT_LIMIT（170°），不是 180°：按 180 算会让整幅地形相对水系/城池
	# 上移（1 倍时几像素，120 倍时一千多像素）
	var ppy2: float = content_h / (LAT_LIMIT * 2.0)
	# 可见纬度范围是 ±LAT_LIMIT，所以内容区上边界对应 LAT_LIMIT
	var content_rect := Rect2(
			Vector2(vs.x * 0.5 - (map_center.x + 180.0) * ppd2,
					vs.y * 0.5 - (LAT_LIMIT - map_center.y) * ppy2),
			Vector2(content_w, content_h))
	var scroll_rect := Rect2(content_rect.position - Vector2(pad_x, pad_y), Vector2(sheet_w, sheet_h))
	_content_w = content_w
	_content_h = content_h
	_clamp_map_center()
	if OS.get_cmdline_user_args().has("--mapsize"):
		print("[尺寸] vs=%.0fx%.0f content=%.0fx%.0f at (%.0f,%.0f) sheet=%.0fx%.0f zoom=%.2f"
				% [vs.x, vs.y, content_w, content_h, content_rect.position.x, content_rect.position.y,
					sheet_w, sheet_h, map_zoom])
	# 可见区上下各内缩 1 像素：贴图最边那一行是极地行（冰色），内缩后落在裁剪区外
	map_view.position = content_rect.position + Vector2(0, 1)
	map_view.size = content_rect.size - Vector2(0, 2)
	if map_hydro != null:
		map_hydro.position = content_rect.position
		map_hydro.size = content_rect.size

	var sc := _map_scale()
	var ppd := sc.x
	var w := ppd * 360.0
	var h := sc.y * 180.0
	if OS.get_cmdline_user_args().has("--pintest") and not _pin_probed:
		_pin_probed = true
		var vsz2 := get_viewport().get_visible_rect().size
		var pr := Vector2(vsz2.x * 0.25, vsz2.y * 0.75)
		var llp := _screen_to_lonlat(pr)
		var bk := _lonlat_to_screen_off(llp, 0.0)
		print("[针测] %.0f,%.0f -> %.3f,%.3f -> %.0f,%.0f" % [pr.x, pr.y, llp.x, llp.y, bk.x, bk.y])

	# 一张完整地图（不再左右复制）
	var x0 := vs.x * 0.5 + (-180.0 - map_center.x) * ppd
	var y0 := vs.y * 0.5 - (90.0 - map_center.y) * (h / 180.0)
	var rect := Rect2(Vector2(x0, y0), Vector2(w, h))
	if _map_shader_ok:
		map_surface.visible = true
		# 相对裁剪容器定位
		# 四周各多画 2 像素，把着色器边缘那一行推到裁剪区外，避免出现白线
		map_surface.position = Vector2(-2, -2)
		map_surface.size = content_rect.size + Vector2(4, 4)
		_map_mat.set_shader_parameter("shade_alpha",
				clampf((map_zoom - 1.2) / 9.0, 0.0, 1.0) * 0.50)
		# 符号间距：屏幕上约 12 像素
		_map_mat.set_shader_parameter("pat_period",
				clampf(12.0 * 111.0 / maxf(ppd, 0.01), 0.12, 60.0))
		_map_mat.set_shader_parameter("zoom", map_zoom)
		_map_mat.set_shader_parameter("dbg2", float(_detail_dbg))
	else:
		if _world_tex != null:
			map_root.draw_texture_rect(_world_tex, rect, false)
		if _shade_tex != null:
			var a := clampf((map_zoom - 1.2) / 9.0, 0.0, 1.0) * 0.42
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
	map_root.draw_string(ThemeDB.fallback_font, Vector2(vs.x - 132, vs.y - 36), "×%s" % _zoom_text(),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0.72, 0.64, 0.48))

	var _t0 := Time.get_ticks_usec()
	# 地图上下各压一条 2px 的墨线：遮住贴图边缘那一行（极地行会显示成白色）
	map_root.draw_rect(Rect2(content_rect.position, Vector2(content_rect.size.x, 2)), Color(0.22, 0.16, 0.10))
	map_root.draw_rect(Rect2(content_rect.position + Vector2(0, content_rect.size.y - 2),
			Vector2(content_rect.size.x, 2)), Color(0.22, 0.16, 0.10))
	_draw_scroll_rollers(scroll_rect)
	_draw_brocade(scroll_rect, pad_x, pad_y)
	var _t1 := Time.get_ticks_usec()
	var _t2 := Time.get_ticks_usec()
	var _t3 := Time.get_ticks_usec()
	_draw_settlements(content_rect)
	_draw_sites(content_rect)
	if map_hydro != null:
		map_hydro.queue_redraw()
	var _t4 := Time.get_ticks_usec()
	if OS.get_cmdline_user_args().has("--maptime"):
		_tm["frame"] = float(_t1 - _t0) / 1000.0
		_tm["hydro"] = float(_t2 - _t1) / 1000.0
		_tm["roads"] = float(_t3 - _t2) / 1000.0
		_tm["settle"] = float(_t4 - _t3) / 1000.0
		_tm_n += 1
		if _tm_n % 2 == 0:
			print("[计时] 框 %.1f ms / 水系 %.1f / 官道 %.1f / 聚落 %.1f"
					% [_tm["frame"], _tm["hydro"], _tm["roads"], _tm["settle"]])

	# 玩家位置
	if terrain != null:
		var pp := _lonlat_to_screen_off(Vector2(terrain.center_lon, terrain.center_lat), 0.0)
		if pp.x > -12 and pp.x < vs.x + 12:
			map_root.draw_circle(pp, 5.0, Color(0.85, 0.25, 0.15))
			map_root.draw_arc(pp, 8.0, 0.0, TAU, 20, Color(0.55, 0.12, 0.08), 1.5)




	# 手工城市标记（每份可见副本都画；标签放在最靠近屏幕中心的那份）
	# 旅行标（同样按副本绘制，跨循环边界不丢标记）
	if has_pin:
		var ps := _lonlat_to_screen_off(pin_ll, 0.0)
		if ps.x > -20 and ps.x < vs.x + 20 and ps.y > -20 and ps.y < vs.y + 20:
			map_root.draw_arc(ps, 13, 0, TAU, 24, Color(0.42, 0.22, 0.10), 2.0)
			map_root.draw_circle(ps, 3.0, Color(0.42, 0.22, 0.10))


## 经纬度 -> 屏幕（off 用于三份副本：-360 / 0 / +360）
## 地图缩放基准：内容区宽度 × 缩放倍数（1 倍 = 整幅世界图可见）
## sheet 基准：左右布帛各 12%、上下 4%，地图内容 2:1，整体适配屏幕 92%x86%
func _sheet_base(vs: Vector2) -> Vector2:
	var sheet_w := vs.x * 0.92
	var content_w := sheet_w * 0.76
	var content_h := content_w * 0.5
	var sheet_h := content_h / 0.92
	if sheet_h > vs.y * 0.86:
		var k := (vs.y * 0.86) / sheet_h
		sheet_w *= k
		content_w *= k
		content_h *= k
		sheet_h *= k
	return Vector2(sheet_w, sheet_h)


func _map_scale() -> Vector2:
	var vs := get_viewport().get_visible_rect().size
	var base := _sheet_base(vs)
	var content_w: float = base.x * 0.76 * map_zoom
	var content_h: float = content_w * 0.5
	# 内容区高度画的是 ±LAT_LIMIT（170°）而不是 180°，经纬每度像素数必须按 170 算，
	# 否则水系/城池/旅行标会越往南越偏（以前一直差 6%，高倍才看得出来）
	return Vector2(content_w / 360.0, content_h / (LAT_LIMIT * 2.0))


## 唯一的投影来源：返回 [经度像素, 纬度像素, 中心经度, 中心纬度]
func _proj() -> Array:
	var sc := _map_scale()
	return [sc.x, sc.y, map_center.x, map_center.y]


func _lonlat_to_screen_off(ll: Vector2, off: float) -> Vector2:
	var vs := get_viewport().get_visible_rect().size
	var p := _proj()
	return Vector2(vs.x * 0.5 + (ll.x + off - float(p[2])) * float(p[0]),
			vs.y * 0.5 - (ll.y - float(p[3])) * float(p[1]))


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
	var sc := _map_scale()
	var ppd := sc.x
	var ppy := sc.y
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
	# 优先用半分辨率（16MB），没有就退回 8192（64MB）
	var w := 4096
	var h := 2048
	var f := FileAccess.open("res://data/dem_map_lo.bin", FileAccess.READ)
	if f == null:
		w = 8192
		h = 4096
		f = FileAccess.open("res://data/dem_map.bin", FileAccess.READ)
	if f == null:
		print("[地图] 缺少高程纹理，退回烘焙纹理")
		return
	var bytes := f.get_buffer(f.get_length())
	f.close()
	var img := Image.create_from_data(w, h, false, Image.FORMAT_R16, bytes)
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
	_map_mat.set_shader_parameter("dem_size", Vector2(float(w), float(h)))
	_map_mat.set_shader_parameter("noise_tex", nt)
	# 地貌编号贴图（预烘焙，调用游戏自己的 landform_kind）
	var lf_f := FileAccess.open("res://data/landform_id.bin", FileAccess.READ)
	if lf_f != null:
		var lb := lf_f.get_buffer(lf_f.get_length())
		lf_f.close()
		# 分辨率自适应：R8，宽 = 2 × 高
		var lh := int(sqrt(float(lb.size()) / 2.0))
		var lw := lh * 2
		var lf_img := Image.create_from_data(lw, lh, false, Image.FORMAT_R8, lb)
		_map_mat.set_shader_parameter("landform_tex",
				ImageTexture.create_from_image(lf_img))
		print("[地图] 地貌编号贴图 %d KB" % int(lb.size() / 1024))
	else:
		print("[地图] 缺少 landform_id.bin，配色退回气候带")

	# 地图只有一套调色板：29 类本色（TG.landform_color）。
	# 编号图路径和细节层路径都按同一个地貌号取色，跨 60 倍不会变色。
	var pal := PackedByteArray()
	pal.resize(32 * 3)
	for i in 32:
		var c2: Color = TG.landform_color(i)
		pal[i * 3] = int(clampf(c2.r, 0.0, 1.0) * 255.0)
		pal[i * 3 + 1] = int(clampf(c2.g, 0.0, 1.0) * 255.0)
		pal[i * 3 + 2] = int(clampf(c2.b, 0.0, 1.0) * 255.0)
	_map_mat.set_shader_parameter("palette_tex",
			ImageTexture.create_from_image(
					Image.create_from_data(32, 1, false, Image.FORMAT_RGB8, pal)))
	_map_mat.set_shader_parameter("shade_gain", 1.0)
	_map_mat.set_shader_parameter("lat_limit", LAT_LIMIT)
	# 细节层占位（1×1），就绪前 detail_on=0 走编号图
	var blank := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	blank.fill(Color(0, 0, 0, 1))
	_map_mat.set_shader_parameter("detail_tex", ImageTexture.create_from_image(blank))
	_map_mat.set_shader_parameter("detail_on", 0.0)
	_map_mat.set_shader_parameter("detail_org", Vector2.ZERO)
	_map_mat.set_shader_parameter("detail_span", Vector2.ONE)
	_map_mat.set_shader_parameter("detail_reveal", 0.0)
	_map_mat.set_shader_parameter("detail_band", REVEAL_BAND)
	_map_mat.set_shader_parameter("detail_fade", 1.0)
	map_surface.material = _map_mat
	_map_shader_ok = true
	print("[地图] 着色器直绘就绪（%d MB 高程纹理）" % int(bytes.size() / 1048576))


func _build_world_tex() -> void:
	# 着色器直绘就绪时这张烘焙纹理根本用不到：别再白烘 1.2 秒
	if _map_shader_ok:
		print("[地图] 着色器直绘，跳过烘焙纹理")
		return
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
	await terrain._build_vegetation(_on_build_progress)
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
	if _bb_d != null:
		_bb_d.poll()
		if _bb_d.done() or Time.get_ticks_msec() - _bb_t0 > 120000:
			var ms := Time.get_ticks_msec() - _bb_t0
			print("[bench] bake_ms=", ms,
					"  texel/s=", int(524400.0 * 1000.0 / maxf(float(ms), 1.0)),
					"  tiles=", _bb_d.tiles_done, "/", _bb_d.tiles_total)
			_bb_d = null
			get_tree().quit()
		return
	if OS.get_cmdline_user_args().has("--prof"):
		_prof_t += delta
		_prof_max = maxf(_prof_max, delta)
		if _prof_t >= 0.25:
			print("[prof] %d ms 最长帧 %.1f ms（%.0f fps）" % [Time.get_ticks_msec(),
					_prof_max * 1000.0, 1.0 / maxf(_prof_max, 0.001)])
			_prof_t = 0.0
			_prof_max = 0.0
	if boot_bar != null:
		_boot_spin += delta * 3.4
		boot_bar.queue_redraw()
	_poll_map_thread()
	_detail_tick(delta)
	_pan_probe(delta)
	if _debug_air > 0.0 and player != null:
		player.velocity = Vector3.ZERO
		player.global_position = Vector3(player.global_position.x, _debug_air_y, player.global_position.z)
	if _debug_pitch > 0.0 and player != null:
		player.pitch = -deg_to_rad(_debug_pitch)
		player.soul_pitch = -deg_to_rad(_debug_pitch)
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
	if OS.get_cmdline_user_args().has("--fps"):
		print("[帧率] %.1f fps  绘制调用 %d  三角形 %d" % [Engine.get_frames_per_second(),
				Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)])
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


## 关城点位与聚落海陆校验（headless，几秒出结果，不用开图）
func _site_stats() -> void:
	TG.ensure_loaded()
	print("======== 关城 / 邑 / 要地 ========")
	for s in TG.sites():
		var ll := Vector2(float(s["lon"]), float(s["lat"]))
		var h := TG.dem_at(ll.x, ll.y)
		var lf := TG.landform_kind(ll.x, ll.y, h)
		print("  %-6s %-3s (%.3f,%.3f) 高程 %5.0f m  %-6s  %s"
				% [String(s.get("name", "")), String(s.get("kind", "")), ll.x, ll.y, h,
					TG.LF_NAMES[lf], "落水!" if _on_water(ll.x, ll.y) else "陆地"])
	_ensure_settlements()
	print("======== 聚落海陆校验 ========")
	print("  保留 %d / 剔除 %d（原始 %d）"
			% [_settle.size(), _settle_water.size(), _settle.size() + _settle_water.size()])
	var n := 0
	for w in _settle_water:
		if n >= 15:
			break
		print("  剔除 %-10s (%.3f,%.3f) 高程 %.0f m"
				% [String(w["name"]), (w["ll"] as Vector2).x, (w["ll"] as Vector2).y, float(w["h"])])
		n += 1
	print("===============================")
	# 反向检查：留下来的点里还有多少在高程上是水面（判断规则有没有漏）
	var left_water: Array = []
	for it in _settle_thin:
		var h2 := TG.dem_at((it["ll"] as Vector2).x, (it["ll"] as Vector2).y)
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
	# 旅行落地是“地面 +3 m 掉下来”，等它落到地面再量（最多 1 秒）
	for i in 60:
		if dy0 < 2.0:
			break
		await get_tree().process_frame
		gh0 = terrain.height_xyz(0.0, 0.0)
		dy0 = absf(player.global_position.y - gh0)
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
	boot_bar.draw_arc(c, 14.0, 0.0, TAU, 32, Color(0.42, 0.24, 0.16), 1.5)


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


func _run_shots() -> void:
	var last := -1.0
	for s in _debug_shots:
		last = maxf(last, float(s[1]))
	for s in _debug_shots:
		_take_shot(String(s[0]), float(s[1]), absf(float(s[1]) - last) < 0.01)


func _take_shot(path: String, delay: float = 3.0, do_quit: bool = true) -> void:
	await get_tree().create_timer(delay).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("[截图] %s err=%d" % [path, err])
	if do_quit:
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
	if _map_thread != null and _map_thread.is_alive():
		_map_thread.wait_to_finish()
	if _detail != null:
		_detail.wait()
	if _canvas != null:
		_canvas.wait()
	for k in _canvases:
		(_canvases[k] as MapDetail).wait()
