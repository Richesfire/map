shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque, specular_schlick_ggx;

// 3D 水面：海面/河/湖共用。几何是平的（y 由 GDScript 给），只做法线扰动，
// 避免在 180 km 的平面上做顶点位移（细分不够会穿帮，也没有必要）。
uniform vec3 deep_color : source_color = vec3(0.05, 0.15, 0.24);
uniform vec3 shallow_color : source_color = vec3(0.16, 0.32, 0.38);
uniform vec3 sky_color : source_color = vec3(0.62, 0.72, 0.82);
uniform float wave_scale = 0.055;     // 1/米：约 18 m 一个波长
uniform float wave_speed = 0.35;
uniform float wave_strength = 0.30;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float wave_h(vec2 p, float t) {
	return sin(p.x * wave_scale + p.y * wave_scale * 0.6 + t * wave_speed) * 0.5
			+ sin(p.y * wave_scale * 1.37 - p.x * wave_scale * 0.4 - t * wave_speed * 0.83) * 0.5;
}

void fragment() {
	float t = TIME;
	vec2 p = wpos.xz;
	// 中心差分求坡度 → 世界空间法线
	float e = 3.0;
	float h0 = wave_h(p, t);
	float hx = wave_h(p + vec2(e, 0.0), t);
	float hz = wave_h(p + vec2(0.0, e), t);
	vec3 n = normalize(vec3((h0 - hx) * wave_strength, 1.0, (h0 - hz) * wave_strength));
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 col = mix(deep_color, shallow_color, clamp(h0 * 0.22 + 0.5, 0.0, 1.0));
	col = mix(col, sky_color, fres * 0.62);
	ALBEDO = col;
	ROUGHNESS = 0.10;
	SPECULAR = 0.55;
	METALLIC = 0.0;
	ALPHA = 1.0;
	// 近岸一点点白：条纹随波的相位，不取样深度也能看出水在动
	float crest = smoothstep(0.86, 1.0, h0) * 0.35;
	EMISSION = vec3(0.55, 0.62, 0.62) * crest * 0.06;
}
