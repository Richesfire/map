class_name WorldGlobeView
extends Control

## ==============================================================
## 真实球体的地球仪（3D）
##
## 结构：
##   Control（占满屏幕）
##    └ SubViewportContainer（拉伸铺满）
##       └ SubViewport（自己的 3D 世界）
##          ├ Camera3D
##          ├ DirectionalLight3D + WorldEnvironment
##          ├ 底座/子午环（Static，不跟着转）
##          └ GlobePivot（可转）
##             └ SphereMesh（球面贴的就是地图）
##
## 【为什么用 3D 球而不是 shader 画圆】
##   之前是 canvas shader 按像素反算球面——旋转只改一个 uniform，
##   但那是"画出来的球"，没有体积、没有光影、不能有底座。
##   现在是真的球 + 真的光，转的是球体本身，底座纹丝不动。
## ==============================================================

const TEX_BAKED := "res://data/globe_tex.png"
const TEX_W := 512          # 等距圆柱贴图分辨率（一次性生成，约 2 秒）
const TEX_H := 256

signal texture_ready

var world: MapWorld

var _viewport: SubViewport
var _container: SubViewportContainer
var _cam: Camera3D
var _pivot: Node3D           # 自转（绕自身 Y）
var _sphere: MeshInstance3D
var _tex: Texture2D   # 烘焙读进来的是 CompressedTexture2D，现算兜底的是 ImageTexture
var _loading: Label

var _zoom := 1.0             # 滚轮缩放 0.6~2.6
const STATE_PATH := "user://globe_view.cfg"
var _spin_yaw := 0.0         # 绕竖轴，无限转
var _spin_pitch := 0.0       # 前后翻，限位 ±78°，不然南北极会颠倒
const PITCH_LIMIT := deg_to_rad(78.0)
var _orbit_yaw := 0.0        # 相机环绕：水平，无限
var _orbit_pitch := 0.0      # 相机环绕：俯仰，±78° 限位（否则会从球底下倒着看，南北颠倒是假的颠倒）
var _save_timer := 0.0


func _ready() -> void:
	# 资源提供者：默认程序生成；--file-tiles 时改读预制图片
	if "--file-tiles" in OS.get_cmdline_user_args():
		_provider = FileTextureProvider.new()
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_viewport()
	_build_scene()


func _build_viewport() -> void:
	_container = SubViewportContainer.new()
	_container.name = "GlobeContainer"
	_container.stretch = true
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	add_child(_container)

	_viewport = SubViewport.new()
	_viewport.name = "GlobeViewport"
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.msaa_3d = Viewport.MSAA_4X
	_container.add_child(_viewport)


func _build_scene() -> void:
	var root := Node3D.new()
	root.name = "GlobeScene"
	_viewport.add_child(root)

	# ---- 灯光：从左上打，球才有体积感
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-32.0, -38.0, 0.0)
	sun.light_energy = 1.7
	sun.shadow_enabled = false
	root.add_child(sun)

	# 补光：反方向再打一盏弱的。只有一盏方向光时，背光面暗成一团，会被误认成海洋。
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-18.0, 142.0, 0.0)
	fill.light_energy = 0.55
	fill.light_color = Color(0.78, 0.84, 1.0)
	fill.shadow_enabled = false
	root.add_child(fill)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.045, 0.07)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.30, 0.36, 0.46)
	env.ambient_light_energy = 1.25
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	root.add_child(we)

	# ---- 相机
	_cam = Camera3D.new()
	_cam.name = "GlobeCamera"
	# 地球仪用**正交投影**：透视相机 fov 最小 1°，
	# 换算下来最多只能放大 40 倍就卡死；正交用 size 控制，没有下限。
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = 3.31
	_cam.position = Vector3(0.0, 0.05, 4.55)   # 默认朝 -Z，正好对着原点
	root.add_child(_cam)

	# ---- 可转的球（没有底座、没有子午环、没有地轴倾角）
	_pivot = Node3D.new()
	_pivot.name = "GlobePivot"
	root.add_child(_pivot)

	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 96
	mesh.rings = 96
	_sphere = MeshInstance3D.new()
	_sphere.name = "Earth"
	_sphere.mesh = mesh
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/globe_surface.gdshader")
	mat.set_shader_parameter("albedo_tex", _placeholder_texture())
	_sphere.material_override = mat
	_pivot.add_child(_sphere)


	load_state()

	# 区域图生成进度条（只在生成时出现）
	_detail_bar = ProgressBar.new()
	_detail_bar.min_value = 0.0
	_detail_bar.max_value = 1.0
	_detail_bar.value = 0.0
	_detail_bar.show_percentage = false
	_detail_bar.custom_minimum_size = Vector2(360, 20)
	_detail_bar.size = Vector2(360, 20)
	_detail_bar.position = Vector2(60, 60)
	_detail_bar.visible = false
	add_child(_detail_bar)

	_detail_lbl = Label.new()
	_detail_lbl.position = Vector2(60, 36)
	_detail_lbl.visible = false
	add_child(_detail_lbl)

	_loading = Label.new()
	_loading.text = "生成地球纹理…"
	_loading.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	_loading.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_loading.add_theme_constant_override("outline_size", 4)
	_loading.position = Vector2(24, 24)
	add_child(_loading)


## 底座：一个立起来的子午环 + 立柱 + 底盘。全部静止。
func _placeholder_texture() -> ImageTexture:
	var img := Image.create(8, 4, false, Image.FORMAT_RGB8)
	img.fill(Color(0.20, 0.30, 0.18))
	return ImageTexture.create_from_image(img)


# ================================================================ 尺寸
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_apply_size()


func _apply_size() -> void:
	if not is_inside_tree():
		return
	if _container != null:
		_container.position = Vector2.ZERO
		_container.size = size
	if _viewport != null and _viewport.is_inside_tree() and size.x >= 1.0 and size.y >= 1.0:
		var want := Vector2i(int(size.x), int(size.y))
		if _viewport.size != want:
			_viewport.size = want


# ================================================================ 转动
## 只转球体本身：水平拖 = 绕极轴自转，竖直拖 = 前后倾（限幅）
func rotate_by(rel: Vector2) -> void:
	# 左右不限；上下夹在 ±78°，可以翻到接近极点，但不会把南北极翻过来
	# 符号必须是**加**：右拖要看到球面跟着往右走。
	# （相机环绕用的是减号 —— 相机往右移 ↔ 球往左转，两者方向相反，别抄反了。）
	# 灵敏度跟着视野走：放大后视野窄，同样的鼠标位移对应的角度要同比缩小，
	# 否则"轻轻一拖就飞出去"。
	var k := 1.0 / maxf(_zoom, 1.0)
	_spin_yaw += rel.x * 0.005 * k
	_spin_pitch = clampf(_spin_pitch + rel.y * 0.004 * k, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_rotation()
	_save_state_later()


## 空白处拖动：绕着球转相机（球不动，等于换个角度看）
## 屏幕坐标 -> 球面上的地理方向；没打中球返回 Vector3.ZERO
func pick(point: Vector2) -> Vector3:
	if _cam == null or _pivot == null:
		return Vector3.ZERO
	var from := _cam.project_ray_origin(point)
	var ray := _cam.project_ray_normal(point)
	var b := from.dot(ray)
	var c := from.dot(from) - 1.0
	var disc := b * b - c
	if disc < 0.0:
		return Vector3.ZERO
	var t := -b - sqrt(disc)
	if t < 0.0:
		t = -b + sqrt(disc)
	if t < 0.0:
		return Vector3.ZERO
	var hit := from + ray * t
	var local := _pivot.global_transform.basis.inverse() * hit
	return local.normalized()


## 把一个"在球背面看不见"的方向，投到球的轮廓边缘。
## 用方向在屏幕平面上的分量决定贴哪一边 —— 所以转动时它会沿着边缘滑动，
## 从左边贴着走、走过中线就自然换到右边，不会跳。


## 把一个"在球背面看不见"的方向，投到球的轮廓边缘。
## 用方向在屏幕平面上的分量决定贴哪一边 —— 所以转动时它会沿着边缘滑动，
## 从左边贴着走、走过中线就自然换到右边，不会跳。
func edge_point(dir: Vector3) -> Vector2:
	if _cam == null or _pivot == null:
		return Vector2.ZERO
	var center := _cam.unproject_position(Vector3.ZERO)
	var right_w := _cam.global_transform.basis.x
	var up_w := _cam.global_transform.basis.y
	# 轮廓半径：把屏幕右方向的世界单位向量投影出来，它到球心的距离就是像素半径
	var radius := center.distance_to(_cam.unproject_position(right_w))

	var w: Vector3 = _pivot.global_transform * dir.normalized()
	var v2 := Vector2(w.dot(right_w), w.dot(up_w))
	if v2.length() < 0.001:
		v2 = Vector2(1.0, 0.0)          # 正对/正背时没有方向，默认贴右边
	return center + v2.normalized() * radius


## 滚轮缩放：滚轮上 = 放大
## 当前缩放层级 0~3（0=全球，3=本地）
## 阈值按 _zoom（0.6~2.6）划分，滚动时逐级解锁更细的地名。
## 球心在屏幕上的位置（缩放限制按"视野中心"判断，而不是光标）
func center_screen() -> Vector2:
	# 用视口中心，而不是控件坐标：
	# 相机永远看向球心，所以球心就投影在视口正中。用控件坐标会因为
	# 控件偏移而算错位置，导致"明明去过却提示未探索、放不大"。
	return get_viewport().get_visible_rect().size * 0.5


## 迷雾贴图（2048x1024，约 10km 一个像素）。1 = 已探索
const FOG_W := 8192
const FOG_H := 4096
## 放大到一定倍数后，用一块"切平面高清图"盖住糊掉的球面
const DETAIL_MIN_ZOOM := 7.0   # 降到 7 倍：再大就会看到全球贴图的马赛克
const DETAIL_PX := 768  # 整块覆盖全屏，像素数必须接近屏幕分辨率，否则必然糊
const DETAIL_CACHE := "user://region_cache"
const DETAIL_LADDER := [0.05, 0.1, 0.2, 0.4, 0.8, 1.6, 3.2, 6.4]

var _provider: MapTextureProvider = RectTextureProvider.new()
var _cur_rect_key := ""
var _prebaked: Array = []      # 离线烘焙好的大块区域 {lon0, lat0, span, tex}
var _prebaked_loaded := false
var _gen_key := ""
var _gen_rect := Vector4.ZERO
var _zoom_idle := 0.0   # 距离上次滚轮的秒数
var _tiles: Array = []
var _generating := false
var _gen_tile := Vector2.ZERO
var _gen_deg := 1.0
var _gen_lvl := 0
var _job_done_lonlat := Vector2(-999, -999)   # 已铺好的瓦片格号
var _job_done_half := 0.0
var _annot_center := Vector2.INF   # 玩家所在经纬度，预加载按远近排                       # 该瓦片的跨度
var _detail_bar: ProgressBar
var _detail_lbl: Label


var _fog_img: Image
var _fog_tex: ImageTexture


## 从探索记录重建迷雾贴图。只遍历格子（几千个），不遍历像素，所以很快。
func refresh_fog(exp: Exploration) -> void:
	if exp == null:
		return
	if _fog_img == null:
		_fog_img = Image.create(FOG_W, FOG_H, false, Image.FORMAT_L8)
		_fog_img.fill(Color(0, 0, 0))
		_fog_tex = ImageTexture.create_from_image(_fog_img)

	# 每次都要重新绑定：第一次调用时球体可能还没建好，
	# 若只在创建时设一次，uniform 就永远是空的（采样成黑色 = 全迷雾）。
	if _sphere != null and _sphere.material_override is ShaderMaterial:
		(_sphere.material_override as ShaderMaterial).set_shader_parameter("fog_tex", _fog_tex)

	# 先把旧的白点清掉：只清上一帧画过的格子，成本随格子数
	for k in exp.cells.keys():
		var parts: PackedStringArray = String(k).split("_")
		if parts.size() != 2:
			continue
		var lon: float = float(int(parts[0])) * Exploration.CELL_DEG
		var lat: float = float(int(parts[1])) * Exploration.CELL_DEG
		var u := fposmod(lon + 180.0, 360.0) / 360.0
		var v := (90.0 - lat) / 180.0
		var x := clampi(int(u * FOG_W), 0, FOG_W - 1)
		var y := clampi(int(v * FOG_H), 0, FOG_H - 1)
		# 迷雾图是 10km 一格，1km 的足迹不到一个像素，
		# 所以每个格子画成 3x3 的小方块，玩家才看得出"这里去过了"。
		# 照亮半径 10km，会覆盖成片的格子；每格点一个像素即可，
		# 放大成 3x3 反而会把范围夸大到 13km。
		_fog_img.set_pixel(x, y, Color(1, 1, 1))

	_fog_tex.update(_fog_img)



func set_fog_enabled(on: bool) -> void:
	if _sphere != null and _sphere.material_override is ShaderMaterial:
		(_sphere.material_override as ShaderMaterial).set_shader_parameter("fog_enabled", 1.0 if on else 0.0)


func get_zoom() -> float:
	return _zoom


func zoom_level() -> int:
	if _zoom < 1.6:
		return 0
	if _zoom < 6.0:
		return 1
	if _zoom < 25.0:
		return 2
	return 3


func zoom_by(steps: float) -> void:
	_zoom_idle = 0.0
	_zoom = clampf(_zoom * (1.0 + steps * 0.35), 0.6, 4000.0)
	# 只改 FOV，不碰相机位置。
	# （之前这里写着 _cam.position.z = 4.55/_zoom —— 它既把透视改坏，
	#   又会把环绕角度冲掉，等于缩放一下视角就归位了。）
	_apply_orbit()
	_save_state_later()


## 屏幕坐标 -> 球面上的地理方向；没打中球返回 Vector3.ZERO


func get_camera_z() -> float:
	return _cam.position.z if _cam != null else 0.0


## 空白处拖动：绕着球转相机（球不动，等于换个角度看）


func orbit_by(rel: Vector2) -> void:
	# 和球体一样：水平无限，俯仰限位。相机永远不会钻到球的正下方，
	# 所以"南北极颠倒"这件事不可能发生。
	# 和球体拖动用同一套系数与缩放补偿，手感才一致
	# 这是原本"拖球体外拖动"的手感（0.005 / 0.004），球面拖动也统一成这套
	var k := 1.0 / maxf(_zoom, 1.0)
	_orbit_yaw -= rel.x * 0.005 * k
	_orbit_pitch = clampf(_orbit_pitch - rel.y * 0.004 * k, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_orbit()
	_save_state_later()


func _apply_orbit() -> void:
	if _cam == null or not _cam.is_inside_tree():
		return
	var dist := 4.55
	var pivot := Vector3(0.0, 0.05, 0.0)
	# 先绕竖轴，再绕世界 X 俯仰（受限）
	var b := Basis(Vector3.RIGHT, _orbit_pitch) * Basis(Vector3.UP, _orbit_yaw)
	var pos: Vector3 = b * Vector3(0.0, 0.0, dist)
	_cam.position = pivot + pos
	_cam.look_at(pivot, Vector3.UP)
	if _cam != null:
		_cam.size = 3.31 / _zoom


func save_state() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("globe", "spin_yaw", _spin_yaw)
	cfg.set_value("globe", "spin_pitch", _spin_pitch)
	cfg.set_value("globe", "orbit_yaw", _orbit_yaw)
	cfg.set_value("globe", "orbit_pitch", _orbit_pitch)
	cfg.set_value("globe", "zoom", _zoom)
	cfg.save(STATE_PATH)


func load_state() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(STATE_PATH) != OK:
		return
	_spin_yaw = float(cfg.get_value("globe", "spin_yaw", _spin_yaw))
	_spin_pitch = clampf(float(cfg.get_value("globe", "spin_pitch", _spin_pitch)),
			-PITCH_LIMIT, PITCH_LIMIT)
	_orbit_yaw = float(cfg.get_value("globe", "orbit_yaw", _orbit_yaw))
	_orbit_pitch = clampf(float(cfg.get_value("globe", "orbit_pitch", _orbit_pitch)),
			-PITCH_LIMIT, PITCH_LIMIT)
	_zoom = clampf(float(cfg.get_value("globe", "zoom", _zoom)), 0.6, 4000.0)
	_apply_rotation()
	_apply_orbit()


func _save_state_later() -> void:
	if _save_timer > 0.0:
		return
	_save_timer = 0.8      # 停手 0.8 秒后再写盘，别每帧写


func _process(delta: float) -> void:
	_zoom_idle += delta
	_update_detail_new()
	if _save_timer > 0.0:
		_save_timer -= delta
		if _save_timer <= 0.0:
			save_state()


## 把球面上的某个方向转到正前方。
## 缩放前调用，就等于"朝鼠标所指的地方放大"（导航软件的行为）。
## 放大时把光标所指的点往中心挪一小部分，而不是一把拽到正中间。
## ratio = 1 - 1/放大倍数：放大 20% 就只挪 17%，光标下的位置基本不动。
func focus_toward(dir: Vector3, ratio: float) -> void:
	var v := dir.normalized()
	var r := sqrt(v.x * v.x + v.z * v.z)
	if r < 0.0001:
		return
	var ty := atan2(-v.x, v.z)
	var tp := clampf(atan2(v.y, r), -PITCH_LIMIT, PITCH_LIMIT)
	# 取最短方向（角度差折回 -PI..PI）
	var dy := wrapf(ty - _spin_yaw, -PI, PI)
	var dp := tp - _spin_pitch
	_spin_yaw += dy * ratio
	_spin_pitch = clampf(_spin_pitch + dp * ratio, -PITCH_LIMIT, PITCH_LIMIT)
	_apply_rotation()
	_save_state_later()


func focus_on(dir: Vector3) -> void:
	var v := dir.normalized()
	var r := sqrt(v.x * v.x + v.z * v.z)
	if r < 0.0001:
		return                      # 正对极点时水平方向没有意义，跳过
	_spin_yaw = atan2(-v.x, v.z)
	_spin_pitch = clampf(atan2(v.y, r), -PITCH_LIMIT, PITCH_LIMIT)
	_apply_rotation()
	_save_state_later()


## 看清当前球心所指的区域：放大够深就铺一块高清切平面。
## 生成是**分帧**做的：每帧只算 48 行，避免卡住（一张图约 20 帧完成）。
func _apply_rotation() -> void:
	if _pivot == null:
		return
	# 分成两级：倾角绕世界 X，自转绕自身 Y，两者不互相污染
	# 先绕竖轴转，再绕世界 X 前后翻 —— 顺序固定，俯仰受限，所以极轴永远不会倒过来
	_pivot.basis = Basis(Vector3.RIGHT, _spin_pitch) * Basis(Vector3.UP, _spin_yaw)


## 让某个地理方向正对镜头
func face_direction(dir: Vector3) -> void:
	var p := dir.normalized()
	# 自由滚动之后，"正对镜头"就是绕竖轴把 p 转到前方
	_spin_yaw = -atan2(p.x, p.z)
	_spin_pitch = clampf(asin(clampf(p.y, -1.0, 1.0)), -PITCH_LIMIT, PITCH_LIMIT)
	_apply_rotation()


# ================================================================ 投影
## 地理方向 -> 控件坐标；球背面返回 (-1,-1)
func project(dir: Vector3) -> Vector2:
	if _cam == null or _sphere == null:
		return Vector2(-1.0, -1.0)
	# 方向是球体局部空间里的位置，转到世界再投影
	var local := dir.normalized() * 1.004
	var world_pos: Vector3 = _pivot.global_transform * local
	var cam_pos: Vector3 = _cam.global_position
	# 背面剔除：法线（球心指向该点）背对相机
	var n: Vector3 = (world_pos - _sphere.global_position).normalized()
	var to_cam: Vector3 = (cam_pos - world_pos).normalized()
	if n.dot(to_cam) <= 0.02:
		return Vector2(-1.0, -1.0)
	return _cam.unproject_position(world_pos)


# ================================================================ 世界贴图
## 一次性把地球采样成等距圆柱贴图，并把经纬网画进去（否则纯噪声看不出在转）
const MASK_PATH := "res://data/earth_land_mask.png"


## 一次性把地球采样成等距圆柱贴图：
## 海陆来自 Natural Earth 110m 海岸线（公有领域）栅格化出来的掩膜，
## 陆地按地形高度着色（低=绿，高=土黄/灰），极地加冰盖，海洋按"海底高度"给深浅。
## 地形类型的显示颜色（地球仪和小地图共用同一套，避免两边对不上）
const BIOME_COLORS := {
	"ocean": Color(0.055, 0.145, 0.290),
	"ice": Color(0.930, 0.950, 0.970),
	"tundra": Color(0.520, 0.560, 0.480),
	"alpine": Color(0.760, 0.760, 0.740),
	"mountain": Color(0.520, 0.470, 0.400),
	"hills": Color(0.400, 0.470, 0.250),
	"forest": Color(0.180, 0.330, 0.170),
	"jungle": Color(0.110, 0.360, 0.140),
	"savanna": Color(0.620, 0.600, 0.280),
	"steppe": Color(0.640, 0.610, 0.370),
	"desert": Color(0.820, 0.720, 0.450),
	"badland": Color(0.680, 0.620, 0.540),
	"marsh": Color(0.250, 0.350, 0.280),
	"plain": Color(0.330, 0.470, 0.230),
	"inland_water": Color(0.130, 0.330, 0.480),
}


## 一次性把地球采样成等距圆柱贴图：**按生物群系上色**。
## 这是验证"全球分布合不合理"最直接的方式——按一次 M 就能看整张世界图，
## 而不是骑马跑 31 天。
func build_world_texture() -> void:
	if world == null or world.gen == null:
		return
	var t0 := Time.get_ticks_msec()

	# 优先读预烘焙的贴图：启动 0 等待，画质由烘焙分辨率决定
	if ResourceLoader.exists(TEX_BAKED):
		var tex := load(TEX_BAKED) as Texture2D
		if tex != null:
			_tex = tex
			# 材质现在是 ShaderMaterial，必须走 uniform（这里以前只处理
			# StandardMaterial3D 而且赋值后就 return，导致贴图永远贴不上）
			if _sphere != null and _sphere.material_override is ShaderMaterial:
				(_sphere.material_override as ShaderMaterial).set_shader_parameter("albedo_tex", _tex)
			if _loading != null:
				_loading.text = "拖动旋转 · 滚轮缩放 · Esc / M 关闭"
			print("[Globe] 使用预烘焙贴图 %s（%d ms）" % [TEX_BAKED, Time.get_ticks_msec() - t0])
			texture_ready.emit()
			return

	# 兜底：没有烘焙文件就现算低清版（保证功能可用，但会糊）
	var img := make_world_image(world, TEX_W, TEX_H)
	img.generate_mipmaps()
	_tex = ImageTexture.create_from_image(img)
	if _sphere != null and _sphere.material_override is ShaderMaterial:
		(_sphere.material_override as ShaderMaterial).set_shader_parameter("albedo_tex", _tex)
		var got: Variant = (_sphere.material_override as ShaderMaterial).get_shader_parameter("albedo_tex")
		print("[MATDBG] 赋值后 材质里的尺寸=%s 同一对象=%s" % [
				str(got.get_width()) + "x" + str(got.get_height()) if got != null else "null",
				str(got == _tex)])
	if _loading != null:
		_loading.text = "拖动旋转 · 滚轮缩放 · Esc / M 关闭"
	print("[Globe] 现算贴图 %dx%d：%d ms（建议跑 --bake-globe 烘焙高清版）"
			% [TEX_W, TEX_H, Time.get_ticks_msec() - t0])
	texture_ready.emit()


## 烘焙：把高清贴图写到 path。改过群系参数后跑一次即可。
func bake_to(path: String, w: int, h: int) -> void:
	if world == null or world.gen == null:
		push_error("[Globe] world 还没准备好，无法烘焙")
		return
	var t0 := Time.get_ticks_msec()
	var img := make_world_image(world, w, h)
	var err := img.save_png(path)
	print("[Globe] 烘焙 %dx%d -> %s（%d ms，err=%d）" % [w, h, path, Time.get_ticks_msec() - t0, err])


## 把整个地球采成等距圆柱贴图（纯函数，烘焙和运行时共用）
static func make_world_image(world: MapWorld, w: int, h: int) -> Image:
	var mask: Image = null
	var mask_tex := load(MASK_PATH) as Texture2D
	if mask_tex != null:
		mask = mask_tex.get_image()
	else:
		push_warning("[Globe] 找不到海陆掩膜 %s" % MASK_PATH)

	var bm := BiomeMap.new()
	bm.setup(world.gen, mask)

	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var counts := {}

	for y in h:
		var lat := 90.0 - (float(y) + 0.5) / float(h) * 180.0
		var lat_line := _near_multiple(lat, 30.0, 0.9)
		for x in w:
			var lon := _lon_of_x_at(x, w)
			var dir := GeoSphere.lonlat_to_dir(lon, lat)
			var bid := bm.biome_at_ll(dir, lon, lat)
			counts[bid] = counts.get(bid, 0) + 1

			var c: Color = BIOME_COLORS.get(bid, Color(0.5, 0.5, 0.5))
			if bid != "ocean":
				var hh := world.get_height_dir(dir)
				var shade := clampf(0.82 + hh / 600.0, 0.82, 1.12)
				c = Color(c.r * shade, c.g * shade, c.b * shade)

			# 经纬网直接在这里叠，省掉后面两遍全图遍历
			if lat_line or _near_multiple(lon, 30.0, 0.9):
				c = c.lerp(Color(0.9, 0.93, 0.97), 0.22)

			img.set_pixel(x, y, c)

	# 分布统计
	var total := float(w * h)
	var keys := counts.keys()
	keys.sort_custom(func(a, b): return counts[a] > counts[b])
	for k in keys:
		print("  %-6s %-5s %5.2f%%" % [k, bm.name_of(k), float(counts[k]) / total * 100.0])
	return img

## 贴图第 x 列应该填哪个经度。
## Godot 的 SphereMesh：uv.x = 1 - atan2(x, z) / 2π，
## 而我们的经纬约定是 x=cos(lat)cos(lon), z=-cos(lat)sin(lon)，代入得 atan2 = lon + 90°，
## 所以 uv.x = 1 - (lon + 90)/360，反解即可。
## 任意宽度版本（烘焙用 2048，运行时兜底用 512）
static func _lon_of_x_at(x: int, w: int) -> float:
	# Godot SphereMesh：x = sin(u·2π)·w, z = cos(u·2π)·w, uv = (u, v)
	# u = (lon + 90) / 360
	var u := (float(x) + 0.5) / float(w)
	return u * 360.0 - 90.0


static func _lon_of_x(x: int) -> float:
	# Godot SphereMesh：x = sin(u·2π)·w, z = cos(u·2π)·w, uv = (u, v)
	# 我们的经纬约定 x = cos(lat)cos(lon), z = -cos(lat)sin(lon)
	# 代入得 u = (lon + 90) / 360 —— 之前多写了个 1.0 - u，整张图东西镜像了。
	var u := (float(x) + 0.5) / float(TEX_W)
	return u * 360.0 - 90.0


static func _near_multiple(v: float, step: float, tol: float) -> bool:
	var m := fmod(absf(v), step)
	return m < tol or m > step - tol


## 生成进度：让玩家看到在算什么，而不是莫名卡一下
func _show_progress(t: float) -> void:
	if _detail_bar == null or _detail_lbl == null:
		return
	_detail_bar.visible = true
	_detail_lbl.visible = true
	_detail_bar.value = t
	_detail_lbl.text = "生成区域地图… %d%%" % int(t * 100.0)


func _hide_progress() -> void:
	if _detail_bar != null:
		_detail_bar.visible = false
	if _detail_lbl != null:
		_detail_lbl.visible = false


## 区域高清叠加：放大够深时，生成一块覆盖可见范围的图，交给 shader 替换底图。
## 不走独立物体，直接复用球面渲染，避免"新加的物体不显示"。
func _update_detail_new() -> void:
	if _zoom < DETAIL_MIN_ZOOM:
		if _sphere != null and _sphere.material_override is ShaderMaterial:
			(_sphere.material_override as ShaderMaterial).set_shader_parameter("detail_count", 0.0)
		_hide_progress()
		return

	var center := _cam.global_transform.basis.z
	center = (_pivot.global_transform.basis.inverse() * center).normalized()
	var ll := GeoSphere.dir_to_lonlat(center)

	# ---- 视野矩形（含余量），整块生成，不切瓦片 ----
	var aspect := 1.78
	if _viewport != null and _viewport.size.y > 0:
		aspect = float(_viewport.size.x) / float(_viewport.size.y)
	var half_h := rad_to_deg(3.31 / _zoom) * 0.5 * 1.20     # 20% 余量
	var half_w := half_h * aspect
	var cos_lat := maxf(cos(deg_to_rad(ll.y)), 0.15)

	var lon0 := ll.x - half_w / cos_lat
	var lon1 := ll.x + half_w / cos_lat
	var lat0 := maxf(ll.y - half_h, -89.0)
	var lat1 := minf(ll.y + half_h, 89.0)

	# 矩形对齐到网格（约 1/8 视野），便于缓存复用
	var step_deg := maxf(half_h * 2.0 * 0.25, 0.002)
	lon0 = floor(lon0 / step_deg) * step_deg
	lon1 = ceil(lon1 / step_deg) * step_deg
	lat0 = floor(lat0 / step_deg) * step_deg
	lat1 = ceil(lat1 / step_deg) * step_deg
	var key := "%d_%d_%d_%d" % [int(lon0 * 1000), int(lat0 * 1000),
			int((lon1 - lon0) * 1000), int((lat1 - lat0) * 1000)]

	if key == _cur_rect_key:
		return

	var prov := _provider as RectTextureProvider
	if prov == null:
		return

	# 0) 离线烘焙的大块区域优先（覆盖当前视野就直接用，零等待）
	_load_prebaked()
	# 在所有能覆盖当前视野的预烘焙块里，挑**跨度最小**的那块（密度最高）
	var best: Dictionary = {}
	for pb in _prebaked:
		var pl0: float = pb["lon0"]
		var pb0: float = pb["lat0"]
		var ps: float = pb["span"]
		if lon0 >= pl0 and lon1 <= pl0 + ps and lat0 >= pb0 and lat1 <= pb0 + ps:
			if best.is_empty() or ps < float(best["span"]):
				best = pb
	if not best.is_empty():
		var bl0: float = best["lon0"]
		var bb0: float = best["lat0"]
		var bs: float = best["span"]
		_apply_detail(best["tex"], bl0, bl0 + bs, bb0, bb0 + bs)
		_cur_rect_key = key
		return

	# 1) 磁盘缓存
	var cached: Image = prov.try_cached_rect(key)
	if cached != null:
		_apply_detail(cached, lon0, lon1, lat0, lat1)
		_cur_rect_key = key
		return

	# 2) 现算（分帧）；滚动中不触发，停 0.35 秒后才算
	if not _generating and _zoom_idle >= 0.35:
		prov.begin_rect(world, lon0, lat0, lon1, lat1, DETAIL_PX, key)
		_generating = true
		_gen_key = key
		_gen_rect = Vector4(lon0, lat0, lon1, lat1)
		_show_progress(0.0)

	var prog: float = prov.step(24)
	_show_progress(prog)
	if prov.is_done():
		var img: Image = prov.take()
		_generating = false
		_hide_progress()
		if img != null:
			prov.save_rect(_gen_key, img)
			_apply_detail(img, _gen_rect.x, _gen_rect.z, _gen_rect.y, _gen_rect.w)
			_cur_rect_key = _gen_key


func _make_tile(lvl: int, x: int, y: int, img: Image) -> Dictionary:
	var tile_deg := 360.0 / pow(2.0, float(lvl))
	return {
		"key": "%d_%d_%d" % [lvl, x, y],
		"lvl": lvl,
		"tex": ImageTexture.create_from_image(img),
		"lo": Vector2(((x * tile_deg) + 90.0) / 360.0,
				(90.0 - ((y + 1) * tile_deg)) / 180.0),
		"hi": Vector2((((x + 1) * tile_deg) + 90.0) / 360.0,
				(90.0 - (y * tile_deg)) / 180.0),
	}


func _push_tiles() -> void:
	if _sphere == null or not (_sphere.material_override is ShaderMaterial):
		return
	var m := _sphere.material_override as ShaderMaterial
	m.set_shader_parameter("detail_count", float(min(_tiles.size(), 4)))
	for i in 4:
		if i < _tiles.size():
			var t: Dictionary = _tiles[i]
			m.set_shader_parameter("d%d" % i, t["tex"])
			m.set_shader_parameter("d%d_min" % i, t["lo"])
			m.set_shader_parameter("d%d_max" % i, t["hi"])



func _apply_detail(img: Image, lon0: float, lon1: float, lat0: float, lat1: float) -> void:
	if _sphere == null or not (_sphere.material_override is ShaderMaterial):
		return
	var m := _sphere.material_override as ShaderMaterial
	m.set_shader_parameter("detail_tex", ImageTexture.create_from_image(img))
	# UV：u = (lon+90)/360，v = (90-lat)/180
	m.set_shader_parameter("detail_uv_min", Vector2((lon0 + 90.0) / 360.0, (90.0 - lat1) / 180.0))
	m.set_shader_parameter("detail_uv_max", Vector2((lon1 + 90.0) / 360.0, (90.0 - lat0) / 180.0))
	m.set_shader_parameter("detail_enabled", 1.0)
	print("[Detail] 叠加 %.2f~%.2f°E  %.2f~%.2f°N" % [lon0, lon1, lat0, lat1])


## ==============================================================
## 预加载：开局（黑屏过渡里）把已探索区域各层级的瓦片一次性生成好。
##
## 这样在地图上缩放时永远命中缓存，不会出现"边看边算"的卡顿和穿帮。
## 只处理已探索区域——没去过的地方按设计本来就不该有细节。
## ==============================================================
const PRELOAD_LEVELS := [8, 9, 10, 11, 12]
const PRELOAD_CAP := 40  # 层级全，一次补完；每张约 0.9 秒            # 一次最多生成多少张，防止开局过久


## 返回需要处理的瓦片列表，交给调用方逐张推进
func plan_preload(exp: Exploration) -> Array:
	var plan: Array = []
	if exp == null or exp.cells.is_empty():
		return plan

	# 1) 把已探索格子按 z8 粗网格聚类（1.4° 一格）
	var groups := {}
	for k in exp.cells.keys():
		var parts: PackedStringArray = String(k).split("_")
		if parts.size() != 2:
			continue
		var lon: float = float(int(parts[0])) * Exploration.CELL_DEG
		var lat: float = float(int(parts[1])) * Exploration.CELL_DEG
		var gx := int(floor(lon / 1.40625))
		var gy := int(floor(lat / 1.40625))
		groups[Vector2i(gx, gy)] = true

	# 2) 聚类按离玩家由近到远排序：先补真正会看到的地方
	var origin := Vector2i.ZERO
	if _annot_center != Vector2.INF:
		origin = Vector2i(int(floor(_annot_center.x / 1.40625)), int(floor(_annot_center.y / 1.40625)))
	var ordered := groups.keys()
	ordered.sort_custom(func(a, b):
		return Vector2(a - origin).length() < Vector2(b - origin).length())

	for g in ordered:
		var gv := g as Vector2i
		var lon := gv.x * 1.40625
		var lat := gv.y * 1.40625
		for lvl in PRELOAD_LEVELS:
			var tile_deg := 360.0 / pow(2.0, float(lvl))
			var x := int(floor(lon / tile_deg))
			var y := int(floor(lat / tile_deg))
			var key := "%d_%d_%d" % [lvl, x, y]
			if plan.has(key):
				continue
			var path := "%s/z%02d_x%d_y%d.png" % [DETAIL_CACHE, lvl, x, y]
			if not FileAccess.file_exists(path):
				plan.append({"level": lvl, "x": x, "y": y, "key": key})
			if plan.size() >= PRELOAD_CAP:
				return plan
	return plan


## 生成一张瓦片（同步、整张）。预加载用，调用方负责显示进度。
func bake_tile_now(level: int, x: int, y: int) -> void:
	var tile_deg := 360.0 / pow(2.0, float(level))
	var img := Image.create(DETAIL_PX, DETAIL_PX, false, Image.FORMAT_RGB8)
	var px := DETAIL_PX
	var lon0 := x * tile_deg
	var lat0 := y * tile_deg
	var lon1 := lon0 + tile_deg
	var lat1 := lat0 + tile_deg
	var hs := PackedFloat32Array()
	hs.resize(px * px)
	for j in px:
		var lat := lerpf(lat1, lat0, float(j) / float(px - 1))
		for i in px:
			var lon := lerpf(lon0, lon1, float(i) / float(px - 1))
			var d := GeoSphere.lonlat_to_dir(lon, lat)
			hs[j * px + i] = world.get_height_dir(d)
	var light := Vector3(-0.55, 0.62, 0.56).normalized()
	var spacing := absf(tile_deg) * 111000.0 / float(px)
	for j in px:
		for i in px:
			var h := hs[j * px + i]
			var c: Color
			if h < 0.0: c = Color(0.10, 0.22, 0.38)
			elif h < 30.0: c = Color(0.26, 0.42, 0.28)
			elif h < 70.0: c = Color(0.32, 0.46, 0.27)
			elif h < 120.0: c = Color(0.38, 0.49, 0.27)
			elif h < 200.0: c = Color(0.46, 0.51, 0.29)
			elif h < 320.0: c = Color(0.55, 0.54, 0.34)
			elif h < 600.0: c = Color(0.62, 0.52, 0.38)
			elif h < 1000.0: c = Color(0.58, 0.50, 0.46)
			else: c = Color(0.86, 0.86, 0.84)
			if h >= 0.0:
				var il := maxi(i - 1, 0)
				var ir := mini(i + 1, px - 1)
				var jd := maxi(j - 1, 0)
				var ju := mini(j + 1, px - 1)
				var dx := (hs[j * px + ir] - hs[j * px + il]) / (2.0 * spacing) * 8.0
				var dz := (hs[ju * px + i] - hs[jd * px + i]) / (2.0 * spacing) * 8.0
				var n := Vector3(-dx, 1.0, -dz).normalized()
				var lit := clampf(n.dot(light) * 1.4, 0.45, 1.35)
				c = Color(c.r * lit, c.g * lit, c.b * lit)
			img.set_pixel(i, j, c)
	DirAccess.make_dir_recursive_absolute(DETAIL_CACHE)
	img.save_png("%s/z%02d_x%d_y%d.png" % [DETAIL_CACHE, level, x, y])


## 载入 res://data/prebaked/ 下离线烘焙好的区域图（带 .json 描述矩形）
func _load_prebaked() -> void:
	if _prebaked_loaded:
		return
	_prebaked_loaded = true
	const DIR := "res://data/prebaked"
	if not DirAccess.dir_exists_absolute(DIR):
		return
	for f in DirAccess.get_files_at(DIR):
		if not f.ends_with(".json"):
			continue
		var txt := FileAccess.get_file_as_string("%s/%s" % [DIR, f])
		var m: Variant = JSON.parse_string(txt)
		if typeof(m) != TYPE_DICTIONARY:
			continue
		var png := "%s/%s.png" % [DIR, f.get_basename()]
		if not ResourceLoader.exists(png):
			continue
		_prebaked.append({
			"lon0": float(m.get("lon0", 0.0)),
			"lat0": float(m.get("lat0", 0.0)),
			"span": float(m.get("span", 1.0)),
			"tex": load(png),
		})
		print("[Prebaked] %s  覆盖 %.1f°" % [f.get_basename(), float(m.get("span", 0.0))])
