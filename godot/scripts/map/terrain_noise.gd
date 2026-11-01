class_name TerrainNoise
extends RefCounted

## ==============================================================
## 地形与撒点的**纯数学层**（球面版）
##
## 特点：
##   * 没有 Node、没有渲染、没有副作用 —— 可以在无头环境里跑
##   * 用**三维噪声**采样：输入是球面上的单位方向，不是平面坐标。
##     这是整个球面方案的关键 —— 六个立方体面的接缝处地形自动连续，
##     不需要任何缝合逻辑（已实测，见 docs/MAP_API.md）
##   * 同一个方向永远返回同一个高度，与地块、区域、相机都无关
##   * 不包含任何"选定地块"逻辑（平台压平在 LandmarkRegistry 里）
## ==============================================================

var cfg: MapConfig
var world_seed := 209

var _warp_x: FastNoiseLite
var _warp_y: FastNoiseLite
var _warp_z: FastNoiseLite
var _layers: Array = []
var _forest: FastNoiseLite
var _rock: FastNoiseLite
var _lowveg: FastNoiseLite
var _wet: FastNoiseLite      # 湿度场：和高度完全独立的气候噪声


func _init(config: MapConfig = null, seed_value: int = 209) -> void:
	if config == null:
		cfg = MapConfig.new()
	else:
		cfg = config
	world_seed = seed_value

	_warp_x = _make(world_seed + 11, cfg.warp_period, 2)
	_warp_y = _make(world_seed + 12, cfg.warp_period, 2)
	_warp_z = _make(world_seed + 13, cfg.warp_period, 2)
	for i in cfg.layer_periods.size():
		_layers.append(_make(world_seed + 33 + i * 7, cfg.layer_periods[i], 4))
	_forest = _make(world_seed + 900, cfg.forest_period, 3)
	_rock = _make(world_seed + 313, cfg.rock_period, 2)
	_lowveg = _make(world_seed + 707, cfg.low_veg_period, 2)


static func _make(n_seed: int, period: float, octaves: int) -> FastNoiseLite:
	var n := FastNoiseLite.new()
	n.seed = n_seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 1.0 / maxf(period, 0.001)
	if octaves > 1:
		n.fractal_type = FastNoiseLite.FRACTAL_FBM
		n.fractal_octaves = octaves
		n.fractal_lacunarity = 2.0
		n.fractal_gain = 0.5
	else:
		n.fractal_type = FastNoiseLite.FRACTAL_NONE
	return n


static func fbm01(n: FastNoiseLite, p: Vector3) -> float:
	return clampf(n.get_noise_3d(p.x, p.y, p.z) * 0.5 + 0.5, 0.0, 1.0)


static func _raw(n: FastNoiseLite, p: Vector3) -> float:
	return n.get_noise_3d(p.x, p.y, p.z)


# ================================================================ 地形白膜
## 程序化高度（米），**不含**选定地块的平台压平。dir 是单位方向。
func height_at(dir: Vector3) -> float:
	var p := dir.normalized() * GeoSphere.RADIUS_M

	# 域扭曲：在三维空间里把采样位置推歪，等高线才不会是一堆同心圆
	var w := Vector3(_raw(_warp_x, p), _raw(_warp_y, p), _raw(_warp_z, p))
	var q := (p + w * cfg.warp_amp).normalized() * GeoSphere.RADIUS_M

	var h := cfg.height_base
	var n := mini(_layers.size(), cfg.layer_amps.size())
	for i in n:
		h += (fbm01(_layers[i], q) - 0.5) * 2.0 * cfg.layer_amps[i]
	return maxf(h, 0.0)


## 坡度（度）。eps 是沿地表的采样距离（米）。
## 湿度 0..1。独立的低频噪声，与高度无关——用来分森林/草原/沙漠。
func wet_at(dir: Vector3) -> float:
	if _wet == null:
		_wet = FastNoiseLite.new()
		_wet.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_wet.seed = world_seed + 7717
		_wet.frequency = 0.0000005    # 波长约 2000km，才配叫"气候带"
		_wet.fractal_type = FastNoiseLite.FRACTAL_FBM
		_wet.fractal_octaves = 3
	var n: float = _wet.get_noise_3dv(dir * 6371000.0)
	return clampf(n * 0.5 + 0.5, 0.0, 1.0)


func slope_deg_at(dir: Vector3, eps: float = 3.0) -> float:
	var frame := GeoSphere.tangent_frame(dir)
	var e := GeoSphere.tangent_to_dir(frame, eps, 0.0)
	var w := GeoSphere.tangent_to_dir(frame, -eps, 0.0)
	var n2 := GeoSphere.tangent_to_dir(frame, 0.0, eps)
	var s2 := GeoSphere.tangent_to_dir(frame, 0.0, -eps)
	var dh_de := (height_at(e) - height_at(w)) / (2.0 * eps)
	var dh_dn := (height_at(n2) - height_at(s2)) / (2.0 * eps)
	return rad_to_deg(atan(sqrt(dh_de * dh_de + dh_dn * dh_dn)))


# ================================================================ 撒点密度
## 树木：森林遮罩 + 不喜陡坡
func tree_density(dir: Vector3, slope_deg: float) -> float:
	var p := dir * GeoSphere.RADIUS_M
	var m := smoothstep(0.54, 0.70, fbm01(_forest, p))
	m *= 1.0 - smoothstep(8.0, 16.0, slope_deg)
	return m


## 石头：成片分布，整体稀疏，是点缀不是地毯（约 50 块/km²）
func rock_density(dir: Vector3, slope_deg: float) -> float:
	var p := dir * GeoSphere.RADIUS_M
	var m := 0.0012 + 0.010 * smoothstep(0.50, 0.78, fbm01(_rock, p))
	m *= 0.50 + 0.90 * smoothstep(4.0, 12.0, slope_deg)
	return clampf(m, 0.0, 1.0)


## 低矮植被：平地最密
func low_veg_density(dir: Vector3, slope_deg: float) -> float:
	var p := dir * GeoSphere.RADIUS_M
	var m := 1.0 - smoothstep(6.0, 14.0, slope_deg)
	m *= 0.30 + 0.70 * fbm01(_lowveg, p)
	return clampf(m, 0.0, 1.0)
