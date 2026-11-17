extends SceneTree
## 诊断：同一块区域里「实时分类」和「烘焙编号图」各类的占比，看烘焙图是不是过期了。
## 用法：godot --headless --path ias --script res://tools/probe_cmp.gd -- 113 119 34 39 0.1

const TG := preload("res://scripts/terrain_gen.gd")


func _init() -> void:
	TG.ensure_loaded()
	var a := OS.get_cmdline_user_args()
	var lon0 := float(a[0]) if a.size() > 0 else 113.0
	var lon1 := float(a[1]) if a.size() > 1 else 119.0
	var lat0 := float(a[2]) if a.size() > 2 else 34.0
	var lat1 := float(a[3]) if a.size() > 3 else 39.0
	var st := float(a[4]) if a.size() > 4 else 0.1
	var live := {}
	var baked := {}
	var n := 0
	var lat := lat1
	while lat >= lat0:
		var lon := lon0
		while lon <= lon1:
			var h: float = TG.dem_at(lon, lat)
			var k1: int = TG.landform_kind(lon, lat, h)
			var k2: int = TG.kind_baked(lon, lat)
			live[k1] = int(live.get(k1, 0)) + 1
			baked[k2] = int(baked.get(k2, 0)) + 1
			n += 1
			lon += st
		lat -= st
	print("=== %.1f-%.1fE %.1f-%.1fN，%d 点 ===" % [lon0, lon1, lat0, lat1, n])
	print("%-6s %6s %6s %6s" % ["类别", "实时", "烘焙", "差"])
	var keys := {}
	for k in live:
		keys[k] = true
	for k in baked:
		keys[k] = true
	var kk: Array = keys.keys()
	kk.sort()
	for k in kk:
		var l: int = int(live.get(k, 0))
		var b: int = int(baked.get(k, 0))
		if l == 0 and b == 0:
			continue
		var p1 := 100.0 * float(l) / float(n)
		var p2 := 100.0 * float(b) / float(n)
		print("%-6s %5.1f%% %5.1f%% %+5.1f" % [TG.LF_NAMES[k], p1, p2, p1 - p2])
	quit()
