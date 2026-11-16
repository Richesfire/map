# -*- coding: utf-8 -*-
"""
武器模型.blend — 9 行武器陈列库

布局 (俯视图 Top View: X 右, Y 上):
  角色参考  -> X<0 (第二三象限中间)
  武器      -> 第一象限 (X>0, Y>0)

9 行 (从参考模型那一侧开始数, 即俯视图由下往上, Y 由小到大):
   1  双手武器        双手剑 / 阔剑 / 双手斧     <- Y 最小, 紧邻参考模型
   2  单手武器        (占位)
   3  双手长杆武器    长柄斧 / 长枪
   4  单手长杆武器    (占位)
   5  弓              (占位)
   6  弩              (占位)
   7  单手火枪        (占位)
   8  双手火枪        (占位)
   9  盾牌            (占位)                  <- Y 最大, 离参考模型最远

列 = 国家 (5 个)
高度基准: 每把武器底部 (最低顶点) 对齐 Z=0
"""

import bpy
from mathutils import Vector

OUT = r"C:\My box\model\武器模型.blend"

NATIONS = ["国家1", "国家2", "国家3", "国家4", "国家5"]

# 行定义: (行号, 行名, 是否已有真实武器, 行内真实武器清单)
ROWS = [
    (1, "双手武器",     ["双手剑", "阔剑", "双手斧"]),
    (2, "单手武器",     []),
    (3, "双手长杆武器", ["长柄斧", "长枪"]),
    (4, "单手长杆武器", []),
    (5, "弓",           []),
    (6, "弩",           []),
    (7, "单手火枪",     []),
    (8, "双手火枪",     []),
    (9, "盾牌",         []),
]

SLOTS_PER_NATION = 2      # 每国家每行预留格数
COL_GAP    = 1.05         # 同国家内格间距
NATION_GAP = 0.85         # 国家之间的额外空隙
ROW_GAP    = 1.00         # 行间距
X0         = 0.90         # 武器区起始 X
Y_FIRST    = 0.60         # 第一行 Y (最靠近参考模型, 俯视图最下方)
GROUND_Z   = 0.0


def col_x(ni, si):
    return X0 + ni * (COL_GAP * SLOTS_PER_NATION + NATION_GAP) + si * COL_GAP


def row_y(row_no):
    """row_no 从 1 开始; 第 1 行最靠近参考模型 (Y 最小), 往上递增"""
    return Y_FIRST + (row_no - 1) * ROW_GAP


def drop_to_ground(ob):
    if not ob.data.vertices:
        return
    zmin = min(v.co.z for v in ob.data.vertices)
    for v in ob.data.vertices:
        v.co.z -= zmin


def main():
    print("=" * 72)

    # ---------- 清理旧占位盒 ----------
    old = [o for o in bpy.data.objects if o.name.startswith("占位_")]
    for o in old:
        bpy.data.objects.remove(o, do_unlink=True)
    print(f"[清理] 旧占位盒 {len(old)} 个")

    # ---------- 真实武器归位 ----------
    placed = set()
    for row_no, row_name, weapons in ROWS:
        if not weapons:
            continue
        for i, nm in enumerate(weapons):
            ob = bpy.data.objects.get(nm)
            if ob is None:
                print(f"[警告] 缺少 {nm}")
                continue
            drop_to_ground(ob)
            nat, slot = i % len(NATIONS), i // len(NATIONS)
            x, y = col_x(nat, slot), row_y(row_no)
            ob.location = Vector((x, y, GROUND_Z))
            placed.add(nm)
            zs = [v.co.z for v in ob.data.vertices]
            print(f"[第{row_no}行 {row_name:6s}] {nm:6s} 列={NATIONS[nat]} "
                  f"X={x:6.2f} Y={y:5.2f} 长={(max(zs)-min(zs))*100:6.1f}cm")

    # 未列入行定义的武器 (保护, 避免静默丢失)
    for o in bpy.data.objects:
        if o.type == 'MESH' and o.name in ("双手剑", "阔剑", "双手斧", "长柄斧", "长枪"):
            if o.name not in placed:
                print(f"[警告] {o.name} 未归入任何行")

    # ---------- 占位盒 ----------
    # 先算出真实武器占了哪些 (row, nation, slot)
    occupied = set()
    for row_no, row_name, weapons in ROWS:
        for i, nm in enumerate(weapons):
            occupied.add((row_no, i % len(NATIONS), i // len(NATIONS)))

    cnt = 0
    for row_no, row_name, weapons in ROWS:
        for ni, nat in enumerate(NATIONS):
            for si in range(SLOTS_PER_NATION):
                if (row_no, ni, si) in occupied:
                    continue
                x, y = col_x(ni, si), row_y(row_no)
                bpy.ops.mesh.primitive_cube_add(
                    size=1.0, location=(x, y, GROUND_Z))
                h = bpy.context.active_object
                h.name = f"占位_{row_name}_{nat}_{si+1}"
                h.scale = (0.16, 0.09, 0.50)
                h.location.z = 0.25
                bpy.ops.object.transform_apply(
                    location=False, rotation=False, scale=True)
                cnt += 1
    print(f"[占位] {cnt} 个盒子")

    # ---------- 参考物 ----------
    old_ref = bpy.data.objects.get("参考_旧占位剑")
    if old_ref:
        old_ref.location = Vector((-1.585, 0.0, 0.0))

    bpy.ops.wm.save_as_mainfile(filepath=OUT)
    print(f"[保存] {OUT}")

    print("[行序] 从参考模型那一侧开始 (Y 由小到大):")
    for row_no, row_name, weapons in ROWS:
        tag = f"({len(weapons)} 真实武器)" if weapons else "(占位)"
        print(f"   {row_no}. Y={row_y(row_no):5.2f}  {row_name:12s} {tag}")


if __name__ == "__main__":
    main()
