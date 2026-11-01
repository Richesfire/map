extends CharacterBody3D

# ============================================================
# 敌人：真实持武器战斗 + 保持距离 + 随机攻击/格挡
# 只使用 enemy 自己的场景和脚本，不改玩家控制
# ============================================================

@onready var model_ap: AnimationPlayer = get_node_or_null("Model/AnimationPlayer") as AnimationPlayer
@onready var weapon_area: Area3D = get_node_or_null("Model/ren/Skeleton3D/WeaponSocket/Weapon/WeaponArea") as Area3D
@onready var weapon_hitbox: CollisionShape3D = get_node_or_null("Model/ren/Skeleton3D/WeaponSocket/Weapon/WeaponArea/WeaponHitbox") as CollisionShape3D
@onready var health_bg: Sprite3D = get_node_or_null("HealthBar/Background") as Sprite3D
@onready var health_fill: Sprite3D = get_node_or_null("HealthBar/Fill") as Sprite3D

@export var move_speed: float = 2.6
@export var max_health: float = 100.0
@export var attack_damage: float = 25.0
@export var attack_cooldown: float = 1.4
@export var block_chance: float = 0.35
@export var block_duration: float = 0.9
@export var active: bool = true
@export var revive_time: float = 5.0
@export var reaction_time: float = 0.3

var health: float
var target: CharacterBody3D = null
var can_attack: bool = true
var is_blocking: bool = false
var is_attacking: bool = false
var is_dying: bool = false
var _dead: bool = false
var _aggro: bool = false
var _attack_dir: String = "thrust"
var _block_dir: String = "left"
var _weapon_contact: bool = false
var _think_timer: float = 0.0
var _state: String = "idle"
var _attack_distance: float = 2.9
var _hand_reach: float = 0.0
var _attack_min: float = 0.0
var _attack_max: float = 0.0
var _anim_tree: AnimationTree = null
var _move_sm: AnimationNodeStateMachinePlayback = null
var _attack_sm: AnimationNodeStateMachinePlayback = null
var _fill_full_width: float = 84.0
var _hit_stun: float = 0.0
var _spawn_position: Vector3 = Vector3.ZERO
var _spawn_rotation: Vector3 = Vector3.ZERO
var _saved_layer: int = 1
var _saved_mask: int = 1
var _clash_active: bool = false
var _attack_serial: int = 0
var _blocked_attack_serial: int = -1

func _ready() -> void:
	_spawn_position = global_position
	_spawn_rotation = rotation
	_saved_layer = collision_layer
	_saved_mask = collision_mask
	health = max_health
	if active:
		target = get_tree().get_first_node_in_group("player") as CharacterBody3D
	_ensure_weapon()
	if model_ap:
		_hand_reach = _sample_hand_reach()
		_setup_layered_anim()
	_attack_distance = _measure_attack_distance()
	if weapon_hitbox:
		weapon_hitbox.disabled = true
	if weapon_area:
		weapon_area.damage = attack_damage
		weapon_area.my_group = "enemy"
		weapon_area.area_entered.connect(_on_weapon_area_entered)
		weapon_area.area_exited.connect(_on_weapon_area_exited)
	_build_health_bar()
	if not active:
		collision_layer = 0
		collision_mask = 0
	_update_health_bar()

func _ensure_weapon() -> void:
	if weapon_area:
		return
	var skel := get_node_or_null("Model/ren/Skeleton3D") as Skeleton3D
	if skel == null:
		return
	var socket := BoneAttachment3D.new()
	socket.name = "WeaponSocket"
	socket.bone_name = "RightHand"
	socket.bone_idx = skel.find_bone("RightHand")
	socket.transform = Transform3D(
		Vector3(-0.0014129803, 0.9115014, 0.4112956),
		Vector3(0.9999472, -0.0028875656, 0.009834841),
		Vector3(0.010152221, 0.41128805, -0.9114493),
		Vector3(-0.099141605, 1.3015901, 0.1886633))
	skel.add_child(socket)
	var weapon := preload("res://scenes/weapon.tscn").instantiate()
	socket.add_child(weapon)
	weapon_area = weapon.get_node_or_null("WeaponArea") as Area3D
	weapon_hitbox = weapon.get_node_or_null("WeaponArea/WeaponHitbox") as CollisionShape3D

func _setup_layered_anim() -> void:
	var move_names: Array[String] = [
		"s_idle_weapon", "s_run_forward_weapon", "s_walk_forward_weapon", "s_walk_back_weapon"
	]
	var attack_names: Array[String] = [
		"s_attack_left_raise", "s_attack_left_swing",
		"s_attack_right_raise", "s_attack_right_swing",
		"s_attack_up_raise", "s_attack_up_swing",
		"s_attack_thrust_raise", "s_attack_thrust_swing",
		"s_block_left", "s_block_right", "s_block_up", "s_block_down",
		"s_block_success_up", "s_block_success_down", "s_block_success_left", "s_block_success_right",
		"hit_weapon"
	]
	var move_sm := _make_anim_states(move_names, 0.15)
	var attack_sm := _make_anim_states(attack_names, 0.10)
	var root := AnimationNodeBlendTree.new()
	root.add_node("move", move_sm, Vector2(0, 0))
	root.add_node("attack", attack_sm, Vector2(240, 0))
	var blend := AnimationNodeBlend2.new()
	blend.filter_enabled = true
	blend.filters = PackedStringArray([
		"ren/Skeleton3D:Chest", "ren/Skeleton3D:Head",
		"ren/Skeleton3D:LeftHand", "ren/Skeleton3D:LeftLowerArm",
		"ren/Skeleton3D:LeftShoulder", "ren/Skeleton3D:LeftUpperArm",
		"ren/Skeleton3D:Neck", "ren/Skeleton3D:RightHand",
		"ren/Skeleton3D:RightLowerArm", "ren/Skeleton3D:RightShoulder",
		"ren/Skeleton3D:RightUpperArm", "ren/Skeleton3D:Spine",
		"ren/Skeleton3D:UpperChest"
	])
	root.add_node("blend", blend, Vector2(480, 0))
	root.connect_node("blend", 0, "move")
	root.connect_node("blend", 1, "attack")
	root.connect_node("output", 0, "blend")

	var tree := AnimationTree.new()
	tree.name = "LayeredAnimation"
	add_child(tree)
	tree.anim_player = tree.get_path_to(model_ap)
	var model_root: Node3D = get_node_or_null("Model") as Node3D
	if model_root:
		tree.root_node = tree.get_path_to(model_root)
	tree.tree_root = root
	tree.active = true
	_anim_tree = tree
	_move_sm = tree.get("parameters/move/playback") as AnimationNodeStateMachinePlayback
	_attack_sm = tree.get("parameters/attack/playback") as AnimationNodeStateMachinePlayback
	if _move_sm:
		_move_sm.start(&"s_idle_weapon")
	tree.set("parameters/blend/blend_amount", 0.0)

func _make_anim_states(names: Array[String], fade: float) -> AnimationNodeStateMachine:
	var sm := AnimationNodeStateMachine.new()
	for n in names:
		var node := AnimationNodeAnimation.new()
		node.animation = StringName(n)
		sm.add_node(n, node, Vector2.ZERO)
	for a in names:
		for b in names:
			if a == b:
				continue
			var tr := AnimationNodeStateMachineTransition.new()
			tr.xfade_time = fade
			tr.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
			sm.add_transition(a, b, tr)
	return sm

func _physics_process(delta: float) -> void:
	if not active or _dead:
		return
	if _hit_stun > 0.0:
		_hit_stun = maxf(_hit_stun - delta, 0.0)
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 5.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 5.0 * delta)
		velocity.y = -0.2 if is_on_floor() else velocity.y - 9.8 * delta
		move_and_slide()
		return
	# 只有受到攻击后才进入战斗
	if not _aggro:
		_state = "idle"
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 4.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 4.0 * delta)
		_play_idle()
		if not is_on_floor():
			velocity.y -= 9.8 * delta
		else:
			velocity.y = -0.2
		move_and_slide()
		return
	if target == null:
		target = get_tree().get_first_node_in_group("player") as CharacterBody3D
		if target == null:
			return

	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	var dist: float = to_target.length()
	_face_target(delta)
	if is_attacking and not is_blocking:
		_set_optimal_move_state(dist, true)
		_move_state(delta)
	elif not is_blocking:
		_think_timer -= delta
		if _think_timer <= 0.0:
				_think_timer = reaction_time
				_decide(dist)
		_move_state(delta)
	else:
		velocity.x = move_toward(velocity.x, 0.0, move_speed * 4.0 * delta)
		velocity.z = move_toward(velocity.z, 0.0, move_speed * 4.0 * delta)

	if not is_on_floor():
		velocity.y -= 9.8 * delta
	else:
		velocity.y = -0.2
	move_and_slide()

func _set_optimal_move_state(dist: float, lower_only: bool = false) -> void:
	# 留 0.3 的死区，避免在最佳距离附近来回追/退
	var anim: String = "s_idle_weapon"
	if dist > _attack_distance + 0.3:
		_state = "chase"
		anim = "s_run_forward_weapon"
	elif dist < _attack_distance - 0.3:
		_state = "retreat"
		anim = "s_walk_back_weapon"
	else:
		_state = "idle"
	if lower_only:
		# 攻击时只切下半身，别把上身攻击层 blend 掉
		_travel_lower(anim)
	else:
		_play(anim)

func _decide(dist: float) -> void:
	if is_attacking or is_blocking:
		return
	if dist > _attack_max:
		_state = "chase"
		_play("s_run_forward_weapon")
		return
	if dist < _attack_min:
		_state = "retreat"
		_play("s_walk_back_weapon")
		return

	# 进入最大/最小攻击范围就出手，不等到最佳距离
	var player_attacking: bool = bool(target.get("is_attacking")) or bool(target.get("is_charging"))
	if player_attacking and _player_attack_from_front():
		if randf() < block_chance:
			_start_block()
			return
	if can_attack:
		_state = "idle"
		_play_idle()
		_start_attack()
		return

	# 攻击冷却期间移动到最佳距离
	_set_optimal_move_state(dist)

func _player_attack_from_front() -> bool:
	if target == null:
		return false
	var to_enemy: Vector3 = global_position - target.global_position
	to_enemy.y = 0.0
	var player_forward: Vector3 = -target.global_transform.basis.z
	player_forward.y = 0.0
	if to_enemy.length_squared() < 0.0001 or player_forward.length_squared() < 0.0001:
		return false
	return player_forward.normalized().dot(to_enemy.normalized()) > 0.2

func _move_state(delta: float) -> void:
	var to_target: Vector3 = target.global_position - global_position
	to_target.y = 0.0
	if to_target.length_squared() < 0.0001:
		velocity.x = 0.0
		velocity.z = 0.0
		return
	var dir: Vector3 = to_target.normalized()
	match _state:
		"chase":
			velocity.x = dir.x * move_speed
			velocity.z = dir.z * move_speed
		"retreat":
			velocity.x = -dir.x * move_speed * 0.75
			velocity.z = -dir.z * move_speed * 0.75
		_:
			velocity.x = move_toward(velocity.x, 0.0, move_speed * 4.0 * delta)
			velocity.z = move_toward(velocity.z, 0.0, move_speed * 4.0 * delta)

func _face_target(delta: float) -> void:
	var dir: Vector3 = target.global_position - global_position
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		return
	var target_yaw: float = atan2(dir.x, dir.z)
	rotation.y = lerp_angle(rotation.y, target_yaw, 8.0 * delta)

func _start_attack() -> void:
	if is_attacking or is_blocking or not can_attack or target == null:
		return
	_attack_serial += 1
	can_attack = false
	is_attacking = true
	_state = "attack"
	var dirs: Array[String] = ["left", "right", "up", "thrust"]
	_attack_dir = dirs[randi() % dirs.size()]
	var raise_name: String = "s_attack_" + _attack_dir + "_raise"
	var swing_name: String = "s_attack_" + _attack_dir + "_swing"
	_play(raise_name)
	await get_tree().create_timer(_anim_len(raise_name)).timeout
	if _dead:
		return
	_play(swing_name)
	if weapon_area:
		weapon_area.attack_dir = _attack_dir
	if weapon_hitbox:
		weapon_hitbox.disabled = false
	var swing_len: float = _anim_len(swing_name)
	await get_tree().create_timer(swing_len).timeout
	if weapon_hitbox:
		weapon_hitbox.disabled = true
	if _dead:
		return
	is_attacking = false
	_play_idle()
	await get_tree().create_timer(attack_cooldown).timeout
	if not _dead:
		can_attack = true

func is_in_block_window() -> bool:
	if _attack_sm == null or model_ap == null:
		return false
	var anim_name: String = String(_attack_sm.get_current_node())
	if not anim_name.ends_with("_swing"):
		return false
	var anim: Animation = model_ap.get_animation(anim_name)
	if anim == null:
		return false
	var step: float = anim.step if anim.step > 0.0 else 1.0 / 30.0
	return _attack_sm.get_current_play_position() <= 13.0 * step + 0.0001

func on_weapon_clash(duration: float = 0.16) -> void:
	# 只有在挥击前14帧内才能触发格挡成功
	if _clash_active or _blocked_attack_serial == _attack_serial:
		return
	if not is_in_block_window():
		return
	var anim_name: String = String(_attack_sm.get_current_node())
	var anim: Animation = model_ap.get_animation(anim_name)
	if anim == null:
		return
	var step: float = anim.step if anim.step > 0.0 else 1.0 / 30.0
	var f14: float = minf(13.0 * step, anim.length)
	_blocked_attack_serial = _attack_serial
	_clash_active = true
	if _anim_tree:
		_anim_tree.active = false
	model_ap.play(anim_name, 0.0)
	model_ap.seek(f14, true)
	await get_tree().create_timer(duration).timeout
	_clash_active = false
	if _anim_tree and not _dead:
		_anim_tree.active = true

func _start_block() -> void:
	if is_attacking or is_blocking:
		return
	is_blocking = true
	_state = "block"
	if weapon_hitbox:
		weapon_hitbox.disabled = false
	if weapon_area:
		weapon_area.damage = 0.0
	var dirs: Array[String] = ["left", "right", "up", "down"]
	_block_dir = dirs[randi() % dirs.size()]
	_play("s_block_" + _block_dir)
	await get_tree().create_timer(block_duration).timeout
	if _anim_tree and not _anim_tree.active:
		_anim_tree.active = true
	is_blocking = false
	if weapon_hitbox:
		weapon_hitbox.disabled = true
	if weapon_area:
		weapon_area.damage = attack_damage
	if not _dead:
		_play_idle()

func _play_block_success() -> void:
	_play("s_block_success_" + _block_dir)

func _on_weapon_area_entered(area: Area3D) -> void:
	if _is_player_weapon(area):
		_weapon_contact = true
		if is_blocking and target and target.has_method("on_weapon_clash"):
			var block_len: float = _anim_len("s_block_success_" + _block_dir)
			target.on_weapon_clash(block_len)

func _on_weapon_area_exited(area: Area3D) -> void:
	if _is_player_weapon(area):
		_weapon_contact = false

func _is_player_weapon(area: Area3D) -> bool:
	var node: Node = area
	while node:
		if node.is_in_group("player"):
			return true
		node = node.get_parent()
	return false

func _travel_lower(anim: String) -> void:
	var target := StringName(anim)
	if _move_sm and _move_sm.get_current_node() != target:
		_move_sm.travel(target)

func _play(anim: String, blend: float = 0.12) -> void:
	if _anim_tree and _move_sm and _attack_sm:
		if anim.begins_with("s_attack_") or anim.begins_with("s_block_") or anim == "hit_weapon":
			_attack_sm.travel(StringName(anim))
			_anim_tree.set("parameters/blend/blend_amount", 1.0)
		else:
			_travel_lower(anim)
			_anim_tree.set("parameters/blend/blend_amount", 0.0)
		return
	if model_ap and model_ap.has_animation(anim):
		model_ap.play(anim, blend)

func _play_idle() -> void:
	_state = "idle"
	_play("s_idle_weapon")

func _sample_hand_reach() -> float:
	if model_ap == null or weapon_area == null:
		return 0.0
	var max_reach: float = 0.0
	for dir in ["left", "right", "up", "thrust"]:
		var anim_name: String = "s_attack_" + dir + "_swing"
		if not model_ap.has_animation(anim_name):
			continue
		var anim: Animation = model_ap.get_animation(anim_name)
		var t: float = 0.0
		while t <= anim.length:
			model_ap.play(anim_name, 0.0)
			model_ap.seek(t, true)
			var hp: Vector3 = weapon_area.global_position
			var reach: float = Vector2(hp.x - global_position.x, hp.z - global_position.z).length()
			max_reach = maxf(max_reach, reach)
			t += 0.05
	model_ap.stop()
	return max_reach

func _target_collision_radius() -> float:
	if target == null:
		return 0.3
	var r: float = 0.0
	for owner in target.get_shape_owners():
		var count: int = target.shape_owner_get_shape_count(owner)
		for i in count:
			var shape: Shape3D = target.shape_owner_get_shape(owner, i)
			if shape is CapsuleShape3D:
				r = maxf(r, (shape as CapsuleShape3D).radius)
			elif shape is SphereShape3D:
				r = maxf(r, (shape as SphereShape3D).radius)
			elif shape is CylinderShape3D:
				r = maxf(r, (shape as CylinderShape3D).radius)
			elif shape is BoxShape3D:
				var box: BoxShape3D = shape as BoxShape3D
				r = maxf(r, Vector2(box.size.x, box.size.z).length() * 0.5)
	if r <= 0.0:
		return 0.3
	return r

func _measure_attack_distance() -> float:
	# 剑刃碰撞体近端/远端到手的距离，再加上目标碰撞半径
	var near: float = 0.0
	var far: float = 2.9
	if weapon_hitbox and weapon_hitbox.shape is BoxShape3D:
		var box: BoxShape3D = weapon_hitbox.shape as BoxShape3D
		near = maxf(weapon_hitbox.position.z - box.size.z * 0.5, 0.0)
		far = weapon_hitbox.position.z + box.size.z * 0.5
	elif weapon_hitbox and weapon_hitbox.shape is CapsuleShape3D:
		var cap: CapsuleShape3D = weapon_hitbox.shape as CapsuleShape3D
		near = maxf(weapon_hitbox.position.z - cap.height * 0.5, 0.0)
		far = weapon_hitbox.position.z + cap.height * 0.5
	var target_radius: float = _target_collision_radius()
	_attack_min = _hand_reach + near + target_radius
	_attack_max = _hand_reach + far + target_radius
	# 剑刃中段在“手离身体最远”的挥击帧接触目标
	var blade_mid: float = (near + far) * 0.5
	return clampf(_hand_reach + blade_mid + target_radius, _attack_min, _attack_max)

func _anim_len(anim: String) -> float:
	if model_ap and model_ap.has_animation(anim):
		return maxf(model_ap.get_animation(anim).length, 0.05)
	return 0.45

func _build_health_bar() -> void:
	var img: Image = Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)
	var tex: ImageTexture = ImageTexture.create_from_image(img)
	if health_bg:
		health_bg.texture = tex
	if health_fill:
		health_fill.texture = tex
		_fill_full_width = health_fill.scale.x

func _update_health_bar() -> void:
	if health_fill == null or health_bg == null:
		return
	var ratio: float = clampf(health / max_health, 0.0, 1.0)
	health_fill.scale.x = _fill_full_width * ratio
	health_fill.position.x = -0.42 + 0.42 * ratio
	var show: bool = active and not _dead
	health_bg.visible = show
	health_fill.visible = show

func _player_in_block_window() -> bool:
	if target and target.has_method("is_in_block_window"):
		return bool(target.is_in_block_window())
	return false

func take_damage(amount: float, _attack_dir_from_attacker: String = "") -> void:
	if _dead:
		return
	_aggro = true
	if target == null:
		target = get_tree().get_first_node_in_group("player") as CharacterBody3D
	if is_blocking and _weapon_contact and _player_in_block_window():
		_play_block_success()
		return
	health = maxf(health - amount, 0.0)
	_update_health_bar()
	if health <= 0.0:
		_die()
		return
	if is_attacking:
		is_attacking = false
		if weapon_hitbox:
			weapon_hitbox.disabled = true
	_play("hit_weapon")
	_hit_stun = _anim_len("hit_weapon") * 0.7
	await get_tree().create_timer(_hit_stun).timeout
	if not _dead:
		_play_idle()

func _die() -> void:
	if _dead:
		return
	_dead = true
	is_dying = true
	is_attacking = false
	is_blocking = false
	can_attack = false
	if weapon_hitbox:
		weapon_hitbox.disabled = true
	if weapon_area:
		weapon_area.monitoring = false
	_update_health_bar()
	if _anim_tree:
		_anim_tree.active = false
	if model_ap:
		model_ap.play("death")
	set_physics_process(false)
	collision_layer = 0
	collision_mask = 0
	await get_tree().create_timer(revive_time).timeout
	_revive()

func _revive() -> void:
	if not active:
		return
	_dead = false
	_aggro = false
	is_dying = false
	health = max_health
	global_position = _spawn_position
	rotation = _spawn_rotation
	collision_layer = _saved_layer
	collision_mask = _saved_mask
	can_attack = true
	is_attacking = false
	is_blocking = false
	_hit_stun = 0.0
	_weapon_contact = false
	if weapon_hitbox:
		weapon_hitbox.disabled = true
	if weapon_area:
		weapon_area.monitoring = true
	set_physics_process(true)
	if _anim_tree:
		_anim_tree.active = true
	if _move_sm:
		_move_sm.start(&"s_idle_weapon")
	_update_health_bar()
	_play_idle()
	target = get_tree().get_first_node_in_group("player") as CharacterBody3D

func is_dead() -> bool:
	return _dead
