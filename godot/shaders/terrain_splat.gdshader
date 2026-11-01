shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_disabled;

// ==============================================================
// 地块地表着色器 —— 策划总纲里的"纹理"零件
//
// 规则：一个地块里含多种常规纹理，按白膜地形的起伏（坡度）分配，
//       并自然过渡。坡缓 -> 绿草，坡陡 -> 泥土。
//       地表只有这两种纹理；石头是独立零件，不参与地表着色。
//
// 三平面投影（triplanar）：不用 UV，直接用世界坐标采样。
// 好处是陡坡上纹理不会被拉成橡皮泥，而且相邻地块的纹理天然对齐，
// 接缝处不会断。
// ==============================================================

uniform sampler2D tex_grass : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D tex_dirt : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

// 坡度阈值（度）：与 preview/render_preview.py 保持一致
uniform float grass_dirt_lo = 7.0;
uniform float grass_dirt_hi = 26.0;

// 宏观噪声：把泥土斑块打进平地，避免出现等高线一样的硬边
uniform float macro_strength = 0.14;
uniform float macro_scale = 0.0033;

// 中尺度色斑：让大片草地不至于像一块塑料
uniform float mottle_strength = 0.16;
uniform float mottle_scale = 0.0208;

// 纹理重复：1 米对应多少 UV，0.16 约等于每 6.25 米重复一次
uniform float tri_scale = 0.16;
uniform float tri_sharpness = 4.0;

// 调试：只看白膜（策划总纲里"地形（白膜地形）"那一步）
// 生物群系染色：整体乘上去，配合地表纹理把草原/沙漠/冰原区分开
uniform vec3 biome_tint : source_color = vec3(1.0, 1.0, 1.0);
uniform float biome_tint_strength = 1.0;

uniform bool show_white_model = false;
uniform vec3 white_color : source_color = vec3(0.84, 0.84, 0.82);

varying vec3 wpos;
varying vec3 n_loc;   // 区域局部法线：算坡度用
varying vec3 n_wld;   // 世界法线：算三平面权重用

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec3 tri_sample(sampler2D tex, vec3 p, vec3 n, float s) {
	vec3 w = pow(abs(n), vec3(tri_sharpness));
	w /= (w.x + w.y + w.z + 1e-5);
	vec3 cx = texture(tex, p.zy * s).rgb;
	vec3 cy = texture(tex, p.xz * s).rgb;
	vec3 cz = texture(tex, p.xy * s).rgb;
	return cx * w.x + cy * w.y + cz * w.z;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	n_loc = normalize(NORMAL);
	n_wld = normalize(mat3(MODEL_MATRIX) * NORMAL);
}

void fragment() {
	vec3 n = normalize(n_loc);
	vec3 nw = normalize(n_wld);
	float slope = degrees(acos(clamp(n.y, -1.0, 1.0)));

	// 坡度 -> 草/泥土 权重
	float w_dirt = smoothstep(grass_dirt_lo, grass_dirt_hi, slope);

	// 自然过渡：用宏观噪声把边界打碎
	float macro = vnoise(wpos.xz * macro_scale);
	w_dirt = clamp(w_dirt + (macro - 0.5) * macro_strength, 0.0, 1.0);

	vec3 cg = tri_sample(tex_grass, wpos, nw, tri_scale);
	vec3 cd = tri_sample(tex_dirt, wpos, nw, tri_scale);

	vec3 col = mix(cg, cd, w_dirt);

	float mottle = 1.0 + (vnoise(wpos.xz * mottle_scale) - 0.5) * mottle_strength;
	col *= mottle;

	if (show_white_model) {
		col = white_color;
	}

	// 相乘只能压暗，压不出雪地/沙漠这种换色。
	// 这里按亮度把地面往目标色上拉：亮度提供细节，目标色提供色相。
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	vec3 tinted = biome_tint * (0.28 + 1.15 * lum);
	col = mix(col, tinted, biome_tint_strength);
	ALBEDO = col;
	ROUGHNESS = 0.94;
	SPECULAR = 0.16;
}
