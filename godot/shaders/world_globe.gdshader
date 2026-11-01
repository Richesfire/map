shader_type canvas_item;

// ==============================================================
// 地球仪：把等距圆柱（equirectangular）世界贴图投影成一个可转的球
//
// 不是用 3D 场景渲染的，是纯像素算的：
//   每个像素 -> 球面上的一个方向 -> 反算经纬度 -> 采样世界贴图
// 好处是拖动时只改一个 uniform，GPU 免费重投影，不用重算地形。
//
// 注意：Godot 的 fragment 里**不允许 return**，所以用 if/else 两个分支赋值。
// ==============================================================

uniform sampler2D world_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 view_dir = vec3(1.0, 0.0, 0.0);
uniform vec4 space_color : source_color = vec4(0.02, 0.03, 0.05, 1.0);

void fragment() {
	vec2 p = (UV - vec2(0.5)) * 2.0;
	float r2 = dot(p, p);
	vec3 outc = space_color.rgb;

	if (r2 <= 1.0) {
		float z = sqrt(max(0.0, 1.0 - r2));

		vec3 f = normalize(view_dir);
		vec3 rgt = cross(vec3(0.0, 1.0, 0.0), f);
		rgt = length(rgt) < 1e-4 ? vec3(1.0, 0.0, 0.0) : normalize(rgt);
		vec3 upv = cross(f, rgt);

		vec3 d = normalize(f * z + rgt * p.x + upv * p.y);

		float lat = asin(clamp(d.y, -1.0, 1.0));
		float lon = atan(-d.z, d.x);

		vec2 tuv = vec2((lon + 3.14159265) / 6.2831853, 0.5 - lat / 3.14159265);
		vec3 c = texture(world_tex, tuv).rgb;

		// 边缘压暗，做出球感
		outc = c * (0.38 + 0.62 * z);
	}

	COLOR = vec4(outc, 1.0);
}
