class_name MapGlobeOverlay
extends Control

## 地球仪上的覆盖层：标注点 + 名字 + 玩家位置。
## 球体和经纬网在 WorldGlobeView 里（3D），这里只画投影到屏幕上的东西。

var dialog: WorldMapDialog


func _draw() -> void:
	if dialog == null or dialog.world == null:
		return
	var font := ThemeDB.fallback_font

	# ---- 标注
	for entry in dialog.annotations:
		var a := entry as MapAnnotation
		if a == null:
			continue
		var p := dialog.project(a.dir)
		if p.x < 0.0:
			continue
		draw_circle(p, 4.0, Color(0.06, 0.04, 0.02, 0.95))
		draw_circle(p, 3.0, Color(1.0, 0.84, 0.36))
		if font != null:
			draw_string(font, p + Vector2(8, 5), a.label, HORIZONTAL_ALIGNMENT_LEFT,
					-1, 15, Color(1, 1, 1, 0.96))

	# ---- 旅行准星：只有一个。定了目标就跟着球面走，没定就停在鼠标松手的位置
	var behind: bool = dialog.target_behind()
	_draw_reticle(dialog.reticle_pos(), behind)

	# ---- 提示文字（海洋「敬请期待」等）
	if dialog._notice != "":
		var f2 := ThemeDB.fallback_font
		if f2 != null:
			var msg: String = dialog._notice
			var sz := Vector2(size.x * 0.5, 0)
			draw_string(f2, Vector2(sz.x - 150.0, size.y - 90.0), msg,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(1, 0.86, 0.42, 0.98))

	# ---- 玩家当前位置（红点 + 光环）
	var pm := dialog.project(dialog.world.region_center_dir)
	if pm.x >= 0.0:
		draw_circle(pm, 7.0, Color(1, 0.33, 0.24, 0.95))
		draw_arc(pm, 12.0, 0.0, TAU, 28, Color(1, 0.33, 0.24, 0.6), 2.0)
		if font != null:
			draw_string(font, pm + Vector2(14, 5), "你在这里", HORIZONTAL_ALIGNMENT_LEFT,
					-1, 14, Color(1, 0.75, 0.6, 0.95))


## 准星指向的经纬度和海陆
func _loc_text() -> String:
	if dialog._target_dir == Vector3.ZERO:
		return ""
	var ll := GeoSphere.dir_to_lonlat(dialog._target_dir)
	var ns := "N" if ll.y >= 0.0 else "S"
	var ew := "E" if ll.x >= 0.0 else "W"
	var kind := "陆地"
	if dialog.world != null and dialog.world.biome != null:
		if not dialog.world.biome.is_land(dialog._target_dir):
			kind = "海洋"
	return "%.1f°%s  %.1f°%s  %s" % [absf(ll.x), ew, absf(ll.y), ns, kind]


func _draw_reticle(pp: Vector2, behind: bool = false) -> void:
	draw_circle(pp, 15.0, Color(0.06, 0.05, 0.03, 0.55))
	var rc := Color(0.98, 0.82, 0.32, 0.95) if not behind else Color(0.62, 0.55, 0.32, 0.85)
	draw_arc(pp, 15.0, 0.0, TAU, 32, rc, 2.5)
	draw_line(pp + Vector2(-22, 0), pp + Vector2(-8, 0), Color(0.98, 0.82, 0.32), 2.0)
	draw_line(pp + Vector2(8, 0), pp + Vector2(22, 0), Color(0.98, 0.82, 0.32), 2.0)
	draw_line(pp + Vector2(0, -22), pp + Vector2(0, -8), Color(0.98, 0.82, 0.32), 2.0)
	draw_line(pp + Vector2(0, 8), pp + Vector2(0, 22), Color(0.98, 0.82, 0.32), 2.0)
	var txt := _loc_text()
	if txt != "":
		var f := ThemeDB.fallback_font
		if f != null:
			draw_string(f, pp + Vector2(26, 6), txt, HORIZONTAL_ALIGNMENT_LEFT,
					-1, 16, Color(1, 0.92, 0.55, 0.98))
