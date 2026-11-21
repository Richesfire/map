extends CharacterBody3D
## 角色：胶囊 + 第三人称相机 + 灵魂观察模式。
## 战斗（攻击/格挡/受伤）已剥离，等战斗系统合入后再接。

var cam: Camera3D
var terrain: Node3D
var map_open := false
var look_locked := false   # 选 TAB 轮盘时锁视角

var yaw := 0.0
var pitch := -0.2
var _cam_dist := 6.0
var soul := false
var soul_pos := Vector3.ZERO
var soul_yaw := 0.0
var soul_pitch := 0.0

const SPEED := 9.0
const SOUL_SPEED := 150.0
const GRAVITY := 25.0


func setup(t: Node3D) -> void:
	terrain = t
	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.8
	col.shape = cap
	col.position.y = 0.9
	add_child(col)

	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.8
	body.mesh = cm
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(0.88, 0.88, 0.90)
	body.material_override = bm
	body.position.y = 0.9
	add_child(body)

	cam = Camera3D.new()
	cam.far = 200000.0
	add_child(cam)
	cam.current = true

	global_position = Vector3(0, terrain.height_xyz(0, 0) + 3.0, 0)
	soul_pos = global_position + Vector3(0, 30, 30)


func _physics_process(delta: float) -> void:
	if cam == null:
		return
	if soul:
		_soul(delta)
	else:
		_walk(delta)
	_update_cam(delta)


func _walk(delta: float) -> void:
	# 看地图时人物不该盲走
	if map_open:
		velocity.x = 0.0
		velocity.z = 0.0
		velocity.y -= GRAVITY * delta
		move_and_slide()
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		dir.z += 1
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		dir.x += 1
	var b := Basis(Vector3.UP, yaw)
	var v := b * dir.normalized() * SPEED
	velocity.x = v.x
	velocity.z = v.z
	velocity.y -= GRAVITY * delta
	move_and_slide()


## 从当前摄像机位置与朝向脱离身体（策划案 7.5：进入瞬间画面连续）
func enter_soul() -> void:
	if soul:
		return
	soul = true
	soul_pos = cam.global_position
	soul_yaw = yaw
	soul_pitch = pitch
	print("[角色] 灵魂模式（TAB 上）")


func exit_soul() -> void:
	soul = false


func _soul(delta: float) -> void:
	if map_open:
		return
	var dir := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		dir.z -= 1
	if Input.is_key_pressed(KEY_S):
		dir.z += 1
	if Input.is_key_pressed(KEY_A):
		dir.x -= 1
	if Input.is_key_pressed(KEY_D):
		dir.x += 1
	if Input.is_key_pressed(KEY_SPACE):
		dir.y += 1
	if Input.is_key_pressed(KEY_Z):
		dir.y -= 1
	var b := Basis.from_euler(Vector3(soul_pitch, soul_yaw, 0))
	soul_pos += b * dir.normalized() * SOUL_SPEED * delta


func _update_cam(delta: float) -> void:
	if soul:
		cam.global_position = soul_pos
		cam.rotation = Vector3(soul_pitch, soul_yaw, 0)
	else:
		var target := global_position + Vector3(0, 1.7, 0)
		var b := Basis.from_euler(Vector3(pitch, yaw, 0.0))
		var dist := 6.0
		var want := target + b * Vector3(0.0, 0.0, dist)
		var free := dist
		# 弹簧臂：被地形挡住时只把相机拉近，不限制俯仰（否则上坡看平原抬不起头）
		if terrain != null:
			var space := get_world_3d().direct_space_state
			var q := PhysicsRayQueryParameters3D.create(target, want, 1, [get_rid()])
			q.collide_with_areas = false
			var hit := space.intersect_ray(q)
			if not hit.is_empty():
				free = clampf(target.distance_to(hit.position) - 0.45, 0.9, dist)
		# 距离做平滑：撞墙立刻拉近（防穿模），离开时缓慢推回，避免沿山壁走时上下抖
		if free < _cam_dist:
			_cam_dist = free
		else:
			_cam_dist = lerpf(_cam_dist, free, clampf(delta * 5.0, 0.0, 1.0))
		var pos := target + b * Vector3(0.0, 0.0, _cam_dist)
		if terrain != null and free >= dist - 0.01:
			var gh: float = terrain.height_xyz(pos.x, pos.z) + 0.35
			if pos.y < gh:
				pos = Vector3(pos.x, gh, pos.z)
		cam.global_position = pos
		cam.look_at(target, Vector3.UP)


func respawn() -> void:
	soul = false
	global_position = Vector3(0, terrain.height_xyz(0, 0) + 3.0, 0)
	velocity = Vector3.ZERO


func _input(e: InputEvent) -> void:
	if map_open:
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			if soul:
				soul = false
				return
			if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if look_locked:
			return
		var mm := e as InputEventMouseMotion
		if soul:
			soul_yaw -= mm.relative.x * 0.003
			soul_pitch = clampf(soul_pitch - mm.relative.y * 0.003, -1.5, 1.5)
		else:
			yaw -= mm.relative.x * 0.003
			pitch = clampf(pitch - mm.relative.y * 0.003, -1.2, 0.6)
