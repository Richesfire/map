extends SceneTree
## 单点诊断：给一串 "经度,纬度"，打印高程 / 实时分类 / 烘焙编号 / 掩膜是否判水。
## 用法：godot --headless --path ias --script res://tools/probe_at.gd -- 120.5,34 121.0,33.5

const TG := preload("res://scripts/terrain_gen.gd")


func _init() -> void:
	TG.ensure_loaded()
	for a in OS.get_cmdline_user_args():
		if not a.contains(","):
			continue
		var p := a.split(",")
		var lon := float(p[0])
		var lat := float(p[1])
		var h: float = TG.dem_at(lon, lat)
		var live: int = TG.landform_kind(lon, lat, h)
		var baked: int = TG.kind_baked(lon, lat)
		print("%8.3f,%7.3f  h=%6.0f  mask水=%s  实时=%2d(%-6s)  烘焙=%2d(%-6s)"
				% [lon, lat, h, str(TG.is_water(lon, lat)), live, TG.LF_NAMES[live],
				baked, TG.LF_NAMES[baked]])
	quit()
