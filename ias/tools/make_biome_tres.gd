extends SceneTree
## 一次性工具：把内置配置写成 .tres（godot --headless --script res://tools/make_biome_tres.gd）

func _init() -> void:
	var Lib = load("res://scripts/biome_library.gd")
	var PS = load("res://scripts/biome_profile.gd")
	DirAccess.make_dir_recursive_absolute("res://data/biomes")
	var saved := 0
	for d in Lib.DEFAULTS:
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
		var path := "res://data/biomes/%02d_%s.tres" % [saved, d["id"]]
		var err := ResourceSaver.save(p, path)
		if err == OK:
			saved += 1
		else:
			print("保存失败 ", path, " err=", err)
	print("[工具] 已写出 %d 个 .tres" % saved)
	quit()
