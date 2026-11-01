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

	# ---- 旅行准星：只在还没定下目标时画（定下后只画球上那个，跟着球转）
	if dialog._target_dir == Vector3.ZERO:
		_draw_reticle(dialog.pin_pos())

	# ---- 旅行目标标记：跟着球体一起转
	if dialog._target_dir != Vector3.ZERO:
		var tp := dialog.project(dialog._target_dir)
		if tp.x >= 0.0:
			draw_circle(tp, 9.0, Color(0.98, 0.80, 0.25, 0.95))
			draw_arc(tp, 15.0, 0.0, TAU, 28, Color(0.98, 0.80, 0.25, 0.75), 2.5)
			draw_line(tp + Vector2(-18, 0), tp + Vector2(18, 0), Color(1, 1, 1, 0.9), 1.5)
			draw_line(tp + Vector2(0, -18), tp + Vector2(0, 18), Color(1, 1, 1, 0.9), 1.5)
			if font != null:
				draw_string(font, tp + Vector2(18, -10), "旅行目标 · 回车", HORIZONTAL_ALIGNMENT_LEFT,
						-1, 15, Color(1, 0.88, 0.5, 0.98))

	# ---- 玩家当前位置（红点 + 光环）
	var pm := dialog.project(dialog.world.region_center_dir)
	if pm.x >= 0.0:
		draw_circle(pm, 7.0, Color(1, 0.33, 0.24, 0.95))
		draw_arc(pm, 12.0, 0.0, TAU, 28, Color(1, 0.33, 0.24, 0.6), 2.0)
		if font != null:
			draw_string(font, pm + Vector2(14, 5), "你在这里", HORIZONTAL_ALIGNMENT_LEFT,
					-1, 14, Color(1, 0.75, 0.6, 0.95))


func _draw_reticle(pp: Vector2) -> void:
	draw_circle(pp, 15.0, Color(0.06, 0.05, 0.03, 0.55))
	draw_arc(pp, 15.0, 0.0, TAU, 32, Color(0.98, 0.82, 0.32, 0.95), 2.5)
	draw_line(pp + Vector2(-22, 0), pp + Vector2(-8, 0), Color(0.98, 0.82, 0.32), 2.0)
	draw_line(pp + Vector2(8, 0), pp + Vector2(22, 0), Color(0.98, 0.82, 0.32), 2.0)
	draw_line(pp + Vector2(0, -22), pp + Vector2(0, -8), Color(0.98, 0.82, 0.32), 2.0)
	draw_line(pp + Vector2(0, 8), pp + Vector2(0, 22), Color(0.98, 0.82, 0.32), 2.0)
