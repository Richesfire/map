extends CharacterBody3D

# ============================================================
# 马匹控制：速度驱动步态(idle/walk/trot/canter/gallop) + 转向 + 跳跃
# 上马后读玩家输入；未骑乘时保持原地待机
# ============================================================

@export_group("速度")
@export var walk_speed: float = 1.8       # 低于此值播 walk
@export var trot_speed: float = 3.6       # 低于此值播 trot
@export var canter_speed: float = 6.0     # 低于此值播 canter，之上播 gallop
@export var gallop_speed: float = 9.0     # 最大前进速度
@export var back_speed: float = 1.5       # 倒退最大速度
@export var accel: float = 5.0            # 加速（倒退用）
@export var brake: float = 8.0            # 减速
@export var speed_up_time: float = 3.0    # 从静止到最高速的时间（平滑）

@export_group("转向")
@export var turn_speed: float = 2.2       # 弧度/秒（低速）
@export var turn_speed_fast: float = 1.1  # 弧度/秒（高速时转向变钝）

@export_group("跳跃")
@export var jump_velocity: float = 5.5
@export var gravity: float = 12.0

@export_group("动画")
@export var gait_fade: float = 0.25       # 步态之间交叉淡化时长

@export var ride_bone_name: String = "spine.005"   # 骑手附着骨骼（随该骨骼动画一起动）
@export var ride_bone_offset: Vector3 = Vector3.ZERO  # 相对该骨骼的落点偏移（X左右 / Y高低 / Z前后，随骨骼旋转）
var _skel: Skeleton3D = null
var _ride_bone: int = -1
@onready var mount_area: Area3D = get_node_or_null("MountArea") as Area3D

var speed: float = 0.0
var _speed_up_t: float = 0.0
var has_rider: bool = false
var rider: Node3D = null
var steer_locked: bool = false   # 下马动画期间锁定 A/D 转向

var _ap: AnimationPlayer
var _last_gait: String = ""
var _gaits := ["idle", "walk", "trot", "canter", "gallop", "walk_back", "turn_in_place_left", "turn_in_place_right"]

# 转向：用 turn_left / turn_right 动画驱动（按住正放并停在末帧，松开反放回正）
# 只让这两个动画控制这些骨骼，其余骨骼交给步态动画
const TURN_KEEP_BONES := ["spine.004", "spine.006", "neck.002", "neck.004"]
var _turn_ap: AnimationPlayer = null
var _turn_dir: int = 0        # -1 左, 0 无, 1 右
var _turn_t: float = 0.0      # 转向动画当前进度（秒），手动推进/回退
var _dbg_acc: float = 0.0     # 临时调试计时
@export var turn_out_time: float = 0.35   # 松开后回正所需时间（秒）

func _ready() -> void:
	add_to_group("horse")
	_skel = find_child("Skeleton3D", true, false)
	var _rb := get_node_or_null("RideBone")
	if _skel and _rb:
		# 必须同时打开 use_external_skeleton，否则 external_skeleton 不起作用（没绑上骨）
		_rb.use_external_skeleton = true
		_rb.external_skeleton = _rb.get_path_to(_skel)
		_rb.bone_name = ride_bone_name
		_ride_bone = _skel.find_bone(ride_bone_name)
	_ap = find_child("AnimationPlayer", true, false)
	if _ap:
		for g in _gaits:                      # 步态动画需要循环
			if _ap.has_animation(g):
				_ap.get_animation(g).loop_mode = Animation.LOOP_LINEAR
		_play("idle")
	# 转向动画用的第二播放器：共享 glb 的动画库；放在 Model 之后，覆盖步态里同名骨骼(脖子)的轨道
	_turn_ap = get_node_or_null("TurnPlayer")
	if _ap and _turn_ap:
		for lib in _ap.get_animation_library_list():
			_turn_ap.add_animation_library(String(lib), _ap.get_animation_library(lib))
		# 轨道路径相对 glb 根（如 metarig/Skeleton3D:...），必须让 TurnPlayer 从同一个根解析
		_turn_ap.root_node = _turn_ap.get_path_to(_ap.get_node(_ap.root_node))
		# 顺序：步态在物理帧应用、转向在空闲帧应用（空闲晚于物理）→ 转向的骨骼覆盖步态
		_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
		_turn_ap.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_IDLE
		for a in ["turn_left", "turn_right"]:
			if _turn_ap.has_animation(a):
				_strip_turn_tracks(_turn_ap.get_animation(a))
				_turn_ap.get_animation(a).loop_mode = Animation.LOOP_NONE
		# 一开始就停在「中位」：让这 4 根骨骼始终由 TurnPlayer 控制
		if _turn_ap.has_animation("turn_left"):
			_turn_ap.play("turn_left")
			_turn_ap.speed_scale = 0.0

func can_mount(body: Node3D) -> bool:
	return mount_area != null and mount_area.overlaps_body(body)

func rider_anchor(side: int = 1) -> Transform3D:
	# 左右各一个鞍座锚点：左侧 Seat / 右侧 SeatRight
	var seat := get_node_or_null("RideBone/SeatRight" if side < 0 else "RideBone/Seat") as Node3D
	if seat:
		return seat.global_transform      # BoneAttachment3D 子节点：随骨骼动画一起动
	return global_transform

func _physics_process(delta: float) -> void:
	var fwd: float = 0.0
	var turn: float = 0.0
	if has_rider:
		fwd = Input.get_axis("move_back", "move_forward")
		turn = 0.0 if steer_locked else Input.get_axis("move_left", "move_right")
	_update_speed(fwd, delta)
	_update_gravity(delta)
	if is_on_floor():
		_update_turn(turn, delta)
		_update_gait(turn)
	else:
		_play_jump()   # 空中：只播跳跃动画，且不能转向
	move_and_slide()

func _process(delta: float) -> void:
	_update_turn_head(delta)

func _update_turn_head(delta: float) -> void:
	if _turn_ap == null or _turn_ap.current_animation == "":
		return
	var turn: float = 0.0
	if has_rider:
		turn = 0.0 if steer_locked else Input.get_axis("move_left", "move_right")
	var want: int = 0
	if turn > 0.1:
		want = 1
	elif turn < -0.1:
		want = -1
	var length: float = _turn_ap.current_animation_length
	var back_rate: float = delta * (length / maxf(turn_out_time, 0.001))
	if want != 0 and want != _turn_dir:
		# 换向：先从中位/对侧平滑回到中位，到中位后再切到目标侧的起始帧（避免瞬间跳到另一侧第一帧的跳变）
		if _turn_t > 0.001:
			_turn_t = maxf(_turn_t - back_rate, 0.0)
		else:
			_switch_turn(want)
	if want == _turn_dir and want != 0:
		_turn_t = minf(_turn_t + delta, maxf(length - 0.001, 0.0))   # 推进到接近末帧就停住
	elif want == 0:
		_turn_dir = 0
		_turn_t = maxf(_turn_t - back_rate, 0.0)                     # 无输入：回正
	# 关键：speed=0 + 手动 seek。绝不"自然播完"——播完播放器会释放姿态、骨骼回落步态中位。
	_turn_ap.speed_scale = 0.0
	_turn_ap.seek(_turn_t, true)
	# ---- 临时调试（定位"瞬间回落/转回无效"）----
	_dbg_acc += delta
	if _dbg_acc >= 0.5:
		_dbg_acc = 0.0
		print("[horse.turn] in=", turn, " dir=", _turn_dir, " t=", _turn_t, "/", length,
			" cur=", _turn_ap.current_animation, " pos=", _turn_ap.current_animation_position,
			" active=", _turn_ap.is_playing())

func _switch_turn(dir: int) -> void:
	_turn_dir = dir
	_turn_t = 0.0
	_turn_ap.play("turn_right" if dir > 0 else "turn_left")
	_turn_ap.speed_scale = 0.0

func _strip_turn_tracks(anim: Animation) -> void:
	# 只保留 TURN_KEEP_BONES 的轨道，删掉其它（导出时整只马被逐帧烘焙，转向动画也带了全身轨道）
	var i: int = anim.get_track_count() - 1
	while i >= 0:
		var bone: String = String(anim.track_get_path(i)).get_slice(":", 1)
		if not TURN_KEEP_BONES.has(bone):
			anim.remove_track(i)
		i -= 1

func _update_speed(fwd: float, delta: float) -> void:
	var target: float = 0.0
	if fwd > 0.01:
		# 前进：3 秒内用 smoothstep 从 0 平滑加速到最高速
		_speed_up_t = minf(_speed_up_t + delta, maxf(speed_up_time, 0.001))
		var p: float = clampf(_speed_up_t / maxf(speed_up_time, 0.001), 0.0, 1.0)
		target = gallop_speed * smoothstep(0.0, 1.0, p)
		speed = move_toward(speed, target, brake * delta)
	elif fwd < -0.01:
		# 倒退保持原来的线性加速
		_speed_up_t = 0.0
		target = back_speed * fwd
		speed = move_toward(speed, target, accel * delta)
	else:
		_speed_up_t = 0.0
		speed = move_toward(speed, 0.0, brake * delta)
	# 沿「马自身的前方」移动（跟随马的朝向），而不是世界 -Z
	var forward: Vector3 = -global_transform.basis.z
	velocity.x = forward.x * speed
	velocity.z = forward.z * speed

func _update_gravity(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= gravity * delta
	elif has_rider and Input.is_action_just_pressed("jump"):
		velocity.y = jump_velocity

func _update_turn(turn: float, delta: float) -> void:
	if absf(turn) < 0.01:
		return
	var t: float = turn_speed if absf(speed) < canter_speed else turn_speed_fast
	rotate_y(-turn * t * delta)

func _update_gait(turn: float = 0.0) -> void:
	var gait: String
	if speed < -0.1:
		gait = "walk_back"
	elif speed < 0.15:
		# 原地转向：速度≈0 且按住 A/D 时播专用原地转动画（没有就回退 idle）
		if absf(turn) > 0.1 and _ap and _ap.has_animation("turn_in_place_right" if turn > 0.0 else "turn_in_place_left"):
			gait = "turn_in_place_right" if turn > 0.0 else "turn_in_place_left"
		else:
			gait = "idle"
	elif speed < walk_speed:
		gait = "walk"
	elif speed < trot_speed:
		gait = "trot"
	elif speed < canter_speed:
		gait = "canter"
	else:
		gait = "gallop"
	if gait != _last_gait:
		_play(gait)

func _play_jump() -> void:
	if _ap and _ap.has_animation("jump") and _last_gait != "jump":
		_ap.get_animation("jump").loop_mode = Animation.LOOP_NONE
		_ap.play("jump", 0.1)
		_last_gait = "jump"

func _play(anim: String) -> void:
	if _ap and _ap.has_animation(anim):
		_ap.play(anim, gait_fade)
		_last_gait = anim
