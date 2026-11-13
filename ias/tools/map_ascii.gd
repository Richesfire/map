extends SceneTree
## 全球地貌分类 ASCII 速查（不烘焙，直接调 landform_kind）
## 字母：~ 水  . 平原/草原/森林  h 丘陵  M 山地  T 高原  D 荒漠  * 冰雪  K 喀斯特  L 黄土

const COLS := 96
const ROWS := 40


func _sym(k: int) -> String:
	match k:
		11:
			return "~"
		0, 7, 8, 9, 17:
			return "."
		1, 23, 24, 25:
			return "h"
		2, 18, 19, 20, 21, 22:
			return "M"
		3:
			return "T"
		4, 5:
			return "v"
		6, 13, 15, 26, 27, 28:
			return "D"
		10, 16:
			return "*"
		12:
			return "K"
		14:
			return "L"
	return "?"


func _init() -> void:
	var tg = load("res://scripts/terrain_gen.gd")
	tg.ensure_loaded()
	var line := "    "
	for c in COLS:
		line += "%d" % ((c * 360 / COLS - 180) / 100)
	print("经度(百) " + line.substr(4))
	for r in ROWS:
		var lat: float = 90.0 - (float(r) + 0.5) / ROWS * 180.0
		var s := "%+4d " % int(lat)
		for c in COLS:
			var lon: float = -180.0 + (float(c) + 0.5) / COLS * 360.0
			var h: float = tg.dem_at(lon, lat)
			s += _sym(tg.landform_kind(lon, lat, h))
		print(s)
	quit()
