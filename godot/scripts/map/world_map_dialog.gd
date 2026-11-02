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
var _orbiting := false
var explored_gate: Exploration = null
var _notice := ""          # 屏幕提示（例如海洋「敬请期待」）
var _pin_pos := Vector2(56, 240)
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
	# 每次打开都按最新足迹重建迷雾（只遍历格子，几毫秒）
	if explored_gate != null:
		_globe.refresh_fog(explored_gate)
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
			if mb.pressed and _near_pin(mb.position):
				_pin_dragging = true
				_pin_pos = mb.position
				get_viewport().set_input_as_handled()
				return
			if not mb.pressed and _orbiting:
				_orbiting = false
				_globe.save_state()
				get_viewport().set_input_as_handled()
				return
			if not mb.pressed and _pin_dragging:
				_pin_dragging = false
				var hit := _globe.pick(mb.position)
				if hit == Vector3.ZERO or _globe.project(hit).x < 0.0:
					_target_dir = Vector3.ZERO
					_pin_pos = Vector2(56, 240)
				else:
					_target_dir = hit
					_pin_pos = mb.position
				_overlay.queue_redraw()
				get_viewport().set_input_as_handled()
				return
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
			# 球面上 = 绕地轴转；工具栏里 = 不理；其余空白 = 环绕相机（换个角度看）
			if mb.pressed and _on_globe(mb.position):
				_dragging = true
			elif mb.pressed and not _inside_bar(mb.position):
				_orbiting = true
			else:
				_dragging = false
			get_viewport().set_input_as_handled()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(mb.position, 1.0)
			_overlay.queue_redraw()
			get_viewport().set_input_as_handled()
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(mb.position, -1.0)
			_overlay.queue_redraw()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _pin_dragging:
		var mmv := event as InputEventMouseMotion
		_pin_pos = mmv.position
		var hv := _globe.pick(mmv.position)
		# 只接受**可见半球**上的点。否则目标跑到球背面，
		# 投影会失败，准星就被迫回退到鼠标位置，看起来准星在这儿、坐标却在别处。
		if hv != Vector3.ZERO and _globe.project(hv).x >= 0.0:
			_target_dir = hv
		_overlay.queue_redraw()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _pin_dragging:
		var mm2 := event as InputEventMouseMotion
		_pin.position = mm2.position - Vector2(32, 32)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _orbiting:
		var mmo := event as InputEventMouseMotion
		_globe.orbit_by(mmo.relative)
		_overlay.queue_redraw()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		_globe.rotate_by(mm.relative)
		_overlay.queue_redraw()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and _target_dir != Vector3.ZERO and (k.keycode == KEY_ENTER or k.keycode == KEY_KP_ENTER):
			# 海里暂时去不了：不做海战，也没有水域系统
			if not _target_is_land():
				show_notice("这里是海洋 · 敬请期待")
				get_viewport().set_input_as_handled()
				return
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


## 鼠标是否落在准星上（半径 34 像素）
## 抓取半径要小：准星贴在球面上，半径太大会把想转地球的点击也吃掉，
## 表现就是我只想转地球，结果准星跟着跑了。16 像素大约是准星的视觉大小。
const PIN_GRAB_R := 16.0


func _near_pin(p: Vector2) -> bool:
	return p.distance_to(reticle_pos()) <= PIN_GRAB_R


## 准星当前画在哪：定了目标就跟着球走，没定就停在鼠标松手的位置
func reticle_pos() -> Vector2:
	if _target_dir != Vector3.ZERO:
		var sp := project(_target_dir)
		if sp.x >= 0.0:
			return sp                      # 可见半球：贴着球面
		return _globe.edge_point(_target_dir)   # 转到背面：贴在轮廓边缘
	return _pin_pos


func pin_pos() -> Vector2:
	return _pin_pos


## 地球贴图是否已生成完（预加载时用来判断）
func is_ready_for_map() -> bool:
	return _globe != null and _globe._tex != null


## 目标点是不是陆地
func _target_is_land() -> bool:
	if _target_dir == Vector3.ZERO or world == null or world.biome == null:
		return false
	return world.biome.is_land(_target_dir)


## 在地图上显示一条提示，2.5 秒后自动消失
func show_notice(text: String) -> void:
	_notice = text
	if _overlay != null:
		_overlay.queue_redraw()
	var tw := get_tree().create_timer(2.5)
	tw.timeout.connect(func():
		_notice = ""
		if _overlay != null:
			_overlay.queue_redraw())


## 诊断：把一批已知经纬度投影到屏幕上，用来核对贴图是否对位
func probe() -> void:
	var pts := [
		[0.0, 0.0], [90.0, 0.0], [180.0, 0.0], [-90.0, 0.0],
		[20.0, 0.0], [-60.0, 0.0], [108.7, 34.3],
	]
	for p in pts:
		var d := GeoSphere.lonlat_to_dir(float(p[0]), float(p[1]))
		var sp := project(d)
		print("[PROBE] lon=%7.1f lat=%5.1f -> screen %s" % [p[0], p[1], str(sp)])


## 目标是否在球背面（看不见）
func target_behind() -> bool:
	if _target_dir == Vector3.ZERO:
		return false
	return project(_target_dir).x < 0.0


## 诊断：检查背面方向的边缘点是否合理
func edge_test() -> void:
	var pts := [[0.0,0.0],[90.0,0.0],[180.0,0.0],[-90.0,0.0],[45.0,30.0],[-135.0,30.0]]
	for q in pts:
		var d := GeoSphere.lonlat_to_dir(float(q[0]), float(q[1]))
		var sp := project(d)
		var ep := _globe.edge_point(d)
		print("[EDGETEST] lon=%7.1f lat=%5.1f  proj=%s  edge=(%.0f,%.0f)  behind=%s" % [q[0], q[1], str(sp), ep.x, ep.y, str(sp.x < 0.0)])


## 鼠标是不是落在球面上
func _on_globe(p: Vector2) -> bool:
	return _globe != null and _globe.pick(p) != Vector3.ZERO


## 鼠标是不是在左侧工具栏里
func _inside_bar(p: Vector2) -> bool:
	if _bar == null:
		return false
	return Rect2(_bar.position, _bar.size).has_point(p)


## 朝鼠标所指的位置缩放：先把该点转到正前方，再改 FOV。
## 这样连续滚动就会一直往目标点钻进去，和高德那种手感一致。
func _zoom_at(p: Vector2, steps: float) -> void:
	print("[WHEEL] steps=%.1f zoom前=%.2f" % [steps, _globe.get_zoom() if _globe != null else -1.0])
	if _globe == null:
		return
	var hit := _globe.pick(p)

	# 没探索过的地方不能放大到细节级：既符合"没去过就不知道"，
	# 也免去为全世界烘焙高清贴图。
	# 缩放限制暂时关闭：迷雾只做视觉，不拦缩放。
	# （之前按"视野中心"判断，坐标系没对齐时会误判成未探索，导致完全放不大。）
	# 等区域高清贴图做好、探索数据稳定之后，再在这里恢复限制。

	# 纯变焦，不做任何自动转动。
	_globe.zoom_by(steps)

	# 把当前倍数写在地图左上角，方便确认滚轮到底有没有生效
	if _globe._loading != null:
		_globe._loading.text = "缩放 %.1f×   ·   拖动旋转 · Esc / M 关闭" % _globe.get_zoom()
