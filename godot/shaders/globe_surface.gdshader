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

// ---- 区域高清叠加：最多同时叠 4 张瓦片 ----
// 视野跨过瓦片边界时，新旧两张同时在，拼接处不会露出底层糊图。
uniform sampler2D d0 : source_color, filter_linear;
uniform sampler2D d1 : source_color, filter_linear;
uniform sampler2D d2 : source_color, filter_linear;
uniform sampler2D d3 : source_color, filter_linear;
uniform vec2 d0_min = vec2(0.0);
uniform vec2 d0_max = vec2(0.0);
uniform vec2 d1_min = vec2(0.0);
uniform vec2 d1_max = vec2(0.0);
uniform vec2 d2_min = vec2(0.0);
uniform vec2 d2_max = vec2(0.0);
uniform vec2 d3_min = vec2(0.0);
uniform vec2 d3_max = vec2(0.0);
uniform float detail_count = 0.0;

// 如果 UV 落在该瓦片的矩形内，就返回瓦片颜色，否则原样返回
vec3 _tile(vec2 uv, sampler2D tex, vec2 lo, vec2 hi, vec3 fallback) {
	vec2 span = hi - lo;
	if (span.x <= 0.0 || span.y <= 0.0) { return fallback; }
	if (uv.x < lo.x || uv.x > hi.x || uv.y < lo.y || uv.y > hi.y) { return fallback; }
	return texture(tex, (uv - lo) / span).rgb;
}


void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;

	// 区域瓦片：按顺序尝试，命中的覆盖底图（后面的瓦片更细，所以后写优先）
	if (detail_count > 0.5 && d0_max.x > d0_min.x) { base = _tile(UV, d0, d0_min, d0_max, base); }
	if (detail_count > 1.5 && d1_max.x > d1_min.x) { base = _tile(UV, d1, d1_min, d1_max, base); }
	if (detail_count > 2.5 && d2_max.x > d2_min.x) { base = _tile(UV, d2, d2_min, d2_max, base); }
	if (detail_count > 3.5 && d3_max.x > d3_min.x) { base = _tile(UV, d3, d3_min, d3_max, base); }
	float explored = texture(fog_tex, UV).r;

	// 未探索：纯色方案下只做"泛黄淡化"，不再做铜版浮雕
	vec3 paper = mix(base, vec3(0.74, 0.68, 0.52), 0.28);
	vec3 c = mix(paper, base, smoothstep(0.15, 0.6, explored));

	if (fog_enabled < 0.5) {
		c = base;
	}

	// 古地图是"平摊的刻印"，不该被场景灯光冲淡：
	// 颜色主要走自发光，反照率只留一点点参与受光
	ALBEDO = c;
	EMISSION = vec3(0.0);
	ROUGHNESS = 0.95;
	METALLIC = 0.0;
}
