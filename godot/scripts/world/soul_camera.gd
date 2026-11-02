extends Camera3D

## 自由飞行相机（原型用）
## 鼠标直接转视角（不需要按键），WASD 平移，空格升 / Ctrl 降，Shift 加速。
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
	# 不再需要按住右键：进入灵魂状态就锁定鼠标，直接跟随
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var mm := event as InputEventMouseMotion
		_yaw -= mm.relative.x * look_sensitivity
		_pitch = clampf(_pitch - mm.relative.y * look_sensitivity,
				deg_to_rad(-89.0), deg_to_rad(89.0))
		rotation = Vector3(_pitch, _yaw, 0.0)


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
	# 上升：空格（E 也保留）；下降：Ctrl（Q 也保留）
	if Input.is_physical_key_pressed(KEY_SPACE) or Input.is_physical_key_pressed(KEY_E):
		dir += Vector3.UP
	if Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_Q):
		dir -= Vector3.UP

	if dir.length_squared() > 0.0:
		var speed := move_speed
		if Input.is_physical_key_pressed(KEY_SHIFT):
			speed *= boost_multiplier
		global_position += dir.normalized() * speed * delta


## 被外部强行摆放位置/朝向之后，必须调用一次。
## 否则内部 _yaw/_pitch 还停在旧值，鼠标一动镜头就"啪"地跳回去。
func sync_angles() -> void:
	_yaw = rotation.y
	_pitch = rotation.x
