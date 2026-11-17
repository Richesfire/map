extends SceneTree
## 诊断：在给定矩形里网格采样，比较「实时分类」和「烘焙编号图」，看两边是否一致。
## 用法：godot --headless --path ias --script res://tools/probe_grid.gd -- 113 117 35 38 0.25

const TG := preload("res://scripts/terrain_gen.gd")


func _init() -> void:
	TG.ensure_loaded()
	var a := OS.get_cmdline_user_args()
	var lon0 := float(a[0]) if a.size() > 0 else 113.0
	var lon1 := float(a[1]) if a.size() > 1 else 117.0
	var lat0 := float(a[2]) if a.size() > 2 else 35.0
	var lat1 := float(a[3]) if a.size() > 3 else 38.0
	var st := float(a[4]) if a.size() > 4 else 0.25
	var diff := 0
	var total := 0
	print("=== 实时分类 vs 烘焙编号（%s=一致，数字=实时；大写字母=不一致且烘焙=%s）==="
			% ["·", "?"])
	var lat := lat1
	while lat >= lat0:
		var row := ""
		var lon := lon0
		while lon <= lon1:
			var h: float = TG.dem_at(lon, lat)
			var live: int = TG.landform_kind(lon, lat, h)
			var baked: int = TG.kind_baked(lon, lat)
			total += 1
			if live != baked:
				diff += 1
				row += "@"
			else:
				row += "." if live < 10 else "+"
			lon += st
		print("  %5.2f  %s" % [lat, row])
		lat -= st
	print("[对比] %d 点，不一致 %d 点（%.1f%%）" % [total, diff, 100.0 * float(diff) / float(maxi(total, 1))])
	# 再打几个具体点
	for ll in [[114.5, 37.0], [115.0, 36.5], [115.5, 37.5], [116.0, 36.0], [114.0, 37.5]]:
		var h2: float = TG.dem_at(ll[0], ll[1])
		var l2: int = TG.landform_kind(ll[0], ll[1], h2)
		var b2: int = TG.kind_baked(ll[0], ll[1])
		print("[点] %.2f,%.2f h=%.0f 实时=%d(%s) 烘焙=%d(%s)"
				% [ll[0], ll[1], h2, l2, TG.LF_NAMES[l2], b2, TG.LF_NAMES[b2]])
	quit()
