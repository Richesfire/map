extends SceneTree
## 体检工具：地貌编号 → 生物群系配置 的对应是否正确，顺带打几个代表点的分类。
## 用法：godot --headless --path ias --script res://tools/probe_biome.gd
## 判据：第 k 行右边应当是 k 号地貌自己的配置（花岗岩山地 → mtn_granite）。

const TG := preload("res://scripts/terrain_gen.gd")
const Lib := preload("res://scripts/biome_library.gd")


func _init() -> void:
	TG.ensure_loaded()
	print("[体检] 配置数 = %d" % Lib.count())
	print("[体检] 编号 -> 配置")
	for k in 29:
		var p: Dictionary = Lib.profile_for(k)
		var nm: String = TG.LF_NAMES[k] if k < TG.LF_NAMES.size() else "?"
		print("  %2d %-8s -> %s" % [k, nm, p.get("id", "?")])
	var pts := [
		["柴达木盐碱", 94.5, 37.0],
		["塔克拉玛干", 83.5, 39.0],
		["太行山东麓", 113.6, 37.5],
		["江南红壤", 115.0, 27.0],
		["滇东喀斯特", 105.0, 24.5],
		["陕北黄土", 109.0, 36.5],
	]
	for pt in pts:
		var h: float = TG.dem_at(pt[1], pt[2])
		var k2: int = TG.landform_kind(pt[1], pt[2], h)
		var kb: int = TG.kind_baked(pt[1], pt[2])
		print("[点] %-8s %6.2f,%5.2f h=%5.0f 实时=%d(%s) 烘焙=%d 配置=%s"
				% [pt[0], pt[1], pt[2], h, k2, TG.LF_NAMES[k2], kb,
				Lib.profile_for(k2).get("id", "?")])
	# 内置默认（DEFAULTS）vs data/biomes 里的 .tres：两份配置是不是同一套数值。
	# 实际生效的是 .tres；DEFAULTS 只在 .tres 缺失时兜底，但两边不一致会误导人。
	var fields := ["disp_tiles", "disp_amp", "disp_scale", "tex_tiles",
			"grass", "shrub", "rock", "tree", "special_kind", "special_density"]
	var diff := 0
	for k in 29:
		var p: Dictionary = Lib.profile_for(k)
		var d := {}
		for dd in Lib.DEFAULTS:
			if String(dd["id"]) == String(p["id"]):
				d = dd
				break
		if d.is_empty():
			continue
		var bad: Array = []
		for f in fields:
			if not d.has(f):
				continue
			if str(d[f]) != str(p.get(f, "")):
				bad.append(f)
		if not bad.is_empty():
			diff += 1
			print("[默认值差异] %-14s %s" % [p["id"], ", ".join(bad)])
	print("[体检] 内置默认与 .tres 不一致的配置：%d / 29" % diff)
	quit()
