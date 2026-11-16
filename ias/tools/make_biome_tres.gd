extends SceneTree
## 一次性工具：把内置配置写成 .tres
##   godot --headless --path ias --script res://tools/make_biome_tres.gd
##
## 文件名 = 「地貌编号_配置id」，编号取自 biome_library.gd 的 LF_PROFILE，
## 不再按 DEFAULTS 的数组下标编号。—— 历史教训：以前按下标编号，DEFAULTS 顺序
## 变过一次，目录里就留下两套重名文件（36 个），加载端按排序取下标后 18..28 号
## 地貌全部串位（盐碱地拿到三角洲配置）。这里顺便把不符合规范的老文件删掉。
##
## 注意：数值取自 DEFAULTS；2026-11-16 起 DEFAULTS 已按 .tres 现值重新同步过
## （以前它停在旧一轮调参，跑一次这个工具就会把手工调好的参数冲掉，
##  `probe_biome.gd` 会把这类差异打出来）。改参数请改 .tres 或 DEFAULTS 其中一处再同步另一处。

func _init() -> void:
	var Lib = load("res://scripts/biome_library.gd")
	var PS = load("res://scripts/biome_profile.gd")
	DirAccess.make_dir_recursive_absolute("res://data/biomes")
	var by_id := {}
	for d in Lib.DEFAULTS:
		by_id[d["id"]] = d
	var keys: Array = Lib.LF_PROFILE.keys()
	keys.sort()
	var keep := {}
	var saved := 0
	for k in keys:
		var pc: String = Lib.LF_PROFILE[k]
		if not by_id.has(pc):
			print("[工具] 编号 %d 的配置 %s 不在 DEFAULTS 里，跳过" % [k, pc])
			continue
		var d: Dictionary = by_id[pc]
		var p: Resource = PS.new()
		p.id = d["id"]
		p.display_name = d["display_name"]
		p.category = d["category"]
		p.subtype = d["subtype"]
		var dt: Array[int] = []
		for v in d["disp_tiles"]:
			dt.append(int(v))
		p.disp_tiles = dt
		p.disp_amp = float(d["disp_amp"])
		p.disp_scale = float(d["disp_scale"])
		var tt: Array[int] = []
		for v in d["tex_tiles"]:
			tt.append(int(v))
		p.tex_tiles = tt
		p.special_kind = int(d.get("special_kind", 0))
		p.special_density = float(d.get("special_density", 0.0))
		p.grass = float(d["grass"])
		p.shrub = float(d["shrub"])
		p.rock = float(d["rock"])
		p.tree = float(d["tree"])
		var path := "res://data/biomes/%02d_%s.tres" % [k, pc]
		keep[path.get_file()] = true
		var err := ResourceSaver.save(p, path)
		if err == OK:
			saved += 1
		else:
			print("[工具] 保存失败 ", path, " err=", err)
	# 清掉不属于这套编号的老文件（重名批次留下的）
	var d2 := DirAccess.open("res://data/biomes")
	if d2 != null:
		for f in d2.get_files():
			if not f.ends_with(".tres") or keep.has(f):
				continue
			print("[工具] 删除多余文件 ", f)
			d2.remove(f)
	print("[工具] 已写出 %d 个 .tres（编号 = 地貌号）" % saved)
	quit()
