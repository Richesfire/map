# -*- coding: utf-8 -*-
"""
导出 5 把武器为独立 glTF (.glb) — Godot 原生格式
每把武器一个文件, 只含武器网格, 不含角色参考
"""
import bpy, os

OUT = r"C:\My box\model\export"
os.makedirs(OUT, exist_ok=True)

NAMES = ["双手剑", "阔剑", "双手斧", "长柄斧", "长枪"]
# 文件名 -> 英文 (避免 Godot 路径中文问题)
FILEMAP = {
    "双手剑": "twohanded_sword",
    "阔剑":   "greatsword",
    "双手斧": "twohanded_axe",
    "长柄斧": "halberd",
    "长枪":   "spear",
}

print("=" * 60)
for nm in NAMES:
    ob = bpy.data.objects.get(nm)
    if ob is None:
        print(f"[SKIP] 找不到 {nm}")
        continue

    # 关键: 导出前把物体移到世界原点
    # 网格顶点本身已相对握柄中心归零, 这里清零物体变换
    orig_loc = ob.location.copy()
    ob.location = (0.0, 0.0, 0.0)

    bpy.ops.object.select_all(action='DESELECT')
    ob.select_set(True)
    bpy.context.view_layer.objects.active = ob

    fn = FILEMAP[nm] + ".glb"
    path = os.path.join(OUT, fn)

    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format='GLB',
        use_selection=True,
        export_apply=True,
        export_yup=True,
        export_materials='EXPORT',
        export_normals=True,
        export_texcoords=True,
        export_animations=False,
        export_skins=False,
    )

    # 还原场景中的摆放位置
    ob.location = orig_loc

    zs = [v.co.z for v in ob.data.vertices]
    L = (max(zs) - min(zs)) * 100
    sz = os.path.getsize(path) / 1024
    print(f"[EXPORT] {nm:6s} -> {fn:22s} {sz:6.1f}KB  "
          f"verts={len(ob.data.vertices):4d} 长={L:6.1f}cm 枢轴=原点")
print("=" * 60)
