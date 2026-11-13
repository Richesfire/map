shader_type canvas_item;
render_mode unshaded;

// 世界地图：逐像素从高程纹理算地貌配色 + 地势阴影，放大到任意倍数都不会出现色块。
uniform sampler2D dem_tex : filter_linear, repeat_disable;
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform vec2 dem_size = vec2(8192.0, 4096.0);
uniform float shade_alpha = 0.62;
uniform float shade_gain = 1.0;
uniform float lat_limit = 85.0;
uniform sampler2D palette_tex : filter_nearest, repeat_disable;
uniform sampler2D landform_tex : filter_nearest, repeat_disable;

vec3 pal(float i) {
	return texture(palette_tex, vec2((i + 0.5) / 32.0, 0.5)).rgb;
}

float h_at(vec2 uv) {
	return texture(dem_tex, uv).r * 20000.0 - 11000.0;
}

// 与 GDScript 同一套：温度带(9) × 湿度带(5)，高地变体压灰
vec3 biome(float lat, float h, float moist) {
	float alat = abs(lat);
	float temp = 28.0 - 0.42 * alat - 0.0062 * max(h, 0.0) + (moist - 0.5) * 7.0;
	float snowline = 5800.0 - max(alat - 30.0, 0.0) * 110.0;
	float belt = clamp(1.0 - abs(alat - 25.0) / 13.0, 0.0, 1.0);
	float m = moist * (1.0 - 0.62 * belt);

	if (h < -8.0) return vec3(0.09, 0.17, 0.25);
	if (alat > 73.0 && h < 500.0) return vec3(0.91, 0.94, 0.96);
	if (h > snowline) return vec3(0.92, 0.93, 0.94);
	if (h > 3400.0 && temp < 6.0) return vec3(0.49, 0.46, 0.41);

	float tb = clamp(floor((temp + 12.0) / 6.0), 0.0, 8.0);
	float mb = clamp(floor(m * 5.0), 0.0, 4.0);
	float t01 = tb / 8.0;
	float m01 = mb / 4.0;

	vec3 dry = vec3(0.60, 0.55, 0.38);
	vec3 wet = vec3(0.19, 0.32, 0.15);
	vec3 c = mix(dry, wet, pow(m01, 0.85));
	float cold = clamp(1.0 - t01 * 1.7, 0.0, 1.0);
	c = mix(c, vec3(0.46, 0.48, 0.42), cold * 0.42);
	if (h > 1200.0) c = mix(c, vec3(0.40, 0.38, 0.33), 0.22);
	return c;
}

void fragment() {
	// 可见区是 ±lat_limit，贴图仍是整幅世界：把屏幕 uv 映射到世界 uv
	float v0 = (90.0 - lat_limit) / 180.0;
	float v1 = (90.0 + lat_limit) / 180.0;
	vec2 uv = vec2(UV.x, mix(v0, v1, UV.y));
	float lat = mix(lat_limit, -lat_limit, UV.y);
	float h = h_at(uv);

	// 地势阴影：按 DEM 邻域求坡向（固定西北来光）
	vec2 texel = 1.0 / dem_size;
	float hx = h_at(uv + vec2(texel.x, 0.0));
	float hy = h_at(uv + vec2(0.0, texel.y));
	float km_x = max(40075.0 * cos(radians(lat)) / dem_size.x, 0.5);
	float km_y = 20004.0 / dem_size.y;
	float sx = (hx - h) / km_x;
	float sy = (hy - h) / km_y;
	float shade = clamp(0.62 - (sx * 0.55 + sy * 0.75) * 0.0030 * shade_gain, 0.16, 1.0);

	// 地貌配色：直接取预烘焙的地貌编号 → 游戏同一套 29 色
	float lid = floor(texture(landform_tex, uv).r * 255.0 + 0.5);
	vec3 c = (lid > 10.5 && lid < 11.5) ? vec3(0.26, 0.33, 0.40) : pal(lid);

	// 古地图纸色
	float lum = dot(c, vec3(0.35, 0.45, 0.20));
	vec3 paper = vec3(lum + 0.16, lum * 0.92 + 0.11, lum * 0.72 + 0.04);
	c = mix(c, paper, 0.12);

	// 阴影叠上去
	c = mix(c, vec3(0.30, 0.27, 0.22) * (0.45 + 0.75 * shade), shade_alpha);
	COLOR = vec4(c, 1.0);
}
