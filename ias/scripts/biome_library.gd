extends Node
## 地貌资源库：优先从 res://data/biomes/*.tres 读取（BiomeProfile），
## 读不到时用内置默认值，保证项目在任何时候都能跑。
## 三类资源堆：置换贴图 / 地表纹理 / 环境杂物，各自独立。

const DIR := "res://data/biomes"
const PROFILE_SCRIPT := "res://scripts/biome_profile.gd"
const LandformDb := preload("res://scripts/landform_db.gd")

## 地貌编号 → 配置 id（唯一的事实表，改地貌/配置文件时先看这里）。
## 以前是按"文件名排序后的下标"取配置，而 data/biomes 里留着历史批次的重名文件
## （17_delta_wet 与 17_hill_red 并存，共 36 个），下标从 18 起整体错位：
## 花岗岩山地拿到红壤丘陵、盐碱地拿到三角洲（盐滩上长草和湿地杂物）。
## 现在按 id 查字典，文件名只当说明；编号本身只用于排序和肉眼对照。
## 地貌编号 → 配置 id：表在 landform_db.gd
const LF_PROFILE := LandformDb.PROFILES

## 内置默认（与 .tres 同结构）——仅作为缺省，正式配置在 data/biomes 下
const DEFAULTS := [
	{
		"id": "plain_open", "display_name": "开阔平原", "category": "平原", "subtype": "开阔平原",
		"disp_tiles": [0, 1], "disp_amp": 2.2, "disp_scale": 420.0,
		"tex_tiles": [0, 2, 1, 3],
		"grass": 0.55, "shrub": 0.06, "rock": 0.02, "tree": 0.04,
	},
	{
		"id": "hill_rolling", "display_name": "起伏丘陵", "category": "丘陵", "subtype": "起伏丘陵",
		"disp_tiles": [1, 2], "disp_amp": 4.5, "disp_scale": 360.0,
		"tex_tiles": [0, 2, 3, 3],
		"grass": 0.45, "shrub": 0.12, "rock": 0.05, "tree": 0.22,
	},
	{
		"id": "mountain_mid", "display_name": "中山", "category": "山地", "subtype": "中山",
		"disp_tiles": [2, 5], "disp_amp": 6.0, "disp_scale": 300.0,
		"tex_tiles": [5, 6, 11, 3],
		"grass": 0.18, "shrub": 0.10, "rock": 0.30, "tree": 0.30,
		"special_kind": 4, "special_density": 0.12,
	},
	{
		"id": "plateau_steppe", "display_name": "草原高原", "category": "高原", "subtype": "草原高原",
		"disp_tiles": [1, 0], "disp_amp": 3.0, "disp_scale": 480.0,
		"tex_tiles": [1, 3, 0, 2],
		"grass": 0.50, "shrub": 0.05, "rock": 0.06, "tree": 0.03,
	},
	{
		"id": "basin_flat", "display_name": "平坦盆地", "category": "盆地", "subtype": "平坦盆地",
		"disp_tiles": [0, 1], "disp_amp": 1.8, "disp_scale": 520.0,
		"tex_tiles": [0, 3, 1, 2],
		"grass": 0.52, "shrub": 0.07, "rock": 0.03, "tree": 0.10,
	},
	{
		"id": "valley_wide", "display_name": "宽阔河谷", "category": "河谷", "subtype": "宽阔河谷",
		"disp_tiles": [4, 0], "disp_amp": 2.0, "disp_scale": 300.0,
		"tex_tiles": [2, 9, 0, 3],
		"grass": 0.60, "shrub": 0.10, "rock": 0.04, "tree": 0.18,
	},
	{
		"id": "desert_sand", "display_name": "沙漠", "category": "荒漠", "subtype": "沙漠",
		"disp_tiles": [3, 3], "disp_amp": 2.6, "disp_scale": 700.0,
		"tex_tiles": [7, 3, 4, 11],
		"grass": 0.02, "shrub": 0.05, "rock": 0.10, "tree": 0.01,
	},
	{
		"id": "steppe_temp", "display_name": "温带草原", "category": "草原", "subtype": "温带草原",
		"disp_tiles": [1, 0], "disp_amp": 2.4, "disp_scale": 520.0,
		"tex_tiles": [1, 13, 0, 3],
		"grass": 0.70, "shrub": 0.06, "rock": 0.02, "tree": 0.05,
	},
	{
		"id": "forest_plain", "display_name": "平原森林", "category": "森林地貌", "subtype": "平原森林",
		"disp_tiles": [0, 1], "disp_amp": 2.8, "disp_scale": 420.0,
		"tex_tiles": [14, 2, 3, 10],
		"grass": 0.35, "shrub": 0.16, "rock": 0.02, "tree": 0.65,
	},
	{
		"id": "wetland_marsh", "display_name": "沼泽", "category": "湿地", "subtype": "沼泽",
		"disp_tiles": [4, 3], "disp_amp": 1.2, "disp_scale": 240.0,
		"tex_tiles": [9, 10, 2, 3],
		"grass": 0.65, "shrub": 0.10, "rock": 0.01, "tree": 0.15,
	},
	{
		"id": "ice_glacier", "display_name": "冰川", "category": "冰雪地貌", "subtype": "冰川",
		"disp_tiles": [2, 5], "disp_amp": 3.2, "disp_scale": 520.0,
		"tex_tiles": [8, 5, 6, 11],
		"grass": 0.0, "shrub": 0.0, "rock": 0.18, "tree": 0.0,
	},
	{
		"id": "coast_beach", "display_name": "沙滩", "category": "海岸", "subtype": "沙滩",
		"disp_tiles": [3, 0], "disp_amp": 1.0, "disp_scale": 260.0,
		"tex_tiles": [15, 7, 4, 3],
		"grass": 0.12, "shrub": 0.04, "rock": 0.06, "tree": 0.05,
	},
	{
		"id": "karst_cone", "display_name": "喀斯特峰丛", "category": "喀斯特", "subtype": "峰丛洼地",
		"disp_tiles": [6, 5], "disp_amp": 5.0, "disp_scale": 300.0,
		"tex_tiles": [5, 10, 3, 11],
		"grass": 0.30, "shrub": 0.20, "rock": 0.25, "tree": 0.30,
		"special_kind": 1, "special_density": 0.28,
	},
	{
		"id": "yardang", "display_name": "雅丹", "category": "荒漠", "subtype": "风蚀垄",
		"disp_tiles": [7, 3], "disp_amp": 4.5, "disp_scale": 420.0,
		"tex_tiles": [7, 4, 3, 11],
		"grass": 0.02, "shrub": 0.03, "rock": 0.15, "tree": 0.0,
		"special_kind": 2, "special_density": 0.30,
	},
	{
		"id": "loess_yuan", "display_name": "黄土塬", "category": "高原", "subtype": "黄土塬",
		"disp_tiles": [8, 3], "disp_amp": 5.0, "disp_scale": 340.0,
		"tex_tiles": [1, 3, 0, 4],
		"grass": 0.45, "shrub": 0.08, "rock": 0.05, "tree": 0.06,
		"special_kind": 3, "special_density": 0.10,
	},
	{
		"id": "dune_sand", "display_name": "沙丘", "category": "荒漠", "subtype": "沙丘",
		"disp_tiles": [3, 3], "disp_amp": 4.2, "disp_scale": 520.0,
		"tex_tiles": [7, 7, 3, 4],
		"grass": 0.01, "shrub": 0.02, "rock": 0.03, "tree": 0.0,
		"special_kind": 1, "special_density": 0.04,
	},
	{
		"id": "glacial_valley", "display_name": "冰川谷", "category": "冰雪地貌", "subtype": "U 形谷",
		"disp_tiles": [2, 5], "disp_amp": 5.5, "disp_scale": 460.0,
		"tex_tiles": [8, 5, 6, 11],
		"grass": 0.02, "shrub": 0.0, "rock": 0.22, "tree": 0.05,
		"special_kind": 4, "special_density": 0.22,
	},
	{
		"id": "hill_red", "display_name": "红壤丘陵", "category": "丘陵", "subtype": "红壤",
		"disp_tiles": [1, 6], "disp_amp": 4.2, "disp_scale": 330.0,
		"tex_tiles": [13, 3, 0, 10],
		"grass": 0.42, "shrub": 0.16, "rock": 0.04, "tree": 0.30,
	},
	{
		"id": "hill_loess", "display_name": "黄土丘陵", "category": "丘陵", "subtype": "黄土梁",
		"disp_tiles": [8, 1], "disp_amp": 4.4, "disp_scale": 320.0,
		"tex_tiles": [1, 3, 4, 0],
		"special_kind": 3, "special_density": 0.10,
		"grass": 0.40, "shrub": 0.08, "rock": 0.06, "tree": 0.10,
	},
	{
		"id": "hill_danxia", "display_name": "丹霞丘陵", "category": "丘陵", "subtype": "丹霞",
		"disp_tiles": [5, 2], "disp_amp": 4.6, "disp_scale": 300.0,
		"tex_tiles": [12, 6, 11, 3],
		"special_kind": 1, "special_density": 0.12,
		"grass": 0.20, "shrub": 0.12, "rock": 0.30, "tree": 0.18,
	},
	{
		"id": "desert_sand2", "display_name": "沙质荒漠", "category": "荒漠", "subtype": "沙质",
		"disp_tiles": [3, 3], "disp_amp": 3.6, "disp_scale": 560.0,
		"tex_tiles": [7, 7, 3, 4],
		"grass": 0.02, "shrub": 0.04, "rock": 0.05, "tree": 0.0,
	},
	{
		"id": "desert_gobi", "display_name": "砾质荒漠", "category": "荒漠", "subtype": "戈壁",
		"disp_tiles": [7, 3], "disp_amp": 3.0, "disp_scale": 520.0,
		"tex_tiles": [4, 7, 11, 3],
		"grass": 0.03, "shrub": 0.05, "rock": 0.18, "tree": 0.0,
	},
	{
		"id": "desert_salt", "display_name": "盐碱地", "category": "荒漠", "subtype": "盐碱",
		"disp_tiles": [4, 3], "disp_amp": 1.6, "disp_scale": 380.0,
		"tex_tiles": [15, 3, 9, 11],
		"grass": 0.04, "shrub": 0.03, "rock": 0.06, "tree": 0.0,
	},
	{
		"id": "mtn_granite", "display_name": "花岗岩山地", "category": "山地", "subtype": "花岗岩",
		"disp_tiles": [2, 5], "disp_amp": 5.5, "disp_scale": 340.0,
		"tex_tiles": [5, 6, 11, 3],
		"special_kind": 4, "special_density": 0.16,
		"grass": 0.16, "shrub": 0.10, "rock": 0.32, "tree": 0.22,
	},
	{
		"id": "mtn_karst", "display_name": "喀斯特山地", "category": "山地", "subtype": "峰丛山地",
		"disp_tiles": [6, 2], "disp_amp": 6.0, "disp_scale": 300.0,
		"tex_tiles": [5, 10, 6, 11],
		"special_kind": 1, "special_density": 0.30,
		"grass": 0.28, "shrub": 0.18, "rock": 0.28, "tree": 0.30,
	},
	{
		"id": "mtn_loess", "display_name": "黄土山地", "category": "山地", "subtype": "黄土梁峁",
		"disp_tiles": [8, 2], "disp_amp": 5.5, "disp_scale": 320.0,
		"tex_tiles": [1, 3, 4, 0],
		"special_kind": 3, "special_density": 0.14,
		"grass": 0.34, "shrub": 0.08, "rock": 0.10, "tree": 0.10,
	},
	{
		"id": "mtn_volcanic", "display_name": "火山山地", "category": "山地", "subtype": "火山锥",
		"disp_tiles": [5, 2], "disp_amp": 5.0, "disp_scale": 380.0,
		"tex_tiles": [6, 11, 5, 3],
		"special_kind": 4, "special_density": 0.20,
		"grass": 0.10, "shrub": 0.06, "rock": 0.40, "tree": 0.14,
	},
	{
		"id": "mtn_ice", "display_name": "冰蚀山地", "category": "山地", "subtype": "刃脊角峰",
		"disp_tiles": [2, 5], "disp_amp": 6.5, "disp_scale": 420.0,
		"tex_tiles": [8, 5, 6, 11],
		"special_kind": 4, "special_density": 0.18,
		"grass": 0.02, "shrub": 0.0, "rock": 0.35, "tree": 0.03,
	},
	{
		"id": "delta_wet", "display_name": "三角洲", "category": "海岸", "subtype": "三角洲",
		"disp_tiles": [4, 0], "disp_amp": 1.0, "disp_scale": 260.0,
		"tex_tiles": [9, 10, 2, 15],
		"grass": 0.55, "shrub": 0.12, "rock": 0.01, "tree": 0.10,
		"special_kind": 5, "special_density": 0.45,
	},
]

static var _profiles: Array = []
static var _by_id := {}
static var _loaded := false
static var _warned := {}


static func _to_dict(p: Resource) -> Dictionary:
	return {
		"id": p.id, "display_name": p.display_name,
		"category": p.category, "subtype": p.subtype,
		"disp_tiles": p.disp_tiles, "disp_amp": p.disp_amp, "disp_scale": p.disp_scale,
		"tex_tiles": p.tex_tiles,
		"special_kind": p.special_kind, "special_density": p.special_density,
		"grass": p.grass, "shrub": p.shrub, "rock": p.rock, "tree": p.tree,
	}


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_profiles = []
	_by_id = {}
	var d := DirAccess.open(DIR)
	if d != null:
		var files := d.get_files()
		files.sort()
		for f in files:
			if not f.ends_with(".tres"):
				continue
			var res: Resource = load(DIR + "/" + f)
			if res == null or not res is Resource:
				continue
			var prof := _to_dict(res)
			var pid := String(prof.get("id", ""))
			if pid.is_empty():
				push_warning("[地貌] %s 没有 id，跳过" % f)
				continue
			if _by_id.has(pid):
				continue   # 重名的旧批次文件：保留文件名靠前的那份
			_by_id[pid] = prof
			_profiles.append(prof)
	if _profiles.is_empty():
		for dd in DEFAULTS:
			var p2: Dictionary = (dd as Dictionary).duplicate(true)
			_by_id[p2["id"]] = p2
			_profiles.append(p2)
		print("[地貌] 使用内置配置（data/biomes 下没有 .tres）")
	else:
		print("[地貌] 已加载 %d 个 .tres 配置" % _profiles.size())


static func profile_for(kind: int) -> Dictionary:
	_load()
	var nm: String = String(LF_PROFILE.get(kind, ""))
	if _by_id.has(nm):
		return _by_id[nm]
	# 兜底：这个编号还没配 .tres（新加地貌时），退回下标近似，并且只提醒一次
	if not _warned.has(kind):
		_warned[kind] = true
		push_warning("[地貌] 编号 %d 没有配置 %s，退回第 %d 项" % [kind, nm, kind])
	return _profiles[clampi(kind, 0, _profiles.size() - 1)]


static func count() -> int:
	_load()
	return _profiles.size()
