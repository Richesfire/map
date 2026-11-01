extends CharacterBody3D

# ============================================================
# 玩家控制器 —— 上半身(战斗) / 下半身(移动) 分层状态机
#   move_sm:  走路/待机的全身基底（下半身用它持续走路）
#   attack_sm: 攻击/格挡/受击/死亡（只覆盖上半身，通过混合权重控制）
# ============================================================

# ---------- 节点引用 ----------
@onready var animation_tree = $AnimationTree
@onready var move_sm = null
@onready var attack_sm = null

# 攻击时上半身混合权重（0=全身走路，1=上半身全部切换为攻击动作）
var combat_upper_blend: float = 0.0
# 攻击俯仰：平滑跟随镜头俯仰，避免蓄力/攻击/收招瞬间脊柱俯仰跳变
var aim_pitch: float = 0.0
# 举剑/收剑时的俯仰过渡（分别与举剑、收剑动画时长同步）
var raise_pitch_from: float = 0.0
var raise_pitch_t: float = 0.0
var raise_pitch_dur: float = 0.001
var recover_pitch_from: float = 0.0
var recover_pitch_t: float = 0.0
var recover_pitch_dur: float = 0.001
# body_blend(Blend2) 节点：用于动态开关上半身骨骼遮罩
var blend_node = null
# 当前是否有移动输入（决定下半身播移动动画还是举剑动画）
var is_moving: bool = false
var _moving_right: bool = false   # 当前移动方向是否偏屏幕右（用于右挥击第14帧决定是否转身）
var _moving_left: bool = false    # 当前移动方向是否偏屏幕左（用于左挥击第14帧决定是否转身）
@export var camera_pivot: Node3D
@export var camera_3d: Camera3D
@export var cam_default_marker: Marker3D
@export var cam_hold_marker: Marker3D
@export var cam_ride_marker: Marker3D   # 左侧骑乘机位
@export var cam_ride_hold_marker: Marker3D   # 左侧按住 ~ 的观察机位
@export var cam_ride_marker_right: Marker3D   # 右侧骑乘机位（main 里的偏移）
@export var cam_ride_hold_marker_right: Marker3D   # 右侧观察机位
@onready var weapon_area: Area3D = $CharacterRig/character/ren/Skeleton3D/WeaponSocket/Weapon/WeaponArea
@onready var weapon_hitbox: CollisionShape3D = $CharacterRig/character/ren/Skeleton3D/WeaponSocket/Weapon/WeaponArea/WeaponHitbox
@onready var skeleton: Skeleton3D = $CharacterRig/character/ren/Skeleton3D

# ---------- 移动参数 ----------
@export var walk_speed: float = 3.0
@export var run_speed: float = 6.0
@export var jump_velocity: float = 4.29  # 起跳初速度（匹配 jump 动画：1帧起跳→22帧落地，滞空约0.875s）
@export var jump_interval: float = 1.5  # 两次跳跃之间的间隔
@export var body_rotation_speed: float = 3
@export var spine_bone_name: String = "Spine"
@export var chest_bone_name: String = "Chest"

# ---------- 摄像机 ----------
@export var cam_transition_speed: float = 6.0
const CAM_PITCH_MIN: float = -1.6   # 镜头俯仰下限（低头）
const CAM_PITCH_MAX: float = 0.8     # 镜头俯仰上限（抬头）—— 攻击俯仰的限幅与之同步

# ---------- 战斗参数 ----------
@export var max_health: float = 100.0
@export var attack_cooldown: float = 0.1

# ---------- 运行时状态 ----------
var health: float
var _health_bar: ProgressBar = null
var _weapon_contact: bool = false
var _weapon_damage: float = 25.0
var _hit_stun: float = 0.0
var _last_blocked_enemy_serial: int = -1
var can_attack: bool = true
var attack_gen: int = 0   # 挥砍代次：格挡打断挥砍时 +1，令旧挥砍协程彻底退出（只看 is_blocking 会漏掉「格挡已松开」的时机）
var is_charging: bool = false
var is_blocking: bool = false
var is_attacking: bool = false
var _clash_freeze_t: float = 0.0
var _blocked_attack_gen: int = -1
var current_attack: String = ""
var block_dir: String = ""
var attack_buffered: bool = false   # 挥砍/冷却期间按左键 → 缓冲下一刀（举刀）
var lmb_held: bool = false          # 左键是否按住（缓冲刀要先举刀，松手再挥刀）
var is_recovering: bool = false     # 正在播放"收招"动画（保持上身权重=1，收招才显示）
var _lateral_attack_phase: int = 0      # 右挥击下身阶段：0=正常 / 1=朝右（举刀+挥刀前段）/ 2=朝左（第14帧后）
var recover_gen: int = 0               # 收招「代次」：打断/接管收招时 +1，旧收招协程据此提前退出（避免 bool 残留）
var is_block_recovering: bool = false  # 正在播格挡收招（松开右键后）——此期间按左键可立刻打断接举剑
var mouse_move_delta: Vector2 = Vector2.ZERO
var last_mouse_relative: Vector2 = Vector2.ZERO  # 最近一次鼠标移动（原始值），用于格挡方向判定，避免用到攻击残留
var was_moving: bool = false                     # 上一帧是否在移动（用于捕获「停止瞬间」的朝向）
var was_in_combat: bool = false                  # 上一帧是否在攻击/格挡（用于捕获「攻击结束瞬间」的朝向）
var attack_started_moving: bool = false          # 本次攻击是「移动中起手」的 → 全程下半身走移动动画
var jump_vel: Vector3 = Vector3.ZERO             # 起跳那一刻的水平速度（空中保持惯性）
var jump_cool: float = 0.0                       # 跳跃冷却（两次跳跃间隔）
var idle_face_yaw: float = 0.0                   # 停止瞬间上身朝向；停止后下身朝它平滑回正
var aim_yaw: float = 0.0                         # 上身瞄准 yaw（平滑后的，起停不跳变）
var attack_dir: AttackDir = AttackDir.THRUST  # 保留的上次攻击方向（默认「下」/前刺）；鼠标不动就保持不变
var block_dir_keep: String = "down"           # 保留的上次格挡方向（默认「下」）；鼠标不动就保持不变

enum AttackDir { LEFT, RIGHT, UP, THRUST }

const ATTACK_DIR_NAMES = {
	AttackDir.LEFT: "left",
	AttackDir.RIGHT: "right",
	AttackDir.UP: "up",
	AttackDir.THRUST: "thrust",
}

# 骑乘左右劈：攻击状态机里的状态名 → 骑乘专用动画名（地面动作用 "s_" + 状态名）
const RIDE_ATTACK_SWAP := {
	"attack_left_raise": &"s_attack_left_ride_raise",
	"attack_left_swing": &"s_attack_left_ride_swing",
	"attack_left_recover": &"s_attack_left_ride_recover",
	"attack_right_raise": &"s_attack_right_ride_raise",
	"attack_right_swing": &"s_attack_right_ride_swing",
	"attack_right_recover": &"s_attack_right_ride_recover",
}
var _attack_anim_nodes: Dictionary = {}   # 状态名 → AnimationNodeAnimation（运行时切换地面/骑乘动画）
# 右挥击的转身时机（按动画帧）：
# 挥刀 22 帧 → 第 14 帧开始下身朝左；收刀 8 帧 → 第 5 帧恢复
const LATERAL_SWING_TURN_T := 14.0 / 22.0
const LATERAL_RECOVER_RESTORE_T := 5.0 / 8.0

# ---------- 摄像机平滑切换 ----------
var cam_target: Vector3 = Vector3.ZERO
var is_holding_cam: bool = false
var cam_lock: bool = false   # 按住 ~ 或松开后镜头回归期间：身体/上身不跟随镜头
var cam_returning: bool = false   # 松开 ~ 后镜头角度/位置正在回归按住前的状态
var saved_cam_yaw: float = 0.0    # 按下 ~ 时的镜头 yaw（松开后回到这里）
var saved_cam_pitch: float = 0.0  # 按下 ~ 时的镜头 pitch
var saved_body_pitch: float = 0.0 # 按下 ~ 时的身体俯仰（按住期间锁定）

var cam_yaw: float = 0.0
var cam_pitch: float = 0.0
var spine_bone_idx: int = -1
var chest_bone_idx: int = -1
var body_target_yaw: float = 0.0
var frozen_move_yaw: float = 0.0
var head_world_yaw: float = 0.0
var is_walking: bool = false
var default_fov: float = 75.0
var last_anim_state: String = ""
var initialized: bool = false
var has_weapon: bool = true

# ---------- 骑乘 ----------
var riding: bool = false            # 是否正在骑乘
var mount_horse: Node3D = null      # 当前骑的马（group "horse"）
var _mount_base_anim: StringName = &"mount"   # 本次使用的上马动画（mount_left/mount_right，旧资源回退 mount）
var _ride_side: int = 1             # 当前鞍座侧：+1 Seat / -1 SeatRight
var _ride_state_nodes: Dictionary = {}   # 右侧骑乘切到镜像 Hips 的 ride_*
var is_mounting: bool = false       # 正播上马动画（全身）
var is_dismounting: bool = false    # 正播下马动画（倒放，此期间人物不受控）
var _saved_layer: int = 1           # 骑乘时保存玩家的碰撞层/掩码，下马还原
var _saved_mask: int = 1
@export var mount_prompt: Label               # 屏幕提示（F · 上马）
@export var ride_offset: Vector3 = Vector3.ZERO   # 骑乘落点相对鞍座的偏移（X左右 / Y高低 / Z前后，随马朝向旋转）
@export var ride_twist_speed: float = 6.0         # 扭转过渡/回正速度
@export var ride_combat_blend: float = 12.0       # 骑乘时攻击/非攻击混合速度（越小越慢）
@export_group("骑乘瞄准·左右劈")
@export var ride_aim_right_min_deg: float = 70.0  # 左右劈·右侧：最小角（>此角进入右区）
@export var ride_aim_right_max_deg: float = 100.0 # 左右劈·右侧：最大角
@export var ride_aim_left_min_deg: float = 70.0   # 左右劈·左侧：最小角（<-此角进入左区）
@export var ride_aim_left_max_deg: float = 100.0  # 左右劈·左侧：最大角
@export_group("骑乘瞄准·上劈")
@export var ride_aim_up_right_min_deg: float = 15.0  # 上劈·右侧：最小角
@export var ride_aim_up_right_max_deg: float = 90.0  # 上劈·右侧：最大角
@export var ride_aim_up_left_min_deg: float = 15.0   # 上劈·左侧：最小角
@export var ride_aim_up_left_max_deg: float = 90.0   # 上劈·左侧：最大角
@export_group("骑乘瞄准·下刺")
@export var ride_aim_thrust_right_min_deg: float = 0.0  # 下刺·右侧：最小角
@export var ride_aim_thrust_right_max_deg: float = 60.0  # 下刺·右侧：最大角
@export var ride_aim_thrust_left_min_deg: float = 15.0   # 下刺·左侧：最小角
@export var ride_aim_thrust_left_max_deg: float = 130.0  # 下刺·左侧：最大角
@export_group("骑乘瞄准·通用")
@export var ride_aim_turn_speed: float = 6.0      # 骑乘攻击方向换侧过渡角速度(弧度/秒)：越小越慢；时长=需转角度/此值
@export var ride_aim_front_free_pitch_deg: float = -10.0  # 瞄准俯仰高于此角时取消正前 min 限制（可直接朝正前攻击）
@export var ride_aim_front_free_blend_deg: float = 8.0   # 低于阈值后 min 从 0 渐变到完整值的过渡角度（防止瞬间转向）
var _ride_anchor: Transform3D = Transform3D()     # 当前鞍座（骨骼锚点）世界变换
var _ride_twist: float = 0.0                      # 平滑后的扭转量(-1..1)
var _ride_aim_yaw: float = 0.0                    # 平滑后的骑乘攻击水平角（相对马正前）
var _ride_aim_side: int = 1                       # 当前攻击侧：+1 左 / -1 右（越过中线即切）
var _ride_aim_switching: bool = false             # 是否正在换侧限速过渡
# 弹簧骨骼（布娃娃式次级运动）参数
@export var spring_stiffness: float = 200.0
@export var spring_drag: float = 2.0
@export var spring_gravity: float = 0.0
var spring_bones: SpringBoneSimulator3D = null

# ============================================================
func _ready():
	health = max_health
	_build_health_bar()
	if weapon_area:
		_weapon_damage = weapon_area.damage
		weapon_area.area_entered.connect(_on_block_area_entered)
		weapon_area.area_exited.connect(_on_block_area_exited)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if animation_tree:
		move_sm = animation_tree.get("parameters/move_state/playback")
		attack_sm = animation_tree.get("parameters/attack_state/playback")
		# 用 tree_root 可靠获取 body_blend(Blend2) 节点（parameters/body_blend 方式可能返回 null）
		var tree = animation_tree.tree_root
		if tree is AnimationNodeBlendTree:
			blend_node = tree.get_node("body_blend")
			# 运行时给 move 状态机加上马/下马状态，并生成倒放的 mount_rev（不改 .tscn）
			_ensure_mount_states(tree.get_node("move_state"))
			if tree.has_node("attack_state"):
				_setup_ride_attack_anims(tree.get_node("attack_state"))
		print("[player] body_blend 节点 = ", blend_node)
	_setup_spring_bones()

	cam_target = cam_default_marker.position
	camera_3d.position = cam_target

	spine_bone_idx = skeleton.find_bone(spine_bone_name)
	chest_bone_idx = skeleton.find_bone(chest_bone_name)

# ============================================================
func _process(delta: float):
	_update_mount_prompt()
	# 延迟到第一帧再初始化状态机（_ready 时动画树还没准备好）
	if not initialized:
		initialized = true
		animation_tree.set_active(true)
		if move_sm:
			move_sm.start(&"idle_weapon")
			last_anim_state = "idle_weapon"
		if attack_sm:
			attack_sm.start(&"idle_weapon")
	# 上马/下马动画：全身交给 move 层（关遮罩、上身混合归零），播完自动恢复
	if is_mounting or is_dismounting:
		combat_upper_blend = 0.0
		animation_tree.set("parameters/body_blend/blend_amount", 0.0)
		if blend_node is AnimationNodeBlend2:
			blend_node.filter_enabled = false
		skeleton.clear_bones_global_pose_override()   # 上马/下马期间不写上半身覆盖，避免和上马动画抢姿势
		return
	if riding:
		_apply_ride_twist(delta)
	# 平滑切换上半身加权：战斗中（蓄力/攻击/格挡）上半身切到攻击动作，否则回走路（腾空不算战斗 → 上身继续用跳跃动画）
	var combat_active: bool = is_charging or is_attacking or is_blocking or is_recovering or _hit_stun > 0.0 or health <= 0
	var blend_spd: float = ride_combat_blend if riding else 8.0   # 骑乘时上下身混合更慢
	combat_upper_blend = move_toward(combat_upper_blend, 1.0 if combat_active else 0.0, blend_spd * delta)
	animation_tree.set("parameters/body_blend/blend_amount", combat_upper_blend)
	# 战斗中：移动时只让攻击覆盖上半身(下半身走移动动画)；站着不动时关闭遮罩，全身播攻击。
	# 「移动中起的攻击」全程保持遮罩（下半身一直用移动动画），避免攻击结束前停下导致脚跳。
	if not combat_active:
		attack_started_moving = false
	# 骑乘时永远保留上半身遮罩（下半身始终是骑马姿势，不能用地面攻击的全身动作）
	var mask_off: bool = combat_active and not is_moving and not attack_started_moving and not riding
	if blend_node is AnimationNodeBlend2:
		blend_node.filter_enabled = not mask_off
	# 俯仰过渡：收剑 = 与收剑动画同步归零；举剑/挥砍 = 跟随镜头；格挡取消俯仰变化
	var cancel_pitch: bool = is_blocking
	var pitch_target: float = 0.0 if cancel_pitch else cam_pitch
	if is_recovering:
		recover_pitch_t += delta
		aim_pitch = lerpf(recover_pitch_from, 0.0, clampf(recover_pitch_t / recover_pitch_dur, 0.0, 1.0))
	elif is_charging:
		raise_pitch_t += delta
		aim_pitch = lerpf(raise_pitch_from, pitch_target, clampf(raise_pitch_t / raise_pitch_dur, 0.0, 1.0))
	else:
		aim_pitch = lerpf(aim_pitch, pitch_target if combat_active else 0.0, 12.0 * delta)
	# 按住 ~ 时锁定身体俯仰（镜头俯仰不受影响，仍可上下看）
	if is_holding_cam:
		aim_pitch = saved_body_pitch
	var _combat_aim: bool = is_charging or is_attacking or is_blocking or is_recovering
	if not riding or _combat_aim:
		_update_head_rotation(delta)   # 骑乘时仅在攻击/格挡下用瞄准覆盖(朝镜头)；否则交给弹簧骨骼

# ============================================================
# 上下半身分层的骨骼遮罩已配在 player.tscn 的 body_blend(Blend2) 节点上（见编辑筛选轨道）
# ============================================================
func _input(event: InputEvent):
	# 下马动画期间人物不受控，但镜头仍然可以转
	if is_dismounting:
		if event is InputEventMouseMotion:
			cam_yaw += -event.relative.x * 0.002
			cam_pitch += -event.relative.y * 0.002
			cam_pitch = clamp(cam_pitch, CAM_PITCH_MIN, CAM_PITCH_MAX)
			camera_pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)
		return
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# 上/下马：按交互键(F)
	if event.is_action_pressed("interact") and not event.echo:
		if is_mounting or is_dismounting:
			pass                       # 动画播放中不响应
		elif riding:
			_dismount()
		else:
			_try_mount()

	if event is InputEventKey and event.keycode == KEY_CAPSLOCK and event.pressed:
		is_walking = not is_walking
		print("移动模式: ", "走路" if is_walking else "跑步")

	if event is InputEventKey and event.keycode == KEY_QUOTELEFT:
		if event.pressed and not event.echo:
			is_holding_cam = true
			frozen_move_yaw = head_world_yaw
			saved_cam_yaw = cam_yaw       # 记住按 ~ 前的镜头角度，松开后回归
			saved_cam_pitch = cam_pitch
			saved_body_pitch = aim_pitch   # 锁定身体俯仰在当前值
			cam_returning = false
		elif not event.pressed:
			is_holding_cam = false
			cam_returning = true                              # 松开后开始回归
			camera_3d.position = _cam_hold_marker_pos()     # ① 机位秒切到「悬停机位」（骑乘用专用机位）
			# 视角也秒切回按住前，这样前进方向不变（往北走还是往北走）
			cam_yaw = saved_cam_yaw
			cam_pitch = saved_cam_pitch
			camera_pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)
		if is_holding_cam:
			cam_target = _cam_hold_marker_pos()
		else:
			cam_target = _cam_base_marker_pos()

	if event is InputEventMouseMotion:
		cam_yaw += -event.relative.x * 0.002
		cam_pitch += -event.relative.y * 0.002
		cam_pitch = clamp(cam_pitch, CAM_PITCH_MIN, CAM_PITCH_MAX)
		camera_pivot.rotation = Vector3(cam_pitch, cam_yaw, 0.0)

		# 攻击方向判定用的位移记录：对每帧鼠标位移做指数平滑（0.8 = 跟手程度，越大越跟手、越小越"重"）
		# 注意这是持续累积的平滑值（不限定时间窗），按下左键时读它来定方向
		mouse_move_delta = mouse_move_delta.lerp(event.relative, 0.8)
		last_mouse_relative = event.relative   # 原始单帧值：格挡方向用它，避免用到攻击方向的残留

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			lmb_held = true
			# 格挡优先：按住右键时左键完全无效（必须先松开右键才能攻击）
			if is_blocking:
				pass
			# 收剑/格挡收招期间按下左键 → 立刻打断收招、接举剑
			elif is_recovering:
				recover_gen += 1
				is_recovering = false
				is_block_recovering = false
				attack_buffered = false
				can_attack = true
				_begin_charge()
			# 挥砍中按左键 → 缓冲下一刀
			elif is_attacking:
				attack_buffered = true
			elif not is_charging:
				_begin_charge()
		else:
			lmb_held = false
			if is_charging:
				_release_attack()

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_set_blocking(event.pressed)

# ============================================================
# 骑乘
# ============================================================
# 返回最近的、玩家位于其 MountArea（矩形）内的马；side=0 让 _mount 按玩家所在侧判断
func _find_mount_target() -> Dictionary:
	var best: Dictionary = {}
	var best_d: float = INF
	for h in get_tree().get_nodes_in_group("horse"):
		var horse := h as Node3D
		if not (horse.has_method("can_mount") and horse.can_mount(self)):
			continue
		# 必须镜头朝向马匹才能上马
		var to_horse: Vector3 = horse.global_position - global_position
		to_horse.y = 0.0
		if to_horse.length_squared() > 0.0001:
			var view_forward: Vector3 = -Vector3(sin(cam_yaw), 0.0, cos(cam_yaw))
			if camera_3d:
				view_forward = -camera_3d.global_transform.basis.z
				view_forward.y = 0.0
			if view_forward.length_squared() > 0.0001 and view_forward.normalized().dot(to_horse.normalized()) < 0.5:   # 约 ±60°
				continue
		var d: float = global_position.distance_to(horse.global_position)
		if d < best_d:
			best_d = d
			best = {"horse": horse, "side": 0}
	return best

func _try_mount():
	var target: Dictionary = _find_mount_target()
	if not target.is_empty():
		_mount(target["horse"] as Node3D)

func _update_mount_prompt() -> void:
	if mount_prompt == null:
		return
	var can_mount: bool = not riding and not is_mounting and not is_dismounting and health > 0
	if can_mount:
		can_mount = not _find_mount_target().is_empty()
	mount_prompt.visible = can_mount

func _mount_anim_for_side(side: int) -> StringName:
	var ap: AnimationPlayer = null
	if animation_tree and animation_tree.anim_player != NodePath(""):
		ap = animation_tree.get_node_or_null(animation_tree.anim_player) as AnimationPlayer
	if ap and ap.has_animation("mount_left"):
		if side < 0 and ap.has_animation("mount_right"):
			return &"mount_right"
		return &"mount_left"
	return &"mount"   # 旧 glb 只有 mount，先回退

func _mount(h: Node3D, side: int = 0):
	# 有传入侧就用它；否则按玩家在马哪一侧判断（-X=左 / +X=右）
	var approach_side: int = side
	if approach_side == 0:
		var side_dot: float = (global_position - h.global_position).dot(h.global_transform.basis.x.normalized())
		approach_side = 1 if side_dot < 0.0 else -1
	_mount_base_anim = _mount_anim_for_side(approach_side)
	_ride_side = approach_side
	_set_ride_anim_side(_ride_side)
	mount_horse = h
	var start_seat: Transform3D = h.rider_anchor(_ride_side) if h.has_method("rider_anchor") else h.global_transform
	global_position = start_seat.origin
	global_rotation = Vector3(0.0, start_seat.basis.get_euler().y, 0.0)
	riding = true                       # 上马动画期间即可控制马
	is_mounting = true
	_set_ride_attack_anims(true)        # 左右劈切到骑乘专用动画
	_lateral_attack_phase = 0
	_moving_right = false
	_moving_left = false
	h.set("has_rider", true)
	h.set("rider", self)
	if weapon_hitbox:
		weapon_hitbox.disabled = true
	if weapon_area:
		weapon_area.monitoring = false
	# 关掉玩家碰撞：否则玩家贴在马身上会互相顶，马的 CharacterBody 每帧被弹开 → 一上马就飘走
	_saved_layer = collision_layer
	_saved_mask = collision_mask
	collision_layer = 0
	collision_mask = 0
	if spring_bones:
		spring_bones.set_active(true)   # 上马一开始就开，避免播完瞬间才激活造成抽搐
	_update_riding()
	if move_sm:
		move_sm.start(_mount_base_anim)   # 全身播放对应侧的上马动画
	await get_tree().create_timer(_get_anim_length(String(_mount_base_anim), 1.0)).timeout
	is_mounting = false                  # 播完：下半身保持末帧，上半身恢复常规

func _dismount_last_ground_pos() -> Vector3:
	# 用下马动画最后一帧的脚部世界位置作为最终落点；没有脚骨时退回当前位置
	if skeleton:
		var sum: Vector3 = Vector3.ZERO
		var count: int = 0
		for bone_name in ["LeftFoot", "RightFoot"]:
			var idx: int = skeleton.find_bone(bone_name)
			if idx < 0:
				continue
			sum += skeleton.global_transform * skeleton.get_bone_global_pose(idx).origin
			count += 1
		if count > 0:
			var feet: Vector3 = sum / float(count)
			return Vector3(feet.x, 0.0, feet.z)
	return Vector3(global_position.x, 0.0, global_position.z)

func _dismount():
	if mount_horse == null:
		return
	is_dismounting = true
	mount_horse.set("steer_locked", true)   # 下马动画期间禁止马转向
	# 下马侧按摄像机视角定（左右共用同一骑乘机位，镜头在哪侧就从哪侧下）
	var cam_side: float = 0.0
	if camera_3d:
		cam_side = (camera_3d.global_position - mount_horse.global_position).dot(
			mount_horse.global_transform.basis.x.normalized())
	var dismount_side: int = 1 if cam_side < 0.0 else -1
	_ride_side = dismount_side
	_set_ride_anim_side(_ride_side)
	var dismount_base: StringName = _mount_anim_for_side(dismount_side)
	if move_sm:
		move_sm.start(StringName(String(dismount_base) + "_rev"))   # 倒放同侧下马动画
	await get_tree().create_timer(_get_anim_length(String(dismount_base), 1.0)).timeout
	mount_horse.set("has_rider", false)
	mount_horse.set("rider", null)
	mount_horse.set("steer_locked", false)
	# 停在本次下马动画最后一帧的脚部位置，而不是固定横向偏移
	global_position = _dismount_last_ground_pos()
	var dismount_yaw: float = global_rotation.y
	global_rotation = Vector3(0.0, dismount_yaw, 0.0)
	velocity = Vector3.ZERO
	mount_horse = null
	riding = false
	_set_ride_attack_anims(false)       # 下马恢复地面左右劈
	_lateral_attack_phase = 0
	_moving_right = false
	_moving_left = false
	collision_layer = _saved_layer
	collision_mask = _saved_mask
	if weapon_area:
		weapon_area.monitoring = true
	if cam_default_marker:
		cam_target = cam_default_marker.position   # 下马回到默认机位
	_ride_twist = 0.0
	_ride_aim_yaw = 0.0
	_ride_aim_side = 1
	_ride_aim_switching = false
	_mount_base_anim = &"mount"
	_ride_side = 1
	_set_ride_anim_side(1)
	last_anim_state = ""   # 让下马后第一帧重新 travel 到当前移动动画（否则按住移动键不播跑）
	if skeleton:
		skeleton.clear_bones_global_pose_override()
	is_dismounting = false

func _update_riding(_delta: float = 0.0):
	if mount_horse == null:
		riding = false
		return
	var spd: float = absf(float(mount_horse.get("speed")))
	var anchor: Transform3D = mount_horse.global_transform
	if mount_horse.has_method("rider_anchor"):
		anchor = mount_horse.rider_anchor(_ride_side)
	# 完整跟随 Seat 骨骼（位置 + 旋转），人物真正绑在马的鞍座骨骼上
	_ride_anchor = anchor * Transform3D(Basis(), ride_offset)
	global_transform = _ride_anchor            # 刚性贴锚点；拖尾交给骨骼/动画
	if is_mounting:
		# 上马动画期间也跟马走；只暂停步态切换
		if not is_holding_cam:
			var mount_cam: Marker3D = _ride_cam_marker()
			if mount_cam:
				cam_target = mount_cam.position
		velocity = Vector3.ZERO
		return
	# 按马的速度选骑乘前倾动作（走/快步/跑步/飞奔）；左右上马都播这 4 个
	# 马静止时保持上马动画的末帧
	if riding and not is_mounting and not is_dismounting and move_sm and spd >= 0.1:
		var gait: String = "walk"
		if spd >= float(mount_horse.get("canter_speed")):
			gait = "gallop"
		elif spd >= float(mount_horse.get("trot_speed")):
			gait = "canter"
		elif spd >= float(mount_horse.get("walk_speed")):
			gait = "trot"
		move_sm.travel(StringName("ride_" + gait))   # 步态前倾（按速度）
	# 按住 ~ 时不要每帧覆盖机位（否则 ~ 的悬停机位会被立刻刷回骑乘机位 → 按了没反应）
	if not is_holding_cam:
		var ride_cam: Marker3D = _ride_cam_marker()
		if ride_cam:
			cam_target = ride_cam.position   # 上马动画期间按上马侧；动画结束左右共用同一骑乘机位
	if spring_bones:
		spring_bones.set_active(not is_mounting and not is_dismounting)   # 骑乘态才开弹簧骨骼
	velocity = Vector3.ZERO

func _setup_spring_bones() -> void:
	# 在玩家骨架下建弹簧骨骼：左右腿 + 脊椎链（骑乘时开启 → 布娃娃式次级滞后）
	if skeleton == null:
		return
	spring_bones = SpringBoneSimulator3D.new()
	skeleton.add_child(spring_bones)
	var chains := [
		["Chest", "Head"],                 # 躯干：Chest 到 Head（Spine 让给前倾控制）
		["LeftShoulder", "LeftHand"],      # 左臂：肩到手
		["RightShoulder", "RightHand"],    # 右臂：肩到手
		["LeftUpperLeg", "LeftFoot"],      # 左腿：上腿到脚
		["RightUpperLeg", "RightFoot"],    # 右腿：上腿到脚
	]
	spring_bones.set_setting_count(chains.size())
	for i in chains.size():
		spring_bones.set_root_bone_name(i, chains[i][0])
		spring_bones.set_end_bone_name(i, chains[i][1])
		spring_bones.set_extend_end_bone(i, true)
		spring_bones.set_stiffness(i, spring_stiffness)
		spring_bones.set_drag(i, spring_drag)
		spring_bones.set_gravity(i, spring_gravity)
		spring_bones.set_radius(i, 0.02)

	spring_bones.set_active(false)   # 默认关；骑乘时开

func _apply_ride_twist(delta: float) -> void:
	# 骑乘左右转：在【当前动画姿态】基础上叠世界竖直轴(yaw)扭转；平滑过渡、松手回正
	if skeleton == null or mount_horse == null:
		return
	# 攻击/格挡时：不跟马转向、身体朝镜头（交给 _update_head_rotation）
	var aiming: bool = is_charging or is_attacking or is_blocking or is_recovering
	var turn: float = 0.0 if aiming else Input.get_axis("move_left", "move_right")
	_ride_twist = move_toward(_ride_twist, turn, ride_twist_speed * delta)
	for pair in [["Spine", 0.15], ["Chest", 0.2]]:
		var idx: int = skeleton.find_bone(pair[0])
		if idx < 0:
			continue
		skeleton.set_bone_global_pose_override(idx, Transform3D(), 0.0, false)   # 每帧都先清本骨覆盖（回正不残留、也不累加自转）
		if absf(_ride_twist) < 0.001:
			continue
		var cur: Transform3D = skeleton.get_bone_global_pose(idx)
		var q: Quaternion = Quaternion(Vector3.UP, -float(pair[1]) * _ride_twist)
		skeleton.set_bone_global_pose_override(idx, Transform3D(Basis(q) * cur.basis, cur.origin), 1.0, true)

func _setup_ride_attack_anims(sm) -> void:
	_attack_anim_nodes.clear()
	if sm == null:
		return
	for state in RIDE_ATTACK_SWAP:
		if sm.has_node(state):
			var n = sm.get_node(state)
			if n is AnimationNodeAnimation:
				_attack_anim_nodes[state] = n
	print("[player] 骑乘攻击动画节点 = ", _attack_anim_nodes.size())

func _set_ride_attack_anims(use_ride: bool) -> void:
	if _attack_anim_nodes.is_empty():
		return
	var ap: AnimationPlayer = null
	if animation_tree.anim_player != NodePath(""):
		ap = animation_tree.get_node_or_null(animation_tree.anim_player) as AnimationPlayer
	for state in _attack_anim_nodes:
		var node: AnimationNodeAnimation = _attack_anim_nodes[state]
		var anim: StringName = StringName("s_" + String(state))
		if use_ride:
			var ride_anim: StringName = RIDE_ATTACK_SWAP[state]
			if ap == null or ap.has_animation(ride_anim):
				anim = ride_anim
		node.animation = anim

func _ensure_mount_states(machine) -> void:
	# 运行时给 move 状态机加上马/下马状态；并生成倒放的 mount_rev（不改 .tscn）
	var ap: AnimationPlayer = null
	if animation_tree.anim_player != NodePath(""):
		ap = animation_tree.get_node_or_null(animation_tree.anim_player) as AnimationPlayer
	# 上马基础动画：新资源有 mount_left/right；旧资源回退 mount
	var mount_bases: Array[StringName] = []
	if ap:
		if ap.has_animation("mount_left"):
			mount_bases.append(&"mount_left")
			if ap.has_animation("mount_right"):
				mount_bases.append(&"mount_right")
		elif ap.has_animation("mount"):
			mount_bases.append(&"mount")
		for base in mount_bases:
			ap.get_animation(base).loop_mode = Animation.LOOP_NONE
			var rev_name: StringName = StringName(String(base) + "_rev")
			if not ap.has_animation(rev_name):
				var libs := ap.get_animation_library_list()
				if libs.size() > 0:
					ap.get_animation_library(libs[0]).add_animation(String(rev_name), _make_reversed(ap.get_animation(base)))
	if machine == null:
		return
	var state_names: Array[String] = []
	for base in mount_bases:
		state_names.append(String(base))
		state_names.append(String(base) + "_rev")
	for s in state_names:
		if not machine.has_node(s):
			var n := AnimationNodeAnimation.new()
			n.animation = StringName(s)
			machine.add_node(s, n)
	for s in [["ride_walk", "ride_walk"], ["ride_trot", "ride_trot"],
			["ride_canter", "ride_canter"], ["ride_gallop", "ride_gallop"]]:
		if not machine.has_node(s[0]):
			var n := AnimationNodeAnimation.new()
			n.animation = StringName(s[1])
			machine.add_node(s[0], n)
	_ride_state_nodes.clear()
	for s in ["ride_walk", "ride_trot", "ride_canter", "ride_gallop"]:
		if machine.has_node(s):
			var node := machine.get_node(s) as AnimationNodeAnimation
			if node:
				_ride_state_nodes[s] = node
		if ap and ap.has_animation(s):
			var right_name: StringName = StringName(s + "_right")
			if not ap.has_animation(right_name):
				var libs := ap.get_animation_library_list()
				if libs.size() > 0:
					ap.get_animation_library(libs[0]).add_animation(String(right_name), _make_right_ride(ap.get_animation(s)))
	# 4 个骑乘态之间加交叉淡化转场（0.3s）→ travel 切换时渐变
	var ride_states := ["ride_walk", "ride_trot", "ride_canter", "ride_gallop"]
	for from_name in ride_states:
		for to_name in ride_states:
			if from_name == to_name:
				continue
			if not machine.has_transition(from_name, to_name):
				var trans := AnimationNodeStateMachineTransition.new()
				trans.xfade_time = 0.3
				trans.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
				machine.add_transition(from_name, to_name, trans)
	# 上马状态 -> 骑乘步态：也加交叉淡化，避免上马结束后姿势瞬移
	for base in mount_bases:
		var from_name: String = String(base)
		if not machine.has_node(from_name):
			continue
		for to_name in ride_states:
			if not machine.has_transition(from_name, to_name):
				var t2 := AnimationNodeStateMachineTransition.new()
				t2.xfade_time = 0.3
				t2.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
				machine.add_transition(from_name, to_name, t2)
	# 下马倒放状态 -> 地面移动状态：否则下马后 travel 没有路径，下半身会卡在倒放动作
	var foot_states := ["idle_weapon", "walk_forward_weapon", "run_forward_weapon",
		"walk_back_weapon", "run_back_weapon", "jump",
		"idle_empty", "walk_forward_empty", "run_forward_empty",
		"walk_back_empty", "run_back_empty"]
	for base in mount_bases:
		var rev: String = String(base) + "_rev"
		if not machine.has_node(rev):
			continue
		for to_name in foot_states:
			if machine.has_node(to_name) and not machine.has_transition(rev, to_name):
				var t3 := AnimationNodeStateMachineTransition.new()
				t3.xfade_time = 0.2
				t3.switch_mode = AnimationNodeStateMachineTransition.SWITCH_MODE_IMMEDIATE
				machine.add_transition(rev, to_name, t3)

func _make_reversed(src: Animation) -> Animation:
	var rev := Animation.new()
	rev.length = src.length
	rev.loop_mode = Animation.LOOP_NONE
	for t in src.get_track_count():
		var idx: int = rev.add_track(src.track_get_type(t))
		rev.track_set_path(idx, src.track_get_path(t))
		var kc: int = src.track_get_key_count(t)
		for k in kc:
			var sk: int = kc - 1 - k                      # 倒序取源键 → 插入时间递增，避免乱序
			var nt: float = src.length - src.track_get_key_time(t, sk)
			rev.track_insert_key(idx, nt, src.track_get_key_value(t, sk))
	return rev

func _make_right_ride(src: Animation) -> Animation:
	# 右侧骑乘：镜像 Hips 的横向位置，匹配 SeatRight 上的右侧上马末帧
	var out: Animation = src.duplicate(true)
	for t in out.get_track_count():
		if not String(out.track_get_path(t)).ends_with("Skeleton3D:Hips"):
			continue
		if out.track_get_type(t) != Animation.TYPE_POSITION_3D:
			continue
		for k in out.track_get_key_count(t):
			var v: Vector3 = out.track_get_key_value(t, k)
			v.x = -v.x
			out.track_set_key_value(t, k, v)
	return out

func _set_ride_anim_side(side: int) -> void:
	for s in _ride_state_nodes.keys():
		var node := _ride_state_nodes[s] as AnimationNodeAnimation
		if node == null:
			continue
		node.animation = StringName(String(s) + "_right") if side < 0 else StringName(s)

# ============================================================
func _physics_process(delta: float):
	if _hit_stun > 0.0:
		_hit_stun = maxf(_hit_stun - delta, 0.0)
	if riding:
		_update_riding(delta)
		_update_camera_follow()
		_update_camera(delta)
		return
	_update_movement(delta)
	_update_body_facing(delta)
	move_and_slide()
	# 跟随放在移动之后，避免镜头落后一帧（表现为朝移动反方向偏）
	_update_camera_follow()
	_update_camera(delta)

# ============================================================
func _update_movement(delta: float):
	var input: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_back")

	var move_yaw: float = frozen_move_yaw if cam_lock else head_world_yaw
	var cam_fwd: Vector3 = Vector3(sin(move_yaw), 0, cos(move_yaw))
	var cam_rgt: Vector3 = Vector3(cos(move_yaw), 0, -sin(move_yaw))
	var world_dir: Vector3 = (cam_fwd * input.y + cam_rgt * input.x).normalized()

	is_moving = input.length() > 0.1
	_moving_right = is_moving and world_dir.dot(cam_rgt) > 0.1
	_moving_left = is_moving and world_dir.dot(cam_rgt) < -0.1
	_update_lateral_attack_phase()   # 按举刀/挥刀/收刀动画帧决定下身朝右还是朝左

	# 非走路模式（未开 CapsLock）下所有移动都跑，含后退（速度与动画都用跑）
	var is_running: bool = not is_walking
	var speed: float = run_speed if is_running else walk_speed

	velocity.x = world_dir.x * speed
	velocity.z = world_dir.z * speed

	jump_cool = maxf(jump_cool - delta, 0.0)
	if is_on_floor():
		if Input.is_action_just_pressed("jump") and jump_cool <= 0.0:
			velocity.y = jump_velocity
			jump_cool = jump_interval
			jump_vel = Vector3(velocity.x, 0.0, velocity.z)   # 记住起跳那一刻的水平速度（惯性）
		elif velocity.y <= 0.0:
			velocity.y = -0.2
	else:
		velocity.y -= 9.8 * delta
		# 空中：水平方向只按起跳那一刻，忽略腾空时的输入（有惯性、方向不随空中按键变）
		velocity.x = jump_vel.x
		velocity.z = jump_vel.z

	# 攻击中下身默认按正常移动朝向；只有「移动方向与攻击方向相同」且挥刀到第14帧后，才转到另一侧
	var turn_to_opposite: bool = _lateral_attack_phase == 2
	var same_dir: bool = false
	if current_attack == "right":
		same_dir = _moving_right
	elif current_attack == "left":
		same_dir = _moving_left

	# 停止瞬间：记住当时上身朝向，之后下身朝它平滑回正、上身保持不变
	if was_moving and not is_moving:
		idle_face_yaw = aim_yaw
	was_moving = is_moving

	var in_combat: bool = is_charging or is_attacking or is_recovering or is_blocking
	# 攻击/格挡结束瞬间：以当前实际朝向为准，之后不回正到攻击前
	if was_in_combat and not in_combat:
		idle_face_yaw = rotation.y
		print("[atk_end] rot=", rad_to_deg(rotation.y), " face=", rad_to_deg(idle_face_yaw), " aim=", rad_to_deg(aim_yaw), " move=", rad_to_deg(move_yaw), " tgt=", rad_to_deg(body_target_yaw), " moving=", is_moving)
	was_in_combat = in_combat

	if not is_on_floor():
		body_target_yaw = move_yaw   # 空中：下身朝镜头（移动键不控制转身）
	elif turn_to_opposite:
		# 同向移动且挥刀到第14帧后：下身转到另一侧（左劈↔右劈镜像）
		var turn_dir: Vector3 = cam_rgt if current_attack == "right" else -cam_rgt
		body_target_yaw = atan2(turn_dir.x, turn_dir.z)
	elif world_dir.length() > 0.1:
		var body_dir: Vector3
		if input.y == 0:
			body_dir = -cam_rgt * input.x
		else:
			body_dir = world_dir if input.y >= 0 else -world_dir
		body_target_yaw = atan2(body_dir.x, body_dir.z)
	elif in_combat:
		# 攻击/格挡中不移动：下身转向瞄准方向（跟着攻击方向转过来）；转向平滑由 _update_body_facing 处理
		body_target_yaw = move_yaw
		idle_face_yaw = move_yaw   # 攻击结束后保持这个朝向，不回正到攻击前
	else:
		# 不移动：下身朝「停止瞬间的朝向」回正（平滑由 _update_body_facing 处理）
		body_target_yaw = idle_face_yaw

	# 基底状态机始终驱动走路（战斗时上半身被攻击层覆盖，下半身仍走路）
	if animation_tree and move_sm:
		var suffix: String = "weapon" if has_weapon else "empty"
		var move_state: String
		var back_state: String = ("run_back_" if not is_walking else "walk_back_") + suffix
		if not is_on_floor() or velocity.y > 0.0:
			move_state = "jump"   # 离地或在上升（起跳当帧）就播跳跃
		elif input.length() < 0.1:
			move_state = "idle_" + suffix
		elif turn_to_opposite:
			# 下身已转到另一侧：同向移动相对身体是后退，否则前进
			move_state = back_state if same_dir else ("run_forward_" if is_running else "walk_forward_") + suffix
		elif input.y > 0.1:
			# 后退：默认跑步后退（走路模式才用走路后退）
			move_state = back_state
		else:
			move_state = ("run_forward_" if is_running else "walk_forward_") + suffix
		if last_anim_state != move_state:
			move_sm.travel(StringName(move_state))
			last_anim_state = move_state

# 地面左右劈下身阶段：0=正常 / 1=正常（举刀~挥刀14帧） / 2=转到另一侧（14帧~收刀5帧）
# 只有「右走右劈 / 左走左劈」才进入 2；反向移动不触发
func _update_lateral_attack_phase() -> void:
	if riding or attack_sm == null or (current_attack != "right" and current_attack != "left"):
		_lateral_attack_phase = 0
		return
	if is_charging:
		_lateral_attack_phase = 1
		return
	var node: StringName = attack_sm.get_current_node()
	var pos: float = attack_sm.get_current_play_position()
	var swing_node: StringName = StringName("attack_" + current_attack + "_swing")
	var recover_node: StringName = StringName("attack_" + current_attack + "_recover")
	var same_dir: bool = _moving_right if current_attack == "right" else _moving_left
	if node == swing_node:
		var swing_len: float = _get_anim_length(String(swing_node), 0.42)
		if pos < swing_len * LATERAL_SWING_TURN_T:
			_lateral_attack_phase = 1
		elif same_dir or _lateral_attack_phase == 2:
			_lateral_attack_phase = 2   # 第14帧后且同向移动：锁存转向另一侧
	elif node == recover_node:
		var recover_len: float = _get_anim_length(String(recover_node), 0.4)
		if pos >= recover_len * LATERAL_RECOVER_RESTORE_T:
			_lateral_attack_phase = 0   # 收刀第5帧：恢复正常
	elif is_attacking or is_recovering:
		pass   # 切换过渡帧：保持当前阶段
	else:
		_lateral_attack_phase = 0

# 上马动画期间用上马侧的镜像机位；动画结束回到左右共用的骑乘机位
func _ride_cam_marker() -> Marker3D:
	if _ride_side < 0 and cam_ride_marker_right:
		return cam_ride_marker_right
	return cam_ride_marker

func _ride_hold_marker() -> Marker3D:
	if _ride_side < 0 and cam_ride_hold_marker_right:
		return cam_ride_hold_marker_right
	return cam_ride_hold_marker

# ============================================================
# 松开 ~ 的归位目标：骑乘回骑乘机位、否则回默认机位
func _cam_base_marker_pos() -> Vector3:
	if riding:
		var m: Marker3D = _ride_cam_marker()
		if m:
			return m.position
	return cam_default_marker.position

# 按住 ~ 的观察机位：骑乘用专用 marker，没有配置时回退到步行的 CamHold
func _cam_hold_marker_pos() -> Vector3:
	if riding:
		var m: Marker3D = _ride_hold_marker()
		if m:
			return m.position
	return cam_hold_marker.position

func _update_camera(delta: float):
	if cam_returning:
		# ② 只回归机位：从悬停机位平滑回到默认/骑乘机位（角度不锁，玩家全程可自由控制）
		var ret_pos: Vector3 = _cam_base_marker_pos()
		camera_3d.position = camera_3d.position.lerp(ret_pos, cam_transition_speed * delta)
		if camera_3d.position.distance_to(ret_pos) < 0.005:
			camera_3d.position = ret_pos
			cam_returning = false
	else:
		camera_3d.position = camera_3d.position.lerp(cam_target, cam_transition_speed * delta)
	# ③ 回归那段不锁身体；只有按住 ~ 时才锁
	cam_lock = is_holding_cam
	var target_fov: float = 25.0 if Input.is_key_pressed(KEY_SHIFT) else default_fov
	camera_3d.fov = lerpf(camera_3d.fov, target_fov, 10.0 * delta)

func _update_camera_follow():
	var base: Vector3 = _ride_anchor.origin if riding else global_position
	camera_pivot.global_position = base + Vector3(0, 1.6, 0)

func _update_body_facing(delta: float):
	var angle_diff: float = abs(wrapf(cam_yaw - rotation.y, -PI, PI))
	var t: float = clampf(angle_diff / deg_to_rad(30.0), 0.0, 1.0)
	var speed: float = lerpf(body_rotation_speed, 30.0, t)
	rotation.y = lerp_angle(rotation.y, body_target_yaw, speed * delta)

func _update_head_rotation(delta: float):
	head_world_yaw = cam_yaw
	if spine_bone_idx < 0:
		return

	# 死亡：上半身完全交给动画（优先于瞄准，避免俯仰残留盖住死亡姿势）
	if health <= 0:
		if not riding:
			skeleton.clear_bones_global_pose_override()
		return

	var aiming: bool = is_charging or is_attacking or is_blocking or is_recovering
	# 瞄准 yaw 每帧都更新（战斗时也跟镜头），否则攻击结束瞬间 aim_yaw 还是旧值会把上身拽回去
	# 站定(未移动/未战斗)时上身不朝镜头——即使按住 ~ 也保持原朝向
	var aim_target: float
	if riding:
		aim_target = rotation.y
	elif is_moving or aiming:
		aim_target = frozen_move_yaw if cam_lock else cam_yaw
	else:
		aim_target = idle_face_yaw
	if is_moving or aiming or cam_lock or riding:
		aim_yaw = aim_target   # 骑乘：只跟马身朝向（镜头不影响人物转向）；其余同原
	else:
		aim_yaw = lerp_angle(aim_yaw, aim_target, 10.0 * delta)   # 停下回正：平滑

	# 蓄力/攻击/格挡/收招，或俯仰还没归零：上身左右转由代码控制（朝镜头瞄准）+ 平滑俯仰弯曲
	if aiming or absf(aim_pitch) > 0.001:
		_apply_aim_bend(aim_pitch, delta)
		return

	# 非战斗：上身朝瞄准方向（移动时=镜头；停止后=停止瞬间的朝向）
	if not riding:
		skeleton.clear_bones_global_pose_override()   # 骑乘时保留骑乘覆盖，瞄准叠加在其上
	var upper_yaw: float = aim_yaw
	# 归一化到最短角，避免 cam_yaw 无界累加导致差值绕多圈、腰部扭成麻花
	var delta_yaw: float = wrapf(upper_yaw - rotation.y, -PI, PI)
	var chain: Array = [spine_bone_idx, chest_bone_idx]
	var poses: Array = []
	for bone in chain:
		poses.append(skeleton.get_bone_global_pose(bone) if bone >= 0 else Transform3D())
	var n: int = chain.size()
	for i in n:
		var bone: int = chain[i]
		if bone < 0:
			continue
		var cur: Transform3D = poses[i]
		var frac: float = float(i + 1) / float(n)
		var q: Quaternion = Quaternion(Vector3.UP, delta_yaw * frac)
		# 世界空间左乘：在当前动画朝向上叠加 yaw，动画姿势保留
		skeleton.set_bone_global_pose_override(bone, Transform3D(Basis(q) * cur.basis, cur.origin), 1.0, true)

# ============================================================
# 用镜头俯仰弯曲上身实现攻击俯仰（下半身不动），头/颈反向抵消保持平视
# ============================================================
func _apply_aim_bend(aim: float, delta: float):
	if not riding:
		skeleton.clear_bones_global_pose_override()
	# 上身朝向瞄准方向：yaw 用「世界空间左乘」（不依赖骨骼局部轴），避免按 A/D 时上身左右晃动
	var upper_yaw: float = frozen_move_yaw if cam_lock else cam_yaw
	# 同样归一化到最短角，避免腰部扭成麻花
	var dy: float = wrapf(upper_yaw - rotation.y, -PI, PI)
	if riding:
		# 骑乘：水平攻击角限制（左右劈/上劈/下刺各自独立）
		# 换侧判定：越过中线（马正前 dy=0）即切到另一侧
		var switched: bool = false
		# 只在挥刀动画期间锁死攻击侧；举刀/收刀阶段允许换侧
		var attack_locked: bool = is_attacking
		if not attack_locked:
			# Godot: +yaw = 左、-yaw = 右。side=+1 表示正角(左)侧，-1 表示负角(右)侧
			if _ride_aim_side > 0 and dy < 0.0:
				_ride_aim_side = -1
				switched = true
			elif _ride_aim_side < 0 and dy > 0.0:
				_ride_aim_side = 1
				switched = true
		# 瞄准抬得够高时刃已离开马身，取消正前死区（允许直接朝马头正前挥/刺）
		# 低于阈值时用 min 缩放做过渡，避免从无限制切到有限制时瞬间转向
		var front_min_scale: float = _ride_front_min_scale(aim)
		var target: float = _clamp_ride_aim(dy, _ride_aim_side, front_min_scale)
		if switched:
			_ride_aim_switching = true
		if _ride_aim_switching:
			# 换侧中：按固定角速度限速扫向「当前」目标（两端异号 → 必经 0°=马头正前，不会从后面绕）
			# 时长自然 = 需转角度 / 角速度；快到目标才停，避免端点对不上造成的瞬跳
			var step: float = maxf(ride_aim_turn_speed, 0.001) * delta
			_ride_aim_yaw = move_toward(_ride_aim_yaw, target, step)
			if absf(_ride_aim_yaw - target) <= step:
				_ride_aim_yaw = target
				_ride_aim_switching = false
		else:
			_ride_aim_yaw = target   # 同侧有效范围内：即时跟随，无延迟
		dy = _ride_aim_yaw
	var yaw_q: Quaternion = Quaternion(Vector3.UP, dy)
	if not riding:
		# 与非战斗移动时相同的分配（Spine 0.5 / Chest 1.0）：
		# 否则进入攻击时 Chest 覆盖突然消失，会表现为腰部突变
		var yaw_half: Quaternion = Quaternion(Vector3.UP, dy * 0.5)
		var cur_spine: Transform3D = skeleton.get_bone_global_pose(spine_bone_idx) if spine_bone_idx >= 0 else Transform3D()
		var cur_chest: Transform3D = skeleton.get_bone_global_pose(chest_bone_idx) if chest_bone_idx >= 0 else Transform3D()
		if spine_bone_idx >= 0:
			var rest: Transform3D = skeleton.get_bone_global_rest(spine_bone_idx)
			# 俯仰轴取「举剑(转向瞄准)后的静止朝向」的侧轴并右转90°：各攻击方向一致，不随具体动画偏
			var aim_frame: Basis = Basis(yaw_q) * rest.basis
			var lateral: Vector3 = aim_frame.x.normalized().rotated(aim_frame.y.normalized(), -PI * 0.5)
			var pitch_q: Quaternion = Quaternion(lateral, clampf(-aim, -CAM_PITCH_MAX, -CAM_PITCH_MIN))
			var aimed: Basis = Basis(yaw_half) * cur_spine.basis
			skeleton.set_bone_global_pose_override(spine_bone_idx, Transform3D(Basis(pitch_q) * aimed, cur_spine.origin), 1.0, true)
		if chest_bone_idx >= 0:
			skeleton.set_bone_global_pose_override(chest_bone_idx, Transform3D(Basis(yaw_q) * cur_chest.basis, cur_chest.origin), 1.0, true)
		return
	if spine_bone_idx >= 0:
		var cur: Transform3D = skeleton.get_bone_global_pose(spine_bone_idx)
		var rest: Transform3D = skeleton.get_bone_global_rest(spine_bone_idx)
		var aim_frame: Basis = Basis(yaw_q) * rest.basis
		var lateral: Vector3 = aim_frame.x.normalized().rotated(aim_frame.y.normalized(), -PI * 0.5)
		var pitch_q: Quaternion = Quaternion(lateral, clampf(-aim, -CAM_PITCH_MAX, -CAM_PITCH_MIN))
		var aimed: Basis = Basis(yaw_q) * cur.basis
		skeleton.set_bone_global_pose_override(spine_bone_idx, Transform3D(Basis(pitch_q) * aimed, cur.origin), 1.0, true)

# 骑乘一次攻击开始时锁定攻击侧：左攻击=左侧，右攻击=右侧；上/下按当前镜头侧
func _lock_ride_aim_side() -> void:
	if not riding:
		return
	# 只锁住举剑结束/挥剑第一帧时镜头所在的侧；
	# 不要按 current_attack 的左/右劈方向强制把侧改回上马侧
	var upper_yaw: float = frozen_move_yaw if cam_lock else cam_yaw
	var dy: float = wrapf(upper_yaw - rotation.y, -PI, PI)
	var new_side: int = 1 if dy >= 0.0 else -1
	if new_side != _ride_aim_side:
		_ride_aim_side = new_side
		_ride_aim_switching = true

# 骑乘攻击的水平角限制（相对马正前方，正=左、负=右）
# 左右劈 / 上劈 / 下刺各自独立；格挡沿用左右劈的限幅
func _clamp_ride_aim(delta_yaw: float, side: int, front_min_scale: float = 1.0) -> float:
	var dir: String = "" if is_blocking else current_attack
	var lim: Vector2 = _ride_aim_limits(dir, side, front_min_scale)
	return clampf(delta_yaw, lim.x, lim.y)

# 正前 min 限制的缩放：高于阈值=0（无限制）；低于阈值后按 blend 角度从 0 渐变到 1
func _ride_front_min_scale(pitch: float) -> float:
	var thr: float = deg_to_rad(ride_aim_front_free_pitch_deg)
	if pitch >= thr:
		return 0.0
	var band: float = deg_to_rad(maxf(ride_aim_front_free_blend_deg, 0.001))
	return clampf((thr - pitch) / band, 0.0, 1.0)

func _ride_aim_limits(dir: String, side: int, front_min_scale: float = 1.0) -> Vector2:
	var lo: float = ride_aim_left_min_deg
	var hi: float = ride_aim_left_max_deg
	if dir == "up":
		lo = ride_aim_up_left_min_deg
		hi = ride_aim_up_left_max_deg
	elif dir == "thrust":
		lo = ride_aim_thrust_left_min_deg
		hi = ride_aim_thrust_left_max_deg
	if side < 0:
		lo = ride_aim_right_min_deg
		hi = ride_aim_right_max_deg
		if dir == "up":
			lo = ride_aim_up_right_min_deg
			hi = ride_aim_up_right_max_deg
		elif dir == "thrust":
			lo = ride_aim_thrust_right_min_deg
			hi = ride_aim_thrust_right_max_deg
	lo *= clampf(front_min_scale, 0.0, 1.0)   # 0=正前无限制；1=完整 min
	# 左侧为正角区间，右侧为负角区间
	if side > 0:
		return Vector2(deg_to_rad(lo), deg_to_rad(hi))
	return Vector2(-deg_to_rad(hi), -deg_to_rad(lo))

# ============================================================
# 战斗逻辑
# ============================================================
func _begin_charge():
	if is_attacking:
		return
	is_charging = true
	_lateral_attack_phase = 0
	can_attack = true                   # 举剑了就能挥：清掉上一次的冷却/锁定（否则松手会卡在举剑）
	attack_started_moving = is_moving   # 记下起手时是否在移动（决定下半身是否用攻击动画）
	# 攻击方向：鼠标动过（平滑位移长度 > 2px）才更新方向；没动就保持上一次（初始默认「下」/前刺）
	if mouse_move_delta.length() > 2.0:
		attack_dir = _judge_mouse_dir(mouse_move_delta)
	current_attack = ATTACK_DIR_NAMES[attack_dir]
	# 举剑俯仰过渡：与举剑动画时长同步
	raise_pitch_from = aim_pitch
	raise_pitch_dur = maxf(_get_anim_length("attack_" + current_attack + "_raise", 0.3), 0.001)
	raise_pitch_t = 0.0
	if attack_sm:
		var target := StringName("attack_" + current_attack + "_raise")
		# 连击（从挥砍来）或从格挡起手 → 走交叉淡化；从待机起手 → 瞬切（淡入交给上身混合权重）
		var cur: String = String(attack_sm.get_current_node())
		if cur.begins_with("attack_") or cur.begins_with("block_"):
			attack_sm.travel(target)
		else:
			attack_sm.start(target)

func _release_attack():
	is_charging = false
	_do_attack_by_name(current_attack)

# 把鼠标位移判成 4 个攻击方向（以对角线 45° 为分界）：
#	|x| > |y| → 右 / 左（按 x 正负）
#	否则       → 下刺(motion.y > 0) / 上劈(motion.y < 0)
func _judge_mouse_dir(motion: Vector2) -> AttackDir:
	var ax: float = abs(motion.x)
	var ay: float = abs(motion.y)
	if ax > ay:
		return AttackDir.RIGHT if motion.x > 0 else AttackDir.LEFT
	else:
		return AttackDir.THRUST if motion.y > 0 else AttackDir.UP

func _do_attack_by_name(attack_name: String):
	if not can_attack:
		return
	can_attack = false
	is_attacking = true
	attack_gen += 1
	var my_gen: int = attack_gen
	# 从「开始挥击」这一刻起重新累积鼠标移动，用于判定下一刀方向（输入缓冲）
	mouse_move_delta = Vector2.ZERO
	current_attack = attack_name
	_lock_ride_aim_side()   # 保证直接调用时也按本次攻击方向锁侧
	weapon_area.attack_dir = current_attack
	var swing_name: String = "attack_" + current_attack + "_swing"
	if attack_sm:
		attack_sm.travel(StringName(swing_name))
	var swing_len: float = _get_anim_length(swing_name, 0.42)
	if weapon_area:
		weapon_area.damage = _weapon_damage
	if weapon_hitbox:
		weapon_hitbox.disabled = false
	# 有效判定覆盖整个挥剑过程
	await get_tree().create_timer(swing_len).timeout
	if weapon_hitbox:
		weapon_hitbox.disabled = true
	if my_gen != attack_gen or is_blocking:
		return
	is_attacking = false
	# 注意：这里不要清 last_anim_state —— 否则下一帧会对 move 层重新 travel，把移动动画从 0 帧重启（闪一下）
	# 缓冲连击：挥砍期间按住左键 → 挥砍结束直接过渡到下一次举刀（跳过收刀）；其间松手则作废
	if attack_buffered:
		attack_buffered = false
		can_attack = true
		if lmb_held and not is_blocking:
			_begin_charge()
			return
	# 收招 → 待机（收招期间 is_recovering=true，让上身权重保持 1，收招动作才显示）
	if attack_sm and not is_blocking:
		var recover_name: String = "attack_" + current_attack + "_recover"
		var recover_len: float = _get_anim_length(recover_name, 0.4)
		# 收剑俯仰过渡：与收剑动画时长同步归零
		recover_pitch_from = aim_pitch
		recover_pitch_dur = maxf(recover_len, 0.001)
		recover_pitch_t = 0.0
		is_recovering = true
		var recover_my_gen: int = recover_gen
		attack_sm.travel(StringName(recover_name))
		await get_tree().create_timer(recover_len).timeout
		if recover_my_gen != recover_gen:
			return   # 收招已被打断/被新的收招接管，交给接管者处理，勿回待机
		is_recovering = false
		attack_buffered = false
		attack_sm.travel(&"idle_weapon")
	await get_tree().create_timer(attack_cooldown).timeout
	can_attack = true

func _get_anim_length(clip: String, fallback: float) -> float:
	if animation_tree.anim_player != NodePath(""):
		var ap: AnimationPlayer = animation_tree.get_node_or_null(animation_tree.anim_player) as AnimationPlayer
		if ap:
			# 骑乘左右劈用专用动画的长度（时机对齐）；其余仍按地面动画
			if riding and RIDE_ATTACK_SWAP.has(clip):
				var ride_name: StringName = RIDE_ATTACK_SWAP[clip]
				if ap.has_animation(ride_name):
					return ap.get_animation(ride_name).get_length()
			if ap.has_animation(clip):
				return ap.get_animation(clip).get_length()
			# 持剑动画带 s_ 前缀
			var sname: String = "s_" + clip
			if ap.has_animation(sname):
				return ap.get_animation(sname).get_length()
	return fallback

func _find_group_ancestor(node: Node, group_name: StringName) -> Node:
	var n: Node = node
	while n:
		if n.is_in_group(group_name):
			return n
		n = n.get_parent()
	return null

func _on_block_area_entered(area: Area3D) -> void:
	if not is_blocking:
		return
	var enemy: Node = _find_group_ancestor(area, &"enemy")
	if enemy == null:
		return
	if enemy.has_method("is_in_block_window") and not bool(enemy.is_in_block_window()):
		return
	var serial: int = int(enemy.get("_attack_serial"))
	if serial == _last_blocked_enemy_serial:
		return
	_last_blocked_enemy_serial = serial
	_weapon_contact = true
	var block_len: float = _get_anim_length("block_success_" + block_dir, 0.4)
	if enemy.has_method("on_weapon_clash"):
		enemy.on_weapon_clash(block_len)
	_play_block_success(block_dir)

func _on_block_area_exited(area: Area3D) -> void:
	if _find_group_ancestor(area, &"enemy") != null:
		_weapon_contact = false

func _play_block_success(dir: String) -> void:
	if attack_sm and dir != "":
		attack_sm.start(StringName("block_success_" + dir))

func _set_blocking(active: bool):
	is_blocking = active
	if active:
		# 格挡优先：重置全部攻击状态（蓄力/挥砍/收剑/缓冲），并让挂起的收剑协程提前退出，
		# 避免残留的攻击动画在格挡之后乱播。
		is_charging = false
		is_attacking = false
		is_recovering = false
		_lateral_attack_phase = 0
		recover_gen += 1   # 令挂起的收招协程提前退出（无条件 +1，不会像 bool 那样残留）
		attack_gen += 1    # 令挂起的挥砍协程彻底退出（否则挥砍协程醒来时格挡可能已松开，会顶掉格挡/后续攻击）
		can_attack = true  # 清除挥砍锁定，否则打断后「格挡完再攻击」会被 _do_attack_by_name 的 can_attack 挡掉
		_weapon_contact = false
		if weapon_hitbox:
			weapon_hitbox.disabled = false
		if weapon_area:
			weapon_area.damage = 0.0
		attack_buffered = false
		# 鼠标动过才更新格挡方向；没动就保持上一次（初始默认「下」）
		if last_mouse_relative.length() > 1.0:
			var dir_name: String = ATTACK_DIR_NAMES[_judge_mouse_dir(last_mouse_relative)]
			block_dir_keep = "down" if dir_name == "thrust" else dir_name
		block_dir = block_dir_keep
		if attack_sm:
			# 用 travel 走 attack_* -> block_* 的短交叉淡化，避免 start() 硬切造成的跳变
			attack_sm.travel(StringName("block_" + block_dir))
		if weapon_area:
			for area in weapon_area.get_overlapping_areas():
				_on_block_area_entered(area)
	else:
		_weapon_contact = false
		if animation_tree and not animation_tree.active:
			animation_tree.active = true
		if weapon_hitbox:
			weapon_hitbox.disabled = true
		if weapon_area:
			weapon_area.damage = _weapon_damage
		# 松开格挡时左键还按着 → 立刻淡入举剑攻击（不播格挡收招）
		if lmb_held:
			is_block_recovering = false
			is_recovering = false
			attack_buffered = false
			can_attack = true
			block_dir = ""
			last_anim_state = ""
			_begin_charge()
			return
		# 格挡松开：先播收招，再回待机（收招期间 is_recovering 保持上身权重=1）
		if block_dir != "" and attack_sm:
			var recover_name: String = "block_" + block_dir + "_recover"
			var recover_len: float = _get_anim_length(recover_name, 0.4)
			# 收剑俯仰过渡：与收剑动画时长同步归零
			recover_pitch_from = aim_pitch
			recover_pitch_dur = maxf(recover_len, 0.001)
			recover_pitch_t = 0.0
			is_block_recovering = true
			is_recovering = true
			var my_gen: int = recover_gen
			attack_sm.travel(StringName(recover_name))
			await get_tree().create_timer(recover_len).timeout
			is_block_recovering = false
			if my_gen != recover_gen:
				return   # 收招已被打断/接管，交给接管者处理，勿回待机
			is_recovering = false
			if attack_buffered and lmb_held:
				attack_buffered = false
				_begin_charge()
			elif not is_blocking:
				attack_sm.travel(&"idle_weapon")
		block_dir = ""
		last_anim_state = ""

func is_in_block_window() -> bool:
	if attack_sm == null or animation_tree == null:
		return false
	var state_name: String = String(attack_sm.get_current_node())
	if not state_name.ends_with("_swing"):
		return false
	var ap: AnimationPlayer = animation_tree.get_node_or_null(animation_tree.anim_player) as AnimationPlayer
	if ap == null:
		return false
	var anim_name: String = "s_" + state_name
	if _attack_anim_nodes.has(state_name):
		var node: AnimationNodeAnimation = _attack_anim_nodes[state_name]
		if node and node.animation != &"":
			anim_name = String(node.animation)
	var anim: Animation = ap.get_animation(anim_name)
	if anim == null:
		return false
	var step: float = anim.step if anim.step > 0.0 else 1.0 / 30.0
	return attack_sm.get_current_play_position() <= 13.0 * step + 0.0001

func on_weapon_clash(duration: float = 0.16):
	# 挥剑撞到对方格挡武器：停在第14帧，退回第13帧停5帧
	if _clash_freeze_t > 0.0 or not is_attacking:
		return
	if _blocked_attack_gen == attack_gen:
		return
	if not is_in_block_window():
		return
	if attack_sm == null or animation_tree == null:
		return
	var state_name: String = String(attack_sm.get_current_node())
	if not state_name.ends_with("_swing"):
		return
	var ap: AnimationPlayer = animation_tree.get_node_or_null(animation_tree.anim_player) as AnimationPlayer
	if ap == null:
		return
	var anim_name: String = "s_" + state_name
	if _attack_anim_nodes.has(state_name):
		var node: AnimationNodeAnimation = _attack_anim_nodes[state_name]
		if node and node.animation != &"":
			anim_name = String(node.animation)
	var anim: Animation = ap.get_animation(anim_name)
	if anim == null:
		return
	var step: float = anim.step if anim.step > 0.0 else 1.0 / 30.0
	var f14: float = minf(13.0 * step, anim.length)
	_blocked_attack_gen = attack_gen
	_clash_freeze_t = duration
	animation_tree.active = false
	ap.play(anim_name, 0.0)
	ap.seek(f14, true)
	await get_tree().create_timer(duration).timeout
	_clash_freeze_t = 0.0
	animation_tree.active = true

func _build_health_bar() -> void:
	var hud := CanvasLayer.new()
	hud.name = "PlayerHUD"
	hud.layer = 10
	add_child(hud)
	var bar := ProgressBar.new()
	bar.name = "PlayerHealthBar"
	bar.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	bar.offset_left = -280.0
	bar.offset_top = -52.0
	bar.offset_right = -20.0
	bar.offset_bottom = -20.0
	bar.show_percentage = true
	bar.max_value = max_health
	bar.value = health
	hud.add_child(bar)
	_health_bar = bar

func _update_health_bar() -> void:
	if _health_bar == null:
		return
	_health_bar.max_value = max_health
	_health_bar.value = clampf(health, 0.0, max_health)

func _block_direction_matches(attack_dir: String) -> bool:
	if block_dir == "" or attack_dir == "":
		return false
	if block_dir == "down":
		return attack_dir == "thrust" or attack_dir == "down"
	return block_dir == attack_dir

func take_damage(amount: float, _attack_dir: String = ""):
	var enemy := get_tree().get_first_node_in_group("enemy")
	var block_window_ok: bool = true
	if enemy and enemy.has_method("is_in_block_window"):
		block_window_ok = bool(enemy.is_in_block_window())
	if block_window_ok and is_blocking and (_weapon_contact or _block_direction_matches(_attack_dir)):
		# 武器接触，或格挡方向与来袭方向一致：格挡成功
		if enemy:
			var serial: int = int(enemy.get("_attack_serial"))
			if serial == _last_blocked_enemy_serial:
				return
			_last_blocked_enemy_serial = serial
		if not _weapon_contact:
			var block_len: float = _get_anim_length("block_success_" + block_dir, 0.4)
			if enemy and enemy.has_method("on_weapon_clash"):
				enemy.on_weapon_clash(block_len)
			_play_block_success(block_dir)
		return
	if animation_tree and not animation_tree.active:
		animation_tree.active = true
	health -= amount
	_update_health_bar()
	# 受击时强制中断举剑/挥剑/格挡，播放受击动画（不再卡在攻击状态）
	attack_gen += 1
	is_charging = false
	is_attacking = false
	is_recovering = false
	is_block_recovering = false
	is_blocking = false
	attack_buffered = false
	attack_started_moving = false
	can_attack = true
	_lateral_attack_phase = 0
	if weapon_hitbox:
		weapon_hitbox.set_deferred("disabled", true)
	_hit_stun = _get_anim_length("hit_weapon", 0.4)
	if attack_sm:
		attack_sm.start(&"hit_weapon")
	if health <= 0:
		_die()

func _die():
	_update_health_bar()
	if animation_tree and not animation_tree.active:
		animation_tree.active = true
	if attack_sm:
		attack_sm.start(&"death")
	set_physics_process(false)

func is_dead() -> bool:
	return health <= 0
