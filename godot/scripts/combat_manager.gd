extends Node

# ============================================================
# 战斗管理器 —— 单例，放在 autoload 里
# 处理伤害信号传递、击杀统计等全局战斗逻辑
# ============================================================

signal player_died
signal enemy_died(enemy)

func deal_damage(attacker: Node, target: Node, amount: float, attack_dir: String = ""):
	"""统一的伤害接口"""
	if target.has_method("take_damage"):
		target.take_damage(amount, attack_dir)

func get_health_percent(node: Node) -> float:
	if node.has_method("get_health"):
		return node.get_health()
	return 0.0
