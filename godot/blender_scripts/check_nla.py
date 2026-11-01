import bpy

print("=== 所有 Action（动作）===")
for a in bpy.data.actions:
    print("ACTION:", a.name, "| users:", a.users)

print()
print("=== NLA 轨道里的动画（这些才会被 glTF 导出）===")
count = 0
for obj in bpy.data.objects:
    if obj.animation_data and obj.animation_data.nla_tracks:
        for track in obj.animation_data.nla_tracks:
            for strip in track.strips:
                print("NLA:", strip.name)
                count += 1
print("NLA 总数:", count)
