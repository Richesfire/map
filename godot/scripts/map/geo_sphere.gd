class_name GeoSphere
extends RefCounted

## ==============================================================
## 立方体球（cube-sphere）地址系统
##
## 为什么不是经纬度网格：
##   等距圆柱投影下，一格在赤道是 1.0 km²，到咸阳只剩 0.82，
##   到匈奴 0.67，到北欧 0.50。纬度越高东西方向被压得越扁，
##   南北向和东西向的行军距离严重不一致。
##
## 现在的做法：把地球投到立方体的 6 个面上，每个面切成 FACE_RES × FACE_RES。
##   * 每个面 9216 × 9216 = 8493 万格，6 个面一共 **5.096 亿格**
##   * 全球表面积 5.101 亿 km² ÷ 5.096 亿格 = **平均每格 1.001 km²**
##   * 格子面积区间 0.83 ~ 1.18 km²（面中心最大、面角最小），
##     **和纬度无关**，这是关键——不再有南北系统性偏差
##   * 想查某一格的真实面积：GeoSphere.tile_area_m2(tile)
##
## 9216 = 2^10 × 9：既能被 96 整除，也能被 2^10 整除，
## 以后要做四叉树 LOD 可以直接往下细分。
##
## 映射用 equi-angular（切线）而不是纯线性：
##   纯线性会把格子拉成明显的长短边，equi-angular 让格子接近正方形。
##   代价就是上面的 ±18% 面积差异。
##   要绝对等面积得换 COBE 四边形化映射，格子会变成不等边四边形，
##   对格子策略游戏的"东南西北各走一格"不友好，所以没选。
##
## 【坐标约定】
##   方向 = 单位 Vector3（Godot：Y 轴向上，北纬为正）
##   格子 = Vector3i(面号 0..5, x 0..FACE_RES-1, y 0..FACE_RES-1)
##          Vector3i 可以直接当字典键，也可以直接存盘
## ==============================================================

## 地球半径（米）
const RADIUS_M := 6371000.0

## 每个立方体面的格子数（每边）
const FACE_RES := 9216

## 面数
const FACE_COUNT := 6

## 全球格子总数
const TOTAL_CELLS := 509607936      # 6 × 9216²


# ================================================================ 面的基向量
static func face_normal(face: int) -> Vector3:
	match face:
		0: return Vector3(0, 1, 0)
		1: return Vector3(0, -1, 0)
		2: return Vector3(1, 0, 0)
		3: return Vector3(0, 0, -1)
		4: return Vector3(-1, 0, 0)
		_: return Vector3(0, 0, 1)


static func face_right(face: int) -> Vector3:
	match face:
		0: return Vector3(1, 0, 0)
		1: return Vector3(1, 0, 0)
		2: return Vector3(0, 0, -1)
		3: return Vector3(-1, 0, 0)
		4: return Vector3(0, 0, 1)
		_: return Vector3(1, 0, 0)


static func face_up(face: int) -> Vector3:
	match face:
		0: return Vector3(0, 0, -1)
		1: return Vector3(0, 0, 1)
		_: return Vector3(0, 1, 0)


# ================================================================ 经纬度
## 经纬度 -> 单位方向。东经为正，北纬为正。
## lon=0,lat=0 -> +X；lon=90E -> -Z；lat=90 -> +Y
static func lonlat_to_dir(lon_deg: float, lat_deg: float) -> Vector3:
	var lon := deg_to_rad(lon_deg)
	var lat := deg_to_rad(lat_deg)
	var cl := cos(lat)
	return Vector3(cl * cos(lon), sin(lat), -cl * sin(lon)).normalized()


## 单位方向 -> (经度, 纬度) 度
static func dir_to_lonlat(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	var lat := rad_to_deg(asin(clampf(d.y, -1.0, 1.0)))
	var lon := rad_to_deg(atan2(-d.z, d.x))
	return Vector2(lon, lat)


# ================================================================ 方向 <-> 面坐标
static func dir_to_face(dir: Vector3) -> int:
	var d := dir.normalized()
	var best := -2.0
	var bi := 0
	for i in FACE_COUNT:
		var c := d.dot(face_normal(i))
		if c > best:
			best = c
			bi = i
	return bi


## 方向在指定面上的 (u, v)，范围 [-1, 1]
static func dir_to_face_uv(dir: Vector3, face: int) -> Vector2:
	var d := dir.normalized()
	var c := d.dot(face_normal(face))
	if c <= 1e-9:
		return Vector2.ZERO
	var a := d.dot(face_right(face)) / c
	var b := d.dot(face_up(face)) / c
	return Vector2(_warp(a), _warp(b))


static func face_uv_to_dir(face: int, u: float, v: float) -> Vector3:
	var n := face_normal(face)
	var r := face_right(face)
	var up := face_up(face)
	return (n + r * _unwarp(u) + up * _unwarp(v)).normalized()


static func _warp(a: float) -> float:
	return (4.0 / PI) * atan(a)


static func _unwarp(u: float) -> float:
	return tan(u * PI * 0.25)


# ================================================================ 格子
static func dir_to_tile(dir: Vector3) -> Vector3i:
	var face := dir_to_face(dir)
	var uv := dir_to_face_uv(dir, face)
	var x := int(floor((uv.x + 1.0) * 0.5 * float(FACE_RES)))
	var y := int(floor((uv.y + 1.0) * 0.5 * float(FACE_RES)))
	return Vector3i(face, clampi(x, 0, FACE_RES - 1), clampi(y, 0, FACE_RES - 1))


static func tile_to_dir(tile: Vector3i) -> Vector3:
	var u := ((float(tile.y) + 0.5) / float(FACE_RES)) * 2.0 - 1.0
	var v := ((float(tile.z) + 0.5) / float(FACE_RES)) * 2.0 - 1.0
	return face_uv_to_dir(tile.x, u, v)


## 四个角的方向，顺序：左下、右下、右上、左上
static func tile_corners(tile: Vector3i) -> Array:
	var u0 := (float(tile.y) / float(FACE_RES)) * 2.0 - 1.0
	var u1 := (float(tile.y + 1) / float(FACE_RES)) * 2.0 - 1.0
	var v0 := (float(tile.z) / float(FACE_RES)) * 2.0 - 1.0
	var v1 := (float(tile.z + 1) / float(FACE_RES)) * 2.0 - 1.0
	return [
		face_uv_to_dir(tile.x, u0, v0),
		face_uv_to_dir(tile.x, u1, v0),
		face_uv_to_dir(tile.x, u1, v1),
		face_uv_to_dir(tile.x, u0, v1),
	]


## 这一格的真实球面面积（m²）。整格 0.83~1.18 km²。
## 用 64 位算，否则 float32 下 1e-7 量级的球面超会掉精度。
static func tile_area_m2(tile: Vector3i) -> float:
	var c := tile_corners(tile)
	var total := 0.0
	for i in range(1, 3):
		total += _tri_area(c[0], c[i], c[i + 1])
	return total * RADIUS_M * RADIUS_M


static func _tri_area(a: Vector3, b: Vector3, c: Vector3) -> float:
	var cx := float(b.y) * float(c.z) - float(b.z) * float(c.y)
	var cy := float(b.z) * float(c.x) - float(b.x) * float(c.z)
	var cz := float(b.x) * float(c.y) - float(b.y) * float(c.x)
	var num := absf(float(a.x) * cx + float(a.y) * cy + float(a.z) * cz)
	var den := 1.0 + float(a.dot(b)) + float(b.dot(c)) + float(c.dot(a))
	return 2.0 * atan2(num, den)


# ================================================================ 距离与局部坐标系
## 两点之间的大圆距离（米）—— 要距离就用这个，别拿格子差值算
##
## 不能用 acos(a·b)：两个方向相差 1km 时点积是 1-1.2e-8，
## 而 Vector3 是 32 位浮点（1.0 附近 ULP 约 6e-8），点积会被舍成 1.0，
## acos 恒等于 0，距离永远返回 0。
## 所以改用弦长：|a-b| = 2·sin(θ/2)，小角度下精度很好。
static func distance_m(a: Vector3, b: Vector3) -> float:
	var ax := float(a.x)
	var ay := float(a.y)
	var az := float(a.z)
	var bx := float(b.x)
	var by := float(b.y)
	var bz := float(b.z)
	var la := sqrt(ax * ax + ay * ay + az * az)
	var lb := sqrt(bx * bx + by * by + bz * bz)
	if la < 1e-12 or lb < 1e-12:
		return 0.0
	var dx := ax / la - bx / lb
	var dy := ay / la - by / lb
	var dz := az / la - bz / lb
	var chord := sqrt(dx * dx + dy * dy + dz * dz)
	return RADIUS_M * 2.0 * asin(clampf(chord * 0.5, 0.0, 1.0))


## 某个方向处的局部切平面坐标系（东、北、天）
static func tangent_frame(dir: Vector3) -> Dictionary:
	var up := dir.normalized()
	var east := Vector3.UP.cross(up)
	if east.length_squared() < 1e-8:
		# 在极点附近，退化时换个参考
		east = Vector3.RIGHT.cross(up)
	east = east.normalized()
	var north := up.cross(east).normalized()
	return {"up": up, "east": east, "north": north}


## 把切平面上的 (东, 北) 偏移换算成球面方向
static func tangent_to_dir(frame: Dictionary, east_m: float, north_m: float) -> Vector3:
	var up: Vector3 = frame["up"]
	var e: Vector3 = frame["east"]
	var n: Vector3 = frame["north"]
	return (up + (e * east_m + n * north_m) / RADIUS_M).normalized()


## 把球面方向换算回切平面偏移（米），返回 (东, 北)
##
## 同样不能用 acos：1km 外 up·d = 1-1.2e-8，float32 会舍成 1.0 → 恒返回 0。
## 角度改用弦长反推。
static func dir_to_tangent(frame: Dictionary, dir: Vector3) -> Vector2:
	var up: Vector3 = frame["up"]
	var e: Vector3 = frame["east"]
	var n: Vector3 = frame["north"]
	var d := dir.normalized()

	var cdx := float(d.x) - float(up.x)
	var cdy := float(d.y) - float(up.y)
	var cdz := float(d.z) - float(up.z)
	var chord := sqrt(cdx * cdx + cdy * cdy + cdz * cdz)
	var ang := 2.0 * asin(clampf(chord * 0.5, 0.0, 1.0))
	if ang < 1e-9:
		return Vector2.ZERO

	var proj := d - up * up.dot(d)
	var l := proj.length()
	if l < 1e-9:
		return Vector2.ZERO
	var t := proj / l
	return Vector2(t.dot(e), t.dot(n)) * (ang * RADIUS_M)
