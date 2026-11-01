"""
创建动作框架 - walk_forward
运行前先在 Blender 选中 Armature 骨架
运行: exec(open(r"D:/NSS-huangrongji/Godot/IASv1.0/blender_scripts/create_action.py").read())
"""

import bpy

# 要创建的动作列表（走路循环用 24 帧，1秒）
ACTION_NAME = "walk_forward_empty"
START_FRAME = 1
END_FRAME = 25   # 24帧循环 + 1帧回绕

# 删除旧动作
if ACTION_NAME in bpy.data.actions:
    bpy.data.actions.remove(bpy.data.actions[ACTION_NAME])

# 创建新动作
action = bpy.data.actions.new(ACTION_NAME)
action.use_fake_user = True
action.frame_range = (START_FRAME, END_FRAME)

# 设置场景帧范围
bpy.context.scene.frame_start = START_FRAME
bpy.context.scene.frame_end = END_FRAME

# 把动作赋给骨架
obj = bpy.context.active_object
if obj and obj.type == 'ARMATURE':
    if obj.animation_data is None:
        obj.animation_data_create()
    obj.animation_data.action = action

print("动作", ACTION_NAME, "已创建，帧范围", START_FRAME, "-", END_FRAME)
print("现在可以开始摆姿势打关键帧了")
