shader_type canvas_item;
render_mode unshaded;

// 世界地图：逐像素从高程纹理算地势阴影；地貌配色来自预烘焙编号图，
// 高倍时改用后台按真源（TG.landform_kind）现烘的细节层，避免 13~16 px 色块。
uniform sampler2D dem_tex : filter_linear, repeat_disable;
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform vec2 dem_size = vec2(8192.0, 4096.0);
uniform float shade_alpha = 0.62;
uniform float shade_gain = 1.0;
uniform float pat_period = 4.0;   // 符号间距（公里），由缩放决定
uniform float lat_limit = 85.0;
uniform sampler2D palette_tex : filter_nearest, repeat_disable;
uniform sampler2D palette_fine_tex : filter_nearest, repeat_disable;   // 29 类本色（高倍用）
uniform float pal_fine = 0.0;                 // 0=分组色（世界尺度）1=一地形一色（高倍）
uniform sampler2D landform_tex : filter_nearest, repeat_disable;

// 细节层：R = 地貌编号，G = 阴影，B = 水线标记，A = 该 texel 已烘好。
// 贴在地理坐标上，拖动时留在原位；未烘到的区域仍显示编号图。
uniform sampler2D detail_tex : filter_nearest, repeat_disable;
uniform vec2 detail_org = vec2(0.0, 0.0);    // 细节层左上角（世界 uv）
uniform vec2 detail_span = vec2(1.0, 1.0);   // 细节层覆盖的 uv 范围
uniform float detail_on = 0.0;
uniform float detail_reveal = 1e9;           // 揭开半径（屏幕像素，从屏幕中心算）
uniform float detail_band = 40.0;            // 揭开环的过渡带宽（屏幕像素）
uniform float detail_fade = 1.0;             // 整体淡出（换窗口/缩放时用）
uniform float water_ink = 1.0;               // 水线浓度
uniform float zoom = 1.0;                    // 当前缩放倍率（符号在高倍减淡）
uniform float dbg2 = 0.0;                    // 1 = 输出细节层覆盖率，2 = 输出 duv（对位排查）

vec3 pal(float i) {
	return texture(palette_tex, vec2((i + 0.5) / 32.0, 0.5)).rgb;
}

vec3 pal2(float i) {
	return texture(palette_fine_tex, vec2((i + 0.5) / 32.0, 0.5)).rgb;
}

// 一个地貌号对应的颜色（水单独一色）
vec3 lf_color(float id) {
	if (id > 10.5 && id < 11.5) {
		return vec3(0.26, 0.33, 0.40);
	}
	return mix(pal(id), pal2(id), pal_fine);
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
	vec2 uv = vec2(clamp(UV.x, 0.0, 1.0), clamp(mix(v0, v1, UV.y), v0, v1));
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

	// —— 地貌编号 + 配色 ——
	// 粗层：预烘焙编号图（8192，一格 2.3 km）
	float lid = floor(texture(landform_tex, uv).r * 255.0 + 0.5);
	float fw = max(fwidth(h), 0.5);
	float coast = 1.0 - smoothstep(0.45, 1.50, abs(h + 8.0) / fw);
	vec3 c = lf_color(lid);

	// 细节层：贴在地理坐标上，边界淡出、A 通道表示“这块烘好了”。
	// 揭开：以**屏幕中心**为圆心、半径 detail_reveal 向外扫，环带内做软过渡，
	// 所以细节是“从中间慢慢扩散”出来的，不会一块一块跳。
	float g_cov = 0.0;
	vec2 g_duv = vec2(0.0);
	if (detail_on > 0.5) {
		vec2 duv = (uv - detail_org) / detail_span;
		vec4 dt = texture(detail_tex, clamp(duv, 0.0, 1.0));
		vec2 e0 = smoothstep(vec2(0.0), vec2(0.02), duv);
		vec2 e1 = smoothstep(vec2(0.0), vec2(0.02), vec2(1.0) - duv);
		// 屏幕像素坐标 → 到屏幕中心的距离 → 揭开环
		vec2 spx = SCREEN_UV / SCREEN_PIXEL_SIZE;
		float dpx = distance(spx, 0.5 / SCREEN_PIXEL_SIZE);
		// 云雾/水墨边：两层噪声把“圆环”扰成不规则的墨晕，宽度也随噪声起伏
		float n1 = texture(noise_tex, spx * 0.0022).r - 0.5;
		float n2 = texture(noise_tex, spx * 0.0068 + vec2(0.31, 0.67)).r - 0.5;
		float edge = detail_reveal + n1 * 110.0 + n2 * 45.0;
		float band = detail_band * (0.75 + 0.7 * (n2 + 0.5));
		float ring = 1.0 - smoothstep(edge, edge + band, dpx);
		float cov = e0.x * e0.y * e1.x * e1.y * dt.a * ring * detail_fade;
		g_cov = cov;
		g_duv = duv;
		if (cov > 0.002) {
			float lid_d = floor(dt.r * 255.0 + 0.5);
			c = mix(c, lf_color(lid_d), cov);
			shade = mix(shade, dt.g, cov);
			coast = max(coast * (1.0 - cov), dt.b * cov);
			lid = mix(lid, lid_d, cov);
		}
	}
	float is_water = (lid > 10.5 && lid < 11.5) ? 1.0 : 0.0;

	// —— 地貌符号（舆图风格）：按类别画不同的纹理，密度随缩放调整 ——
	{
		float slope_p = length(vec2(sx, sy));
		float kmx = uv.x * 360.0 * 111.32 * cos(radians(lat));
		float kmy = uv.y * 180.0 * 110.54;
		float px = max(pat_period, 0.02);
		// 沙丘 / 荒漠：无方向细颗粒（不再画弧线与走向）
		vec2 gp = vec2(kmx, kmy) / px;
		float g1 = texture(noise_tex, gp * 1.15 + vec2(0.13, 0.41)).r;
		float g2 = texture(noise_tex, gp * 2.90 + vec2(0.71, 0.23)).r;
		float grain = smoothstep(0.50, 0.76, g1 * 0.55 + g2 * 0.45);
		float dune_ink = grain * 0.50;
		// 戈壁/砾石：点阵
		vec2 cell = fract(vec2(kmx / px, kmy / px)) - 0.5;
		float dot_p = 1.0 - smoothstep(0.10, 0.20, length(cell));
		// 山地：顺坡短划（晕滃），密度随坡度；高倍时淡出（10 px 周期线条会起摩尔纹）
		float fade_ln = 1.0 - smoothstep(40.0, 85.0, zoom);
		float ang = atan(sy, sx);
		float hach = abs(fract((kmx * cos(ang) + kmy * sin(ang)) / (px * 0.8)) - 0.5);
		float hach_line = (1.0 - smoothstep(0.04, 0.12, hach))
				* clamp(slope_p * 1.6, 0.0, 1.0) * fade_ln;
		// 平地：极淡横划
		float dash = abs(fract((kmy) / (px * 1.6)) - 0.5);
		float dash_line = (1.0 - smoothstep(0.01, 0.05, dash)) * 0.35 * fade_ln;

		float ink = 0.0;
		if (lid > 5.5 && lid < 6.5) ink = dune_ink * 0.70;            // 荒漠
		else if (lid > 14.5 && lid < 15.5) ink = dune_ink * 0.90;     // 沙丘
		else if (lid > 25.5 && lid < 26.5) ink = dune_ink * 0.85;     // 沙质荒漠
		else if (lid > 26.5 && lid < 27.5) ink = dot_p * 0.55;        // 砾质荒漠
		else if (lid > 12.5 && lid < 13.5) ink = dot_p * 0.45;        // 雅丹
		else if (lid > 27.5 && lid < 28.5) ink = dot_p * 0.35;        // 盐碱
		else if (lid > 11.5 && lid < 12.5) ink = dot_p * 0.75;        // 喀斯特（峰丛）
		else if (lid > 18.5 && lid < 19.5) ink = dot_p * 0.55;        // 喀斯特山地
		else if (lid > 1.5 && lid < 2.5) ink = hach_line * 0.55;      // 山地
		else if (lid > 17.5 && lid < 18.5) ink = hach_line * 0.60;    // 花岗岩山地
		else if (lid > 19.5 && lid < 20.5) ink = hach_line * 0.45;    // 黄土山地
		else if (lid > 20.5 && lid < 21.5) ink = hach_line * 0.45;    // 火山山地
		else if (lid > 21.5 && lid < 22.5) ink = hach_line * 0.40;    // 冰蚀山地
		else if (lid > -0.5 && lid < 1.5) ink = dash_line * 0.30;     // 平原/丘陵
		else if (lid > 6.5 && lid < 9.5) ink = dash_line * 0.22;      // 草原/森林/湿地
		else if (lid > 13.5 && lid < 14.5) ink = dot_p * 0.30;        // 黄土
		// 高倍时符号淡出：这个尺度上靠阴影读地形，符号只会变成噪点
		ink *= mix(1.0, 0.0, smoothstep(40.0, 90.0, zoom));
		c *= 1.0 - ink * 0.35;
	}

	// 水陆交界浅线：陆地侧提亮，水面侧压一点青色
	if (coast > 0.001) {
		vec3 wl = mix(vec3(0.62, 0.64, 0.55), vec3(0.44, 0.57, 0.65), is_water);
		c = mix(c, wl, 0.34 * coast * water_ink);
	}

	// 古地图纸色
	float lum = dot(c, vec3(0.35, 0.45, 0.20));
	vec3 paper = vec3(lum + 0.16, lum * 0.92 + 0.11, lum * 0.72 + 0.04);
	c = mix(c, paper, 0.12);

	// 阴影叠上去
	c = mix(c, vec3(0.30, 0.27, 0.22) * (0.45 + 0.75 * shade), shade_alpha);
	if (dbg2 > 0.5) {
		c = (dbg2 > 1.5) ? vec3(g_duv, 0.0) : vec3(g_cov, 0.0, 0.0);
	}
	COLOR = vec4(c, 1.0);
}
