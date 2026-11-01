class_name WorldMapDialog
extends Control

## ==============================================================
## 全屏世界地图：中间一台真实的地球仪
##
## M 打开 / 关闭。打开时冻结玩家、释放鼠标。
## 拖拽只转**球体**，底座和子午环不动。
##
## 图层：
##   Control（全屏，吃输入）
##    ├ 背景压暗 ColorRect
##    ├ WorldGlobeView（3D 球，铺满）
##    └ MapGlobeOverlay（标注点 + 名字，投影自 3D 相机）
## ==============================================================

signal closed
signal travel_requested(target_dir: Vector3)

var world: MapWorld
var annotations: Array = []

var _bg: ColorRect
var _globe: WorldGlobeView
var _overlay: MapGlobeOverlay
var _title: Label
var _dragging := false
var _built := false
var _target_dir := Vector3.ZERO
var _pin_dragging := false
var _pin: Panel
var _bar: ColorRect
var _pin_home := Vector2(24, 220)


func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE   # 输入走 _input，不靠 GUI 命中
	visible = false
	get_viewport().size_changed.connect(_layout)


func _ensure_built() -> void:
	if _built:
		return
	_built = true

	_bg = ColorRect.new()
	_bg.color = Color(0.0, 0.0, 0.0, 0.86)
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg)

	_globe = WorldGlobeView.new()
	_globe.name = "GlobeView"
	_globe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_globe)

	_overlay = MapGlobeOverlay.new()
	_overlay.dialog = self
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)
	# ---- 左侧工具栏：独立于 3D 视口，缩放不会改变它的大小
	_bar = ColorRect.new()
	_bar.color = Color(0.08, 0.09, 0.11, 0.55)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar)

	var tip := Label.new()
	tip.text = "鼠标移到地球仪上选目的地，回车出发"
	tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tip.add_theme_font_size_override("font_size", 13)
	tip.add_theme_color_override("font_color", Color(0.8, 0.82, 0.86))
	tip.position = Vector2(8, 24)
	tip.size = Vector2(100, 100)
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART






func open(map: MapWorld, ann: Array, center_dir: Vector3) -> void:
	_ensure_built()
	world = map
	annotations = ann
	visible = true
	_layout()

	_globe.world = world
	_globe.face_direction(center_dir)
	if _globe._tex == null:
		await get_tree().process_frame
		_globe.build_world_texture()
	_overlay.queue_redraw()


func close() -> void:
	visible = false
	_dragging = false
	closed.emit()


func is_open() -> bool:
	return visible


func _layout() -> void:
	var vp := get_viewport_rect().size
	position = Vector2.ZERO
	size = vp

	if _bg != null:
		_bg.position = Vector2.ZERO
		_bg.size = vp
	if _globe != null:
		_globe.position = Vector2.ZERO
		_globe.size = vp
	if _bar != null:
		_bar.position = Vector2.ZERO
		_bar.size = Vector2(112, vp.y)
	if _pin != null and not _pin_dragging and _target_dir == Vector3.ZERO:
		_pin.position = _pin_home
		_pin.size = Vector2(64, 64)
	if _title != null:
		_title.position = Vector2(24, 18)
	if _overlay != null:
		_overlay.position = Vector2.ZERO
		_overlay.size = vp



# ================================================================ 输入
## 用 _input：全屏模态，不跟 GUI 命中测试和鼠标捕获较劲
func _input(event: InputEvent) -> void:
	if not visible:
		return

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if false:
				_pin_dragging = true
				_pin.position = mb.position - Vector2(32, 32)
				get_viewport().set_input_as_handled()
				return
			if not mb.pressed and _pin_dragging:
				_pin_dragging = false
				var hit := _globe.pick(mb.position)
				if hit == Vector3.ZERO:
					_target_dir = Vector3.ZERO
					_pin.position = _pin_home
				else:
					_target_dir = hit
					_pin.position = mb.position - Vector2(32, 32)
				_overlay.queue_redraw()
				get_viewport().set_input_as_handled()
				return
			_dragging = mb.pressed
			get_viewport().set_input_as_handled()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_globe.zoom_by(1.0)
			_overlay.queue_redraw()
			get_viewport().set_input_as_handled()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_globe.zoom_by(-1.0)
			_overlay.queue_redraw()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		var mmv := event as InputEventMouseMotion
		var hv := _globe.pick(mmv.position)
		var changed := hv != _target_dir
		_target_dir = hv
		if changed:
			_overlay.queue_redraw()
	elif event is InputEventMouseMotion and _pin_dragging:
		var mm2 := event as InputEventMouseMotion
		_pin.position = mm2.position - Vector2(32, 32)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_globe.rotate_by(mm.relative)
		_overlay.queue_redraw()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and _target_dir != Vector3.ZERO and (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER):
			travel_requested.emit(_target_dir)
			get_viewport().set_input_as_handled()
			return
		if k.pressed and not k.echo and (k.keycode == KEY_ESCAPE or k.keycode == KEY_BACKSPACE):
			close()
			get_viewport().set_input_as_handled()


# ================================================================ 查询
func project(dir: Vector3) -> Vector2:
	if _globe == null:
		return Vector2(-1.0, -1.0)
	return _globe.project(dir)


func get_globe() -> WorldGlobeView:
	return _globe


func get_view() -> Vector3:
	if _globe == null:
		return Vector3.FORWARD
	return _globe._pivot.global_transform.basis.z


func _pin_rect() -> Rect2:
	if _pin == null:
		return Rect2()
	return Rect2(_pin.position, Vector2(64, 64))


func target_dir() -> Vector3:
	return _target_dir


func clear_target() -> void:
	_target_dir = Vector3.ZERO
	if _pin != null:
		_pin.position = _pin_home
