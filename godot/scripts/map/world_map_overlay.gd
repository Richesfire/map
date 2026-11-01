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

	# ---- 玩家当前位置（红点 + 光环）
	var pp := dialog.project(dialog.world.region_center_dir)
	if pp.x >= 0.0:
		draw_circle(pp, 7.0, Color(1, 0.33, 0.24, 0.95))
		draw_arc(pp, 12.0, 0.0, TAU, 28, Color(1, 0.33, 0.24, 0.6), 2.0)
		if font != null:
			draw_string(font, pp + Vector2(14, 5), "你在这里", HORIZONTAL_ALIGNMENT_LEFT,
					-1, 14, Color(1, 0.75, 0.6, 0.95))
