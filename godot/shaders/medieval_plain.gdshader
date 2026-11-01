shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 grass_dark : source_color = vec3(0.16, 0.20, 0.11);
uniform vec3 grass_mid : source_color = vec3(0.27, 0.33, 0.17);
uniform vec3 grass_light : source_color = vec3(0.38, 0.43, 0.24);
uniform vec3 dry_grass : source_color = vec3(0.47, 0.43, 0.28);
uniform vec3 dirt_color : source_color = vec3(0.35, 0.29, 0.21);
uniform float path_strength : hint_range(0.0, 1.0) = 0.55;

varying vec3 world_pos;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * value_noise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		amp *= 0.5;
	}
	return v;
}

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz;
	float broad = fbm(p * 0.035);
	float mid = fbm(p * 0.11 + vec2(37.2, 11.7));
	float fine = fbm(p * 0.55 + vec2(5.3, 21.1));

	vec3 col = mix(grass_dark, grass_mid, smoothstep(0.18, 0.82, broad));
	col = mix(col, grass_light, smoothstep(0.50, 0.90, mid) * 0.45);
	col = mix(col, dry_grass, smoothstep(0.62, 0.90, fine) * 0.26);

	float dirt = smoothstep(0.48, 0.70, fbm(p * 0.08 + vec2(71.3, 3.7)));
	float path = smoothstep(0.11, 0.0, abs(p.x - sin(p.y * 0.035) * 7.0));
	dirt = max(dirt, path * path_strength);
	col = mix(col, dirt_color, dirt * 0.68);

	// 轻微明暗变化，避免单一纯色；世界坐标噪声没有方形贴图接缝
	col *= 0.90 + 0.14 * fine;

	// 远处边缘轻微压暗，配合雾让 170m 平原边界不突兀
	float edge = smoothstep(78.0, 86.0, max(abs(p.x), abs(p.y)));
	col = mix(col, grass_dark * 0.82, edge * 0.45);

	ALBEDO = col;
	ROUGHNESS = 0.97;
	SPECULAR = 0.10;
}
