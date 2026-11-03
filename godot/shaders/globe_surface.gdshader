shader_type spatial;

// ==============================================================
// 地球仪表面：地形贴图 + 未探索区域的旧地图迷雾
//
// fog_tex 的 r 通道：1 = 已探索，0 = 未探索
// 未探索区域压成羊皮纸色，只隐约透出一点地形轮廓
// ==============================================================

uniform sampler2D albedo_tex : source_color, filter_linear, repeat_enable;
uniform sampler2D fog_tex : filter_linear, repeat_enable;
uniform vec3 fog_color : source_color = vec3(0.78, 0.70, 0.52);
uniform float fog_enabled = 1.0;

// ---- 区域高清叠加：放大到一定程度时，用一张只覆盖可见范围的图替换底图
uniform sampler2D detail_tex : source_color, filter_linear;
uniform vec2 detail_uv_min = vec2(0.0);
uniform vec2 detail_uv_max = vec2(0.0);
uniform float detail_enabled = 0.0;

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;

	// 区域图覆盖范围内，改用高清图（UV 换算到区域局部坐标）
	if (detail_enabled > 0.5) {
		vec2 span = detail_uv_max - detail_uv_min;
		if (UV.x >= detail_uv_min.x && UV.x <= detail_uv_max.x &&
				UV.y >= detail_uv_min.y && UV.y <= detail_uv_max.y &&
				span.x > 0.0 && span.y > 0.0) {
			vec2 duv = (UV - detail_uv_min) / span;
			base = texture(detail_tex, duv).rgb;
		}
	}
	float explored = texture(fog_tex, UV).r;

	// ---- 未探索：古籍铜版画风 ----
	vec3 lumw = vec3(0.299, 0.587, 0.114);
	float lum = dot(base, lumw);

	// 用亮度梯度当假法线，做出浮雕（山脊亮、沟谷暗）
	vec2 texel = 1.0 / vec2(textureSize(albedo_tex, 0));
	float lx = dot(texture(albedo_tex, UV + vec2(texel.x * 2.0, 0.0)).rgb, lumw)
			- dot(texture(albedo_tex, UV - vec2(texel.x * 2.0, 0.0)).rgb, lumw);
	float ly = dot(texture(albedo_tex, UV + vec2(0.0, texel.y * 2.0)).rgb, lumw)
			- dot(texture(albedo_tex, UV - vec2(0.0, texel.y * 2.0)).rgb, lumw);
	vec3 emboss_n = normalize(vec3(-lx * 6.0, -ly * 6.0, 1.0));
	float emboss = clamp(dot(emboss_n, normalize(vec3(-0.45, 0.55, 0.70))), 0.0, 1.0);

	// 铜色三段：暗铜 → 中间铜 → 亮铜
	vec3 bronze_dark = vec3(0.055, 0.045, 0.035);
	vec3 bronze_mid  = vec3(0.20, 0.165, 0.125);
	vec3 bronze_lite = vec3(0.52, 0.44, 0.32);
	vec3 paper = mix(bronze_dark, bronze_mid, clamp(lum * 2.2, 0.0, 1.0));
	paper = mix(paper, bronze_lite, clamp(emboss * 0.40 + lum * 0.35, 0.0, 0.85));

	// 海面细横纹（海洋亮度低，条纹只在暗处显现）
	float wave = sin(UV.y * 900.0 + sin(UV.x * 40.0) * 2.0) * 0.5 + 0.5;
	paper *= mix(1.0, 0.90 + 0.10 * wave, clamp((0.34 - lum) * 4.0, 0.0, 1.0));

	// 旧书页暗角
	vec2 vd = UV - vec2(0.5, 0.5);
	paper *= 1.0 - clamp(dot(vd, vd) * 0.55, 0.0, 0.45);

	vec3 c = mix(paper, base, smoothstep(0.15, 0.6, explored));

	if (fog_enabled < 0.5) {
		c = base;
	}

	// 古地图是"平摊的刻印"，不该被场景灯光冲淡：
	// 颜色主要走自发光，反照率只留一点点参与受光
	ALBEDO = c * 0.22;
	EMISSION = c * 0.80;
	ROUGHNESS = 0.95;
	METALLIC = 0.0;
}
