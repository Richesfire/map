shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

// 树：只有树冠（局部 Y 高于树干顶）随风摆动，树干保持不动
uniform float wind_strength = 1.0;
uniform float trunk_top = 3.1;   // 树干高度，低于此处不动
uniform float canopy_h = 3.5;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform bool use_tex = true;
uniform int mode = 1;  // 0 树干取左半，1 叶卡取右半

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float h = clamp((VERTEX.y - trunk_top) / canopy_h, 0.0, 1.0);
	h = h * h;
	float ph = wp.x * 0.09 + wp.z * 0.07;
	float sx = sin(TIME * 1.05 + ph) * 0.55 + sin(TIME * 2.3 + ph * 1.7) * 0.25;
	float sz = cos(TIME * 0.87 + ph * 1.3) * 0.45;
	VERTEX.x += sx * 0.22 * h * wind_strength;
	VERTEX.z += sz * 0.18 * h * wind_strength;
}

void fragment() {
	if (mode == 2) {
		// 针叶/柱状树冠：用树皮贴图取细节，但压成针叶绿（不再是一块褐色锥）
		vec2 auv2 = vec2(UV.x * 0.5, UV.y);
		vec4 c2 = texture(albedo_tex, auv2);
		float g = dot(c2.rgb, vec3(0.33, 0.5, 0.17));
		vec3 needle = COLOR.rgb * vec3(0.62, 1.00, 0.60) * (0.75 + 0.55 * g);
		ALBEDO = mix(needle, COLOR.rgb, 0.15);
	} else if (use_tex) {
		vec2 auv = vec2(mode == 0 ? UV.x * 0.5 : 0.5 + UV.x * 0.5, UV.y);
		vec4 c = texture(albedo_tex, auv);
		ALBEDO = c.rgb * COLOR.rgb * 1.45;
		ALPHA = c.a;
		ALPHA_SCISSOR_THRESHOLD = 0.45;
	} else {
		ALBEDO = COLOR.rgb;
	}
	ROUGHNESS = 0.93;
	SPECULAR = 0.05;
	BACKLIGHT = vec3(0.10, 0.14, 0.07);
}
