import bpy


def count_curves(a):
    try:
        return len(a.fcurves)
    except Exception:
        pass
    n = 0
    for layer in getattr(a, "layers", []):
        for strip in getattr(layer, "strips", []):
            for cb in getattr(strip, "channelbags", []):
                n += len(getattr(cb, "fcurves", []))
    return n


for a in sorted(bpy.data.actions, key=lambda x: x.name):
    print("ACT|%s|%d|%d|%d" % (a.name, int(a.frame_range[0]), int(a.frame_range[1]), count_curves(a)))
