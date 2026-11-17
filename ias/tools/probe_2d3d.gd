extends SceneTree
## 对比「2D 舆图的地貌」和「3D 世界近景的地貌」是否一致。
## 2D 低倍用烘焙编号图（kind_baked）；3D 现在也用底图高程 dem_at 分类（2026-11-17 解耦）。
## 正常应 0 不一致；有偏差说明烘焙图过期，要重烘。
## 用法：godot --headless --path ias --script res://tools/probe_2d3d.gd -- 108 110 34 35.5 0.05

const TG := preload("res://scripts/terrain_gen.gd")


func _init() -> void:
	TG.ensure_loaded()
	var a := OS.get_cmdline_user_args()
	var lon0 := float(a[0]) if a.size() > 0 else 108.0
	var lon1 := float(a[1]) if a.size() > 1 else 110.0
	var lat0 := float(a[2]) if a.size() > 2 else 34.0
	var lat1 := float(a[3]) if a.size() > 3 else 35.5
	var st := float(a[4]) if a.size() > 4 else 0.05
	var n := 0
	var diff := 0
	var pairs := {}
	var hmax := 0.0
	var lat := lat1
	while lat >= lat0:
		var lon := lon0
		while lon <= lon1:
			var h2: float = TG.dem_at(lon, lat)
			var k2: int = TG.kind_baked(lon, lat)
			var h3: float = TG.dem_at(lon, lat)
			var k3: int = TG.landform_kind(lon, lat, h3)
			n += 1
			hmax = maxf(hmax, absf(h3 - h2))
			if k2 != k3:
				diff += 1
				var key := "%s -> %s" % [TG.LF_NAMES[k2], TG.LF_NAMES[k3]]
				pairs[key] = int(pairs.get(key, 0)) + 1
			lon += st
		lat -= st
	print("=== %.1f-%.1fE %.1f-%.1fN  %d 点 ===" % [lon0, lon1, lat0, lat1, n])
	print("分类不一致 %d 点（%.1f%%），高差最大 %.0f m" % [diff, 100.0 * float(diff) / float(maxi(n, 1)), hmax])
	var keys: Array = pairs.keys()
	keys.sort()
	for k in keys.slice(0, 10):
		print("  %-22s %d" % [k, pairs[k]])
	quit()
