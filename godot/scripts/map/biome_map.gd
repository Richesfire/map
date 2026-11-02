class_name BiomeMap
extends RefCounted

## ==============================================================
## 生物群系判定：球面方向 -> 地形 id
##
## 判定的**唯一入口**。地块生成、地球仪上色、小地图都得走这里，
## 否则"地图上看到的"和"脚下踩的"会对不上。
##
## 判定顺序（先到先得，越上面优先级越高）：
##   海洋 -> 冰盖 -> 苔原 -> 高山 -> 山地 -> 丘陵
##        -> 雨林 -> 稀树草原 -> 沙漠 -> 盐碱
##        -> 沼泽 -> 森林 -> 草原 -> 平原
##
## 用到的输入：
##   lat      纬度，决定气候带
##   h        高度，决定高山/山地/丘陵
##   wet      湿度（噪声），决定森林/草原/沙漠
##   land     海陆掩膜，决定海洋
## ==============================================================

var ice_lat := 72.0          # 以下阈值全部由 terrain_types.json 的 biome_rules 覆盖（Excel「群系规则」页）
var tundra_lat := 62.0
var jungle_lat := 16.0
var savanna_lat := 26.0
var desert_lat := 38.0

var h_alpine := 125.0
var h_mountain := 95.0
var h_hills := 66.0

var wet_jungle := 0.56
var wet_forest := 0.48
var wet_steppe := 0.33
var wet_desert := 0.22

var arid_lo := 14.0
var arid_hi := 34.0
var arid_peak := 0.28

var gen: TerrainNoise
var _mask: Image
var _mask_w := 0
var _mask_h := 0


func setup(noise_gen: TerrainNoise, land_mask: Image = null) -> void:
	gen = noise_gen
	_load_rules()
	_mask = land_mask
	if _mask != null:
		_mask_w = _mask.get_width()
		_mask_h = _mask.get_height()


## 海陆掩膜：有掩膜就按掩膜，没有就当全是陆地
func is_land(dir: Vector3) -> bool:
	if _mask == null:
		return true
	var ll := GeoSphere.dir_to_lonlat(dir)
	var x := clampi(int((ll.x + 180.0) / 360.0 * float(_mask_w)), 0, _mask_w - 1)
	var y := clampi(int((90.0 - ll.y) / 180.0 * float(_mask_h)), 0, _mask_h - 1)
	return _mask.get_pixel(x, y).r > 0.5


## 湿度直接用气候噪声（独立于高度），再叠一条纬度干旱带
func wet_at(dir: Vector3) -> float:
	if gen == null:
		return 0.5
	var raw: float = gen.wet_at(dir)
	# 纬度干旱带：南北纬 15~35 度是副热带高压带，全球的沙漠都在这里
	var lat: float = absf(GeoSphere.dir_to_lonlat(dir).y)
	var aridity := 0.0
	if lat > arid_lo and lat < arid_hi:
		var t := (lat - arid_lo) / maxf(arid_hi - arid_lo, 1.0)
		aridity = sin(t * PI) * 0.28             # 顶点在 24 度左右（副热带高压带）
	return clampf(raw - aridity, 0.0, 1.0)


## 主判定
func biome_at(dir: Vector3) -> String:
	if gen == null:
		return "plain"
	var d := dir.normalized()
	var ll := GeoSphere.dir_to_lonlat(d)
	var lat := absf(ll.y)

	# 先判海陆、再算高度：海洋占地球表面 71%，原先每格都白算一次高度噪声。
	# 调换这一处，烘焙全球图、地块生成、撒点全都跟着变快。
	if not is_land(d):
		return "ocean"

	var h := gen.height_at(d)

	if lat >= ice_lat:
		return "ice"
	if h >= h_alpine:
		return "alpine"
	if lat >= tundra_lat:
		return "tundra"
	if h >= h_mountain:
		return "mountain"
	if h >= h_hills:
		return "hills"

	var w := wet_at(d)

	if lat <= jungle_lat:
		if w >= wet_jungle:
			return "jungle"
		if w >= wet_steppe:
			return "savanna"
		return "desert"

	if w >= wet_forest:
		return "forest"
	if w >= wet_steppe:
		return "steppe"
	if w >= wet_desert and lat >= 12.0 and lat <= desert_lat:
		return "desert"
	if w < wet_desert * 0.62:
		return "badland"

	# 低洼 + 潮湿 = 沼泽
	if h < 12.0 and w > 0.45:
		return "marsh"
	return "plain"


func name_of(id: String) -> String:
	var table := {
		"plain": "平原", "forest": "森林", "desert": "沙漠", "steppe": "草原",
		"hills": "丘陵", "mountain": "山地", "alpine": "高山", "tundra": "苔原",
		"ice": "冰原", "jungle": "雨林", "savanna": "稀树草原", "marsh": "沼泽",
		"inland_water": "河流", "ocean": "海洋", "badland": "荒漠",
	}
	return table.get(id, id)


## 从 terrain_types.json 的 biome_rules 里读阈值（这些值由 Excel 的「群系规则」页驱动）
func _load_rules() -> void:
	const PATH := "res://data/terrain_types.json"
	if not FileAccess.file_exists(PATH):
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	if typeof(data) != TYPE_DICTIONARY:
		return
	var r: Dictionary = data.get("biome_rules", {})
	if r.is_empty():
		return
	if r.has("ice_lat"): ice_lat = float(r["ice_lat"])
	if r.has("tundra_lat"): tundra_lat = float(r["tundra_lat"])
	if r.has("jungle_lat"): jungle_lat = float(r["jungle_lat"])
	if r.has("savanna_lat"): savanna_lat = float(r["savanna_lat"])
	if r.has("desert_lat"): desert_lat = float(r["desert_lat"])
	if r.has("h_alpine"): h_alpine = float(r["h_alpine"])
	if r.has("h_mountain"): h_mountain = float(r["h_mountain"])
	if r.has("h_hills"): h_hills = float(r["h_hills"])
	if r.has("wet_jungle"): wet_jungle = float(r["wet_jungle"])
	if r.has("wet_forest"): wet_forest = float(r["wet_forest"])
	if r.has("wet_steppe"): wet_steppe = float(r["wet_steppe"])
	if r.has("wet_desert"): wet_desert = float(r["wet_desert"])
	if r.has("arid_lo"): arid_lo = float(r["arid_lo"])
	if r.has("arid_hi"): arid_hi = float(r["arid_hi"])
	if r.has("arid_peak"): arid_peak = float(r["arid_peak"])
	print("[Biome] 已载入 %d 条群系规则" % r.size())
