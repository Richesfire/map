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

const TEX_W := 512          # 等距圆柱贴图分辨率（一次性生成，约 2 秒）
const TEX_H := 256

signal texture_ready

var world: MapWorld

var _viewport: SubViewport
var _container: SubViewportContainer
var _cam: Camera3D
var _tilt_node: Node3D       # 前后倾（绕世界 X，不受自转影响）
var _pivot: Node3D           # 自转（绕自身 Y）
var _sphere: MeshInstance3D
var _tex: ImageTexture
var _loading: Label

var _zoom := 1.0             # 滚轮缩放 0.6~2.6
var _spin := 0.0             # 绕极轴自转（弧度）
var _tilt := 0.0             # 前后倾（弧度，限幅）
var _pivot_base_tilt := 0.0   # 地轴竖直，底座不倾


func _ready() -> void:
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
	_cam.fov = 40.0
	_cam.position = Vector3(0.0, 0.05, 4.55)   # 默认朝 -Z，正好对着原点
	root.add_child(_cam)

	# ---- 底座 + 子午环（静止，不跟球转）
	_build_stand(root)

	# ---- 可转的球
	_tilt_node = Node3D.new()
	_tilt_node.name = "GlobeTilt"
	root.add_child(_tilt_node)

	_pivot = Node3D.new()
	_pivot.name = "GlobePivot"
	_tilt_node.add_child(_pivot)

	var mesh := SphereMesh.new()
	mesh.radius = 1.0
	mesh.height = 2.0
	mesh.radial_segments = 96
	mesh.rings = 48
	_sphere = MeshInstance3D.new()
	_sphere.name = "Earth"
	_sphere.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _placeholder_texture()
	mat.roughness = 0.88
	mat.metallic = 0.0
	mat.metallic_specular = 0.35
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_sphere.material_override = mat
	_pivot.add_child(_sphere)

	_loading = Label.new()
	_loading.text = "生成地球纹理…"
	_loading.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
	_loading.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_loading.add_theme_constant_override("outline_size", 4)
	_loading.position = Vector2(24, 24)
	add_child(_loading)


## 底座：一个立起来的子午环 + 立柱 + 底盘。全部静止。
func _build_stand(root: Node3D) -> void:
	var stand := Node3D.new()
	stand.name = "Stand"
	stand.rotation.z = _pivot_base_tilt
	root.add_child(stand)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.13, 0.10)
	mat.metallic = 0.75
	mat.roughness = 0.35

	# 子午环（竖着套住球的圆环）
	var torus := TorusMesh.new()
	torus.inner_radius = 1.10
	torus.outer_radius = 1.16
	torus.rings = 64
	torus.ring_segments = 12
	var ring := MeshInstance3D.new()
	ring.name = "MeridianRing"
	ring.mesh = torus
	ring.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	ring.material_override = mat
	stand.add_child(ring)

	# 立柱
	var stem_mesh := CylinderMesh.new()
	stem_mesh.top_radius = 0.05
	stem_mesh.bottom_radius = 0.07
	stem_mesh.height = 0.42
	stem_mesh.radial_segments = 16
	var stem := MeshInstance3D.new()
	stem.name = "Stem"
	stem.mesh = stem_mesh
	stem.position = Vector3(0.0, -1.30, 0.0)
	stem.material_override = mat
	stand.add_child(stem)

	# 底盘
	var base_mesh := CylinderMesh.new()
	base_mesh.top_radius = 0.34
	base_mesh.bottom_radius = 0.40
	base_mesh.height = 0.07
	base_mesh.radial_segments = 40
	var base := MeshInstance3D.new()
	base.name = "Base"
	base.mesh = base_mesh
	base.position = Vector3(0.0, -1.54, 0.0)
	base.material_override = mat
	stand.add_child(base)


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
	# 镜头在 +Z 看 -Z：绕 Y 增大 = 正面的点往 +X（屏幕右）移动
	# 所以右拖（rel.x>0）要**加**，之前是减，方向是反的
	_spin += rel.x * 0.006
	# 绕 X 增大 = 正面的点往下移，所以下拖（rel.y>0）也是加
	_tilt = clampf(_tilt + rel.y * 0.005, deg_to_rad(-75.0), deg_to_rad(75.0))
	_apply_rotation()


## 滚轮缩放：滚轮上 = 放大（相机靠近）
func zoom_by(steps: float) -> void:
	_zoom = clampf(_zoom * (1.0 + steps * 0.12), 0.6, 2.6)
	if _cam != null:
		_cam.position = Vector3(0.0, 0.05, 4.55 / _zoom)


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


func get_camera_z() -> float:
	return _cam.position.z if _cam != null else 0.0


func _apply_rotation() -> void:
	if _pivot == null or _tilt_node == null:
		return
	# 分成两级：倾角绕世界 X，自转绕自身 Y，两者不互相污染
	_tilt_node.rotation = Vector3(_tilt, 0.0, 0.0)
	_pivot.rotation = Vector3(0.0, _spin, 0.0)


## 让某个地理方向正对镜头
func face_direction(dir: Vector3) -> void:
	var p := dir.normalized()
	# 球体应用的是 R_y(spin)：把 p 的水平分量转到 +Z（镜头方向）就是 spin = -atan2(x, z)
	_spin = -atan2(p.x, p.z)
	# 不做纬度倾斜：地球仪要竖着，赤道保持水平
	_tilt = 0.0
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

	var mask: Image = null
	var mask_tex := load(MASK_PATH) as Texture2D
	if mask_tex != null:
		mask = mask_tex.get_image()
	else:
		push_warning("[Globe] 找不到海陆掩膜 %s" % MASK_PATH)

	var bm := BiomeMap.new()
	bm.setup(world.gen, mask)

	var img := Image.create(TEX_W, TEX_H, false, Image.FORMAT_RGB8)
	var counts := {}

	for y in TEX_H:
		var lat := 90.0 - (float(y) + 0.5) / float(TEX_H) * 180.0
		for x in TEX_W:
			var lon := _lon_of_x(x)
			var dir := GeoSphere.lonlat_to_dir(lon, lat)
			var bid := bm.biome_at(dir)
			counts[bid] = counts.get(bid, 0) + 1

			var c: Color = BIOME_COLORS.get(bid, Color(0.5, 0.5, 0.5))
			# 高度带来的明暗，让球面不至于死板
			if bid != "ocean":
				var h := world.get_height_dir(dir)
				var shade := clampf(0.82 + h / 600.0, 0.82, 1.12)
				c = Color(c.r * shade, c.g * shade, c.b * shade)
			img.set_pixel(x, y, c)

	# 经纬网
	for y in TEX_H:
		var lat2 := 90.0 - (float(y) + 0.5) / float(TEX_H) * 180.0
		if _near_multiple(lat2, 30.0, 0.9):
			for x in TEX_W:
				img.set_pixel(x, y, img.get_pixel(x, y).lerp(Color(0.9, 0.93, 0.97), 0.22))
	for x in TEX_W:
		var lon2 := _lon_of_x(x)
		if _near_multiple(lon2, 30.0, 0.9):
			for y in TEX_H:
				img.set_pixel(x, y, img.get_pixel(x, y).lerp(Color(0.9, 0.93, 0.97), 0.22))

	img.generate_mipmaps()
	_tex = ImageTexture.create_from_image(img)
	if _sphere != null and _sphere.material_override is StandardMaterial3D:
		(_sphere.material_override as StandardMaterial3D).albedo_texture = _tex
	if _loading != null:
		_loading.text = "拖动旋转 · 滚轮缩放 · Esc / M 关闭"
	print("[Globe] 地形分布贴图 %dx%d 生成完成：%d ms" % [TEX_W, TEX_H, Time.get_ticks_msec() - t0])

	# 分布统计：海洋占比、各类地形占比（这是设计评审要看的数字）
	var total := float(TEX_W * TEX_H)
	var keys := counts.keys()
	keys.sort_custom(func(a, b): return counts[a] > counts[b])
	for k in keys:
		print("  %-6s %-5s %5.2f%%" % [k, bm.name_of(k), float(counts[k]) / total * 100.0])
	texture_ready.emit()

## 贴图第 x 列应该填哪个经度。
## Godot 的 SphereMesh：uv.x = 1 - atan2(x, z) / 2π，
## 而我们的经纬约定是 x=cos(lat)cos(lon), z=-cos(lat)sin(lon)，代入得 atan2 = lon + 90°，
## 所以 uv.x = 1 - (lon + 90)/360，反解即可。
static func _lon_of_x(x: int) -> float:
	var u := 1.0 - (float(x) + 0.5) / float(TEX_W)
	return u * 360.0 - 90.0


static func _near_multiple(v: float, step: float, tol: float) -> bool:
	var m := fmod(absf(v), step)
	return m < tol or m > step - tol
