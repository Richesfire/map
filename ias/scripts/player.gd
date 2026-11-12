extends CharacterBody3D
## 角色：胶囊 + 第三人称相机 + 灵魂模式 + 近战（攻击/格挡/受伤）

signal hurt(amount: float)
signal died
signal incoming(dir: String)

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

# 战斗
var hp := 100.0
var max_hp := 100.0
var attacking := false
var attack_t := 0.0
var attack_cd := 0.0
var blocking := false
var _hit_done := false
var damage_taken := 0.0
var attack_dir := "thrust"        # left / right / up / thrust（下刺）
var block_dir := "down"           # left / right / up / down
var _mouse_acc := Vector2.ZERO    # 平滑累积的鼠标位移，用来判攻击方向
var _last_mouse := Vector2.ZERO   # 最近一帧原始位移，用来判格挡方向

const SPEED := 9.0
const SOUL_SPEED := 150.0
const GRAVITY := 25.0
const ATTACK_WINDUP := 0.18
const ATTACK_RECOVER := 0.55
const ATTACK_RANGE := 2.9
const ATTACK_ARC := 0.9          # 约 ±51°
const ATTACK_DAMAGE := 26.0


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
	if attack_cd > 0.0:
		attack_cd -= delta
	if attacking:
		attack_t += delta
		if not _hit_done and attack_t >= ATTACK_WINDUP:
			_hit_done = true
			_do_hit()
		if attack_t >= ATTACK_WINDUP + 0.22:
			attacking = false
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
	var spd := SPEED * (0.45 if blocking else 1.0)
	var v := b * dir.normalized() * spd
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
	attacking = false
	blocking = false
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


# ---------------- 战斗 ----------------
## 鼠标位移判四向：|x|>|y| 分左右，否则分上劈/下刺
func _judge_mouse_dir(m: Vector2) -> String:
	if absf(m.x) > absf(m.y):
		return "right" if m.x > 0.0 else "left"
	return "thrust" if m.y > 0.0 else "up"


func start_attack() -> void:
	if attack_cd > 0.0 or attacking:
		return
	# 鼠标动过才换方向；没动就沿用上一次（默认下刺）
	if _mouse_acc.length() > 6.0:
		attack_dir = _judge_mouse_dir(_mouse_acc)
	_mouse_acc = Vector2.ZERO
	attacking = true
	attack_t = 0.0
	_hit_done = false
	attack_cd = ATTACK_RECOVER


func _do_hit() -> void:
	var fwd := Vector3(-sin(yaw), 0.0, -cos(yaw))
	# 四向的判定差异：横斩扇形宽、上劈居中、下刺远而窄
	var reach := ATTACK_RANGE
	var arc := ATTACK_ARC
	var dmg := ATTACK_DAMAGE
	match attack_dir:
		"left", "right":
			arc = 1.05
			reach = 2.7
		"up":
			arc = 0.75
			reach = 2.9
			dmg = 24.0
		"thrust":
			arc = 0.45
			reach = 3.4
			dmg = 30.0
	for e in get_tree().get_nodes_in_group("enemies"):
		if not is_instance_valid(e):
			continue
		var to: Vector3 = e.global_position - global_position
		to.y = 0.0
		if to.length() > reach:
			continue
		if fwd.dot(to.normalized()) < cos(arc):
			continue
		e.take_damage(dmg, attack_dir)


func take_damage(d: float, dir: String = "") -> void:
	if hp <= 0.0:
		return
	# 格挡：方向对上完全挡住，方向不对只减伤 55%
	var mult := 1.0
	if blocking:
		# 敌人的下刺叫 thrust，玩家的格挡方向叫 down，先统一
		var need := "down" if dir == "thrust" else dir
		mult = 0.05 if (need != "" and need == block_dir) else 0.45
	var real := d * mult
	hp = maxf(hp - real, 0.0)
	damage_taken += real
	hurt.emit(real)
	if hp <= 0.0:
		died.emit()


## 敌人起手时通知来袭方向（没有动画时给玩家一个文字预警）
func show_incoming(dir: String) -> void:
	incoming.emit(dir)


func respawn() -> void:
	hp = max_hp
	attacking = false
	soul = false
	global_position = Vector3(0, terrain.height_xyz(0, 0) + 3.0, 0)
	velocity = Vector3.ZERO


func _input(e: InputEvent) -> void:
	if map_open:
		return
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if soul and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			soul = false
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
				if mb.pressed:
					start_attack()
			elif mb.pressed:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			blocking = mb.pressed
			if blocking:
				if _last_mouse.length() > 1.0:
					var bd := _judge_mouse_dir(_last_mouse)
					block_dir = "down" if bd == "thrust" else bd
				attacking = false
				attack_cd = 0.0
	elif e is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if look_locked:
			return
		var mm := e as InputEventMouseMotion
		_last_mouse = mm.relative
		_mouse_acc = _mouse_acc * 0.8 + mm.relative
		if soul:
			soul_yaw -= mm.relative.x * 0.003
			soul_pitch = clampf(soul_pitch - mm.relative.y * 0.003, -1.5, 1.5)
		else:
			yaw -= mm.relative.x * 0.003
			pitch = clampf(pitch - mm.relative.y * 0.003, -1.2, 0.6)
