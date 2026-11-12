shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha, diffuse_burley, specular_schlick_ggx;

// 草丛：alpha 裁剪 + 顶点风摆（越靠叶尖摆得越大）
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform vec3 tint : source_color = vec3(1.0);
uniform float wind_strength = 1.0;
uniform float wind_speed = 1.6;

varying float v_wind;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float phase = wp.x * 0.27 + wp.z * 0.21;
	float s = sin(TIME * wind_speed + phase) * 0.5 + sin(TIME * wind_speed * 0.43 + phase * 1.7) * 0.5;
	float k = UV.y * UV.y;
	VERTEX.x += s * 0.16 * k * wind_strength;
	VERTEX.z += s * 0.09 * k * wind_strength;
	v_wind = s * k;
}

void fragment() {
	vec4 c = texture(albedo_tex, UV);
	// 根部压暗，和地面自然衔接（不然像贴在土上的纸片）
	float root = mix(0.55, 1.0, smoothstep(0.0, 0.42, UV.y));
	ALBEDO = c.rgb * tint * root;
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45;
	ROUGHNESS = 0.92;
	SPECULAR = 0.05;
	// 逆光时叶尖透亮一点
	BACKLIGHT = vec3(0.35, 0.42, 0.25);
}
