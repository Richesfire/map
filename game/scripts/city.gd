extends Node3D
## 灰盒城市（咸阳原型）：城墙 + 城门 + 主街 + 街区。
## 位置由经纬度换算到地形局部坐标，地形重建时跟着重建。
## 地面高度只读 terrain_gen 的城市手工高程，保证和地表一致。

const TG := preload("res://scripts/terrain_gen.gd")

var _wall_mat: StandardMaterial3D
var _bld_mat: StandardMaterial3D
var _road_mat: StandardMaterial3D
var _ground_mat: StandardMaterial3D
var _palace_mat: StandardMaterial3D
var _body: StaticBody3D
var _rng := RandomNumberGenerator.new()


func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	return m


func rebuild(clon: float, clat: float) -> void:
	for c in get_children():
		c.queue_free()
	_body = null
	_wall_mat = _mat(Color(0.56, 0.51, 0.42), 0.95)
	_bld_mat = _mat(Color(0.49, 0.44, 0.37), 0.92)
	_palace_mat = _mat(Color(0.42, 0.34, 0.28), 0.85)
	_road_mat = _mat(Color(0.33, 0.30, 0.25), 1.0)
	_ground_mat = _mat(Color(0.47, 0.43, 0.34), 1.0)
	_body = StaticBody3D.new()
	add_child(_body)

	for city in TG.cities():
		var d := TG.distance_m(float(city["lon"]), float(city["lat"]), clon, clat) / 1000.0
		if d > 110.0:
			continue
		_build_city(city, clon, clat)


func _build_city(city: Dictionary, clon: float, clat: float) -> void:
	var lon := float(city["lon"])
	var lat := float(city["lat"])
	var h := float(city["height"])
	var x := (lon - clon) * 111320.0 * cos(deg_to_rad(clat))
	var z := -(lat - clat) * 110540.0
	var half := float(city["radius"]) * 1000.0 * 0.42     # 城墙半边长（保护半径内留出郊野）
	var wall_h := 14.0
	var wall_t := 14.0

	# 城内地面（土色），比地形高 5 cm；略大于城墙
	_box(Vector3(x, h + 0.05, z), Vector3(half * 2.3, 0.1, half * 2.3), _ground_mat, false)

	# 主街：南北 + 东西，通到城墙
	_box(Vector3(x, h + 0.12, z), Vector3(30.0, 0.08, half * 2.0), _road_mat, false)
	_box(Vector3(x, h + 0.12, z), Vector3(half * 2.0, 0.08, 30.0), _road_mat, false)

	# 城墙四面
	_box(Vector3(x, h + wall_h * 0.5, z - half), Vector3(half * 2.0, wall_h, wall_t), _wall_mat, true)
	_box(Vector3(x, h + wall_h * 0.5, z + half), Vector3(half * 2.0, wall_h, wall_t), _wall_mat, true)
	_box(Vector3(x - half, h + wall_h * 0.5, z), Vector3(wall_t, wall_h, half * 2.0), _wall_mat, true)
	_box(Vector3(x + half, h + wall_h * 0.5, z), Vector3(wall_t, wall_h, half * 2.0), _wall_mat, true)
	# 南门：留 52 m 缺口 + 门楼
	var seg := half - 26.0
	_box(Vector3(x - (half + 26.0) * 0.5, h + wall_h * 0.5, z + half),
			Vector3(seg - 26.0, wall_h, wall_t), _wall_mat, true)
	_box(Vector3(x + (half + 26.0) * 0.5, h + wall_h * 0.5, z + half),
			Vector3(seg - 26.0, wall_h, wall_t), _wall_mat, true)
	_box(Vector3(x, h + wall_h + 5.0, z + half), Vector3(80.0, 10.0, 30.0), _palace_mat, true)
	# 角楼
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			_box(Vector3(x + sx * half, h + wall_h + 4.0, z + sz * half),
					Vector3(40.0, 8.0, 40.0), _palace_mat, true)

	# 街区：4×4 网格，避开十字主街；北城中部放一组高台宫殿
	_rng.seed = 20900 + int(lon * 100.0)
	var cell := half / 2.0
	for ix in 4:
		for iz in 4:
			var cx := x + (float(ix) - 1.5) * cell
			var cz := z + (float(iz) - 1.5) * cell
			if absf(cx - x) < 44.0 or absf(cz - z) < 44.0:
				continue
			var w := 70.0 + _rng.randf() * 60.0
			var dd := 70.0 + _rng.randf() * 60.0
			var bh := 9.0 + _rng.randf() * 13.0
			var mt := _bld_mat
			if iz == 0 and absf(ix - 1.5) < 1.6:
				bh += 8.0
				mt = _palace_mat
			_box(Vector3(cx, h + bh * 0.5, cz), Vector3(w, bh, dd), mt, true)
	# 宫殿高台（北城正中）
	_box(Vector3(x, h + 4.0, z - half * 0.42), Vector3(220.0, 8.0, 160.0), _palace_mat, true)
	_box(Vector3(x, h + 14.0, z - half * 0.42), Vector3(140.0, 12.0, 96.0), _palace_mat, true)


func _box(pos: Vector3, size: Vector3, mat: Material, collide: bool) -> void:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	if collide and _body != null:
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		cs.shape = shape
		cs.position = pos
		_body.add_child(cs)
