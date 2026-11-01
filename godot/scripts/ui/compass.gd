class_name Compass
extends Control

## ==============================================================
## 顶部方向标（上古卷轴那种）
##
## 一条横向刻度带，只显示相机**正前方 ±SPAN/2** 的范围：
##   每 15° 一个短刻度，每 45° 一个长刻度 + 方位字母
##   附近的地标（咸阳、邯郸…）会作为标记出现在带子上
##
## 朝向取相机的水平朝向；世界约定 x=东、z=南，所以正北是 -z。
## ==============================================================

const SPAN_DEG := 110.0        # 显示跨度
const STRIP_W := 620.0
const STRIP_H := 34.0

var player: Node3D
var camera: Camera3D
var map: MapWorld
var annotations: Array = []

var _names := {
	0.0: "北", 45.0: "东北", 90.0: "东", 135.0: "东南",
	180.0: "南", 225.0: "西南", 270.0: "西", 315.0: "西北",
}


func setup(p: Node3D, cam: Camera3D, m: MapWorld, ann: Array) -> void:
	player = p
	camera = cam
	map = m
	annotations = ann
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2(STRIP_W, STRIP_H + 34.0)


func _process(_delta: float) -> void:
	queue_redraw()


## 相机当前朝向（0=北, 90=东），单位度，0~360
func _facing() -> float:
	if camera == null:
		return 0.0
	var f: Vector3 = -camera.global_transform.basis.z
	return fposmod(rad_to_deg(atan2(f.x, -f.z)), 360.0)


## 从玩家指向某个世界坐标的方位角
func _bearing_to(world_pos: Vector3) -> float:
	if player == null:
		return 0.0
	var d: Vector3 = world_pos - player.global_position
	if d.length() < 1.0:
		return 0.0
	return fposmod(rad_to_deg(atan2(d.x, -d.z)), 360.0)


func _delta(a: float, b: float) -> float:
	var d := fposmod(a - b + 180.0, 360.0) - 180.0
	return d


func _draw() -> void:
	var facing := _facing()
	var cx := size.x * 0.5
	var cy := 20.0
	var half := SPAN_DEG * 0.5

	# ---- 底条（边缘柔化）
	for i in 32:
		var t := float(i) / 31.0
		var a := 0.42 * (1.0 - pow(absf(t * 2.0 - 1.0), 2.0))
		draw_rect(Rect2(t * size.x, 6.0, size.x / 31.0 + 1.0, STRIP_H - 10.0),
				Color(0.04, 0.05, 0.06, a))

	var font := ThemeDB.fallback_font

	# ---- 刻度
	for deg in range(0, 360, 15):
		var d := _delta(float(deg), facing)
		if absf(d) > half:
			continue
		var x := cx + (d / half) * (size.x * 0.5)
		var fade := 0.55 + 0.45 * (1.0 - pow(absf(d) / half, 3.0))
		var major: bool = int(deg) % 45 == 0
		var h := 9.0 if major else 5.0
		draw_line(Vector2(x, cy - h), Vector2(x, cy + h * 0.4),
				Color(0.92, 0.88, 0.74, 0.9 * fade), 1.5 if major else 1.0)
		if major and font != null:
			var label: String = _names.get(float(deg), "")
			var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
			draw_string_outline(font, Vector2(x - w * 0.5, cy + 30.0), label,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 17, 4,
					Color(0, 0, 0, 0.8 * fade))
			draw_string(font, Vector2(x - w * 0.5, cy + 30.0), label,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 17,
					Color(1.0, 0.96, 0.82, fade))

	# ---- 地标
	if map != null and player != null:
		for e in annotations:
			var a := e as MapAnnotation
			if a == null:
				continue
			var pos := map.render_position(a.dir)
			var dist := player.global_position.distance_to(pos)
			if dist < 100.0 or dist > 200000.0:
				continue
			var d := _delta(_bearing_to(pos), facing)
			if absf(d) > half:
				continue
			var x := cx + (d / half) * (size.x * 0.5)
			var fade := 0.55 + 0.45 * (1.0 - pow(absf(d) / half, 3.0))
			var km := dist / 1000.0
			# 点贴着刻度带顶部，黄字放在带子中间，不再被屏幕顶边裁掉
			var py := cy - 15.0
			draw_circle(Vector2(x, py), 3.0, Color(1.0, 0.84, 0.36, fade))
			if font != null:
				var txt := "%s %.0fkm" % [a.label, km] if km >= 1.0 else a.label
				var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
				draw_string_outline(font, Vector2(x - w * 0.5, cy + 4.0), txt,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4,
						Color(0, 0, 0, 0.85 * fade))
				draw_string(font, Vector2(x - w * 0.5, cy + 4.0), txt,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 13,
						Color(1.0, 0.88, 0.42, fade))

	# ---- 中央指示
	draw_colored_polygon(PackedVector2Array([
		Vector2(cx - 6.0, 4.0), Vector2(cx + 6.0, 4.0), Vector2(cx, 12.0),
	]), Color(1.0, 0.95, 0.8, 0.95))
	draw_line(Vector2(cx, 12.0), Vector2(cx, cy + 3.0), Color(1, 0.95, 0.8, 0.5), 1.0)
