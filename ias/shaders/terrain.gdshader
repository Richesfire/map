shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// 地形表面：地表纹理图集（4x4）按坡度/海拔/干湿混合，再乘顶点色与三平面噪声
uniform sampler2D noise_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ground_atlas : source_color, filter_linear, repeat_enable;
uniform sampler2D ground_normal : hint_normal, filter_linear, repeat_enable;
// 地貌 → 4 张贴图索引的查表（128x1，索引 = lf + mat*32）
uniform sampler2D kind_tex : filter_nearest, repeat_disable;
uniform float normal_strength = 1.55;
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

// 查表：(t0,t1,t2,t3) 存成 index*17，读回时还原成 0..15
vec4 lf_tiles(float pid) {
	vec4 v = texture(kind_tex, vec2((pid + 0.5) / 128.0, 0.5));
	return floor(v * 255.0 / 17.0 + 0.5);
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

	// 地貌 id 从顶点色 alpha 传进来（lf + mat*32），第二个 id 与权重走 UV2：
	// 相邻两顶点用同一对 id（min/max），插值不会串类别，权重负责把硬边过渡开
	float pa = floor(COLOR.a * 128.0 + 0.5);
	float pb = floor(UV2.x * 128.0 + 0.5);
	float wb = clamp(UV2.y, 0.0, 1.0);
	vec4 ta = lf_tiles(pa);
	vec4 tb = lf_tiles(pb);
	int t0 = int(ta.x);
	int t1 = int(ta.y);
	int t2 = int(ta.z);
	int t3 = int(ta.w);
	int b0 = int(tb.x);
	int b1 = int(tb.y);
	int b2 = int(tb.z);
	int b3 = int(tb.w);

	// 法线：取主纹理的法线贴图，按世界 XZ 近似扰动
	vec2 tuv = fract(uv) * 0.985 + 0.0075;
	vec2 cellN = vec2(float(t0 % 4), floor(float(t0) / 4.0)) * (1.0 / atlas_n);
	vec3 tn = texture(ground_normal, cellN + tuv * (1.0 / atlas_n)).rgb * 2.0 - 1.0;
	float nstr = normal_strength * (1.0 - smoothstep(140.0, 460.0, distance(wpos, CAMERA_POSITION_WORLD)));

	// 两套尺度混合：近尺度 13m、远尺度 78m，压掉重复感
	vec2 uv_big = uv * 0.17 + vec2(13.7, 5.3);
	// 旋转 + 缩放的第二层，专门用来打散贴图重复感
	vec2 uv_rot = vec2(uv.x * 0.82 + uv.y * 0.57, -uv.x * 0.57 + uv.y * 0.82) * 1.63 + vec2(41.3, 17.9);
	vec3 grass = mix(mix(tile_at(uv, t0), tile_at(uv_big, t0), 0.30), tile_at(uv_rot, t0), 0.34);
	vec3 lush = mix(mix(tile_at(uv, t1), tile_at(uv_big, t1), 0.30), tile_at(uv_rot, t1), 0.34);
	vec3 dry = mix(mix(tile_at(uv, t2), tile_at(uv_big, t2), 0.30), tile_at(uv_rot, t2), 0.34);
	vec3 soil = mix(mix(tile_at(uv, t3), tile_at(uv_big, t3), 0.30), tile_at(uv_rot, t3), 0.34);
	// 第二套贴图只在近尺度取一次：权重最大 0.75，远尺度看不出来
	if (wb > 0.002) {
		grass = mix(grass, tile_at(uv, b0), wb);
		lush = mix(lush, tile_at(uv, b1), wb);
		dry = mix(dry, tile_at(uv, b2), wb);
		soil = mix(soil, tile_at(uv, b3), wb);
	}
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
	ground = mix(ground, mix(gravel, rock, smoothstep(0.45, 0.80, slope)),
			smoothstep(0.30, 0.56, slope));
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
	float hump = texture(noise_tex, wpos.xz * 0.021).r - texture(noise_tex, wpos.xz * 0.047 + vec2(5.7, 2.3)).r;
	vec3 bump_n = vec3(hump * 0.55, 0.0, hump * 0.55) * (1.0 - smoothstep(80.0, 300.0, distance(wpos, CAMERA_POSITION_WORLD)));
	NORMAL = normalize(wnrm + vec3(tn.x, 0.0, tn.y) * 0.55 * nstr + bump_n);
	ROUGHNESS = mix(0.97, 0.88, smoothstep(0.45, 0.8, slope));
	SPECULAR = 0.06;
}
