extends SceneTree
## 诊断地貌分类：打印若干点的 h / 坡度 / 起伏 / 分类

func _init() -> void:
	var tg = load("res://scripts/terrain_gen.gd")
	tg.ensure_loaded()
	var pts := [[116.0, 32.0], [114.0, 35.0], [108.7, 34.3], [87.0, 43.0],
			[-100.0, 40.0], [105.0, 30.0], [121.0, 31.0]]
	for p in pts:
		var lon: float = p[0]
		var lat: float = p[1]
		var h: float = tg.dem_at(lon, lat)
		var dd := 0.0135
		var h_e: float = tg.dem_at(lon + dd, lat)
		var h_w: float = tg.dem_at(lon - dd, lat)
		var h_n: float = tg.dem_at(lon, lat + dd)
		var h_s: float = tg.dem_at(lon, lat - dd)
		var km := dd * 111.0
		var slope: float = sqrt(pow((h_e - h_w) / (2.0 * km), 2.0) + pow((h_n - h_s) / (2.0 * km), 2.0))
		var hi: float = maxf(maxf(h_e, h_w), maxf(h_n, h_s))
		var lo: float = minf(minf(h_e, h_w), minf(h_n, h_s))
		print("%.1f,%.1f h=%.0f slope=%.3f relief=%.0f kind=%d"
				% [lon, lat, h, slope, hi - lo, tg.landform_kind(lon, lat, h)])
	quit()
