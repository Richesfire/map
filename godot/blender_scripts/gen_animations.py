"""
程序化动画生成脚本 - IASv1.0
在 Blender 中运行此脚本，自动生成所有动画。

使用方法：
1. 打开含骨架的场景，选中 Armature（骨架）
2. 打开 Python 控制台 (Shift+F4)
3. 运行: exec(open(r"D:/NSS-huangrongji/Godot/IASv1.0/blender_scripts/gen_animations.py").read())
"""

import bpy
import math
from mathutils import Euler, Vector, Quaternion

# ============================================================
# 配置
# ============================================================
FPS = 24                     # 动画帧率
WALK_CYCLE = 30              # 走路循环帧数（1.25秒）
RUN_CYCLE = 18               # 奔跑循环帧数（0.75秒）
ATTACK_RAISE_FRAMES = 10     # 举剑帧数
ATTACK_SWING_FRAMES = 8      # 挥剑帧数

# 手臂骨骼
ARM_LEFT = ["LeftShoulder", "LeftUpperArm", "LeftLowerArm", "LeftHand"]
ARM_RIGHT = ["RightShoulder", "RightUpperArm", "RightLowerArm", "RightHand"]

# 腿骨骼
LEG_LEFT = ["LeftUpperLeg", "LeftLowerLeg", "LeftFoot"]
LEG_RIGHT = ["RightUpperLeg", "RightLowerLeg", "RightFoot"]

# 脊柱骨骼
SPINE = ["Hips", "Spine", "Chest", "UpperChest"]

DEG = math.pi / 180.0

# ============================================================
# 工具函数
# ============================================================
def ensure_pose_mode():
    """确保处于姿态模式"""
    obj = bpy.context.active_object
    if obj is None or obj.type != 'ARMATURE':
        raise Exception("请先选中 Armature 骨架")
    bpy.context.view_layer.objects.active = obj
    if bpy.context.mode != 'POSE':
        bpy.ops.object.mode_set(mode='POSE')
    return obj

def create_action(name, start, end, loop=True):
    """创建或清空动作"""
    if name in bpy.data.actions:
        bpy.data.actions.remove(bpy.data.actions[name])
    action = bpy.data.actions.new(name)
    action.use_fake_user = True
    action.frame_range = (start, end)
    return action

def clear_pose(obj):
    """清除所有骨骼的旋转"""
    for bone in obj.pose.bones:
        bone.rotation_euler = Euler((0, 0, 0), 'XYZ')
        bone.rotation_quaternion = Quaternion()
        bone.location = Vector((0, 0, 0))

def set_bone_rot(obj, bone_name, x=0, y=0, z=0, space='LOCAL'):
    """设置骨骼旋转（欧拉角，度）"""
    bone = obj.pose.bones[bone_name]
    if space == 'LOCAL':
        bone.rotation_mode = 'XYZ'
        bone.rotation_euler = Euler((x * DEG, y * DEG, z * DEG), 'XYZ')
    else:
        # 世界空间近似：先清空再设局部
        bone.rotation_mode = 'XYZ'
        bone.rotation_euler = Euler((x * DEG, y * DEG, z * DEG), 'XYZ')

def keyframe_bones(obj, bones, frame, props=('rotation_euler',)):
    """为骨骼在指定帧打关键帧"""
    for b in bones:
        for p in props:
            obj.keyframe_insert(data_path='pose.bones["%s"].%s' % (b, p), frame=frame)

def keyframe_all(obj, frame):
    """所有骨骼打关键帧"""
    for bone in obj.pose.bones:
        obj.keyframe_insert(data_path='pose.bones["%s"].rotation_euler' % bone.name, frame=frame)

# ============================================================
# 走路动画（程序化）
# ============================================================
def gen_walk(obj, action_name, is_run=False, is_weapon=False, is_back=False):
    """程序化走路/奔跑/后退动画
    is_run: 奔跑模式（更大幅摆动，更短周期）
    is_weapon: 持武器（手臂弯曲握剑姿势）
    is_back: 后退（腿部方向相反）
    """
    cycle = RUN_CYCLE if is_run else WALK_CYCLE
    amplitude = 20 if is_run else 12      # 腿部摆动幅度（度）降低
    knee_bend_amp = 30 if is_run else 20  # 膝盖弯曲幅度
    hip_sway = 5 if is_run else 3         # 臀部横向摆动
    arm_swing = 18 if is_run else 10      # 手臂摆动幅度
    bounce = 0.06 if is_run else 0.03     # 身体上下起伏
    stride = 0.18 if is_run else 0.10     # 每步前进距离（米）

    total_frames = cycle + 1
    action = create_action(action_name, 1, total_frames)
    obj.animation_data.action = action

    clear_pose(obj)

    for frame in range(1, total_frames + 1):
        t = (frame - 1) / cycle
        phase = t * 2 * math.pi  # 0 ~ 2PI 一个循环
        p = t                     # 0~1 归一化

        direction = -1 if is_back else 1

        # ---- 步态阶段函数（0~1 一个循环）----
        # 相位 0 左腿着地，0.5 右腿着地
        def gait(ph):
            """步态：返回该腿的相对摆动角度（度）
            脚相对身体的位置：支撑相时脚向后移（身体前进），摆动相时脚前伸"""
            if ph < 0.5:
                # 支撑相：脚从前方(-15) 向后挪到 (+20)，相当于身体越过脚
                return -15 + (35 * ph / 0.5)
            else:
                # 摆动相：脚从后(+20)快速前摆到前方(-15)
                q = (ph - 0.5) / 0.5
                return 20 - 35 * q

        # 左腿相位 = p，右腿相位 = (p + 0.5) % 1
        left_ph = p
        right_ph = (p + 0.5) % 1.0

        left_swing = gait(left_ph) * amplitude / 20.0 * direction
        right_swing = gait(right_ph) * amplitude / 20.0 * direction

        # ---- 膝盖弯曲（摆动相时弯曲膝盖抬腿）----
        def knee_bend_fn(ph):
            if 0.5 <= ph < 1.0:
                q = (ph - 0.5) / 0.5
                return math.sin(q * math.pi) * knee_bend_amp
            return 0

        left_knee = knee_bend_fn(left_ph)
        right_knee = knee_bend_fn(right_ph)

        # ---- 身体前进位移 ----
        # Hips 沿 -Y 方向前进（模型面朝 -Y）
        # 一个循环前进 stride，然后循环回绕
        forward_dist = -p * stride * direction

        # ---- 设置腿部骨骼 ----
        set_bone_rot(obj, "LeftUpperLeg", x=left_swing, z=hip_sway * math.sin(phase))
        set_bone_rot(obj, "RightUpperLeg", x=right_swing, z=-hip_sway * math.sin(phase))
        set_bone_rot(obj, "LeftLowerLeg", x=left_knee)
        set_bone_rot(obj, "RightLowerLeg", x=right_knee)
        # 脚跟/脚尖（轻微）
        set_bone_rot(obj, "LeftFoot", x=left_swing * 0.15)
        set_bone_rot(obj, "RightFoot", x=right_swing * 0.15)

        # ---- 手臂摆动 ----
        if is_weapon:
            # 持武器：双手向前握剑姿势，微微摆动
            set_bone_rot(obj, "LeftShoulder", x=-60, y=5, z=10)
            set_bone_rot(obj, "RightShoulder", x=-60, y=-5, z=-10)
            set_bone_rot(obj, "LeftUpperArm", x=-30, z=5)
            set_bone_rot(obj, "RightUpperArm", x=-30, z=-5)
            set_bone_rot(obj, "LeftLowerArm", x=-80)
            set_bone_rot(obj, "RightLowerArm", x=-80)
            set_bone_rot(obj, "LeftHand", z=15)
            set_bone_rot(obj, "RightHand", z=-15)
        else:
            # 空手：自然摆动
            left_arm = math.sin(phase) * arm_swing * direction
            right_arm = math.sin(phase + math.pi) * arm_swing * direction
            set_bone_rot(obj, "LeftShoulder", x=left_arm)
            set_bone_rot(obj, "RightShoulder", x=right_arm)
            set_bone_rot(obj, "LeftLowerArm", x=5)
            set_bone_rot(obj, "RightLowerArm", x=5)

        # ---- 脊柱/身体起伏 ----
        set_bone_rot(obj, "Hips", y=hip_sway * math.sin(phase))
        set_bone_rot(obj, "Spine", y=-hip_sway * 0.5 * math.sin(phase))
        set_bone_rot(obj, "Chest", y=-hip_sway * 0.5 * math.sin(phase))
        # 身体位移：沿 -Y 前进 + 上下起伏
        obj.pose.bones["Hips"].location = Vector((0, forward_dist, bounce * math.sin(phase * 2)))

        keyframe_all(obj, frame)

    print("已生成:", action_name)

# ============================================================
# 攻击动画（举剑 + 挥剑）
# ============================================================
def gen_attack(obj, dir_name, weapon_hand="both"):
    """四向攻击动画
    dir_name: left / right / up / thrust
    每个攻击分两段：_raise（举剑蓄力） + _swing（挥剑）
    """
    raise_frames = ATTACK_RAISE_FRAMES
    swing_frames = ATTACK_SWING_FRAMES

    # ---- 举剑（蓄力）----
    raise_name = "attack_%s_raise" % dir_name
    action = create_action(raise_name, 1, raise_frames)
    obj.animation_data.action = action
    clear_pose(obj)

    for frame in range(1, raise_frames + 1):
        t = (frame - 1) / (raise_frames - 1)  # 0~1 插值

        # 默认站姿（下半身）
        set_bone_rot(obj, "LeftUpperLeg", x=5)
        set_bone_rot(obj, "RightUpperLeg", x=-5)
        set_bone_rot(obj, "LeftFoot", x=5)
        set_bone_rot(obj, "RightFoot", x=-5)
        set_bone_rot(obj, "Hips", y=0)
        set_bone_rot(obj, "Spine", y=0)

        # 上半身蓄力姿势（插值）
        if dir_name == "left":
            # 左砍：身体向右后拉，双手持剑举到右侧
            set_bone_rot(obj, "Chest", y=-30 * t, z=-10 * t)
            set_bone_rot(obj, "UpperChest", y=-20 * t)
            set_bone_rot(obj, "Neck", y=-10 * t)
            set_bone_rot(obj, "Head", y=-15 * t)
            set_bone_rot(obj, "LeftShoulder", x=-100 * t, z=20 * t)
            set_bone_rot(obj, "RightShoulder", x=-100 * t, z=40 * t)
            set_bone_rot(obj, "LeftUpperArm", z=30 * t)
            set_bone_rot(obj, "RightUpperArm", z=60 * t)
            set_bone_rot(obj, "LeftLowerArm", x=-100 * t)
            set_bone_rot(obj, "RightLowerArm", x=-100 * t)
        elif dir_name == "right":
            # 右砍：身体向左后拉，双手持剑举到左侧
            set_bone_rot(obj, "Chest", y=30 * t, z=10 * t)
            set_bone_rot(obj, "UpperChest", y=20 * t)
            set_bone_rot(obj, "Neck", y=10 * t)
            set_bone_rot(obj, "Head", y=15 * t)
            set_bone_rot(obj, "LeftShoulder", x=-100 * t, z=-40 * t)
            set_bone_rot(obj, "RightShoulder", x=-100 * t, z=-20 * t)
            set_bone_rot(obj, "LeftUpperArm", z=-60 * t)
            set_bone_rot(obj, "RightUpperArm", z=-30 * t)
            set_bone_rot(obj, "LeftLowerArm", x=-100 * t)
            set_bone_rot(obj, "RightLowerArm", x=-100 * t)
        elif dir_name == "up":
            # 上劈：双手举过头顶
            set_bone_rot(obj, "Chest", y=10 * t, z=0)
            set_bone_rot(obj, "UpperChest", y=-30 * t)
            set_bone_rot(obj, "Neck", y=-20 * t)
            set_bone_rot(obj, "Head", y=-10 * t)
            set_bone_rot(obj, "LeftShoulder", x=-170 * t, z=15 * t)
            set_bone_rot(obj, "RightShoulder", x=-170 * t, z=-15 * t)
            set_bone_rot(obj, "LeftUpperArm", z=20 * t)
            set_bone_rot(obj, "RightUpperArm", z=-20 * t)
            set_bone_rot(obj, "LeftLowerArm", x=-60 * t)
            set_bone_rot(obj, "RightLowerArm", x=-60 * t)
        elif dir_name == "thrust":
            # 突刺：双手前伸持剑
            set_bone_rot(obj, "Chest", y=-5 * t)
            set_bone_rot(obj, "UpperChest", y=-10 * t)
            set_bone_rot(obj, "Neck", y=-5 * t)
            set_bone_rot(obj, "Head", y=0)
            set_bone_rot(obj, "LeftShoulder", x=-90 * t, z=5 * t)
            set_bone_rot(obj, "RightShoulder", x=-90 * t, z=-5 * t)
            set_bone_rot(obj, "LeftUpperArm", x=-10 * t)
            set_bone_rot(obj, "RightUpperArm", x=-10 * t)
            set_bone_rot(obj, "LeftLowerArm", x=-60 * t)
            set_bone_rot(obj, "RightLowerArm", x=-60 * t)

        keyframe_all(obj, frame)

    print("已生成:", raise_name)

    # ---- 挥剑 ----
    swing_name = "attack_%s_swing" % dir_name
    action = create_action(swing_name, 1, swing_frames)
    obj.animation_data.action = action
    clear_pose(obj)

    for frame in range(1, swing_frames + 1):
        t = (frame - 1) / (swing_frames - 1)  # 0~1 插值

        # 下半身保持站姿
        set_bone_rot(obj, "LeftUpperLeg", x=5)
        set_bone_rot(obj, "RightUpperLeg", x=-5)
        set_bone_rot(obj, "LeftFoot", x=5)
        set_bone_rot(obj, "RightFoot", x=-5)

        if dir_name == "left":
            # 左砍：从右往左挥
            swing = -90 * t
            set_bone_rot(obj, "Chest", y=-30 + 60 * t, z=-10 + 20 * t)
            set_bone_rot(obj, "UpperChest", y=-20 + 40 * t)
            set_bone_rot(obj, "Neck", y=-10 + 20 * t)
            set_bone_rot(obj, "Head", y=-15 + 30 * t)
            set_bone_rot(obj, "LeftShoulder", x=-100 + 80 * t, z=20 - 40 * t)
            set_bone_rot(obj, "RightShoulder", x=-100 + 80 * t, z=40 - 80 * t)
            set_bone_rot(obj, "LeftLowerArm", x=-100 + 60 * t)
            set_bone_rot(obj, "RightLowerArm", x=-100 + 60 * t)
        elif dir_name == "right":
            swing = 90 * t
            set_bone_rot(obj, "Chest", y=30 - 60 * t, z=10 - 20 * t)
            set_bone_rot(obj, "UpperChest", y=20 - 40 * t)
            set_bone_rot(obj, "Neck", y=10 - 20 * t)
            set_bone_rot(obj, "Head", y=15 - 30 * t)
            set_bone_rot(obj, "LeftShoulder", x=-100 + 80 * t, z=-40 + 80 * t)
            set_bone_rot(obj, "RightShoulder", x=-100 + 80 * t, z=-20 + 40 * t)
            set_bone_rot(obj, "LeftLowerArm", x=-100 + 60 * t)
            set_bone_rot(obj, "RightLowerArm", x=-100 + 60 * t)
        elif dir_name == "up":
            # 上劈：从头顶往下劈
            set_bone_rot(obj, "Chest", y=10 - 20 * t)
            set_bone_rot(obj, "UpperChest", y=-30 + 40 * t)
            set_bone_rot(obj, "Neck", y=-20 + 30 * t)
            set_bone_rot(obj, "Head", y=-10 + 15 * t)
            set_bone_rot(obj, "LeftShoulder", x=-170 + 140 * t, z=15 - 30 * t)
            set_bone_rot(obj, "RightShoulder", x=-170 + 140 * t, z=-15 + 30 * t)
            set_bone_rot(obj, "LeftLowerArm", x=-60 + 30 * t)
            set_bone_rot(obj, "RightLowerArm", x=-60 + 30 * t)
        elif dir_name == "thrust":
            # 突刺：前刺
            set_bone_rot(obj, "Chest", y=-5 + 10 * t)
            set_bone_rot(obj, "UpperChest", y=-10 + 20 * t)
            set_bone_rot(obj, "Neck", y=-5 + 10 * t)
            set_bone_rot(obj, "LeftShoulder", x=-90, z=5 - 10 * t)
            set_bone_rot(obj, "RightShoulder", x=-90, z=-5 + 10 * t)
            set_bone_rot(obj, "LeftLowerArm", x=-60)
            set_bone_rot(obj, "RightLowerArm", x=-60)
            # 突刺时身体前移（Hips 位移）
            obj.pose.bones["Hips"].location = Vector((0, 0.2 * t, 0))

        keyframe_all(obj, frame)

    print("已生成:", swing_name)

# ============================================================
# 主流程
# ============================================================
def main():
    obj = ensure_pose_mode()

    # 生成移动动画（空手 + 持武器）
    gen_walk(obj, "walk_forward_empty", is_weapon=False)
    gen_walk(obj, "walk_forward_weapon", is_weapon=True)
    gen_walk(obj, "run_forward_empty", is_run=True, is_weapon=False)
    gen_walk(obj, "run_forward_weapon", is_run=True, is_weapon=True)
    gen_walk(obj, "walk_back_empty", is_weapon=False, is_back=True)
    gen_walk(obj, "walk_back_weapon", is_weapon=True, is_back=True)

    # 生成四向攻击（举剑 + 挥剑）
    for d in ["left", "right", "up", "thrust"]:
        gen_attack(obj, d)

    # 回到默认动作
    obj.animation_data.action = None
    print("=" * 50)
    print("所有动画生成完毕！")
    print("请在导出前检查各动作，导出时勾选 Animations")

if __name__ == "__main__":
    main()
