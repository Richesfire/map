"""
清理脚本 - 删除程序化生成的所有动画动作
运行: exec(open(r"D:/NSS-huangrongji/Godot/IASv1.0/blender_scripts/clear_animations.py").read())
"""

import bpy

# 要删除的所有动作名
animations_to_delete = [
    "walk_forward_empty", "walk_forward_weapon",
    "run_forward_empty", "run_forward_weapon",
    "walk_back_empty", "walk_back_weapon",
    "attack_left_raise", "attack_left_swing",
    "attack_right_raise", "attack_right_swing",
    "attack_up_raise", "attack_up_swing",
    "attack_thrust_raise", "attack_thrust_swing",
]

deleted = 0
for name in animations_to_delete:
    if name in bpy.data.actions:
        bpy.data.actions.remove(bpy.data.actions[name])
        deleted += 1

print("已删除 %d 个动作" % deleted)
print("剩余动作:", [a.name for a in bpy.data.actions])
