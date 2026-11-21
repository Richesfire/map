extends CharacterBody3D
## 盗匪（灰盒）：追击 → 近身攻击 → 死亡。
## 只做验证战斗手感需要的最小 AI，不做寻路（直线追击 + 卡住时侧移）。

var hp := 60.0
var max_hp := 60.0
var speed := 4.2
var atk_range := 2.6
var atk_damage := 11.0
var target: Node3D = null
var atk_dir := "thrust"
var terrain: Node3D = null

var _atk_cd := 0.0
var _windup := -1.0
var _stuck := 0.0
var _mesh: MeshInstance3D
var _mat: StandardMaterial3D

const GRAVITY := 25.0


func setup(t: Node3D, tgt: Node3D) -> void:
	terrain = t
	target = tgt
	add_to_group("enemies")

	var col := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.6
	col.shape = cap
	col.position.y = 0.8
	add_child(col)

	var body := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.35
	cm.height = 1.6
	body.mesh = cm
	_mat = StandardMaterial3D.new()
	_mat.albedo_color = Color(0.55, 0.18, 0.14)
	body.material_override = _mat
	body.position.y = 0.8
	add_child(body)
	_mesh = body


func _physics_process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	if player_dead:
		velocity.x = 0
		velocity.z = 0
		velocity.y -= GRAVITY * delta
		move_and_slide()
		return

	_atk_cd = maxf(_atk_cd - delta, 0.0)
	var to := target.global_position - global_position
	to.y = 0.0
	var dist := to.length()

	# 起手后判定
	if _windup >= 0.0:
		_windup -= delta
		if _windup < 0.0:
			if dist <= atk_range + 0.6:
				if target.has_method("take_damage"):
					target.take_damage(atk_damage, atk_dir)
				_atk_cd = 1.4
		velocity.x = 0
		velocity.z = 0
	else:
		if dist > atk_range:
			var dir := to.normalized()
			var v := dir * speed
			# 卡住就侧移一下
			if velocity.length() < 0.5 and dist > 3.0:
				_stuck += delta
				if _stuck > 0.6:
					v += dir.cross(Vector3.UP) * speed * 0.8
					_stuck = 0.0
			velocity.x = v.x
			velocity.z = v.z
			if v.length() > 0.2:
				look_at(Vector3(target.global_position.x, global_position.y, target.global_position.z), Vector3.UP)
		else:
			velocity.x = 0
			velocity.z = 0
			if _atk_cd <= 0.0:
				var dirs := ["left", "right", "up", "thrust"]
				atk_dir = dirs[randi() % dirs.size()]
				_windup = 0.35
				if target.has_method("show_incoming"):
					target.show_incoming(atk_dir)
	velocity.y -= GRAVITY * delta
	move_and_slide()


var player_dead := false


func take_damage(d: float, _dir: String = "") -> void:
	hp -= d
	# 受击闪一下
	if _mat != null:
		_mat.albedo_color = Color(0.95, 0.55, 0.35)
		get_tree().create_timer(0.12).timeout.connect(func() -> void:
			if is_instance_valid(_mat):
				_mat.albedo_color = Color(0.55, 0.18, 0.14))
	if hp <= 0.0:
		die()


func die() -> void:
	remove_from_group("enemies")
	queue_free()
