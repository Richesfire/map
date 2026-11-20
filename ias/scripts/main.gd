extends Node3D
## 主控：主菜单 → 游戏；小地图 + TAB 十字 + 大地图 + 世界时间

const TG := preload("res://scripts/terrain_gen.gd")
const LFDB := preload("res://scripts/landform_db.gd")
const MapDetail := preload("res://scripts/map_detail.gd")
const TestHarness := preload("res://scripts/test_harness.gd")

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
## TAB 轮盘：直接按鼠标移动方向判定（平滑后位移阈值 + 主方向优势比）
const TAB_MOVE_MIN := 8.0
const TAB_DIR_BIAS := 1.45
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
var _debug_up := 0.0          # --up=米：把出生点抬高，调试看水面/地形用
var _debug_fresh := false
var _debug_shot := ""
var _debug_shot_delay := 3.0
var _debug_shots: Array = []
var _preview_args: Array = []
var city_panel: Control
var city_tip: Control
var _panel_city: Dictionary = {}
var _panel_village: Dictionary = {}
var _panel_place: Dictionary = {}
var _debug_citypanel := ""
var _debug_sitepanel := ""
var _debug_countypanel := ""
var _debug_mapcenter := Vector2(INF, INF)
var _debug_mapzoom := 0.0
var _debug_sheet := ""        # --sheet=char|troops|bag：开局直接打开整页界面（调试截图用）
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
# TAB 轮盘打开的整页界面（角色 / 部队 / 背包）
var sheet_panel: Control
var sheet_title: Label
var sheet_body: Label
var sheet_open := false
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
const DETAIL_ZOOM := 9999.0   # 细节层停用（改矢量地形，用户 2026-11-19）
const DETAIL_SCALE := 2.0     # 细档：2 屏幕像素 / texel（靠距离场保持边缘柔和）
const DETAIL_SCALE_CO := 2.0  # 粗档也用 2 屏幕像素 / texel
const DETAIL_KEEP := 4        # 缓存几个窗口（拖回去直接命中）
const DETAIL_MARGIN := 8.0    # 边缘多烘几像素，避免采样到边界
var _detail: MapDetail = null       # 正在烘/最近烘好的窗口
var _detail_shown := false
var _detail_off := false
var _detail_dbg := 0
var _dump_detail := ""      # --dumpdetail=路径：细节层烘完后存 PNG（对位/查色用）
var _pan_test := Vector2.ZERO       # --pan=dx,dy：开图 5 秒后平移这么多像素（测流式）
var _zoom_test := 0.0               # --zoomto=Z：开图 5 秒后切到这个倍率
var _pan_acc := 0.0
var _vel_px := Vector2.ZERO
var _prev_center := Vector2(1e9, 1e9)
var _prof_t := 0.0
var _bb_d = null
var _bb_t0 := 0
var _harness: TestHarness = null   # 自检/基准（test_harness.gd）
var _prof_max := 0.0
var _argv: PackedStringArray = []   # `--` 之后的用户参数：启动时取一次
var _flags := {}                    # 上面参数的集合，避免逐帧 OS.get_cmdline_user_args()


func _ready() -> void:
	_parse_args()
	MapDetail.dbg_state = _flags.has("--dbgstate")
	MapDetail.dbg_bakelog = _flags.has("--bakelog")
	MapDetail.cache_on = not _flags.has("--nocache")
	_vec_on = not _flags.has("--novec")
	if _flags.has("--bakebench"):
		_bb_d = MapDetail.new()
		_bb_d.setup(100.0, 27.0, 106.0, 23.0, 920, 570)
		_bb_t0 = Time.get_ticks_msec()
		return
	if _flags.has("--citytest"):
		_th()._city_test()
		return
	if _flags.has("--maptest"):
		_th()._map_test()
		return
	if _flags.has("--sitestats"):
		_th()._site_stats()
		return
	if _flags.has("--worldstats"):
		_world_stats()
		return
	if _flags.has("--hash"):
		TG.ensure_loaded()
		print("[稳定] 校验和 %d" % _th()._hash_samples())
		get_tree().quit()
		return
	if _flags.has("--nooverlay"):
		TG.disable_overlay()
	if _flags.has("--seamtest"):
		_th()._seam_test()
		return
	if _debug_demtest.size() > 0:
		_th()._dem_test(_debug_demtest)
		get_tree().quit()
		return
	if _flags.has("--probe"):
		_th()._probe()
		get_tree().quit()
		return
	_show_boot("正在载入地形数据……")
	await get_tree().process_frame
	await get_tree().process_frame
	for a in _argv:
		if a.begins_with("--bootshot="):
			_take_shot(a.substr(11), 0.4)
	await get_tree().process_frame
	_setup_world()
	_build_ui()
	_boot_text("正在烘焙世界地图……")
	await get_tree().process_frame
	_build_world_tex()
	var uargs := _argv
	if not _preview_args.is_empty():
		_th()._preview_tile(float(_preview_args[0]), float(_preview_args[1]), float(_preview_args[2]),
				int(_preview_args[3]), String(_preview_args[4]))
		return
	if uargs.has("--start") or uargs.has("--bugtest"):
		_boot_text("正在生成地形……")
		await get_tree().process_frame
		await get_tree().process_frame
		await _start_game()
		print("[启动] 世界就绪 %d ms" % Time.get_ticks_msec())
		if uargs.has("--bugtest"):
			_th()._bug_test()
		elif _debug_shot != "":
			_take_shot(_debug_shot, _debug_shot_delay)
		_run_shots()
		if uargs.has("--mapbench"):
			_th()._map_bench()
	else:
		_hide_boot()
		if _debug_shot != "":
			_take_shot(_debug_shot, _debug_shot_delay)
		_run_shots()

	_bug_unused()


## 调试参数：--at lon,lat   --fresh   --shot 路径.png
func _parse_args() -> void:
	_argv = OS.get_cmdline_user_args()
	_flags = {}
	for a in _argv:
		_flags[a] = true
	var ua := _argv
	var i := 0
	while i < ua.size():
		var a: String = ua[i]
		if a.begins_with("--at="):
			var p := a.substr(5).split(",")
			if p.size() >= 2:
				_debug_center = Vector2(float(p[0]), float(p[1]))
			if p.size() >= 3:
				_debug_up = float(p[2])
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
		elif a.begins_with("--countypanel="):
			_debug_countypanel = a.substr(14)
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
		elif a.begins_with("--sheet="):
			_debug_sheet = a.substr(8)
		elif a == "--nodetail":
			_detail_off = true
		elif a.begins_with("--dbgdetail="):
			_detail_dbg = int(a.substr(12))
		elif a.begins_with("--dumpdetail="):
			_dump_detail = a.substr(13)
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

	# 目的地面板（点城市/聚落/关城/汉县后弹出）：贴在地图内容区的左上角，
	# 不是屏幕左上角（时间/坐标 HUD 在地图外，不会打架）。
	# 位置每帧由 _place_map_panel() 按 content_rect 重算，所以拖动/缩放时它跟着地图走。
	city_panel = Control.new()
	city_panel.anchor_left = 0.0
	city_panel.anchor_top = 0.0
	city_panel.anchor_right = 0.0
	city_panel.anchor_bottom = 0.0
	city_panel.offset_left = 0.0
	city_panel.offset_top = 0.0
	city_panel.offset_right = 300.0
	city_panel.offset_bottom = 172.0
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

	# —— 整页界面（TAB 轮盘：角色 / 部队 / 背包）——
	sheet_panel = Control.new()
	sheet_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	sheet_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	sheet_panel.visible = false
	ui_layer.add_child(sheet_panel)
	var sd := ColorRect.new()
	sd.color = Color(0.05, 0.04, 0.03, 0.72)
	sd.set_anchors_preset(Control.PRESET_FULL_RECT)
	sheet_panel.add_child(sd)
	var sp := Panel.new()
	sp.set_anchors_preset(Control.PRESET_CENTER)
	sp.offset_left = -380.0
	sp.offset_top = -240.0
	sp.offset_right = 380.0
	sp.offset_bottom = 240.0
	var sp_st := StyleBoxFlat.new()
	sp_st.bg_color = Color(0.11, 0.09, 0.06, 0.98)
	sp_st.border_color = Color(0.62, 0.50, 0.28)
	sp_st.set_border_width_all(2)
	sp_st.set_corner_radius_all(3)
	sp.add_theme_stylebox_override("panel", sp_st)
	sheet_panel.add_child(sp)
	sheet_title = Label.new()
	sheet_title.position = Vector2(0, 18)
	sheet_title.size = Vector2(760, 40)
	sheet_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sheet_title.add_theme_font_size_override("font_size", 28)
	sheet_title.add_theme_color_override("font_color", Color(0.94, 0.84, 0.58))
	sp.add_child(sheet_title)
	sheet_body = Label.new()
	sheet_body.position = Vector2(48, 86)
	sheet_body.size = Vector2(664, 300)
	sheet_body.add_theme_font_size_override("font_size", 19)
	sheet_body.add_theme_color_override("font_color", Color(0.86, 0.80, 0.66))
	sheet_body.add_theme_constant_override("line_spacing", 10)
	sp.add_child(sheet_body)
	var sh := Label.new()
	sh.text = "ESC 或再按 TAB 关闭"
	sh.position = Vector2(0, 424)
	sh.size = Vector2(760, 22)
	sh.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sh.add_theme_font_size_override("font_size", 14)
	sh.add_theme_color_override("font_color", Color(0.66, 0.60, 0.46))
	sp.add_child(sh)

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

	var names := ["角色", "部队", "地图", "背包"]
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
	if _debug_sheet != "":
		_open_sheet(_debug_sheet)
	if _flags.has("--map"):
		_open_map()
	if _debug_mapcenter.x != INF:
		map_center = _debug_mapcenter
		_clamp_map_center()
	if _flags.has("--hitcenter"):
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
	if _flags.has("--pickcenter"):
		# 调试：打印"屏幕中心点到了什么"，用来校验 _poi_pick 的优先级和半径
		_pick_probe()
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
	if _debug_countypanel != "":
		var ci := int(_debug_countypanel)
		var cl := TG.counties()
		if ci >= 0 and ci < cl.size():
			_open_county_panel({"ll": cl[ci]["ll"], "county": cl[ci]})
	if _flags.has("--selftest"):
		_th()._selftest()
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
			if k.pressed and sheet_open:
				# 界面开着时再按 TAB：只负责关掉。
				# 轮盘状态必须一起清掉，否则松开 TAB 会拿旧方向再开一次（关了又弹出来）。
				_close_sheet()
				tab_held = false
				tab_sel = -1
				_tab_acc = Vector2.ZERO
				tab_cross.visible = false
				tab_cross.queue_redraw()
				return
			if k.pressed and map_open:
				# 地图开着时按 TAB：也只负责关掉（和整页界面一致）
				_close_map()
				tab_held = false
				tab_sel = -1
				_tab_acc = Vector2.ZERO
				tab_cross.visible = false
				if player != null:
					player.look_locked = false   # 上面按 TAB 时锁过，关图后要放开，否则镜头不动
				tab_cross.queue_redraw()
				return
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
					_open_sheet("char")
				elif tab_sel == 1:
					_open_sheet("troops")
				elif tab_sel == 3:
					_open_sheet("bag")
			tab_cross.queue_redraw()
		elif k.keycode == KEY_BACKSPACE and k.pressed and not k.echo:
			# 灵魂观察模式改到退格键（以前挂在 TAB 轮盘的上箭头）
			if player != null and not player.soul:
				player.enter_soul()
		elif k.keycode == KEY_ESCAPE and k.pressed:
			# 先关整页界面，再释放鼠标，最后关地图
			if sheet_open:
				_close_sheet()
			elif Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			else:
				_close_map()

	if tab_held and e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		# 直接按“这一小段鼠标移动”判方向：往上移就选上、往右移就选右。
		# 不再用“从按下点开始的累积位移”，所以斜着划（上→左上）能立刻换方向。
		# 0.55 的短窗平滑只是压掉抖动；主方向要明显大于另一个轴才换（防 45° 处来回跳）。
		_tab_acc = _tab_acc * 0.55 + mm.relative
		var want := _tab_dir_of_motion(_tab_acc)
		if want != -1 and want != tab_sel:
			tab_sel = want
			_tab_locked = true
			_layout_tab()
			tab_cross.queue_redraw()

	if map_open:
		_map_input(e)


## 按鼠标移动方向给方位（0 上 / 1 右 / 2 下 / 3 左）。
## 几乎没动、或者正好卡在 45° 对角线上时返回 -1 —— 保持当前选中，不乱跳。
func _tab_dir_of_motion(d: Vector2) -> int:
	if d.length() < TAB_MOVE_MIN:
		return -1
	var ax := absf(d.x)
	var ay := absf(d.y)
	if ax > ay * TAB_DIR_BIAS:
		return 1 if d.x > 0.0 else 3
	if ay > ax * TAB_DIR_BIAS:
		return 0 if d.y < 0.0 else 2
	return -1


## TAB 轮盘打开的整页界面：char=角色 / troops=部队 / bag=背包
func _open_sheet(kind: String) -> void:
	if sheet_panel == null:
		return
	sheet_open = true
	sheet_panel.visible = true
	if player != null:
		player.look_locked = true
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	match kind:
		"char":
			sheet_title.text = "角 色"
			sheet_body.text = _sheet_char_text()
		"troops":
			sheet_title.text = "部 队"
			sheet_body.text = "还没有招募部队。\n\n招兵、粮草、士气这些还没做。"
		_:
			sheet_title.text = "背 包"
			sheet_body.text = "还没有物品。\n\n物品、货币、交易这些还没做。"


func _close_sheet() -> void:
	if sheet_panel == null:
		return
	sheet_open = false
	sheet_panel.visible = false
	if player != null:
		player.look_locked = false
	if DisplayServer.get_name() != "headless":
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _sheet_char_text() -> String:
	if terrain == null:
		return "无名旅人"
	var lon: float = terrain.center_lon
	var lat: float = terrain.center_lat
	var h: float = TG.macro_height(lon, lat)
	var b: int = TG.biome_at(lon, lat, h)
	var lf: int = TG.landform_kind(lon, lat, h)
	var mode := "灵魂观察" if (player != null and player.soul) else "步行"
	return "姓名　无名旅人\n时间　%s\n位置　东经 %.2f°　北纬 %.2f°\n海拔　%d 米\n地貌　%s · %s\n状态　%s" % [
			_clock_text(), lon, lat, int(round(h)), TG.biome_name(b),
			TG.LF_NAMES[clampi(lf, 0, TG.LF_COUNT - 1)], mode]


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
	# 地图是整屏覆盖的，底下的 3D 世界看不见却还在渲染（显卡空转、风扇狂转）。
	# 开图时把地形整棵子树藏掉，关图再放出来。
	if terrain != null:
		terrain.visible = false
	_panel_placeholder()      # 面板常显：先摆空面板，点谁换谁
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
	if terrain != null:
		terrain.visible = true
	# 回到游戏就把鼠标锁回去，否则关图后摄像机不跟鼠标
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _map_input(e: InputEvent) -> void:
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var hit := _poi_pick(mb.position, true)
				if not hit.is_empty():
					_poi_open(hit)
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
			var hit := _poi_pick(mm.position)
			var hv: Dictionary = {}
			if not hit.is_empty():
				hv = {"kind": hit["kind"], "ll": hit["ll"]}
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


## 点到点名的定居点时（from_place=true）：城址常常贴海，2.4 km 底图会把那一格判成水，
## 这时把目标吸附到最近的陆地，而不是直接拒绝。自由右键落的旅行标仍然按海面拦截。
## 能不能落脚：既不是海（掩膜），高程也不低于海平面（2.4 km 底图会把贴海的城址判成水下）
func _land_ok(ll: Vector2) -> bool:
	return not TG.is_water(ll.x, ll.y) and TG.dem_at(ll.x, ll.y) >= 0.5


func _snap_to_land(ll: Vector2) -> Vector2:
	if _land_ok(ll):
		return ll
	var cosl := maxf(cos(deg_to_rad(ll.y)), 0.2)
	for r in [0.02, 0.04, 0.08, 0.12, 0.2, 0.3]:
		for k in 12:
			var a := TAU * float(k) / 12.0
			var p := Vector2(ll.x + cos(a) * r / cosl, ll.y + sin(a) * r)
			if _land_ok(p):
				return p
	return ll


func _travel_ll(ll: Vector2, from_place := false) -> void:
	if _traveling:
		return
	var dest := _snap_to_land(ll) if from_place else ll
	if not _land_ok(dest):
		toast("那里是海面，无法前往")
		return
	_traveling = true
	_close_map()
	var dist_km := TG.distance_m(terrain.center_lon, terrain.center_lat, dest.x, dest.y) / 1000.0
	var days := maxf(dist_km / MARCH_KM_PER_DAY, 0.5)
	_show_boot("正在前往……行程 %d 公里，约 %s 日" % [int(round(dist_km)), _cn(int(round(days)))])
	_boot_set(0.02)
	await get_tree().process_frame
	await get_tree().process_frame

	# 快速旅行消耗的是游戏时间，不是无代价传送
	clock_min += days * 1440.0
	terrain.center_lon = dest.x
	terrain.center_lat = dest.y
	await terrain.build(_on_build_progress)
	_boot_text("正在布置植被……")
	_boot_set(0.9)
	await get_tree().process_frame
	await terrain._build_vegetation(_on_build_progress)
	player.soul = false
	player.global_position = Vector3(0, terrain.height_xyz(0, 0) + 3.0 + _debug_up, 0)
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
		var sz: float = clampf(3.7 / km_per_px, 8.0, 260.0)
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



## 秦汉关城 / 邑 / 要地（data/sites_han.json，史书点名的第三层点位）
## 地图上**不落文字**，只画朱砂色 + 米色描边的舆图符号（底图村庄是褐色小方块/圆环，
## 不带描边的话分不出来）；名字和年代走点击面板，悬停只用高亮表示"这个是可点的"。
func _draw_sites(cr: Rect2) -> void:
	var list := TG.sites()
	if list.is_empty():
		return
	_poi_dedup()
	var fade := clampf((map_zoom - 3.0) / 3.0, 0.0, 1.0)      # 关隘/城邑
	var fade_v := clampf((map_zoom - 22.0) / 6.0, 0.0, 1.0)   # 邑（小聚落，最后才出）
	if fade <= 0.01 and fade_v <= 0.01:
		return
	var sz := clampf(3.0 + map_zoom * 0.05, 3.0, 7.5)
	for s in list:
		var kind0 := String(s.get("kind", "要地"))
		var a := fade_v if kind0 == "邑" else fade
		if a <= 0.01:
			continue
		if _hid_sites.has(_ll_key(float(s["lon"]), float(s["lat"]))):
			continue
		var ll := Vector2(float(s["lon"]), float(s["lat"]))
		var p := _lonlat_to_screen_off(ll, 0.0)
		if not cr.grow(12.0).has_point(p):
			continue
		var hov: bool = not _hover.is_empty() and String(_hover.get("kind", "")) == "site" \
				and (_hover["ll"] as Vector2).is_equal_approx(ll)
		if hov:
			# 悬停：金盘 + 一圈亮边，符号本身也放大一点（盘别太大，免得盖住旁边那一丛点位）
			map_root.draw_circle(p, sz + 4.5, Color(0.96, 0.82, 0.42, 0.85 * a))
			map_root.draw_arc(p, sz + 6.5, 0.0, TAU, 20, Color(0.99, 0.90, 0.55, 0.90 * a), 1.4)
			_site_marker(p, kind0, sz * 1.2, a)
		else:
			_site_marker(p, kind0, sz, a)


## 关 / 城（都） / 邑 / 津 / 要地（仓、战场）的舆图符号，画在屏幕坐标 p 上，s 为半径像素。
## 朱砂底 + 米色描边：底图上的村庄是褐色小方块/圆环，只靠颜色深浅分不开。
func _site_marker(p: Vector2, kind: String, s: float, a: float) -> void:
	var ink := Color(0.44, 0.15, 0.11, 0.95 * a)
	var cream := Color(0.93, 0.89, 0.76, 0.80 * a)
	match kind:
		"城", "都":
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
		"津":
			# 津渡：三道水纹（中间一道短一点）
			var wy := s * 0.62
			for k in 3:
				var yy := (float(k) - 1.0) * wy
				var ww: float = s * (0.95 if k != 1 else 0.62)
				map_root.draw_line(p + Vector2(-ww, yy), p + Vector2(ww, yy), cream, 3.2)
				map_root.draw_line(p + Vector2(-ww, yy), p + Vector2(ww, yy), ink, 1.6)
		_:
			# 要地 / 仓 / 战场：实心三角（先用放大的米色三角描边）
			var big := PackedVector2Array([
				p + Vector2(0.0, -s * 1.1), p + Vector2(s, s * 0.85), p + Vector2(-s, s * 0.85)])
			var under := PackedVector2Array([
				p + Vector2(0.0, -s * 1.45), p + Vector2(s * 1.35, s * 1.15),
				p + Vector2(-s * 1.35, s * 1.15)])
			map_root.draw_colored_polygon(under, cream)
			map_root.draw_colored_polygon(big, ink)




## 域外定居点（world_settlements.json）：城邦=褐圈+圆心点（1 倍就可见），
## 附邑/镇=更小的空心圈（2 倍淡入）。只画图上，不写文字。
func _draw_world_cities(cr: Rect2) -> void:
	if map_zoom < 1.0:
		return
	var list := TG.world_settlements()
	if list.is_empty():
		return
	var ink := Color(0.30, 0.17, 0.08, 0.92)
	var ink2 := Color(0.34, 0.22, 0.12, 0.70)
	for w in list:
		var tier := int(w.get("tier", 1))
		if tier >= 3 and map_zoom < 10.0:
			continue
		if tier == 2 and map_zoom < 3.0:
			continue
		var p := _lonlat_to_screen_off(w["ll"], 0.0)
		if not cr.has_point(p):
			continue
		var hov: bool = not _hover.is_empty() and String(_hover.get("kind", "")) == "world" \
				and (_hover["ll"] as Vector2).is_equal_approx(w["ll"])
		if tier <= 1:
			# 城：双圈 + 中心点（看到就知道是城郭）
			var r := clampf(3.2 + map_zoom * 0.04, 4.0, 8.0)
			map_root.draw_arc(p, r, 0.0, TAU, 16, ink, 1.6)
			map_root.draw_arc(p, r * 0.52, 0.0, TAU, 12, ink, 1.1)
			map_root.draw_circle(p, maxf(r * 0.16, 0.9), ink)
			if hov:
				map_root.draw_arc(p, r + 3.0, 0.0, TAU, 18, Color(0.98, 0.84, 0.44, 0.95), 2.0)
		elif tier == 2:
			# 镇：菱形（和城的圆形一眼分开）
			var r2 := clampf(2.6 + map_zoom * 0.03, 3.2, 5.2)
			var pts := PackedVector2Array([p + Vector2(0, -r2), p + Vector2(r2, 0),
					p + Vector2(0, r2), p + Vector2(-r2, 0), p + Vector2(0, -r2)])
			map_root.draw_polyline(pts, ink2, 1.2)
			if hov:
				map_root.draw_arc(p, r2 + 2.6, 0.0, TAU, 14, Color(0.98, 0.84, 0.44, 0.95), 1.5)
		else:
			# 邑：实心小点
			map_root.draw_circle(p, clampf(1.5 + map_zoom * 0.012, 1.8, 3.0), ink2)
			if hov:
				map_root.draw_arc(p, 4.0, 0.0, TAU, 12, Color(0.98, 0.84, 0.44, 0.95), 1.4)


## 汉书·地理志的县（CHGIS V6 点位，1134 处）：一群小空心方框，20 倍淡入。
## 只画图标不写文字；和聚落的实心方块/关城的朱砂方块分开，悬停才高亮。
func _draw_counties(cr: Rect2) -> void:
	var list := TG.counties()
	if list.is_empty():
		return
	_poi_dedup()
	var fade := clampf((map_zoom - 10.0) / 6.0, 0.0, 1.0)
	if fade <= 0.01:
		return
	var sc := _map_scale()
	var half_lon: float = (cr.size.x * 0.5) / maxf(sc.x, 0.0001) + 1.0
	var half_lat: float = (cr.size.y * 0.5) / maxf(sc.y, 0.0001) + 1.0
	var cx := map_center.x
	var cy := map_center.y
	var r := clampf(1.0 + map_zoom * 0.012, 1.0, 2.4)
	var ink := Color(0.36, 0.24, 0.14, 0.80 * fade)
	var hov_ll: Vector2 = Vector2(INF, INF)
	if not _hover.is_empty() and String(_hover.get("kind", "")) == "county":
		hov_ll = _hover["ll"]
	for it in list:
		var ll: Vector2 = it["ll"]
		# 视口外的点先按经纬度框掉（1134 个全画也不卡，但这层是每帧都跑的）
		if absf(ll.x - cx) > half_lon or absf(ll.y - cy) > half_lat:
			continue
		if _hid_counties.has(_ll_key(ll.x, ll.y)):
			continue
		var p := _lonlat_to_screen_off(ll, 0.0)
		if not cr.has_point(p):
			continue
		if ll.is_equal_approx(hov_ll):
			# 悬停：金盘 + 加粗的褐色空框（不改颜色，免得被当成关城那种朱砂点位）
			map_root.draw_circle(p, r + 4.5, Color(0.96, 0.82, 0.42, 0.85 * fade))
			map_root.draw_rect(Rect2(p - Vector2(r + 1.5, r + 1.5), Vector2(r + 1.5, r + 1.5) * 2.0),
					Color(0.30, 0.19, 0.10, 0.95 * fade), false, 2.0)
		else:
			map_root.draw_rect(Rect2(p - Vector2(r, r), Vector2(r, r) * 2.0), ink, false, 1.0)




## 面板贴在地图内容区左上角（用户要求：窗口只出现在地图里）。
## 内容区被拖出屏幕时退到屏幕左上角留 8 px，免得点完看不到面板。
func _place_map_panel(cr: Rect2, vs: Vector2) -> void:
	if city_panel == null or not city_panel.visible:
		return
	var sz := city_panel.size
	var p := cr.position + Vector2(14, 14)
	p.x = clampf(p.x, 8.0, maxf(8.0, vs.x - sz.x - 8.0))
	p.y = clampf(p.y, 8.0, maxf(8.0, vs.y - sz.y - 8.0))
	city_panel.position = p


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








## 江河湖泊：加载时预处理，绘制时按可见范围逐条画
func _draw_hydro_layer() -> void:
	if _flags.has("--nohydro"):
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




## 定居点层级与去重（2026-11-17）：
##   城（cities.json / 域外 tier1）最早显示；关隘、城邑其次；汉县再次；邑（小聚落）最后。
##   同一处叠着的点位只画一个：名字和城一样的史事点位不画（城已经有了），
##   和点位/别的县完全同坐标的县只留第一个。
var _poi_deduped := false
var _hid_sites := {}
var _hid_counties := {}


func _ll_key(lon: float, lat: float) -> String:
	return "%.2f,%.2f" % [lon, lat]


func _poi_dedup() -> void:
	if _poi_deduped:
		return
	_poi_deduped = true
	var names := {}
	for c in TG.cities():
		names[String(c["name"])] = true
	var spots := {}
	for c in TG.cities():
		spots[Vector2i(int(float(c["lon"]) * 100.0), int(float(c["lat"]) * 100.0))] = true
	for st in TG.sites():
		if names.has(String(st["name"])):
			_hid_sites[_ll_key(float(st["lon"]), float(st["lat"]))] = true
		spots[Vector2i(int(float(st["lon"]) * 100.0), int(float(st["lat"]) * 100.0))] = true
	for it in TG.counties():
		var ll2: Vector2 = it["ll"]
		var cell := Vector2i(int(ll2.x * 100.0), int(ll2.y * 100.0))
		if spots.has(cell) or _hid_counties.has(_ll_key(ll2.x, ll2.y)):
			_hid_counties[_ll_key(ll2.x, ll2.y)] = true


## 地图上的可点物：城 / 关城邑 / 汉县（三套数据，一个入口）。
## 命中规则：**取最近的**（各自的命中半径内），距离相同时按 城 → 关城邑 → 汉县 排。
## 以前是"先城、再关城、再汉县"，于是同一处叠着的两个点位（比如咸阳城 12 km 外
## 的渭城/长陵/池阳三个汉县，或者和汉县完全同点的史事点位）永远只能点到排前面的那个，
## 用户看到的就是"点两个不同的定居点，面板都写咸阳"。
## cycle=true 时（左键点击）：同一个位置连点会依次切换叠在这里的候选。
func _poi_cands(pos: Vector2) -> Array:
	_poi_dedup()
	var out: Array = []
	# 城：图标大小随缩放变（咸阳城墙约 3.7 km 见方），命中半径跟着走
	for c in TG.cities():
		var lat := float(c["lat"])
		var km_per_px: float = 40075.0 * maxf(cos(deg_to_rad(lat)), 0.05) / (_map_scale().x * 360.0)
		var sz: float = clampf(3.7 / km_per_px, 8.0, 260.0)
		var ll := Vector2(float(c["lon"]), lat)
		var d := _lonlat_to_screen_off(ll, 0.0).distance_to(pos)
		if d < maxf(sz * 0.75, 12.0):
			out.append({"kind": "city", "ll": ll, "data": c, "d": d, "pri": 0})
	for s in TG.sites():
		var kd := String(s.get("kind", "要地"))
		if kd == "邑":
			if map_zoom < 22.0:
				continue
		elif map_zoom < 3.0:
			continue
		if _hid_sites.has(_ll_key(float(s["lon"]), float(s["lat"]))):
			continue
		var ll := Vector2(float(s["lon"]), float(s["lat"]))
		var d := _lonlat_to_screen_off(ll, 0.0).distance_to(pos)
		if d < 12.0:
			out.append({"kind": "site", "ll": ll, "data": s, "d": d, "pri": 1})
	for w in TG.world_settlements():
		var tier := int(w.get("tier", 1))
		if tier >= 3 and map_zoom < 10.0:
			continue
		if tier == 2 and map_zoom < 3.0:
			continue
		var ll: Vector2 = w["ll"]
		var d := _lonlat_to_screen_off(ll, 0.0).distance_to(pos)
		var rad := 10.0 if tier <= 1 else (8.0 if tier == 2 else 6.0)
		if d < rad:
			out.append({"kind": "world", "ll": ll, "data": w, "d": d, "pri": 1})
	if map_zoom >= 10.0:
		# 汉县 1134 处：先按经纬度粗筛（全算屏幕坐标太浪费）
		var ll0 := _screen_to_lonlat(pos)
		var sc := _map_scale()
		var rl := 12.0 / maxf(sc.x, 0.0001)
		var rb := 12.0 / maxf(sc.y, 0.0001)
		for it in TG.counties():
			var ll: Vector2 = it["ll"]
			if absf(ll.x - ll0.x) > rl or absf(ll.y - ll0.y) > rb:
				continue
			if _hid_counties.has(_ll_key(ll.x, ll.y)):
				continue
			var d := _lonlat_to_screen_off(ll, 0.0).distance_to(pos)
			if d < 9.0:
				out.append({"kind": "county", "ll": ll, "data": it, "d": d, "pri": 2})
	# 近的优先；同距离（<1.5 px）按类别排
	out.sort_custom(func(a, b):
		if absf(float(a["d"]) - float(b["d"])) > 1.5:
			return float(a["d"]) < float(b["d"])
		return int(a["pri"]) < int(b["pri"]))
	return out


var _pick_pos := Vector2(1e9, 1e9)    # 上一次点击的位置（判断"连点同一个地方"）
var _pick_i := 0                      # 同一个地方第几个候选


func _poi_pick(pos: Vector2, cycle: bool = false) -> Dictionary:
	var list := _poi_cands(pos)
	if list.is_empty():
		_pick_pos = Vector2(1e9, 1e9)
		_pick_i = 0
		return {}
	if cycle:
		if _pick_pos.distance_to(pos) < 6.0:
			_pick_i = (_pick_i + 1) % list.size()
		else:
			_pick_i = 0
		_pick_pos = pos
	else:
		_pick_i = 0
		_pick_pos = Vector2(1e9, 1e9)
	var hit: Dictionary = list[_pick_i]
	return {"kind": hit["kind"], "ll": hit["ll"], "data": hit["data"]}


## 点开命中的那个点位（三种面板的差别只在标题/副标题）
func _poi_open(hit: Dictionary) -> void:
	match String(hit.get("kind", "")):
		"city":
			_open_city_panel(hit["data"])
		"site":
			_open_site_panel({"ll": hit["ll"], "site": hit["data"]})
		"world":
			var w: Dictionary = hit["data"]
			var wsub := "域外 · %s" % String(w.get("region", ""))
			var wtier := int(w.get("tier", 1))
			if wtier > 1:
				wsub = ("域外镇 · %s" if wtier == 2 else "域外邑 · %s") % String(w.get("region", ""))
				var par := String(w.get("parent", ""))
				if par != "":
					wsub += "（属%s）" % par
			_open_place_panel(String(w["name"]), wsub, hit["ll"])
		"county":
			_open_county_panel({"ll": hit["ll"], "county": hit["data"]})




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

	var names := ["角色", "部队", "地图", "背包"]
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
## 注意：**低倍不强制居中**（用户 2026-11-15 明确：1 倍居中不合适地图），
## 所以 1 倍时整幅世界会偏在一边，这是刻意的，别再"修"。
func _clamp_map_center() -> void:
	map_center.x = clampf(map_center.x, -180.0, 180.0)
	map_center.y = clampf(map_center.y, -LAT_LIMIT, LAT_LIMIT)


func _zoom_min() -> float:
	return 0.7


## 以鼠标位置为轴心缩放
func _zoom_at(target_zoom: float) -> void:
	var vs := get_viewport().get_visible_rect().size
	var mp := get_viewport().get_mouse_position()
	# 先记下鼠标下的经纬度（用旧缩放）
	var sc0 := _map_scale()
	var before := Vector2(map_center.x + (mp.x - vs.x * 0.5) / sc0.x,
			map_center.y - (mp.y - vs.y * 0.5) / sc0.y)
	map_zoom = clampf(target_zoom, _zoom_min(), 500.0)
	var sc1 := _map_scale()
	var after := Vector2(map_center.x + (mp.x - vs.x * 0.5) / sc1.x,
			map_center.y - (mp.y - vs.y * 0.5) / sc1.y)
	map_center.x += before.x - after.x
	map_center.y += before.y - after.y
	_clamp_map_center()
	map_root.queue_redraw()





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
## ── 高倍细节层：跟着视野的一张画布 + 一块一块显示 ─────────────────────────
## 规则：
##   1. zoom < DETAIL_ZOOM(250)：细版整体渐隐，粗版渐显，淡完释放画布
##   2. zoom >= 60：烘好一块就显示一块（按离屏幕中心由近到远），不做圆环遮罩
##   3. 拖动：烘的优先级跟着屏幕中心变；已烘 texel 全部保留
##   4. 换倍率 / 跳区：旧图渐隐退回粗图，新窗口从头烘
##   5. 画布只为一件事长大：覆盖当前屏幕（已烘好的块整块搬过来，不重烘）
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
var _fade := 0.0                    # 0 = 粗版，1 = 细版
var _st_dbg := 0.0


func _detail_tick(delta: float) -> void:
	if _map_mat == null or _detail_off:
		return
	if _flags.has("--dbgstate"):
		_st_dbg += delta
		if _st_dbg > 0.5:
			_st_dbg = 0.0
			print("[状态] fade=%.2f zk=%d canvas=%s tiles=%d/%d zoom=%.1f"
					% [_fade, _cur_zk, str(_canvas != null),
					-1 if _canvas == null else _canvas.tiles_done,
					-1 if _canvas == null else _canvas.tiles_total, map_zoom])
	# 阈值以下：细版渐隐，粗版渐显
	if not map_open or map_zoom < DETAIL_ZOOM:
		if _fade > 0.0:
			_fade = maxf(0.0, _fade - delta / DETAIL_FADE_S)
			_push_detail_uniforms()
			if _fade <= 0.0:
				_map_mat.set_shader_parameter("detail_on", 0.0)
				_canvas = null
				_cur_zk = -1
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
		# 先定档位再取画布：_canvas_for 用 _canvas_ds 算 texel 数
		_canvas_ds = want_ds
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
	if _dump_detail != "" and _canvas != null and _canvas.done():
		_canvas.img.save_png(_dump_detail)
		print("[细节] 已存 %s（%dx%d，R=地貌编号 G=阴影 B=水线）"
				% [_dump_detail, _canvas.px_w, _canvas.px_h])
		_dump_detail = ""
	# 不做云雾、不做半径、不做区域限制：烘好一块就整块显示，速度只取决于烘焙吞吐
	_fade = minf(1.0, _fade + delta / DETAIL_FADE_S)
	_push_detail_uniforms()


func _canvas_for(zk: int) -> MapDetail:
	if _canvases.has(zk):
		var cached: MapDetail = _canvases[zk]
		# 缓存命中必须同时满足：盖住当前视野 + texel 与当前档位一致。
		# 否则中国那块画布会被当成欧洲的用，_grow_canvas 再做并集 → texel 暴涨。
		var want_d: float = float(_canvas_ds) / maxf(_map_scale().x, 0.0001)
		var texel_ok: bool = absf(cached.lon_per_texel() / want_d - 1.0) < 0.02
		if texel_ok and cached.geom_covers(_detail_core()):
			_canvas_order.erase(zk)
			_canvas_order.push_front(zk)
			return cached
		_canvases.erase(zk)
		_canvas_order.erase(zk)
		cached.cancel()      # 别再让废画布在后台抢 worker
		if _flags.has("--dbgstate"):
			print("[细节] 缓存 zk=%d 不覆盖/texel 不符，丢弃重建" % zk)
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
			(_canvases[old] as MapDetail).cancel()
			_canvases.erase(old)
	return c


## 把画布长大到能盖住 core：新画布照抄旧画布已烘好的块（blit，不重烘），R 不变
func _grow_canvas(core: Vector4) -> void:
	# 并集跨度超过 1.5 屏就说明跳区了：不做并集，按当前视野重建（texel 不变）。
	# 并集会得到「中国∪欧洲」那种 110° 宽画布，被 MAX_PX 压完 texel 放大 20 倍。
	var scg := _map_scale()
	var vsg := get_viewport().get_visible_rect().size
	var ok_lon: float = (vsg.x * 2.2) / maxf(scg.x, 0.0001)
	var ok_lat: float = (vsg.y * 2.2) / maxf(scg.y, 0.0001)
	# 判定用「当前视野」而不是带速度预测的 core：拖动时 core 会往前冲半屏，
	# 一冲就超过阈值 → 每帧重建 → 你看到的“一直重新烘焙”。
	var vw0: Vector4 = _detail_view()
	var u0x := minf(_canvas.lon0, vw0.x)
	var u1x := maxf(_canvas.lon1, vw0.z)
	var v0x := maxf(_canvas.lat0, vw0.y)
	var v1x := minf(_canvas.lat1, vw0.w)
	if (u1x - u0x) > ok_lon or (v0x - v1x) > ok_lat:
		# 关键：仍然把旧画布传进去当 adopt —— 重叠部分直接 blit 复用，不重烘。
		# 范围按「当前视野 + 120px」算（不用带预测的 core，避免拖动时每帧换窗口）。
		var vw: Vector4 = _detail_view()
		var fresh := MapDetail.new()
		fresh.setup(vw.x, vw.y, vw.z, vw.w,
				int(ceil((vw.z - vw.x) * scg.x / float(_canvas_ds))),
				int(ceil((vw.y - vw.w) * scg.y / float(_canvas_ds))), _canvas)
		_canvases[_cur_zk] = fresh
		_canvas = fresh
		# 不要重置 _fade：重叠区是继承过来的，淡出到粗版会闪一下
		_bind_canvas(fresh)
		if _flags.has("--dbgstate"):
			print("[细节] 跨区：按当前视野重建画布（不并集）")
		return
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
		map_zoom = clampf(_zoom_test, _zoom_min(), 500.0)
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
	var b0 := city_panel.get_node("Opt0") as Button
	b0.text = "街道"
	b0.visible = true
	var b1 := city_panel.get_node("Opt1") as Button
	b1.text = "府衙"
	b1.visible = true
	(city_panel.get_node("Sub") as Label).text = ""
	# 面板必须在地图图层之上
	if ui_layer != null and city_panel.get_parent() == ui_layer:
		ui_layer.move_child(city_panel, ui_layer.get_child_count() - 1)
	city_panel.offset_bottom = 172.0
	city_panel.visible = true
	map_root.queue_redraw()


## 打开村庄面板（只有一个“进村”）
func _open_village_panel(v: Dictionary) -> void:
	_panel_city = {}
	_panel_village = v
	var title: Label = city_panel.get_node("Title")
	title.text = String(v["name"])
	var b0 := city_panel.get_node("Opt0") as Button
	b0.text = "进村"
	b0.visible = true
	(city_panel.get_node("Opt1") as Button).visible = false
	(city_panel.get_node("Sub") as Label).text = ""
	if ui_layer != null and city_panel.get_parent() == ui_layer:
		ui_layer.move_child(city_panel, ui_layer.get_child_count() - 1)
	city_panel.offset_bottom = 172.0
	city_panel.visible = true
	map_root.queue_redraw()


## 面板常显：没选中任何点位时（刚开图 / 点了空地）显示占位，不隐藏
func _panel_placeholder() -> void:
	if city_panel == null:
		return
	_panel_city = {}
	_panel_village = {}
	_panel_place = {}
	(city_panel.get_node("Title") as Label).text = "地 图"
	(city_panel.get_node("Sub") as Label).text = "点城 / 关城 / 汉县查看详情"
	city_panel.offset_bottom = 92.0      # 占位时面板矮一点，别留一大块空
	(city_panel.get_node("Opt0") as Button).visible = false
	(city_panel.get_node("Opt1") as Button).visible = false
	if ui_layer != null and city_panel.get_parent() == ui_layer:
		ui_layer.move_child(city_panel, ui_layer.get_child_count() - 1)
	city_panel.visible = true


## 清空当前选择（面板不收起，回到占位）
func _close_city_panel() -> void:
	_panel_placeholder()


## 通用「点位面板」：关城/邑/要地、汉书县共用（标题 + 副标题 + 前往）
func _open_place_panel(title_txt: String, sub_txt: String, ll: Vector2) -> void:
	_panel_city = {}
	_panel_village = {}
	_panel_place = {"name": title_txt, "ll": ll}
	var title: Label = city_panel.get_node("Title")
	title.text = title_txt
	(city_panel.get_node("Sub") as Label).text = sub_txt
	var b0 := city_panel.get_node("Opt0") as Button
	b0.text = "前往"
	b0.visible = true
	(city_panel.get_node("Opt1") as Button).visible = false
	if ui_layer != null and city_panel.get_parent() == ui_layer:
		ui_layer.move_child(city_panel, ui_layer.get_child_count() - 1)
	city_panel.offset_bottom = 172.0
	city_panel.visible = true
	map_root.queue_redraw()


## 打开关城/邑/要地面板
func _open_site_panel(hit: Dictionary) -> void:
	var s: Dictionary = hit["site"]
	var era := int(s.get("era", 0))
	var era_txt := ("前%d年" % -era) if era < 0 else ("%d 年" % era)
	_open_place_panel(String(s.get("name", "")),
			"%s · %s" % [String(s.get("kind", "要地")), era_txt], hit["ll"])


## 打开汉书县面板（只要县名 + 前往；"汉县·今地"那行用户不要，去掉）
func _open_county_panel(hit: Dictionary) -> void:
	var c: Dictionary = hit["county"]
	_open_place_panel(String(c.get("n", "")), "", hit["ll"])


## 街道 = 城中心；府衙 = 城北偏内
func _city_go(what: String) -> void:
	if not _panel_place.is_empty():
		var pll: Vector2 = _panel_place["ll"]
		var pn := String(_panel_place["name"])
		_close_city_panel()
		toast("前往 %s" % pn)
		_travel_ll(pll, true)
		return
	if not _panel_village.is_empty():
		var vll: Vector2 = _panel_village["ll"]
		var vn := String(_panel_village["name"])
		_close_city_panel()
		toast("前往 %s" % vn)
		_travel_ll(vll, true)
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
	_travel_ll(Vector2(lon, lat), true)






func _draw_map() -> void:
	var vs := get_viewport().get_visible_rect().size
	if not _map_shader_ok:
		map_root.draw_rect(Rect2(Vector2.ZERO, vs), Color(0.42, 0.38, 0.28))

	# 先夹取再排版：夹取只夹 ±180/±85（低倍不强制居中），
	# 放在排版前是为了拖动到边界时不用等下一帧才摆正
	_clamp_map_center()
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
	_vec_org = content_rect.position
	_vec_ppd = ppd2
	_vec_ppy = ppy2
	_content_w = content_w
	_content_h = content_h
	if _flags.has("--mapsize"):
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
	if _flags.has("--pintest") and not _pin_probed:
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
				clampf((map_zoom - 1.2) / 9.0, 0.0, 1.0) * 0.34)
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

	# 地图上不写任何文字（缩放读数也去掉了）：要读倍率用 --mapsize 或看 debug

	var _t0 := Time.get_ticks_usec()
	# 地图上下各压一条 2px 的墨线：遮住贴图边缘那一行（极地行会显示成白色）
	map_root.draw_rect(Rect2(content_rect.position, Vector2(content_rect.size.x, 2)), Color(0.22, 0.16, 0.10))
	map_root.draw_rect(Rect2(content_rect.position + Vector2(0, content_rect.size.y - 2),
			Vector2(content_rect.size.x, 2)), Color(0.22, 0.16, 0.10))
	_draw_scroll_rollers(scroll_rect)
	_draw_brocade(scroll_rect, pad_x, pad_y)
	var _t1 := Time.get_ticks_usec()
	_draw_world_cities(content_rect)
	_draw_counties(content_rect)
	_draw_vec_terrain()
	_draw_settlements(content_rect)
	_draw_sites(content_rect)
	_place_map_panel(content_rect, vs)
	if map_hydro != null:
		map_hydro.queue_redraw()
	var _t4 := Time.get_ticks_usec()
	if _flags.has("--maptime"):
		_tm["frame"] = float(_t1 - _t0) / 1000.0
		_tm["marks"] = float(_t4 - _t1) / 1000.0
		_tm_n += 1
		if _tm_n % 2 == 0:
			print("[计时] 框 %.1f ms / 点位 %.1f ms"
					% [_tm["frame"], _tm["marks"]])

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
	# 舆图符号层已经取消（用户要求 2D 地图纯色）。landform_db 里的 SYMBOL_* 表暂时留着不用。
	_map_mat.set_shader_parameter("shade_gain", 1.0)
	_map_mat.set_shader_parameter("lat_limit", LAT_LIMIT)
	# 细节层占位（1×1），就绪前 detail_on=0 走编号图
	var blank := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	blank.fill(Color(0, 0, 0, 1))
	_map_mat.set_shader_parameter("detail_tex", ImageTexture.create_from_image(blank))
	_map_mat.set_shader_parameter("detail_on", 0.0)
	_map_mat.set_shader_parameter("detail_org", Vector2.ZERO)
	_map_mat.set_shader_parameter("detail_span", Vector2.ONE)
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
	var args := _argv
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
	if _flags.has("--prof"):
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
	if _flags.has("--fps"):
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




func _exit_tree() -> void:
	if _map_thread != null and _map_thread.is_alive():
		_map_thread.wait_to_finish()
	if _detail != null:
		_detail.wait()
	if _canvas != null:
		_canvas.wait()
	for k in _canvases:
		(_canvases[k] as MapDetail).wait()


## 自检/基准的宿主：test_harness.gd 里的函数要读写 main 的 terrain/player/map_*，
## 所以挂成 main 的子节点，懒创建一次。
func _th() -> TestHarness:
	if _harness == null:
		_harness = TestHarness.new()
		_harness.m = self
		add_child(_harness)
	return _harness


## 调试：--worldstats 打印域外定居点（坐标/高程/地貌/落水/同点），查数据用
func _world_stats() -> void:
	TG.ensure_loaded()
	var list := TG.world_settlements()
	var t1 := 0
	var t2 := 0
	var t3 := 0
	var wet := 0
	var dup := 0
	var seen := {}
	print("======== 域外定居点 %d 处 ========" % list.size())
	for w in list:
		var ll: Vector2 = w["ll"]
		var h: float = TG.dem_at(ll.x, ll.y)
		var lf: int = TG.landform_kind(ll.x, ll.y, h)
		var is_wet: bool = (h < 0.5 and TG.is_water(ll.x, ll.y)) or h < -8.0
		var tier := int(w.get("tier", 1))
		if tier <= 1:
			t1 += 1
		elif tier == 2:
			t2 += 1
		else:
			t3 += 1
		if is_wet:
			wet += 1
		var key := "%.2f,%.2f" % [ll.x, ll.y]
		if seen.has(key):
			dup += 1
			print("  [同点] %s 与 %s" % [String(w["name"]), String(seen[key])])
		else:
			seen[key] = w["name"]
		var par := String(w.get("parent", ""))
		var extra := ""
		if is_wet:
			var sn := _snap_to_land(ll)
			extra = "  ← 落水，旅行会吸附到 %.3f,%.3f（%s）" % [
					sn.x, sn.y, "已上岸" if not TG.is_water(sn.x, sn.y) else "仍是水"]
		print("  T%d %-10s %8.2f,%7.2f h=%5.0f %-6s %-5s%s%s"
				% [tier, String(w["name"]), ll.x, ll.y, h, TG.LF_NAMES[lf],
				String(w.get("region", "")), "（属%s）" % par if par != "" else "", extra])
	print("[统计] 城 %d / 镇 %d / 邑 %d；落水 %d；同点 %d" % [t1, t2, t3, wet, dup])
	get_tree().quit()


## 调试：--pickcenter 打印"屏幕中心命中了什么"（校验 _poi_pick 的最近优先/连点切换）
func _poi_name(hit: Dictionary) -> String:
	if hit.is_empty():
		return "无"
	var d: Dictionary = hit["data"]
	return "%s「%s」" % [hit["kind"], String(d.get("name", d.get("n", "?")))]


func _pick_probe() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var vs := get_viewport().get_visible_rect().size
	map_root.queue_redraw()
	await get_tree().process_frame
	if _flags.has("--pickcycle"):
		# 模拟在同一个点连点 4 次：应当依次换出叠在这里的候选
		for i in 4:
			var h := _poi_pick(vs * 0.5, true)
			print("[连点] 第 %d 次 -> %s" % [i + 1, _poi_name(h)])
		get_tree().quit()
		return
	var hit := _poi_pick(vs * 0.5)
	if hit.is_empty():
		print("[拾取] 中心 %.3f,%.3f -> 无（zoom %.1f）" % [map_center.x, map_center.y, map_zoom])
	else:
		var d: Dictionary = hit["data"]
		var nm: String = String(d.get("name", d.get("n", "?")))
		print("[拾取] 中心 %.3f,%.3f -> %s「%s」（zoom %.1f）"
				% [map_center.x, map_center.y, hit["kind"], nm, map_zoom])
		if _flags.has("--pickopen"):
			_poi_open(hit)     # 连面板一起验（配合 --shots 截图）
			return
	get_tree().quit()


## ---------------- 矢量地形（实验） ----------------
## 数据由 ias/tools/build_terrain_contours.py 生成：TCON v2（float32 经纬度）
var _vec_pts := PackedFloat32Array()
var _vec_start := PackedInt32Array()
var _vec_len := PackedInt32Array()
var _vec_cls := PackedByteArray()
var _vec_bbox := PackedFloat32Array()
var _vec_order := PackedInt32Array()
var _vec_buckets := {}
var _vec_loaded := false
var _vec_on := false
var _vec_org := Vector2.ZERO
var _vec_ppd := 1.0
var _vec_ppy := 1.0
const VEC_BUCKET := 10.0
const VEC_ZOOM := 60.0     # 到这个倍率切矢量（以下用粗光栅图）
const VEC_FADE := 24.0     # 交叉淡入的倍率宽度


func _load_vec_terrain() -> void:
	if _vec_loaded:
		return
	_vec_loaded = true
	var path := "res://data/terrain_contours.bin"
	if not FileAccess.file_exists(path):
		print("[矢量] 没有数据：", path)
		return
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	if f.get_buffer(4).get_string_from_ascii() != "TCON":
		return
	f.get_32()
	var ncls := f.get_32()
	var t0 := Time.get_ticks_msec()
	for ci in ncls:
		var cls := f.get_32()
		var nr := f.get_32()
		for ri in nr:
			var n := f.get_32()
			var bx0 := f.get_float()
			var by0 := f.get_float()
			var bx1 := f.get_float()
			var by1 := f.get_float()
			var buf := f.get_buffer(n * 8)
			_vec_start.append(_vec_pts.size() / 2)
			_vec_len.append(n)
			_vec_cls.append(cls)
			_vec_bbox.append_array(PackedFloat32Array([bx0, by0, bx1, by1]))
			_vec_pts.append_array(buf.to_float32_array())
	var nr := _vec_len.size()
	var idx: Array = []
	for i in nr:
		var w: float = _vec_bbox[i * 4 + 2] - _vec_bbox[i * 4]
		var h: float = _vec_bbox[i * 4 + 3] - _vec_bbox[i * 4 + 1]
		idx.append([w * h, i])
	idx.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	for a in idx:
		_vec_order.append(int(a[1]))
	for i in nr:
		var x0 := int(floor((_vec_bbox[i * 4] + 180.0) / VEC_BUCKET))
		var x1 := int(floor((_vec_bbox[i * 4 + 2] + 180.0) / VEC_BUCKET))
		var y0 := int(floor((90.0 - _vec_bbox[i * 4 + 3]) / VEC_BUCKET))
		var y1 := int(floor((90.0 - _vec_bbox[i * 4 + 1]) / VEC_BUCKET))
		for by in range(y0, y1 + 1):
			for bx in range(x0, x1 + 1):
				var k := Vector2i(bx, by)
				var arr: PackedInt32Array = _vec_buckets.get(k, PackedInt32Array())
				arr.append(i)
				_vec_buckets[k] = arr
	print("[矢量] %d 环 / %d 点，加载 %d ms" % [nr, _vec_pts.size() / 2, Time.get_ticks_msec() - t0])


func _draw_vec_terrain() -> void:
	if not _vec_on:
		return
	if map_zoom < VEC_ZOOM:
		return
	if not _vec_loaded:
		_load_vec_terrain()
	if _vec_cls.is_empty():
		return
	# 交叉淡入：60 倍刚出现是半透明，84 倍以上完全不透明
	var alpha: float = clampf((map_zoom - VEC_ZOOM) / VEC_FADE + 0.25, 0.0, 1.0)
	# 矢量全不透明时把下面的光栅图藏掉，避免多边形之间的缝里露出方块
	if _map_shader_ok:
		map_surface.visible = alpha < 0.999
	# 纯色纸底（高倍不再填地形色，只画轮廓线）——古地图的"素底"。
	var paper_bg := Color(0.90, 0.86, 0.74, alpha)
	map_root.draw_rect(Rect2(_vec_org, Vector2(360.0 * _vec_ppd, LAT_LIMIT * 2.0 * _vec_ppy)), paper_bg)
	# 纸纹：一层很淡的纤维噪点，让素底不像纯色块
	map_root.draw_texture_rect(_paper_tex(), Rect2(_vec_org,
			Vector2(360.0 * _vec_ppd, LAT_LIMIT * 2.0 * _vec_ppy)), true,
			Color(1, 1, 1, 0.55 * alpha))
	var water_col: Color = LFDB.COLORS[11]
	water_col = Color(water_col.r, water_col.g, water_col.b, alpha * 0.55)
	var ink := Color(0.24, 0.17, 0.10, alpha * 0.62)
	# 和贴图完全同一套变换：content_rect + 每度像素数
	var vs := get_viewport().get_visible_rect().size
	var sx := _vec_ppd
	var sy := _vec_ppy
	var lon_min: float = maxf((0.0 - _vec_org.x) / sx - 180.0, -180.0)
	var lon_max: float = minf((vs.x - _vec_org.x) / sx - 180.0, 180.0)
	var lat_max: float = minf(LAT_LIMIT - (0.0 - _vec_org.y) / sy, LAT_LIMIT)
	var lat_min: float = maxf(LAT_LIMIT - (vs.y - _vec_org.y) / sy, -LAT_LIMIT)
	var px2: float = sx * sy
	var min_area: float = 9.0 / maxf(px2, 1e-9)
	var cand := PackedInt32Array()
	if sx < 60.0:
		for i in _vec_order:
			var w: float = _vec_bbox[i * 4 + 2] - _vec_bbox[i * 4]
			var h: float = _vec_bbox[i * 4 + 3] - _vec_bbox[i * 4 + 1]
			if w * h < min_area:
				break
			cand.append(i)
	else:
		var seen := {}
		var bx0 := int(floor((lon_min + 180.0) / VEC_BUCKET))
		var bx1 := int(floor((lon_max + 180.0) / VEC_BUCKET))
		var by0 := int(floor((90.0 - lat_max) / VEC_BUCKET))
		var by1 := int(floor((90.0 - lat_min) / VEC_BUCKET))
		for by in range(by0, by1 + 1):
			for bx in range(bx0, bx1 + 1):
				var arr: PackedInt32Array = _vec_buckets.get(Vector2i(bx, by), PackedInt32Array())
				for i in arr:
					if not seen.has(i):
						seen[i] = true
						cand.append(i)
	var drawn := 0
	for i in cand:
		var bx0: float = _vec_bbox[i * 4]
		var by0: float = _vec_bbox[i * 4 + 1]
		var bx1: float = _vec_bbox[i * 4 + 2]
		var by1: float = _vec_bbox[i * 4 + 3]
		if bx1 < lon_min or bx0 > lon_max or by1 < lat_min or by0 > lat_max:
			continue
		var n := _vec_len[i]
		var st := _vec_start[i]
		var arr := PackedVector2Array()
		arr.resize(n)
		for k in n:
			var o := (st + k) * 2
			arr[k] = _vec_org + Vector2((_vec_pts[o] + 180.0) * sx, (LAT_LIMIT - _vec_pts[o + 1]) * sy)
		# 共享边界：把每个多边形沿法线往外扩一点点，相邻的就重叠，Chaikin 收缩造成的缝被盖住
		var area2 := 0.0
		for k in n:
			var a0 := _vec_pts[(_vec_start[i] + k) * 2]
			var a1 := _vec_pts[(_vec_start[i] + (k + 1) % n) * 2]
			var b0 := _vec_pts[(_vec_start[i] + k) * 2 + 1]
			var b1 := _vec_pts[(_vec_start[i] + (k + 1) % n) * 2 + 1]
			area2 += a0 * b1 - a1 * b0
		var sgn := 1.0 if area2 > 0.0 else -1.0
		var pad: float = 0.012 / maxf(sx, 0.001)
		for k in n:
			var o := (st + k) * 2
			var ox := _vec_pts[o]
			var oy := _vec_pts[o + 1]
			var op := (st + (k - 1 + n) % n) * 2
			var on := (st + (k + 1) % n) * 2
			var tx := _vec_pts[on] - _vec_pts[op]
			var ty := _vec_pts[on + 1] - _vec_pts[op + 1]
			var tl := maxf(sqrt(tx * tx + ty * ty), 1e-9)
			var nx := -ty / tl * sgn
			var ny := tx / tl * sgn
			arr[k] = _vec_org + Vector2((ox + nx * pad + 180.0) * sx, (LAT_LIMIT - (oy + ny * pad)) * sy)
		var vc: Color = LFDB.COLORS[_vec_cls[i]]
		# 和 shader 同一套：越放大越往纸色靠（最高 30%），地形只当底
		var pz: float = clampf((map_zoom - 3.0) / 50.0, 0.0, 1.0) * 0.30
		var lum: float = vc.r * 0.35 + vc.g * 0.45 + vc.b * 0.20
		var pap := Color(lum + 0.16, lum * 0.92 + 0.11, lum * 0.72 + 0.04)
		vc = vc.lerp(pap, pz)
		vc.a = alpha
		if _vec_cls[i] == 11:
			map_root.draw_colored_polygon(arr, water_col)
		if n >= 3:
			var closed := arr.duplicate()
			closed.append(arr[0])
			map_root.draw_polyline(closed, ink, 1.2, true)
		drawn += 1
	if _flags.has("--vecdbg"):
		print("[矢量] 画 %d/%d 环 视图 lon %.1f..%.1f lat %.1f..%.1f sc=%.2f" % [
				drawn, cand.size(), lon_min, lon_max, lat_min, lat_max, sx])
		for qi in mini(3, cand.size()):
			var q := cand[qi]
			var o0 := _vec_start[q] * 2
			print("  环%d cls=%d n=%d bbox %.2f,%.2f..%.2f,%.2f 首点 %.2f,%.2f" % [
					q, _vec_cls[q], _vec_len[q], _vec_bbox[q*4], _vec_bbox[q*4+1],
					_vec_bbox[q*4+2], _vec_bbox[q*4+3], _vec_pts[o0], _vec_pts[o0+1]])


## 纸张纤维纹理（一次生成，平铺）
static var _paper_tex_cache: ImageTexture


func _paper_tex() -> ImageTexture:
	if _paper_tex_cache != null:
		return _paper_tex_cache
	var n := 128
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261120
	for y in n:
		for x in n:
			var v: float = rng.randf() * 0.5 + 0.5
			# 横向纤维：每 2 行拉长一点
			var fiber: float = rng.randf() * 0.06
			img.set_pixel(x, y, Color(0.88 + v * 0.06 + fiber, 0.84 + v * 0.05, 0.72 + v * 0.04, 1.0))
	_paper_tex_cache = ImageTexture.create_from_image(img)
	return _paper_tex_cache
