"""
动画槽位创建脚本 - 一次性建好所有动画动作
运行前：选中 Armature 骨架
运行: exec(open(r"D:/NSS-huangrongji/Godot/IASv1.0/blender_scripts/create_all_actions.py").read())

只创建槽位（动作名 + 帧范围），不摆姿势。你之后逐个动作手动 K 帧。
已存在的动作（idle、walk_forward_empty）会跳过，不会覆盖你已 K 的内容。
"""

import bpy

FPS = 30

# 动画清单: (动作名, 帧数, 是否循环)
# 30fps 下：走路/后退 1秒=30帧，奔跑 0.67秒=20帧
# 攻击：举剑 0.4秒=12帧，挥剑 0.33秒=10帧
# 其他：格挡循环，受击 0.5秒=15帧，死亡 1秒=30帧
ANIMATIONS = [
    # 移动 - 空手
    ("walk_forward_empty", 30, True),
    ("run_forward_empty", 20, True),
    ("walk_back_empty", 30, True),
    # 移动 - 持武器
    ("walk_forward_weapon", 30, True),
    ("run_forward_weapon", 20, True),
    ("walk_back_weapon", 30, True),
    # 攻击 - 左砍
    ("attack_left_raise", 12, False),
    ("attack_left_swing", 10, False),
    # 攻击 - 右砍
    ("attack_right_raise", 12, False),
    ("attack_right_swing", 10, False),
    # 攻击 - 上劈
    ("attack_up_raise", 12, False),
    ("attack_up_swing", 10, False),
    # 攻击 - 突刺
    ("attack_thrust_raise", 12, False),
    ("attack_thrust_swing", 10, False),
    # 格挡 - 四向（持武器）
    ("block_left", 30, True),
    ("block_right", 30, True),
    ("block_up", 30, True),
    ("block_down", 30, True),
    # 受击 - 空手/持武器
    ("hit_empty", 15, False),
    ("hit_weapon", 15, False),
    # 死亡
    ("death", 30, False),
]


def create_action(name, frames):
    """创建或返回已有动作"""
    if name in bpy.data.actions:
        return bpy.data.actions[name], False

    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    action.frame_range = (1, frames)
    return action, True


def main():
    obj = bpy.context.active_object
    if obj is None or obj.type != 'ARMATURE':
        print("错误: 请先选中 Armature 骨架")
        return

    if obj.animation_data is None:
        obj.animation_data_create()

    created = []
    skipped = []

    for name, frames, loop in ANIMATIONS:
        action, is_new = create_action(name, frames)
        if is_new:
            created.append(name)
        else:
            skipped.append(name)

    print("=" * 50)
    print("新建动作 (%d 个):" % len(created))
    for n in created:
        print("  +", n)
    print()
    print("已存在跳过 (%d 个):" % len(skipped))
    for n in skipped:
        print("  -", n)

    # 列出所有动作
    print()
    print("当前所有动作:")
    for a in bpy.data.actions:
        loop_info = ""
        print("  %s  [%d帧]" % (a.name, int(a.frame_range[1])))

    print()
    print("提示: 循环动画(走路/奔跑/后退/格挡)记得在 Godot 导入设置里设循环模式")
    print("帧率:", FPS, "fps")


if __name__ == "__main__":
    main()
