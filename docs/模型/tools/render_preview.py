# -*- coding: utf-8 -*-
"""渲染俯视图 + 正视图 + 武器列特写"""
import bpy, math, os
from mathutils import Vector

OUT_DIR = r"C:\My box\model\preview"
os.makedirs(OUT_DIR, exist_ok=True)

scene = bpy.context.scene
scene.render.engine = 'BLENDER_WORKBENCH'
scene.render.resolution_x = 1600
scene.render.resolution_y = 1000
scene.display.shading.light = 'STUDIO'
scene.display.shading.color_type = 'SINGLE'
scene.display.shading.single_color = (0.62, 0.63, 0.66)
scene.display.shading.show_cavity = True

objs = [o for o in scene.objects if o.type == 'MESH']
pts = []
for o in objs:
    pts += [o.matrix_world @ Vector(c) for c in o.bound_box]

minx = min(p.x for p in pts); maxx = max(p.x for p in pts)
miny = min(p.y for p in pts); maxy = max(p.y for p in pts)
minz = min(p.z for p in pts); maxz = max(p.z for p in pts)
print(f"[BBOX] X {minx:.2f}..{maxx:.2f}  Y {miny:.2f}..{maxy:.2f}  Z {minz:.2f}..{maxz:.2f}")

cam_data = bpy.data.cameras.new("Cam"); cam_data.type = 'ORTHO'
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam); scene.camera = cam

def shoot(name, loc, rot, ortho, rx=1600, ry=1000):
    scene.render.resolution_x = rx; scene.render.resolution_y = ry
    cam.location = loc; cam.rotation_euler = rot; cam_data.ortho_scale = ortho
    scene.render.filepath = os.path.join(OUT_DIR, name)
    bpy.ops.render.render(write_still=True)
    print(f"[RENDER] {name}")

cx, cy, cz = (minx+maxx)/2, (miny+maxy)/2, (minz+maxz)/2

# 全景俯视
shoot("top.png", (cx, cy, maxz+6), (0, 0, 0),
      max(maxx-minx, maxy-miny)*1.10, 1600, 1000)

# 正视图全景
shoot("front.png", (cx, miny-6, cz), (math.radians(90), 0, 0),
      max(maxx-minx, maxz-minz)*1.06, 1600, 1000)

# 武器列特写 (只框武器)
wp = []
for o in objs:
    if o.name.startswith(("双手剑","阔剑","双手斧","长柄斧","长枪")):
        wp += [o.matrix_world @ Vector(c) for c in o.bound_box]
if wp:
    wx0=min(p.x for p in wp); wx1=max(p.x for p in wp)
    wz0=min(p.z for p in wp); wz1=max(p.z for p in wp)
    wcx, wcy, wcz = (wx0+wx1)/2, 0.55, (wz0+wz1)/2
    shoot("weapons_front.png", (wcx, wcy-6, wcz), (math.radians(90),0,0),
          max(wx1-wx0, wz1-wz0)*1.14, 1800, 1100)

print("[DONE]")
