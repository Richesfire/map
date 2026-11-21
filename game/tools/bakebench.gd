extends SceneTree
## 离线烘焙基准：直接建一张 920x570 的画布，量"整屏烘完要多久"。
## 用法：godot --headless --script res://tools/bakebench.gd

func _init() -> void:
	var MD = load("res://scripts/map_detail.gd")
	var d = MD.new()
	d.setup(100.0, 27.0, 106.0, 23.0, 920, 570)
	var t0 := Time.get_ticks_msec()
	while not d.done():
		d.poll()
		OS.delay_usec(2000)
		if Time.get_ticks_msec() - t0 > 180000:
			print("TIMEOUT")
			break
	var ms := Time.get_ticks_msec() - t0
	var texels := 920 * 570
	print("bake_ms=", ms, "  texels=", texels,
			"  texel_per_s=", int(float(texels) * 1000.0 / maxf(float(ms), 1.0)),
			"  tiles=", d.tiles_done, "/", d.tiles_total)
	quit()
