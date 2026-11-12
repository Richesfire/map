# -*- coding: utf-8 -*-
"""
双手武器 5 件套 — 参数化建模

5 把武器共享同一套「首部->握柄->护手->刃部」装配流程,
仅刃部形态不同:
  1. 双手剑       — 直刃双刃, 带血槽
  2. 阔剑/大剑     — 更宽更长, 六边剖面
  3. 双手斧       — 单侧斧刃 + 背部尖钩
  4. 长柄斧/戟     — 斧刃 + 顶部矛尖
  5. 长枪/矛      — 细长菱形矛头

枢轴: 全部定在握柄中心 (Godot WeaponSocket 挂载基准)
"""

import bpy
import math
from mathutils import Vector

# ============================================================
# 全局规格
# ============================================================
GRIP_LEN   = 0.265
GRIP_R     = 0.0205
GUARD_H    = 0.052
GUARD_D    = 0.036
POMMEL_R   = 0.033
POMMEL_H   = POMMEL_R * 1.85


# ============================================================
# 基础件
# ============================================================

def new_mesh_obj(name, verts, faces):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.validate()
    me.update()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    return ob


def build_grip(name="Grip", z_base=0.0, length=None, radius=None):
    """握柄: 圆柱 + 缠绳纹"""
    L = length if length is not None else GRIP_LEN
    R = radius if radius is not None else GRIP_R
    verts, faces, rings = [], [], []
    segs, rings_n = 12, 9

    for i in range(rings_n):
        u = i / (rings_n - 1)
        z = z_base + u * L
        bulge = 1.0 + 0.10 * math.sin(math.pi * u)
        groove = 1.0 - 0.045 * (0.5 + 0.5 * math.sin(u * math.pi * 7.0))
        r = R * bulge * groove
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

    c0 = len(verts); verts.append((0, 0, z_base))
    for k in range(segs):
        k2 = (k + 1) % segs
        faces.append([rings[0] + k2, rings[0] + k, c0])
    c1 = len(verts); verts.append((0, 0, z_base + L))
    for k in range(segs):
        k2 = (k + 1) % segs
        faces.append([rings[-1] + k, rings[-1] + k2, c1])

    ob = new_mesh_obj(name, verts, faces)
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob


def build_pommel(name="Pommel", z_base=0.0, radius=None):
    """首部: 圆润配重球"""
    R = radius if radius is not None else POMMEL_R
    H = R * 1.85
    verts, faces, rings = [], [], []
    segs, rings_n = 14, 7

    for i in range(rings_n):
        u = i / (rings_n - 1)
        z = z_base + u * H
        if u <= 0.5:
            r = R * math.sqrt(max(0.0, 1.0 - ((0.5 - u) / 0.62) ** 2))
        else:
            r = R * math.sqrt(max(0.0, 1.0 - ((u - 0.5) / 0.52) ** 2))
        r = max(r, R * 0.34)
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


def build_guard(name="Guard", z_base=0.0, length=0.285, height=None, depth=None,
                wings=True, nose=True):
    """十字护手: 方截面, 两端上翘"""
    hh_ = (height if height is not None else GUARD_H) / 2.0
    hd_ = (depth if depth is not None else GUARD_D) / 2.0
    verts, faces, rings = [], [], []
    segs = 11
    hw = length / 2.0

    for i in range(segs + 1):
        u = i / segs
        x = -hw + u * length
        mid = abs(u - 0.5) * 2.0
        taper = 1.0 - 0.62 * (mid ** 1.6)
        sz = 0.38 + 0.62 * taper
        lift = (0.16 * (mid ** 2.2) * hh_ * 2.0) if wings else 0.0
        ns = ((1.0 - mid) ** 3 * hh_ * 0.60) if nose else 0.0

        zc = z_base + lift
        base = len(verts)
        verts.extend([
            (x, -hd_ * sz, zc - hh_ * sz),
            (x,  hd_ * sz, zc - hh_ * sz),
            (x,  hd_ * sz, zc + hh_ * sz + ns),
            (x, -hd_ * sz, zc + hh_ * sz + ns),
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
    for p in ob.data.polygons:
        p.use_smooth = False
    return ob


# ============================================================
# 刃部类型
# ============================================================

def blade_straight(name, length, width, thick, fuller=True, taper=0.42):
    """
    直双刃剑身 (八边剖面带血槽 / 六边剖面)
    沿 +Z 从 0 长到 length
    """
    verts, faces, rings = [], [], []
    w0, t0 = width / 2.0, thick / 2.0
    NP = 12 if fuller else 6

    def ring_pts(z, hw, ht, fu):
        ridge = hw * taper
        if fuller:
            slot = hw * 0.16
            sh = ht * (1.0 - fu) if fu > 0 else ht
            return [
                (-hw, 0.0, z), (-ridge, ht, z), (-slot, sh, z), (0.0, sh, z),
                (slot, sh, z), (ridge, ht, z), (hw, 0.0, z),
                (ridge, -ht, z), (slot, -sh, z), (0.0, -sh, z),
                (-slot, -sh, z), (-ridge, -ht, z),
            ]
        return [
            (-hw, 0.0, z), (-ridge, ht, z), (ridge, ht, z),
            (hw, 0.0, z), (ridge, -ht, z), (-ridge, -ht, z),
        ]

    ric = length * 0.082
    profile = [
        (0.0,                w0,        t0,        0.0),
        (ric,                w0,        t0,        0.0),
        (ric + length*0.02,  w0,        t0,        0.42 if fuller else 0.0),
        (length * 0.45,      w0 * 0.98, t0 * 0.95, 0.42 if fuller else 0.0),
        (length * 0.72,      w0 * 0.92, t0 * 0.90, 0.34 if fuller else 0.0),
        (length * 0.80,      w0 * 0.88, t0 * 0.86, 0.0),
        (length * 0.93,      w0 * 0.60, t0 * 0.70, 0.0),
        (length * 0.985,     w0 * 0.28, t0 * 0.52, 0.0),
    ]

    for (z, hw, ht, fu) in profile:
        base = len(verts)
        verts.extend(ring_pts(z, hw, ht, fu))
        rings.append(base)

    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for k in range(NP):
            k2 = (k + 1) % NP
            faces.append([a + k, a + k2, b + k2, b + k])

    # 剑尖
    tz = length
    thw = width * 0.045
    tht = thick * 0.55 / 2.0
    tb = len(verts)
    verts.extend([(-thw, 0.0, tz), (0.0, tht, tz), (thw, 0.0, tz), (0.0, -tht, tz)])
    last = rings[-1]

    if fuller:
        for k in range(1, 5):
            faces.append([last + k, last + k + 1, tb + 1])
        faces.append([last + 0, last + 1, tb + 1, tb + 0])
        faces.append([last + 5, last + 6, tb + 2, tb + 1])
        for k in range(7, 11):
            faces.append([last + k + 1, last + k, tb + 3])
        faces.append([last + 6, last + 7, tb + 3, tb + 2])
        faces.append([last + 11, last + 0, tb + 0, tb + 3])
    else:
        faces.append([last + 0, last + 1, tb + 0])
        faces.append([last + 1, last + 2, tb + 1])
        faces.append([last + 2, last + 3, tb + 2])
        faces.append([last + 3, last + 4, tb + 2])
        faces.append([last + 4, last + 5, tb + 3])
        faces.append([last + 5, last + 0, tb + 3])
        faces.append([last + 0, tb + 0, tb + 2, last + 2])
        faces.append([last + 3, tb + 2, tb + 0, last + 0])
        faces.append([last + 5, last + 4, tb + 3, tb + 0])

    faces.append([tb + 0, tb + 1, tb + 2, tb + 3])
    r0 = rings[0]
    faces.append([r0 + (NP - 1 - k) for k in range(NP)])

    ob = new_mesh_obj(name, verts, faces)
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob


def blade_axe(name, blade_h, blade_w, spike_back=True, thick=0.022,
              x_in=0.004):
    """
    斧刃: 单侧弧形刃 + 可选背部尖钩
    刃口朝向 +X, 内缘接柄 (x_in 略小于柄半径以便咬合)
    """
    verts, faces, rings = [], [], []
    z0 = 0.0
    segs = 7
    depth = thick / 2.0
    hw0 = blade_w

    def edge_profile(u):
        """u: 0(下)..1(上), 返回 (x_out, z)"""
        z = z0 + u * blade_h
        bulge = math.sin(math.pi * (0.14 + 0.72 * u))
        x_out = hw0 * (0.40 + 0.60 * bulge)
        return x_out, z

    rings = []
    for i in range(segs + 1):
        u = i / segs
        x_out, z = edge_profile(u)
        base = len(verts)
        verts.extend([
            (x_in,    -depth,        z),   # 内缘下
            (x_out,   -depth * 0.16, z),   # 刃口下 (薄)
            (x_out,    depth * 0.16, z),   # 刃口上 (薄)
            (x_in,     depth,        z),   # 内缘上
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

    # 背部尖钩 (朝向 -X)
    if spike_back:
        zc = z0 + blade_h * 0.62
        sp = len(verts)
        verts.extend([
            (x_in * 0.6, -depth * 0.85, zc - blade_h * 0.16),
            (-0.070,     -depth * 0.30, zc + blade_h * 0.03),
            (-0.070,      depth * 0.30, zc + blade_h * 0.03),
            (x_in * 0.6,  depth * 0.85, zc - blade_h * 0.16),
        ])
        faces.append([sp + 0, sp + 1, sp + 2, sp + 3])
        faces.append([sp + 3, sp + 2, sp + 1, sp + 0])

    ob = new_mesh_obj(name, verts, faces)
    for p in ob.data.polygons:
        p.use_smooth = False
    return ob


def blade_spear(name, length, width, thick=0.014):
    """矛头: 细长菱形, 带套管"""
    verts, faces, rings = [], [], []
    w0, t0 = width / 2.0, thick / 2.0
    NP = 8

    def ring_pts(z, hw, ht, sock=0.0):
        ridge = hw * 0.5
        r = max(hw * (1.0 + sock), 0.001)
        return [
            (-r, 0.0, z), (-ridge, ht, z), (0.0, ht * 1.05, z), (ridge, ht, z),
            (r, 0.0, z), (ridge, -ht, z), (0.0, -ht * 1.05, z), (-ridge, -ht, z),
        ]

    sock_len = length * 0.14
    profile = [
        (0.0,               w0 * 0.62, t0 * 0.9,  0.55),   # 套管
        (sock_len,          w0 * 0.70, t0,        0.25),
        (sock_len * 1.25,   w0,        t0,        0.0),
        (length * 0.42,     w0 * 0.86, t0 * 0.92, 0.0),
        (length * 0.70,     w0 * 0.60, t0 * 0.78, 0.0),
        (length * 0.90,     w0 * 0.34, t0 * 0.55, 0.0),
        (length * 0.98,     w0 * 0.14, t0 * 0.30, 0.0),
    ]

    for (z, hw, ht, sk) in profile:
        base = len(verts)
        verts.extend(ring_pts(z, hw, ht, sk))
        rings.append(base)

    for i in range(len(rings) - 1):
        a, b = rings[i], rings[i + 1]
        for k in range(NP):
            k2 = (k + 1) % NP
            faces.append([a + k, a + k2, b + k2, b + k])

    # 尖
    tb = len(verts)
    verts.append((0.0, 0.0, length))
    last = rings[-1]
    for k in range(NP):
        k2 = (k + 1) % NP
        faces.append([last + k, last + k2, tb])

    r0 = rings[0]
    faces.append([r0 + (NP - 1 - k) for k in range(NP)])

    ob = new_mesh_obj(name, verts, faces)
    for p in ob.data.polygons:
        p.use_smooth = True
    return ob


# ============================================================
# 装配
# ============================================================

def assemble(name, blade_fn, grip_len=None, grip_r=None, guard_kw=None,
             pommel_r=None, guard_offset=0.0, pivot='GripCenter'):
    """
    通用装配: 首部 -> 握柄 -> 护手 -> 刃部
    pivot='GripCenter' 时枢轴归到握柄中心 (剑类)
    pivot='GripTop'    时枢轴归到握柄顶端 (长柄类, 便于挂手)
    guard_offset: 护手额外上移量
    """
    parts = []
    gl = grip_len if grip_len is not None else GRIP_LEN
    gr = grip_r if grip_r is not None else GRIP_R
    pr = pommel_r if pommel_r is not None else POMMEL_R

    pom = build_pommel(f"{name}_Pommel", 0.0, pr)
    parts.append(pom)
    z_grip = pr * 1.85
    grip = build_grip(f"{name}_Grip", z_grip, gl, gr)
    parts.append(grip)

    z_guard = z_grip + gl + guard_offset
    gkw = dict(guard_kw or {})
    gh = gkw.get('height', GUARD_H)
    guard = build_guard(f"{name}_Guard", z_guard + gh * 0.5, **gkw)
    parts.append(guard)

    z_blade = z_guard + gh
    blade = blade_fn(z_blade)
    parts.append(blade)

    # 合并
    bpy.ops.object.select_all(action='DESELECT')
    for p in parts:
        p.select_set(True)
    bpy.context.view_layer.objects.active = parts[0]
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

    # 枢轴
    if pivot == 'GripTop':
        center_z = z_grip + gl
    else:
        center_z = z_grip + gl / 2.0
    for v in ob.data.vertices:
        v.co.z -= center_z

    return ob


# ============================================================
# 5 把武器定义
# ============================================================

def make_all():
    specs = [
        # 1. 双手剑 — 标准直刃带血槽
        dict(
            name="双手剑",
            blade=lambda z: _offset(blade_straight("blade", 1.03, 0.062, 0.0075,
                                                   fuller=True), z),
            grip_len=0.265, grip_r=0.0205,
            guard_kw=dict(length=0.285),
        ),
        # 2. 阔剑/大剑 — 更宽更长, 无血槽
        dict(
            name="阔剑",
            blade=lambda z: _offset(blade_straight("blade", 1.16, 0.085, 0.0090,
                                                   fuller=False), z),
            grip_len=0.300, grip_r=0.0215,
            guard_kw=dict(length=0.330, height=0.058, depth=0.040),
            pommel_r=0.035,
        ),
        # 3. 双手斧 — 单侧斧刃, 长柄
        dict(
            name="双手斧",
            blade=lambda z: _offset(blade_axe("blade", blade_h=0.285,
                                              blade_w=0.155, spike_back=True), z),
            grip_len=0.840, grip_r=0.0210,
            guard_kw=dict(length=0.090, height=0.042, depth=0.034,
                          wings=False, nose=False),
            guard_offset=-0.020,
            pivot='GripTop',
        ),
        # 4. 长柄斧/戟 — 斧刃 + 顶部矛尖
        dict(
            name="长柄斧",
            blade=lambda z: _offset(_combo_halberd("blade"), z),
            grip_len=1.300, grip_r=0.0220,
            guard_kw=dict(length=0.085, height=0.040, depth=0.032,
                          wings=False, nose=False),
            guard_offset=-0.020,
            pivot='GripTop',
        ),
        # 5. 长枪 — 细长矛头
        dict(
            name="长枪",
            blade=lambda z: _offset(blade_spear("blade", length=0.360,
                                                width=0.056), z),
            grip_len=1.620, grip_r=0.0200,
            guard_kw=dict(length=0.055, height=0.032, depth=0.028,
                          wings=False, nose=False),
            guard_offset=-0.020,
            pivot='GripTop',
        ),
    ]
    return specs


def _offset(ob, dz):
    """把对象沿 +Z 平移 dz"""
    for v in ob.data.vertices:
        v.co.z += dz
    return ob


def _combo_halberd(name):
    """戟: 斧刃 + 顶部矛尖 (返回合并后的对象, 斧刃底在 z=0)"""
    AXE_H = 0.235
    axe = blade_axe(f"{name}_axe", blade_h=AXE_H, blade_w=0.140, spike_back=True)
    for v in axe.data.vertices:
        v.co.z += 0.020

    # 矛尖接在斧刃顶部之上
    spear = blade_spear(f"{name}_spike", length=0.215, width=0.042)
    for v in spear.data.vertices:
        v.co.z += 0.020 + AXE_H - 0.030

    bpy.ops.object.select_all(action='DESELECT')
    axe.select_set(True); spear.select_set(True)
    bpy.context.view_layer.objects.active = axe
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    return ob


# ============================================================
# 主流程
# ============================================================

def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = 'METRIC'
    scene.unit_settings.scale_length = 1.0

    print("=" * 60)
    built = []
    for spec in make_all():
        nm = spec['name']
        ob = assemble(
            nm,
            spec['blade'],
            grip_len=spec.get('grip_len'),
            grip_r=spec.get('grip_r'),
            guard_kw=spec.get('guard_kw'),
            pommel_r=spec.get('pommel_r'),
        )
        built.append(ob)
        from mathutils import Vector as V
        zs = [v.co.z for v in ob.data.vertices]
        print(f"[BUILD] {nm:8s} verts={len(ob.data.vertices):4d} "
              f"polys={len(ob.data.polygons):4d} 总长={(max(zs)-min(zs))*100:6.1f}cm")
    print("=" * 60)

    # 保存
    out = r"C:\My box\model\双手武器.blend"
    bpy.ops.wm.save_as_mainfile(filepath=out)
    print(f"[SAVE] {out}")


if __name__ == "__main__":
    main()
