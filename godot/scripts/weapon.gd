extends Area3D

# ============================================================
# 武器碰撞区 —— 挂在武器 Area3D 上
# 攻击时开启碰撞，碰到敌人造成伤害
# ============================================================

@export var damage: float = 25.0
@export var attack_dir: String = ""      # 攻击方向(left/right/up/thrust)，用于格挡匹配
@export var my_group: String = "player"  # 武器所属阵营，不打自己人

func _ready():
	body_entered.connect(_on_body_entered)
	area_entered.connect(_on_area_entered)

func _on_body_entered(body: Node3D):
	if damage <= 0.0 or body.is_in_group(my_group):
		return
	if body.has_method("take_damage"):
		body.take_damage(damage, attack_dir)

func _on_area_entered(area: Area3D):
	if damage <= 0.0:
		return
	var parent: Node = area.get_parent()
	if parent and parent.is_in_group(my_group):
		return
	if parent and parent.has_method("take_damage"):
		parent.take_damage(damage, attack_dir)
