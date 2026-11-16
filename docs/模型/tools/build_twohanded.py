# -*- coding: utf-8 -*-
"""
双手武器建模脚本 — IAS (类骑砍 Godot 项目) 资产流水线

坐标系约定 (Blender, 米):
  - 角色朝向 -Y (与 IAS 的 "正视图" rotZ=0 一致)
  - 世界 Z 向上
  - 武器建模时: 沿 +Z 轴生长, 剑尖朝 +Z
  - 枢轴点定在握柄中心 (Godot 里 WeaponSocket 的挂载基准)

布局 (俯视图 / Top View, X 右 Y 上):
  - 角色参考: 第二三象限中间 = X<0, Y≈0
  - 武器:     第一象限     = X>0, Y>0
"""

import bpy
import bmesh
import math
from mathutils import Vector, Matrix

# ============================================================
# 参数区 — 改这里就能批量出不同形制
# ============================================================

# 写实双手剑规格 (米)
BLADE_LEN      = 1.03    # 剑身长
BLADE_W        = 0.062   # 剑身根宽
BLADE_T        = 0.0075  # 剑身厚
BLADE_TIP_T    = 0.004   # 剑尖厚
GUARD_LEN      = 0.285   # 护手全长
GUARD_H        = 0.052   # 护手高 (加厚, 更写实)
GUARD_D        = 0.036   # 护手厚 (加厚)
GRIP_LEN       = 0.265   # 握柄长
GRIP_R         = 0.0205  # 握柄半径 (加粗, 便于握持)
POMMEL_R       = 0.033   # 首部半径
RICASSO_LEN    = 0.085   # 剑根未开锋段 (ricasso)

POMMEL_H = POMMEL_R * 1.85   # 首部高度

TOTAL_LEN = BLADE_LEN + GUARD_H + GRIP_LEN + POMMEL_H


# ============================================================
# 工具
# ============================================================

def wipe_scene():
    """清空场景"""
    bpy.ops.wm.read_factory_settings(use_empty=True)


def new_mesh_obj(name, verts, faces):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.validate()
    me.update()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


# ============================================================
# 剑身 Blade — 双刃, 带血槽, 收尖
# ============================================================

def build_blade(name="Blade"):
    """
    剑身: 沿 +Z 从 0 长到 BLADE_LEN
    剖面为扁平六边形 (中间脊线厚, 两侧收薄成刃)
    """
    verts = []
    faces = []
    rings = []          # 每圈 6 个点的索引

    # 沿剑身的截面定义: (z, 半宽, 半厚)
    w0, t0 = BLADE_W / 2.0, BLADE_T / 2.0
    profile = [
        (0.0,                       w0,                     t0),        # 剑根
        (RICASSO_LEN,               w0,                     t0),        # ricasso 结束
        (BLADE_LEN * 0.45,          w0 * 0.98,              t0 * 0.95),  # 中段
        (BLADE_LEN * 0.78,          w0 * 0.90,              t0 * 0.88),
        (BLADE_LEN * 0.93,          w0 * 0.62,              t0 * 0.72),  # 收尖开始
        (BLADE_LEN * 0.985,         w0 * 0.30,              t0 * 0.55),
    ]

    # 八边形剖面 (带血槽): 刃口 -> 上斜面 -> 血槽内凹 -> 脊线 ...
    def ring_pts(z, hw, ht, taper=0.42, fuller=0.0):
        """
        fuller>0 时, 中央做出下凹血槽
        剖面点序 (逆时针):
          左刃 -> 左上斜 -> 左上槽沿 -> 中央脊(上) -> 右上槽沿 -> 右上斜 -> 右刃
          -> 右下斜 -> 右下槽沿 -> 中央脊(下) -> 左下槽沿 -> 左下斜
        """
        ridge = hw * taper
        slot = hw * 0.16                # 血槽宽度(半)
        if fuller > 0:
            slot_h = ht * (1.0 - fuller)   # 槽底深度
        else:
            slot_h = ht

        return [
            (-hw,    0.0,    z),     # 0 左刃口
            (-ridge, ht,     z),     # 1 左上斜
            (-slot,  slot_h, z),     # 2 左上槽沿
            (0.0,    slot_h, z),     # 3 中央(上)
            (slot,   slot_h, z),     # 4 右上槽沿
            (ridge,  ht,     z),     # 5 右上斜
            (hw,     0.0,    z),     # 6 右刃口
            (ridge,  -ht,    z),     # 7 右下斜
            (slot,   -slot_h, z),    # 8 右下槽沿
            (0.0,    -slot_h, z),    # 9 中央(下)
            (-slot,  -slot_h, z),    # 10 左下槽沿
            (-ridge, -ht,    z),     # 11 左下斜
        ]

    NP = 12   # 剖面点数

    # 沿剑身的截面定义: (z, 半宽, 半厚, 血槽深度比)
    w0, t0 = BLADE_W / 2.0, BLADE_T / 2.0
    profile = [
        (0.0,                       w0,         t0,        0.00),  # 剑根 (无槽)
        (RICASSO_LEN,               w0,         t0,        0.00),  # ricasso 结束
        (RICASSO_LEN + 0.02,        w0,         t0,        0.42),  # 血槽起始
        (BLADE_LEN * 0.45,          w0 * 0.98,  t0 * 0.95, 0.42),  # 中段
        (BLADE_LEN * 0.72,          w0 * 0.92,  t0 * 0.90, 0.34),  # 血槽收尾
        (BLADE_LEN * 0.80,          w0 * 0.88,  t0 * 0.86, 0.00),
        (BLADE_LEN * 0.93,          w0 * 0.60,  t0 * 0.70, 0.00),  # 收尖开始
        (BLADE_LEN * 0.985,         w0 * 0.28,  t0 * 0.52, 0.00),
    ]

    for (z, hw, ht, fu) in profile:
        base = len(verts)
        verts.extend(ring_pts(z, hw, ht, fuller=fu))
        rings.append(base)

    # 侧面
    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for k in range(NP):
            k2 = (k + 1) % NP
            faces.append([a + k, a + k2, b + k2, b + k])

    # 剑尖
    tip_z = BLADE_LEN
    tip_hw = BLADE_W * 0.045
    tip_ht = BLADE_TIP_T / 2.0
    tb = len(verts)
    verts.extend([
        (-tip_hw, 0.0, tip_z),
        (0.0,  tip_ht, tip_z),
        (tip_hw,  0.0, tip_z),
        (0.0, -tip_ht, tip_z),
    ])
    last = rings[-1]
    # 收尖: 从 12 边剖面收到 4 点刃尖
    # 上侧 (索引 1..5 收敛到 tb+1)
    for k in range(1, 5):
        faces.append([last + k, last + k + 1, tb + 1])
    faces.append([last + 0, last + 1, tb + 1, tb + 0])
    faces.append([last + 5, last + 6, tb + 2, tb + 1])
    # 下侧 (索引 7..11 收敛到 tb+3)
    for k in range(7, 11):
        faces.append([last + k + 1, last + k, tb + 3])
    faces.append([last + 6, last + 7, tb + 3, tb + 2])
    faces.append([last + 11, last + 0, tb + 0, tb + 3])
    # 剑尖封口
    faces.append([tb + 0, tb + 1, tb + 2, tb + 3])

    # 剑根封底
    r0 = rings[0]
    faces.append([r0 + (NP - 1 - k) for k in range(NP)])

    ob = new_mesh_obj(name, verts, faces)

    # 平滑 + 倒角
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob


# ============================================================
# 护手 Guard — 十字护手, 两端略收
# ============================================================

def build_guard(name="Guard", z_base=0.0):
    """
    十字护手: 位于剑身与握柄之间
    方截面 + 两端向剑身方向微微上翘, 中间有鼻梁
    """
    verts = []
    faces = []
    segs = 11
    hw = GUARD_LEN / 2.0
    hh = GUARD_H / 2.0
    hd = GUARD_D / 2.0

    rings = []
    for i in range(segs + 1):
        u = i / segs                 # 0..1 从左端到右端
        x = -hw + u * GUARD_LEN
        mid = abs(u - 0.5) * 2.0      # 0=中心 1=两端

        # 截面尺寸: 中心最厚, 两端收细但仍保持棱角
        taper = 1.0 - 0.62 * (mid ** 1.6)
        sz = 0.38 + 0.62 * taper
        # 两端向 +Z 微翘 (护手翼)
        lift = 0.16 * (mid ** 2.2) * GUARD_H
        # 中心鼻梁: 朝向剑身一侧凸起
        nose = (1.0 - mid) ** 3 * GUARD_H * 0.30

        zc = z_base + lift
        base = len(verts)
        # 方截面 (前后厚 hd*sz, 上下 hh*sz)
        verts.extend([
            (x, -hd * sz, zc - hh * sz),
            (x,  hd * sz, zc - hh * sz),
            (x,  hd * sz, zc + hh * sz + nose),
            (x, -hd * sz, zc + hh * sz + nose),
        ])
        rings.append(base)

    for i in range(segs):
        a, b = rings[i], rings[i + 1]
        for k in range(4):
            k2 = (k + 1) % 4
            faces.append([a + k, a + k2, b + k2, b + k])

    faces.append([rings[0] + 3, rings[0] + 2, rings[0] + 1, rings[0] + 0])
    e = rings[-1]
    faces.append([e + 0, e + 1, e + 2, e + 3])

    ob = new_mesh_obj(name, verts, faces)
    # 护手保持硬边 (不全面平滑), 只对侧面平滑
    for p in ob.data.polygons:
        p.use_smooth = False
    return ob


# ============================================================
# 握柄 Grip — 圆柱 + 轻微鼓形, 带缠绳凹槽
# ============================================================

def build_grip(name="Grip", z_base=0.0):
    verts = []
    faces = []
    segs = 12
    rings_n = 9
    rings = []

    for i in range(rings_n):
        u = i / (rings_n - 1)
        z = z_base + u * GRIP_LEN
        # 中间略鼓, 两端收
        bulge = 1.0 + 0.10 * math.sin(math.pi * u)
        # 缠绳纹: 轻微起伏
        groove = 1.0 - 0.045 * (0.5 + 0.5 * math.sin(u * math.pi * 7.0))
        r = GRIP_R * bulge * groove
        base = len(verts)
        for k in range(segs):
            a = 2.0 * math.pi * k / segs
            verts.append((math.cos(a) * r, math.sin(a) * r * 0.78, z))
        rings.append(base)

    for i in range(rings_n - 1):
        a, b = rings[i], rings[i + 1]
        for k in range(segs):
            k2 = (k + 1) % segs
            faces.append([a + k, a + k2, b + k2, b + k])

    # 封两端
    c0 = len(verts); verts.append((0, 0, z_base))
    for k in range(segs):
        k2 = (k + 1) % segs
        faces.append([rings[0] + k2, rings[0] + k, c0])
    c1 = len(verts); verts.append((0, 0, z_base + GRIP_LEN))
    for k in range(segs):
        k2 = (k + 1) % segs
        faces.append([rings[-1] + k, rings[-1] + k2, c1])

    ob = new_mesh_obj(name, verts, faces)
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob


# ============================================================
# 首部 Pommel — 配重球, 略扁
# ============================================================

def build_pommel(name="Pommel", z_base=0.0):
    """首部: 圆润配重球, 略扁, 底部收平"""
    verts = []
    faces = []
    segs = 14
    rings_n = 7
    rings = []
    H = POMMEL_R * 1.85          # 首部高度

    for i in range(rings_n):
        u = i / (rings_n - 1)
        z = z_base + u * H
        # 球体轮廓, 但底部略平 (u=0 处不是尖点)
        if u <= 0.5:
            r = POMMEL_R * math.sqrt(max(0.0, 1.0 - ((0.5 - u) / 0.62) ** 2))
        else:
            r = POMMEL_R * math.sqrt(max(0.0, 1.0 - ((u - 0.5) / 0.52) ** 2))
        r = max(r, POMMEL_R * 0.34)
        base = len(verts)
        for k in range(segs):
            a = 2.0 * math.pi * k / segs
            verts.append((math.cos(a) * r, math.sin(a) * r * 0.88, z))
        rings.append(base)

    for i in range(rings_n - 1):
        a, b = rings[i], rings[i + 1]
        for k in range(segs):
            k2 = (k + 1) % segs
            faces.append([a + k, a + k2, b + k2, b + k])

    c0 = len(verts); verts.append((0, 0, z_base))
    for k in range(segs):
        k2 = (k + 1) % segs
        faces.append([rings[0] + k2, rings[0] + k, c0])
    c1 = len(verts); verts.append((0, 0, z_base + H))
    for k in range(segs):
        k2 = (k + 1) % segs
        faces.append([rings[-1] + k, rings[-1] + k2, c1])

    ob = new_mesh_obj(name, verts, faces)
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob


# ============================================================
# 组装
# ============================================================

def build_twohanded_sword(base_name="双手剑", origin=Vector((0, 0, 0))):
    """
    自下而上组装: 首部 -> 握柄 -> 护手 -> 剑身
    枢轴: 握柄中心 (Godot WeaponSocket 挂载点)
    """
    parts = []

    z_pommel = 0.0
    pom = build_pommel(f"{base_name}_Pommel", z_pommel)
    parts.append(pom)

    z_grip = z_pommel + POMMEL_H
    grip = build_grip(f"{base_name}_Grip", z_grip)
    parts.append(grip)

    z_guard = z_grip + GRIP_LEN
    guard = build_guard(f"{base_name}_Guard", z_guard + GUARD_H * 0.5)
    parts.append(guard)

    z_blade = z_guard + GUARD_H
    blade = build_blade(f"{base_name}_Blade")
    blade.location.z = z_blade
    parts.append(blade)

    # 合并为一个物体
    bpy.ops.object.select_all(action='DESELECT')
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()
    sword = bpy.context.view_layer.objects.active
    sword.name = base_name

    # 应用变换
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    # 把枢轴移到握柄中心
    grip_center_z = z_grip + GRIP_LEN / 2.0
    me = sword.data
    for v in me.vertices:
        v.co.z -= grip_center_z

    # 移到指定位置 (武器区 第一象限)
    sword.location = origin

    # 平滑着色 + 自动平滑
    for p in me.polygons:
        p.use_smooth = True

    return sword


def main():
    wipe_scene()

    # ---- 1. 需要先把角色模型附加进来做参考 ----
    # (在 build_scene.py 里处理, 这里只建武器)

    sword = build_twohanded_sword("双手剑", Vector((0.55, 0.30, 1.35)))
    bpy.context.view_layer.objects.active = sword

    print(f"[OK] 双手剑 总长={TOTAL_LEN:.3f}m verts={len(sword.data.vertices)} polys={len(sword.data.polygons)}")


if __name__ == "__main__":
    main()
