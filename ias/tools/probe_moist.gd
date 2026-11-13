extends SceneTree
## 打印若干点的湿度/温度/高程，用于校准荒漠判定

func _init() -> void:
	var tg = load("res://scripts/terrain_gen.gd")
	tg.ensure_loaded()
	var pts := [[10.0, 23.0], [45.0, 22.0], [132.0, -25.0], [-112.0, 33.0],
			[88.0, 40.0], [60.0, 30.0], [20.0, 15.0], [15.0, 28.0]]
	for p in pts:
		var lon: float = p[0]
		var lat: float = p[1]
		var h: float = tg.dem_at(lon, lat)
		var m: float = tg.moist_at(lon, lat)
		var t: float = 28.0 - 0.42 * absf(lat) - 0.0062 * maxf(h, 0.0)
		print("%.1f,%.1f h=%.0f m=%.3f t=%.1f kind=%d"
				% [lon, lat, h, m, t, tg.landform_kind(lon, lat, h)])
	quit()
