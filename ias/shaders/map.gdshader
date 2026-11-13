shader_type canvas_item;
render_mode unshaded;

// 世界地图：逐像素从高程纹理算地貌配色 + 地势阴影，放大到任意倍数都不会出现色块。
uniform sampler2D dem_tex : filter_linear, repeat_disable;
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform vec2 dem_size = vec2(8192.0, 4096.0);
uniform float shade_alpha = 0.62;
uniform float shade_gain = 1.0;

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
	vec2 uv = UV;
	float lat = mix(90.0, -90.0, uv.y);
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

	// 逐像素地貌配色：不依赖低分辨率贴图，放大不会糊
	float slope = length(vec2(sx, sy)) * 1000.0;   // 竖向/水平（千分比）
	float moist = texture(noise_tex, vec2(uv.x * 9.0, uv.y * 9.0)).r;
	float moist2 = texture(noise_tex, vec2(uv.x * 23.0 + 0.31, uv.y * 23.0 + 0.77)).r;
	float wet = mix(moist, moist2, 0.35);

	vec3 ocean  = vec3(0.24, 0.32, 0.40);
	vec3 sand   = vec3(0.80, 0.72, 0.50);
	vec3 steppe = vec3(0.70, 0.66, 0.42);
	vec3 grass  = vec3(0.52, 0.56, 0.34);
	vec3 forest = vec3(0.30, 0.42, 0.24);
	vec3 rock   = vec3(0.46, 0.44, 0.40);
	vec3 rock_d = vec3(0.38, 0.36, 0.33);
	vec3 snow   = vec3(0.90, 0.92, 0.93);

	vec3 c = grass;
	c = mix(c, forest, smoothstep(0.52, 0.72, wet));
	c = mix(c, steppe, smoothstep(0.46, 0.26, wet));
	c = mix(c, sand, smoothstep(0.22, 0.10, wet) * smoothstep(-200.0, 600.0, h));
	// 高海拔压灰、雪线以上变白
	c = mix(c, rock, smoothstep(2200.0, 3600.0, h) * 0.55);
	c = mix(c, rock_d, smoothstep(0.10, 0.30, slope) * 0.55);
	float snow_line = 5200.0 - max(abs(lat) - 30.0, 0.0) * 110.0;
	c = mix(c, snow, smoothstep(snow_line - 400.0, snow_line, h));
	if (abs(lat) > 72.0 && h < 400.0) c = vec3(0.88, 0.92, 0.94);
	c = mix(c, ocean, step(h, -8.0));

	// 古地图纸色
	float lum = dot(c, vec3(0.35, 0.45, 0.20));
	vec3 paper = vec3(lum + 0.16, lum * 0.92 + 0.11, lum * 0.72 + 0.04);
	c = mix(c, paper, 0.30);

	// 阴影叠上去
	c = mix(c, vec3(0.30, 0.27, 0.22) * (0.45 + 0.75 * shade), shade_alpha);
	COLOR = vec4(c, 1.0);
}
