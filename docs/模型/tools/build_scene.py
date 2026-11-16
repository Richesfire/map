# -*- coding: utf-8 -*-
"""
组装 双手武器.blend — 角色参考 + 5 把双手武器

布局 (俯视图 Top View: X 右, Y 上):
  角色参考   -> 第二三象限中间 = X<0, Y≈0
  武器 5 件   -> 第一象限       = X>0, Y>0 (沿 X 排开)

角色来源: C:\\My box\\战斗流畅性完成\\人物模型.blend
"""

import bpy
import sys
import os
from mathutils import Vector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_five as B

CHAR_BLEND = r"C:\My box\战斗流畅性完成\人物模型.blend"
OUT_BLEND  = r"C:\My box\model\双手武器.blend"

CHAR_X, CHAR_Y = -2.60, 0.0     # 角色中心 (第二三象限中间)
WEAPON_X0      = 0.75           # 武器列起点 X (第一象限)
WEAPON_GAP     = 0.85           # 武器间距
WEAPON_Y       = 0.55           # 武器列 Y (正)
WEAPON_Z       = 1.20           # 统一高度


def import_from_char(names):
    """从人物模型.blend append 指定对象并 link 进当前场景"""
    with bpy.data.libraries.load(CHAR_BLEND, link=False) as (src, dst):
        dst.objects = [n for n in src.objects if n in names]
    imported = [o for o in dst.objects if o is not None]
    for o in imported:
        if o.name not in bpy.context.collection.objects:
            bpy.context.collection.objects.link(o)
    return imported


def main():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = 'METRIC'
    scene.unit_settings.scale_length = 1.0

    # ---------- 角色参考 ----------
    char = import_from_char({"Armature", "Body"})
    print(f"[角色] 导入: {[o.name for o in char]}")
    for o in char:
        if o.parent is None:
            o.location.x += CHAR_X
            o.location.y += CHAR_Y
    print(f"[布局] 角色 -> X={CHAR_X}, Y={CHAR_Y} (第二三象限中间)")

    # ---------- 旧占位剑 (对照) ----------
    old = import_from_char({"双手剑"})
    for o in old:
        o.name = "参考_旧占位剑"
        o.location = Vector((CHAR_X + 0.75, -0.45, 0.0))
        print(f"[参考] 旧占位剑 1.099m 置于角色右侧")

    # ---------- 5 把武器 ----------
    print("=" * 62)
    for i, spec in enumerate(B.make_all()):
        nm = spec['name']
        ob = B.assemble(
            nm, spec['blade'],
            grip_len=spec.get('grip_len'),
            grip_r=spec.get('grip_r'),
            guard_kw=spec.get('guard_kw'),
            pommel_r=spec.get('pommel_r'),
            guard_offset=spec.get('guard_offset', 0.0),
            pivot=spec.get('pivot', 'GripCenter'),
        )
        x = WEAPON_X0 + i * WEAPON_GAP
        ob.location = Vector((x, WEAPON_Y, WEAPON_Z))

        zs = [v.co.z for v in ob.data.vertices]
        L = (max(zs) - min(zs)) * 100
        print(f"[武器] {nm:6s} verts={len(ob.data.vertices):4d} "
              f"polys={len(ob.data.polygons):4d} 长={L:6.1f}cm "
              f"@ X={x:.2f}")
    print("=" * 62)
    print(f"[布局] 武器 -> 第一象限 (X>{WEAPON_X0}, Y={WEAPON_Y})")

    os.makedirs(os.path.dirname(OUT_BLEND), exist_ok=True)
    bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND)
    print(f"[保存] {OUT_BLEND}")


if __name__ == "__main__":
    main()
