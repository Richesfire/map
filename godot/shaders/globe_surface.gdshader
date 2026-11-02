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

void fragment() {
	vec3 base = texture(albedo_tex, UV).rgb;
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
