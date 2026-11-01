class_name TextureFactory
extends RefCounted

## 程序化生成可无缝平铺的地表纹理。
## 项目里不带图片资源，第一次运行就自动生成，省得你去准备贴图。
## 想换成美术给的图，直接在主脚本里 set_shader_parameter 换成 load("res://...") 即可。
##
## 无缝原理：把噪声的四份平移拷贝按像素在贴图内的相对位置做双线性混合，
##           左右、上下边界处的取值相同，因此平铺时看不到接缝。


static func ground(base: Color, dark: Color, tex_seed: int, size_px: int = 192) -> ImageTexture:
	var img := Image.create(size_px, size_px, false, Image.FORMAT_RGB8)

	var n := FastNoiseLite.new()
	n.seed = tex_seed
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.030
	n.fractal_type = FastNoiseLite.FRACTAL_FBM
	n.fractal_octaves = 4
	n.fractal_lacunarity = 2.0
	n.fractal_gain = 0.5

	var size_f := float(size_px)
	var rng := RandomNumberGenerator.new()
	rng.seed = tex_seed

	for y in size_px:
		for x in size_px:
			var v := _seamless(n, float(x), float(y), size_f)
			# 混合会压掉一半对比度，这里拉回来
			v = clampf((v - 0.5) * 1.9 + 0.5, 0.0, 1.0)
			var c := dark.lerp(base, v)
			var grain := rng.randf_range(-0.030, 0.030)
			img.set_pixel(x, y, Color(
					clampf(c.r + grain, 0.0, 1.0),
					clampf(c.g + grain, 0.0, 1.0),
					clampf(c.b + grain, 0.0, 1.0)))

	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


static func _seamless(n: FastNoiseLite, x: float, y: float, size: float) -> float:
	var fx := x / size
	var fy := y / size
	var a := n.get_noise_2d(x, y)
	var b := n.get_noise_2d(x - size, y)
	var c := n.get_noise_2d(x, y - size)
	var d := n.get_noise_2d(x - size, y - size)
	return lerpf(lerpf(a, b, fx), lerpf(c, d, fx), fy) * 0.5 + 0.5
