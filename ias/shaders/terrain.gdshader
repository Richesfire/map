shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// 地形表面：地表纹理图集（4x4）按坡度/海拔/干湿混合，再乘顶点色与三平面噪声
uniform sampler2D noise_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_atlas : source_color, filter_linear, repeat_enable;
uniform sampler2D ground_normal : hint_normal, filter_linear, repeat_enable;
uniform float normal_strength = 1.0;
uniform float atlas_n = 4.0;
uniform float tex_scale = 0.075;     // 1/米：贴图重复尺度（约 13m 一次）
uniform float tex_strength = 0.80;   // 纹理占最终颜色的比例
uniform float snow_line = 2800.0;
uniform float detail_scale = 0.04;
uniform float mid_scale = 0.11;
uniform float macro_scale = 0.0035;
uniform vec3 tint_a : source_color = vec3(0.96, 0.98, 0.90);
uniform vec3 tint_b : source_color = vec3(0.98, 0.95, 0.86);

varying vec3 wpos;
varying vec3 wnrm;

vec3 tile_at(vec2 uv, int idx) {
	float t = 1.0 / atlas_n;
	float ix = float(idx % 4);
	float iy = floor(float(idx) / 4.0);
	vec2 cell = vec2(ix, iy) * t;
	// 收缩半个像素级别，避免采样到图集相邻格（会在每 13m 出现一条亮线）
	return texture(ground_atlas, cell + (fract(uv) * 0.985 + 0.0075) * t).rgb;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec3 w = pow(abs(wnrm), vec3(6.0));
	w /= max(w.x + w.y + w.z, 0.0001);
	float gx = texture(noise_tex, wpos.zy * detail_scale).r;
	float gy = texture(noise_tex, wpos.xz * detail_scale).r;
	float gz = texture(noise_tex, wpos.xy * detail_scale).r;
	float fine = gx * w.x + gy * w.y + gz * w.z;
	float mid = texture(noise_tex, wpos.xz * mid_scale).r;
	float macro = texture(noise_tex, wpos.xz * macro_scale).r;

	// ---- 地表纹理混合 ----
	vec2 uv = wpos.xz * tex_scale;
	float slope = 1.0 - clamp(wnrm.y, 0.0, 1.0);
	float snow = smoothstep(snow_line, snow_line + 600.0, wpos.y);
	// 干湿：低频噪声，直接拿来决定草地/枯草/裸土
	float dryness = texture(noise_tex, wpos.xz * 0.0011).r;

	// 地貌 id 从顶点色 alpha 传进来（0..11），每组地貌从自己的纹理堆取图
	int packed = int(floor(COLOR.a * 64.0 + 0.5));
	int lf = packed % 32;
	int mat = packed / 32;
	int t0 = 0;
	int t1 = 2;
	int t2 = 1;
	int t3 = 3;
	if (lf == 1) {          // 丘陵
		t0 = 0; t1 = 2; t2 = 3; t3 = 3;
	} else if (lf == 2) {   // 山地
		t0 = 5; t1 = 6; t2 = 11; t3 = 3;
	} else if (lf == 3) {   // 高原
		t0 = 1; t1 = 3; t2 = 0; t3 = 2;
	} else if (lf == 4) {   // 盆地
		t0 = 0; t1 = 3; t2 = 1; t3 = 2;
	} else if (lf == 5) {   // 河谷
		t0 = 2; t1 = 9; t2 = 0; t3 = 3;
	} else if (lf == 6) {   // 荒漠
		t0 = 7; t1 = 3; t2 = 4; t3 = 11;
	} else if (lf == 7) {   // 草原
		t0 = 1; t1 = 13; t2 = 0; t3 = 3;
	} else if (lf == 8) {   // 森林
		t0 = 14; t1 = 2; t2 = 3; t3 = 10;
	} else if (lf == 9) {   // 湿地
		t0 = 9; t1 = 10; t2 = 2; t3 = 3;
	} else if (lf == 10) {  // 冰雪
		t0 = 8; t1 = 5; t2 = 6; t3 = 11;
	} else if (lf == 11) {  // 海岸
		t0 = 15; t1 = 7; t2 = 4; t3 = 3;
	} else if (lf == 12) {  // 喀斯特
		t0 = 5; t1 = 10; t2 = 3; t3 = 11;
	} else if (lf == 13) {  // 雅丹
		t0 = 7; t1 = 4; t2 = 3; t3 = 11;
	} else if (lf == 14) {  // 黄土
		t0 = 1; t1 = 3; t2 = 0; t3 = 4;
	} else if (lf == 15) {  // 沙丘
		t0 = 7; t1 = 7; t2 = 3; t3 = 4;
	} else if (lf == 16) {  // 冰川谷
		t0 = 8; t1 = 5; t2 = 6; t3 = 11;
	} else if (lf == 17) {  // 三角洲
		t0 = 9; t1 = 10; t2 = 2; t3 = 15;
	} else if (lf == 18) {  // 花岗岩山地
		t0 = 5; t1 = 6; t2 = 11; t3 = 3;
	} else if (lf == 19) {  // 喀斯特山地
		t0 = 5; t1 = 10; t2 = 6; t3 = 11;
	} else if (lf == 20) {  // 黄土山地
		t0 = 1; t1 = 3; t2 = 4; t3 = 0;
	} else if (lf == 21) {  // 火山山地
		t0 = 6; t1 = 11; t2 = 5; t3 = 3;
	} else if (lf == 22) {  // 冰蚀山地
		t0 = 8; t1 = 5; t2 = 6; t3 = 11;
	}

	// 法线：取主纹理的法线贴图，按世界 XZ 近似扰动
	vec2 tuv = fract(uv) * 0.985 + 0.0075;
	vec2 cellN = vec2(float(t0 % 4), floor(float(t0) / 4.0)) * (1.0 / atlas_n);
	vec3 tn = texture(ground_normal, cellN + tuv * (1.0 / atlas_n)).rgb * 2.0 - 1.0;
	float nstr = normal_strength * (1.0 - smoothstep(60.0, 200.0, distance(wpos, CAMERA_POSITION_WORLD)));

	// 两套尺度混合：近尺度 13m、远尺度 78m，压掉重复感
	vec2 uv_big = uv * 0.17 + vec2(13.7, 5.3);
	// 材质偏置：砂质地表更偏沙/砾，岩质地表更偏碎石/岩石
	if (mat == 1) {
		t0 = 7;
		t1 = 4;
	} else if (mat == 2) {
		t0 = 5;
		t1 = 6;
	}
	vec3 grass = mix(tile_at(uv, t0), tile_at(uv_big, t0), 0.30);
	vec3 lush = mix(tile_at(uv, t1), tile_at(uv_big, t1), 0.30);
	vec3 dry = mix(tile_at(uv, t2), tile_at(uv_big, t2), 0.30);
	vec3 soil = mix(tile_at(uv, t3), tile_at(uv_big, t3), 0.30);
	vec3 gravel = tile_at(uv, 5);
	vec3 rock = tile_at(uv, 6);
	vec3 snowt = tile_at(uv, 8);

	// 多尺度斑块：让 4 张贴图在同一片地里自然交错（草地/枯草/裸土/砾石）
	float p_big = texture(noise_tex, wpos.xz * 0.0045).r;                          // 约 220 m 斑块
	float p_mid = texture(noise_tex, wpos.xz * 0.017 + vec2(0.37, 0.11)).r;       // 约 60 m 斑块
	float p_fine = texture(noise_tex, wpos.xz * 0.055 + vec2(0.71, 0.43)).r;      // 约 20 m 斑块

	vec3 ground = grass;
	ground = mix(ground, lush, smoothstep(0.34, 0.62, p_big));
	ground = mix(ground, dry, smoothstep(0.48, 0.72, p_mid));
	ground = mix(ground, soil, smoothstep(0.52, 0.74, p_fine) * 0.75);
	// 干湿仍然大范围地影响枯/绿比例
	ground = mix(ground, dry, smoothstep(0.60, 0.82, dryness) * 0.6);
	// 陡坡露岩、碎石
	ground = mix(ground, mix(gravel, rock, smoothstep(0.55, 0.85, slope)),
			smoothstep(0.42, 0.62, slope));
	ground = mix(ground, snowt, snow);

	vec3 c = COLOR.rgb;
	c *= 0.86 + 0.24 * fine;
	c *= 0.94 + 0.12 * mid;
	c = mix(c * tint_b, c * tint_a, macro * 0.85);

	// 远处淡出纹理（否则重复贴图在掠射角会产生同心摩尔纹）
	float dfade = 1.0 - smoothstep(120.0, 520.0, distance(wpos, CAMERA_POSITION_WORLD));
	float ts = tex_strength * dfade;
	// 3m 级微颗粒，近看才有的细节
	float micro = texture(noise_tex, wpos.xz * 0.32).r;
	ground *= 0.92 + 0.16 * micro;
	ALBEDO = mix(c, ground * (0.85 + 0.30 * dot(c, vec3(0.33))), ts);
	NORMAL = normalize(wnrm + vec3(tn.x, 0.0, tn.y) * 0.45 * nstr);
	ROUGHNESS = mix(0.97, 0.88, smoothstep(0.45, 0.8, slope));
	SPECULAR = 0.06;
}
