# -*- coding: utf-8 -*-
"""渲染 武器模型.blend 的布局验证图"""
import bpy, math, os
from mathutils import Vector

OUT = r"C:\My box\model\preview"
os.makedirs(OUT, exist_ok=True)

sc = bpy.context.scene
sc.render.engine = 'BLENDER_WORKBENCH'
sc.display.shading.light = 'STUDIO'
sc.display.shading.color_type = 'SINGLE'
sc.display.shading.single_color = (0.60, 0.62, 0.66)
sc.display.shading.show_cavity = True

meshes = [o for o in sc.objects if o.type == 'MESH']
pts = []
for o in meshes:
    pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
minx=min(p.x for p in pts); maxx=max(p.x for p in pts)
miny=min(p.y for p in pts); maxy=max(p.y for p in pts)
minz=min(p.z for p in pts); maxz=max(p.z for p in pts)
print(f"[BBOX] X {minx:.2f}..{maxx:.2f}  Y {miny:.2f}..{maxy:.2f}  Z {minz:.2f}..{maxz:.2f}")

cam_d = bpy.data.cameras.new("Cam"); cam_d.type='ORTHO'
cam = bpy.data.objects.new("Cam", cam_d)
sc.collection.objects.link(cam); sc.camera = cam
cx, cy, cz = (minx+maxx)/2, (miny+maxy)/2, (minz+maxz)/2

def shoot(name, loc, rot, ortho, rx=1800, ry=1100):
    sc.render.resolution_x=rx; sc.render.resolution_y=ry
    cam.location=loc; cam.rotation_euler=rot; cam_d.ortho_scale=ortho
    sc.render.filepath=os.path.join(OUT,name)
    bpy.ops.render.render(write_still=True)
    print(f"[RENDER] {name}")

# 俯视图: 看网格/行列/国家分块
shoot("lib_top.png", (cx, cy, maxz+8), (0,0,0),
      max(maxx-minx, maxy-miny)*1.08, 1800, 1200)

# 正视图: 看握手是否同高
shoot("lib_front.png", (cx, miny-8, cz), (math.radians(90),0,0),
      max(maxx-minx, maxz-minz)*1.06, 2000, 1100)

# 第一行武器特写
row_pts=[]
for o in meshes:
    if o.name in ("双手剑","阔剑","双手斧","长柄斧","长枪"):
        row_pts += [o.matrix_world @ Vector(c) for c in o.bound_box]
if row_pts:
    x0=min(p.x for p in row_pts); x1=max(p.x for p in row_pts)
    z0=min(p.z for p in row_pts); z1=max(p.z for p in row_pts)
    shoot("lib_row1.png", ((x0+x1)/2, 0.6-6, (z0+z1)/2), (math.radians(90),0,0),
          max(x1-x0, z1-z0)*1.12, 2000, 1000)

print("[DONE]")
