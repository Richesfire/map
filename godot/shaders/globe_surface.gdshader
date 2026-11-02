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

	// 未探索：羊皮纸底 + 一点点地形起伏（0.18 倍），像手绘旧图
	vec3 paper = fog_color * (0.86 + 0.14 * base.r);
	vec3 c = mix(paper, base, smoothstep(0.15, 0.6, explored));

	if (fog_enabled < 0.5) {
		c = base;
	}

	ALBEDO = c;
	ROUGHNESS = 0.9;
	METALLIC = 0.0;
}
