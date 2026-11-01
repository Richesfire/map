"""
创建"攻击收招(recover)"动画槽位 —— 持双手剑
用法（后台自动保存）:
  blender.exe --background "人物模型.blend" --python create_recover_actions.py
或在 Blender GUI 里选中 Armature 后:
  exec(open(r"D:/NSS-huangrongji/Godot/IASv1.0/blender_scripts/create_recover_actions.py").read())

只创建动作槽位（名字 + 帧范围），不摆姿势，之后手动 K 帧。
已存在的动作会跳过，不覆盖。
"""

import bpy

FPS = 30
RECOVER_FRAMES = 12   # 0.4 秒

NAMES = [
    # 攻击收招
    "s_attack_left_recover",
    "s_attack_right_recover",
    "s_attack_up_recover",
    "s_attack_thrust_recover",
    # 格挡收招
    "s_block_up_recover",
    "s_block_down_recover",
    "s_block_left_recover",
    "s_block_right_recover",
]


def get_armature():
    obj = bpy.context.active_object
    if obj is not None and obj.type == 'ARMATURE':
        return obj
    for o in bpy.data.objects:
        if o.type == 'ARMATURE':
            return o
    return None


def main():
    arm = get_armature()
    if arm is None:
        print("错误: 场景里没有 Armature 骨架")
        return

    if arm.animation_data is None:
        arm.animation_data_create()

    created, skipped = [], []
    for name in NAMES:
        if name in bpy.data.actions:
            skipped.append(name)
            continue
        action = bpy.data.actions.new(name)
        action.use_fake_user = True
        action.frame_range = (1, RECOVER_FRAMES)
        created.append(name)

    print("=" * 50)
    print("骨架:", arm.name)
    print("新建动作 (%d):" % len(created))
    for n in created:
        print("  +", n)
    print("已存在跳过 (%d):" % len(skipped))
    for n in skipped:
        print("  -", n)
    print()
    print("当前所有动作:")
    for a in sorted(bpy.data.actions, key=lambda x: x.name):
        print("  %s  [%d-%d]" % (a.name, int(a.frame_range[0]), int(a.frame_range[1])))


main()

if bpy.app.background:
    bpy.ops.wm.save_mainfile()
    print("已保存 .blend")
