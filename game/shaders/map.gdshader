shader_type canvas_item;
render_mode unshaded;

// 世界地图：逐像素从高程纹理算地势阴影；地貌配色来自预烘焙编号图，
// 高倍时改用后台按真源（TG.landform_kind）现烘的细节层，避免 13~16 px 色块。
uniform sampler2D dem_tex : filter_linear, repeat_disable;
uniform sampler2D noise_tex : filter_linear, repeat_enable;
uniform vec2 dem_size = vec2(8192.0, 4096.0);
uniform float shade_alpha = 0.62;
uniform float shade_gain = 1.0;
uniform float lat_limit = 85.0;
uniform sampler2D palette_tex : filter_nearest, repeat_disable;
uniform sampler2D color_tex : filter_linear, repeat_disable;   // 离线高程配色
uniform sampler2D hill_tex : filter_linear, repeat_disable;    // 离线 Hillshade   // 29 类本色（唯一一套调色板）
uniform sampler2D landform_tex : filter_nearest, repeat_disable;

// 细节层：R = 地貌编号，G = 阴影，B = 水线标记，A = 该 texel 已烘好。
// 贴在地理坐标上，拖动时留在原位；未烘到的区域仍显示编号图。
uniform sampler2D detail_tex : filter_nearest, repeat_disable;
uniform vec2 detail_org = vec2(0.0, 0.0);    // 细节层左上角（世界 uv）
uniform vec2 detail_span = vec2(1.0, 1.0);   // 细节层覆盖的 uv 范围
uniform float detail_on = 0.0;
uniform float detail_fade = 1.0;             // 整体淡出（换窗口/缩放时用）
uniform float water_ink = 1.0;               // 水线浓度
uniform float zoom = 1.0;                    // 当前缩放倍率（符号在高倍减淡）
uniform float dbg2 = 0.0;                    // 1 = 输出细节层覆盖率，2 = 输出 duv（对位排查）

// 一个地貌号对应的颜色（水单独一色）
// 只有一套调色板（29 类本色，由 main.gd 的 TG.landform_color 生成）：
// 编号图路径和细节层路径都走这里，所以跨 60 倍不会变色。
// id 11 同时代表"海（h < -8）"和"贴着海的低海岸（0..8 m）"：必须按高程区分，
// 否则江苏/渤海那种 2–5 米的平原会被涂成海水蓝。
vec3 lf_color(float id) {
	if (id > 10.5 && id < 11.5) {
		return vec3(0.26, 0.33, 0.40);
	}
	return texture(palette_tex, vec2((id + 0.5) / 32.0, 0.5)).rgb;
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


// 高程配色：低饱和羊皮纸色系，按海拔连续过渡（古行军图底）
vec3 elev_color(float h) {
	if (h < 0.0) {
		// 海：浅蓝灰 → 深蓝灰
		float d = clamp(-h / 4000.0, 0.0, 1.0);
		return mix(vec3(0.56, 0.62, 0.66), vec3(0.26, 0.34, 0.44), d);
	}
	vec3 c = vec3(0.90, 0.85, 0.70);                       // 平原：淡米
	c = mix(c, vec3(0.80, 0.74, 0.58), smoothstep(50.0, 300.0, h));
	c = mix(c, vec3(0.72, 0.63, 0.47), smoothstep(300.0, 900.0, h));
	c = mix(c, vec3(0.68, 0.58, 0.44), smoothstep(900.0, 2000.0, h));
	c = mix(c, vec3(0.58, 0.50, 0.40), smoothstep(2000.0, 3500.0, h));
	c = mix(c, vec3(0.50, 0.44, 0.37), smoothstep(3500.0, 5000.0, h));
	return c;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
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

float fbm3(vec2 p) {
	float v = 0.0;
	v += vnoise(p) * 0.55;
	v += vnoise(p * 2.13) * 0.28;
	v += vnoise(p * 4.37) * 0.17;
	return v;
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
	float coast = 1.0 - smoothstep(0.45, 1.50, abs(h + 2.0) / fw);
	vec3 c = lf_color(lid);
	// 有离线底图就直接用它（高程配色），不再走分类色
	float sh2 = 1.0;
	if (textureSize(color_tex, 0).x > 1) {
		vec2 cuv = vec2(uv.x, clamp(uv.y, 0.0, 1.0));
		vec2 px = 1.0 / vec2(textureSize(color_tex, 0));
		c = texture(color_tex, cuv).rgb;
		sh2 = texture(hill_tex, cuv).r;
		// 高倍锐化：双击取四邻平均做非锐化掩膜，把放大后的双线性糊边拉回来
		float hi0 = smoothstep(60.0, 160.0, zoom);
		if (hi0 > 0.001) {
			vec3 avg = (texture(color_tex, cuv + vec2(px.x, 0.0)).rgb
					+ texture(color_tex, cuv - vec2(px.x, 0.0)).rgb
					+ texture(color_tex, cuv + vec2(0.0, px.y)).rgb
					+ texture(color_tex, cuv - vec2(0.0, px.y)).rgb) * 0.25;
			c = mix(c, clamp(c + (c - avg) * 2.2, 0.0, 1.0), hi0);
		}
	}

	// 细节层：贴在地理坐标上。A 通道 = 这块 texel 已烘好（块级 255/0），
	// 所以粗细交界就是烘焙前沿——烘好一块显示一块，不做任何圆环/云雾遮罩。
	float g_cov = 0.0;
	vec2 g_duv = vec2(0.0);
	if (detail_on > 0.5) {
		vec2 duv = (uv - detail_org) / detail_span;
		vec4 dt = texture(detail_tex, clamp(duv, 0.0, 1.0));
		vec2 e0 = smoothstep(vec2(0.0), vec2(0.02), duv);
		vec2 e1 = smoothstep(vec2(0.0), vec2(0.02), vec2(1.0) - duv);
		float cov = e0.x * e0.y * e1.x * e1.y * dt.a * detail_fade;
		g_cov = cov;
		g_duv = duv;
		if (cov > 0.002) {
			float lid_d = floor(dt.r * 255.0 + 0.5);
			// 用户 2026-11-19：细版不要模糊，边界保持锐利（不加抗锯齿/距离场混合）
			c = mix(c, lf_color(lid_d), cov);
			shade = mix(shade, dt.g, cov);
			coast = max(coast * (1.0 - cov), dt.b * cov);
			lid = mix(lid, lid_d, cov);
		}
	}
	// LOD：放大后改用高程连续配色（分类纯色只留给低倍总览）
	float elev_on = smoothstep(18.0, 45.0, zoom);
	if (elev_on > 0.001) {
		vec3 ec = elev_color(h);
		c = mix(c, ec, elev_on);
	}
	float is_water = (lid > 10.5 && lid < 11.5) ? 1.0 : 0.0;

	// —— 海面：按逐像素高程判定海陆（不用 4.9km 的编号图，否则放大后是方块台阶）——
	float wf = max(fwidth(h) * 1.2, 0.4);
	// 海岸细节：在 0 米附近叠分形扰动，让海岸线曲折起来（越高倍越明显，幅度不超过几米）
	float coast_band = 1.0 - smoothstep(0.0, 12.0, abs(h));
	float czoom = smoothstep(25.0, 90.0, zoom);
	float cn = 0.0;
	if (coast_band > 0.001 && czoom > 0.001) {
		vec2 cp = vec2(uv.x, uv.y);
		cn = (vnoise(cp * 9000.0) - 0.5) * 0.60
		   + (vnoise(cp * 21000.0) - 0.5) * 0.28
		   + (vnoise(cp * 46000.0) - 0.5) * 0.12;
		cn *= coast_band * czoom * 2.2;           // ±1~2 m：只让岸线起小凹湾，不整片翻转          // 幅度：±几米，够让海岸曲折但不至于撕裂
	}
	float wmask = smoothstep(-wf, wf, -(h + cn));          // 0=纯陆 1=纯水，边界 1-2 像素过渡
	if (wmask > 0.001) {
		float depth = clamp(-h / 3500.0, 0.0, 1.0);
		vec3 shall = vec3(0.47, 0.55, 0.55);
		vec3 deepc = vec3(0.27, 0.34, 0.39);
		vec3 sea = mix(shall, deepc, smoothstep(0.0, 1.0, depth));
		// 水纹：横向细纹，越深越淡
		float wy = texture(noise_tex, vec2(uv.x * 300.0, uv.y * 2600.0)).r;
		float wave = smoothstep(0.55, 0.95, wy) * (1.0 - 0.7 * depth);
		sea = mix(sea, vec3(0.62, 0.68, 0.70), 0.05 * wave * clamp(zoom / 60.0, 0.0, 1.0));
		c = mix(c, sea, wmask);
	}

	// 高山雪：雪线随纬度（和 3D terrain.gdshader 的 snow_line 同一公式），只落在陆地上。
	// 2D 以前只有极地冰盖，阿尔卑斯/喜马拉雅在图上都是灰褐色。
	if (is_water < 0.5) {
		float sn = clamp(4800.0 - 45.0 * abs(lat), 600.0, 5200.0);
		float snow = smoothstep(sn, sn + 450.0, h) * 0.82;
		if (snow > 0.002) c = mix(c, vec3(0.93, 0.93, 0.91), snow);
	}

	// 地貌符号层已移除（2026-11-17 用户要求：2D 舆图所有地形一律纯色，不画点阵/短划/晕滃）。
	// 要恢复可查 git 历史（或重新接回一张类别查表纹理）。

	// 海岸线：一条压暗的墨线 + 内侧浅线，放大后不至于糊成一片
	if (coast > 0.001) {
		vec3 wl = mix(vec3(0.62, 0.64, 0.55), vec3(0.44, 0.57, 0.65), is_water);
		c = mix(c, wl, 0.34 * coast * water_ink);
		float ink = smoothstep(0.72, 1.0, coast) * smoothstep(30.0, 120.0, zoom) * is_water;   // 只画海侧，免得陆上冒出一堆线
		c = mix(c, vec3(0.32, 0.35, 0.31), 0.30 * ink * water_ink);
	}

	// 古地图纸色
	float lum = dot(c, vec3(0.35, 0.45, 0.20));
	vec3 paper = vec3(lum + 0.16, lum * 0.92 + 0.11, lum * 0.72 + 0.04);
	c = mix(c, paper, 0.07);
	// 越放大越往纸色靠（最高 30%）、顺带降对比 —— 地形只是旅行图的底。
	float paperize = clamp((zoom - 3.0) / 50.0, 0.0, 1.0) * 0.30;
	c = mix(c, paper, paperize);

	// —— 4.9km 以下的细节：真实数据到不了，分三层“画”出来 ——
	//   ① 水彩晕染（低频斑块，很轻）② 纸纤维（极细颗粒）③ 陡坡微阴影
	float slope = length(vec2(sx, sy)) * 0.0016;
	float rough = smoothstep(0.05, 0.9, slope);
	float det_on = smoothstep(22.0, 65.0, zoom);
	if (det_on > 0.001) {
		vec2 wp = vec2(uv.x, uv.y) * 2600.0;
		// ① 水彩：两个尺度叠加，域扭曲打散方格
		vec2 wq = wp * 0.22 + vec2(fbm3(wp * 0.11), fbm3(wp * 0.11 + 5.7)) * 2.4;
		float m1 = fbm3(wq);
		float m2 = fbm3(wq * 2.7 + 31.7);
		float mottle = (m1 - 0.5) * 0.62 + (m2 - 0.5) * 0.38;
		c *= 1.0 + mottle * 0.13 * det_on;
		// ② 纸纤维：高频细颗粒，几乎不改变明暗，只加“纸感”
		float fiber = vnoise(wp * 21.0) * 0.6 + vnoise(wp * 53.0) * 0.4 - 0.5;
		c += vec3(fiber) * (0.028 * det_on);
		// ③ 陡坡微阴影：顺着西北光加一点高频起伏，平原没有
		float n0 = fbm3(wp);
		float nx = fbm3(wp + vec2(0.08, 0.0));
		float ny = fbm3(wp + vec2(0.0, 0.08));
		float bump = (nx - n0) * 2.0 + (ny - n0) * 2.6;
		c *= 1.0 + clamp(bump, -1.0, 1.0) * 0.22 * rough * det_on;
	}

	// —— 高倍：底图是 4.9km/px 的拉伸，再往下放大只会更糊；
	//    这里往纸色推 + 叠纸纤维噪声，让它读起来像"手绘纸面"而不是"放大的位图" ——
	float hi = smoothstep(40.0, 130.0, zoom);
	if (hi > 0.001) {
		c = mix(c, paper, 0.04 * hi);
		vec2 guv = vec2(uv.x * 620.0, uv.y * 620.0);   // 世界坐标，拖图时跟着地图走
		float g1 = texture(noise_tex, guv).r;
		float g2 = texture(noise_tex, guv * 3.3 + vec2(0.37, 0.21)).r;
		float grain = (g1 * 0.62 + g2 * 0.38) - 0.5;
		c += vec3(grain) * (0.085 * hi);
		// 轻微色阶化：把渐变压成几档，观感更像手工上色
		c = mix(c, floor(c * 26.0 + 0.5) / 26.0, 0.10 * hi);
	}

	// 阴影叠上去
	c = mix(c, c * (0.66 + 0.42 * sh2), 0.85);
	c = mix(c, vec3(0.30, 0.27, 0.22) * (0.45 + 0.75 * shade), shade_alpha * 0.35);
	if (dbg2 > 0.5) {
		c = (dbg2 > 1.5) ? vec3(g_duv, 0.0) : vec3(g_cov, 0.0, 0.0);
	}
	COLOR = vec4(c, 1.0);
}
