class_name PropMeshes
extends RefCounted

## 三个"零件"的临时几何体。
## 原型阶段用程序化几何，方便直接跑；正式美术资源到位后，
## 把 map_world.gd 里 _prop_meshes 换成 load("res://assets/tree.glb") 之类的即可。
##
## 注意：顶点色是**线性空间**的，写 sRGB 数值必须自己转，
## 否则颜色会明显发白（这是 Godot 里最容易踩的坑之一）。


## 树：一根树干 + 两层树冠。顶点色写死，靠缩放和旋转做变化。
static func tree() -> ArrayMesh:
	var am := ArrayMesh.new()
	_append(am, _cylinder(0.16, 0.11, 2.4, 5), Vector3(0.0, 1.2, 0.0), _srgb(0.24, 0.17, 0.11))
	_append(am, _cylinder(1.45, 0.0, 3.4, 6), Vector3(0.0, 3.4, 0.0), _srgb(0.16, 0.32, 0.13))
	_append(am, _cylinder(1.05, 0.0, 2.6, 6), Vector3(0.0, 5.1, 0.0), _srgb(0.20, 0.38, 0.16))
	return am


## 石头：低面数球体，配合非等比缩放看起来像块石头
static func rock() -> ArrayMesh:
	var am := ArrayMesh.new()
	var sp := SphereMesh.new()
	sp.radius = 1.0
	sp.height = 2.0
	sp.radial_segments = 5
	sp.rings = 3
	_append(am, sp, Vector3.ZERO, _srgb(0.38, 0.37, 0.34))
	return am


## 低矮植被：一个很小的锥体，远看就是草丛
static func low_veg() -> ArrayMesh:
	var am := ArrayMesh.new()
	_append(am, _cylinder(0.24, 0.0, 0.55, 3), Vector3(0.0, 0.27, 0.0), _srgb(0.30, 0.42, 0.17))
	return am


## sRGB 数值 -> 线性空间（顶点色需要线性）
static func _srgb(r: float, g: float, b: float) -> Color:
	return Color(r, g, b).srgb_to_linear()


static func _cylinder(bottom_r: float, top_r: float, height: float, segs: int) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.bottom_radius = bottom_r
	m.top_radius = top_r
	m.height = height
	m.radial_segments = segs
	m.rings = 1
	return m


## 把一个 PrimitiveMesh 平移后作为一个 surface 塞进 ArrayMesh，并写入顶点色
static func _append(am: ArrayMesh, src: Mesh, offset: Vector3, col: Color) -> void:
	var arrays: Array = src.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in verts.size():
		verts[i] = verts[i] + offset
	arrays[Mesh.ARRAY_VERTEX] = verts

	var cols := PackedColorArray()
	cols.resize(verts.size())
	cols.fill(col)
	arrays[Mesh.ARRAY_COLOR] = cols

	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
