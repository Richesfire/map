extends CanvasLayer

## ==============================================================
## 加载过渡：睡醒的感觉
##
## 用两条黑边（上下眼皮）+ 一层暗幕做：
##   合眼 cover()：先压暗，再让上下黑边合拢，把画面盖死
##   睁眼 reveal()：黑边从中间往上下退开，同时暗幕淡出，露出一条缝再全开
##
## 注册成 autoload（名字 Wake），切场景时不会被销毁。
##   await Wake.cover()
##   ...
##   await Wake.reveal()
## ==============================================================

const OPEN_TIME := 1.15      # 睁眼总时长
const CLOSE_TIME := 0.45

var _fade: ColorRect
var _lid_top: ColorRect
var _lid_bottom: ColorRect

var _tween: Tween


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS

	_fade = ColorRect.new()
	_fade.color = Color(0, 0, 0, 0)
	_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_fade)

	_lid_top = ColorRect.new()
	_lid_top.color = Color(0, 0, 0, 1)
	_lid_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lid_top)

	_lid_bottom = ColorRect.new()
	_lid_bottom.color = Color(0, 0, 0, 1)
	_lid_bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_lid_bottom)

	get_viewport().size_changed.connect(_resize)
	_resize()
	# 开局就是闭着的，由新场景自己决定什么时候睁眼
	_lid_top.visible = true
	_lid_bottom.visible = true
	_set_openness(0.0)


func _resize() -> void:
	var vp := get_viewport().get_visible_rect().size
	_fade.size = vp
	_lid_top.size = Vector2(vp.x, vp.y * 0.5)
	_lid_bottom.size = Vector2(vp.x, vp.y * 0.5)
	_lid_bottom.position = Vector2(0.0, vp.y * 0.5)


## 眼睛睁开多少：0 = 全黑，1 = 全开
func _set_openness(k: float) -> void:
	var vp := get_viewport().get_visible_rect().size
	var half := vp.y * 0.5
	_lid_top.size = Vector2(vp.x, half * (1.0 - k))
	_lid_top.position = Vector2.ZERO
	_lid_bottom.size = Vector2(vp.x, half * (1.0 - k))
	_lid_bottom.position = Vector2(0.0, vp.y - half * (1.0 - k))
	var show_lids := k < 0.999
	_lid_top.visible = show_lids
	_lid_bottom.visible = show_lids


## 闭眼：压暗 + 合拢，结束时全黑
func cover() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_lid_top.visible = true
	_lid_bottom.visible = true
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(_fade, "color:a", 0.75, CLOSE_TIME * 0.8)
	_tween.tween_method(_set_openness, _current_openness(), 0.0, CLOSE_TIME)
	await _tween.finished
	_fade.color.a = 1.0


## 睁眼：从黑到全亮
func reveal() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_fade.color.a = 1.0
	_set_openness(0.0)
	_lid_top.visible = true
	_lid_bottom.visible = true
	# 第一段：先露出一条缝
	var t1 := create_tween()
	t1.tween_method(_set_openness, 0.0, 0.45, OPEN_TIME * 0.45)
	t1.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await t1.finished

	# 第二段：完全睁开 + 暗幕淡出
	var t2 := create_tween()
	t2.set_parallel(true)
	t2.tween_property(_fade, "color:a", 0.0, OPEN_TIME * 0.55)
	t2.tween_method(_set_openness, 0.45, 1.0, OPEN_TIME * 0.55)
	t2.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	await t2.finished
	_lid_top.visible = false
	_lid_bottom.visible = false
	_fade.color.a = 0.0


func _current_openness() -> float:
	var vp := get_viewport().get_visible_rect().size
	if vp.y <= 0.0:
		return 0.0
	return clampf(1.0 - (_lid_top.size.y * 2.0) / vp.y, 0.0, 1.0)
