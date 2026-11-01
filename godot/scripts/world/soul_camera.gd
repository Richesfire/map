extends Camera3D

## 自由飞行相机（原型用）
## 右键拖拽转视角，WASD 平移，Q/E 升降，Shift 加速，Esc 释放鼠标。
## 不用 InputMap，直接读物理键，省得你去项目设置里配。

@export var move_speed := 60.0
@export var boost_multiplier := 4.0
@export var look_sensitivity := 0.0025

var _yaw := 0.0
var _pitch := 0.0
var _looking := false


func _ready() -> void:
	# Node3D 默认的旋转顺序就是 YXZ，正好适合第一人称视角，不用改
	_yaw = rotation.y
	_pitch = rotation.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_looking = mb.pressed
			if _looking:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			else:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	elif event is InputEventMouseMotion:
		if _looking:
			var mm := event as InputEventMouseMotion
			_yaw -= mm.relative.x * look_sensitivity
			_pitch = clampf(_pitch - mm.relative.y * look_sensitivity,
					deg_to_rad(-89.0), deg_to_rad(89.0))
			rotation = Vector3(_pitch, _yaw, 0.0)

	elif event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and k.keycode == KEY_ESCAPE:
			_looking = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _process(delta: float) -> void:
	var basis := global_transform.basis
	var dir := Vector3.ZERO

	if Input.is_physical_key_pressed(KEY_W):
		dir -= basis.z
	if Input.is_physical_key_pressed(KEY_S):
		dir += basis.z
	if Input.is_physical_key_pressed(KEY_A):
		dir -= basis.x
	if Input.is_physical_key_pressed(KEY_D):
		dir += basis.x
	if Input.is_physical_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_Q):
		dir -= Vector3.UP

	if dir.length_squared() > 0.0:
		var speed := move_speed
		if Input.is_physical_key_pressed(KEY_SHIFT):
			speed *= boost_multiplier
		global_position += dir.normalized() * speed * delta
