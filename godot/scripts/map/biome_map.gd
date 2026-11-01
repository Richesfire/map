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

const ICE_LAT := 72.0        # 冰盖起始纬度
const TUNDRA_LAT := 62.0     # 苔原起始纬度
const JUNGLE_LAT := 16.0     # 热带雨林 |lat| 上限
const SAVANNA_LAT := 26.0    # 稀树草原上限
const DESERT_LAT := 38.0     # 沙漠纬度带上限

const H_ALPINE := 125.0
const H_MOUNTAIN := 95.0
const H_HILLS := 66.0

const WET_JUNGLE := 0.56
const WET_FOREST := 0.48
const WET_STEPPE := 0.33
const WET_DESERT := 0.22

var gen: TerrainNoise
var _mask: Image
var _mask_w := 0
var _mask_h := 0


func setup(noise_gen: TerrainNoise, land_mask: Image = null) -> void:
	gen = noise_gen
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
	if lat > 12.0 and lat < 38.0:
		var t := (lat - 12.0) / 26.0            # 0..1
		aridity = sin(t * PI) * 0.45             # 顶点在 25 度左右
	return clampf(raw - aridity, 0.0, 1.0)


## 主判定
func biome_at(dir: Vector3) -> String:
	if gen == null:
		return "plain"
	var d := dir.normalized()
	var ll := GeoSphere.dir_to_lonlat(d)
	var lat := absf(ll.y)
	var h := gen.height_at(d)

	if not is_land(d):
		return "ocean"
	if lat >= ICE_LAT:
		return "ice"
	if h >= H_ALPINE:
		return "alpine"
	if lat >= TUNDRA_LAT:
		return "tundra"
	if h >= H_MOUNTAIN:
		return "mountain"
	if h >= H_HILLS:
		return "hills"

	var w := wet_at(d)

	if lat <= JUNGLE_LAT:
		if w >= WET_JUNGLE:
			return "jungle"
		if w >= WET_STEPPE:
			return "savanna"
		return "desert"

	if w >= WET_FOREST:
		return "forest"
	if w >= WET_STEPPE:
		return "steppe"
	if w >= WET_DESERT and lat >= 12.0 and lat <= DESERT_LAT:
		return "desert"
	if w < WET_DESERT * 0.62:
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
