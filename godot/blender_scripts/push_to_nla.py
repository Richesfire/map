import bpy

obj = bpy.context.active_object
if obj is None or obj.type != 'ARMATURE':
    print("错误: 请先选中 Armature 骨架")
else:
    if obj.animation_data is None:
        obj.animation_data_create()

    # 清空现有 NLA 轨道（避免重复）
    for track in list(obj.animation_data.nla_tracks):
        obj.animation_data.nla_tracks.remove(track)

    count = 0
    for action in bpy.data.actions:
        # 创建 NLA 轨道
        track = obj.animation_data.nla_tracks.new()
        track.name = action.name
        # 把 action 放入轨道（strip）
        start = int(action.frame_range[0])
        track.strips.new(action.name, start, action)
        count += 1
        print("推入 NLA:", action.name)

    print()
    print("完成！共推入", count, "个动画到 NLA")
    print("现在可以导出 glTF 了（勾选动画）")
