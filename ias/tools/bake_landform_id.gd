extends SceneTree
## 烘焙地貌编号贴图：调用游戏自己的 TG.landform_kind，保证地图配色与游戏一致。
## 用法：godot --headless --script res://tools/bake_landform_id.gd

const W := 8192
const H := 4096
const OUT := "res://data/landform_id.bin"


func _init() -> void:
	var tg = load("res://scripts/terrain_gen.gd")
	tg.ensure_loaded()
	var t0 := Time.get_ticks_msec()
	var buf := PackedByteArray()
	buf.resize(W * H)
	for y in H:
		var lat: float = 90.0 - (float(y) + 0.5) / float(H) * 180.0
		for x in W:
			var lon: float = -180.0 + (float(x) + 0.5) / float(W) * 360.0
			var h: float = tg.dem_at(lon, lat)
			var lf: int = tg.landform_kind(lon, lat, h)
			buf[y * W + x] = lf & 0xFF
		if y % 128 == 0:
			print("  row %d / %d  %d ms" % [y, H, Time.get_ticks_msec() - t0])
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	f.store_buffer(buf)
	f.close()
	print("[烘焙] 地貌编号 %dx%d -> %s，用时 %d ms" % [W, H, OUT, Time.get_ticks_msec() - t0])
	quit()
