class_name DemoAnnotations
extends RefCounted

## ==============================================================
## 演示用的地图标注（**不是选定地块**）
##
## 这些只是小地图上的具名点，完全不影响地形、撒点、生成。
## 选定地块（DesignatedTile）默认是空的 —— 你圈了才有。
##
## 经纬度是示意性的粗估，真正的地理数据应该由内容/GIS 模块产出。
## ==============================================================

static func build() -> Array:
	var out: Array = []

	# ---- 秦
	_add(out, "xianyang", "咸阳", "capital", 108.71, 34.33)
	_add(out, "lishan", "骊山", "poi", 109.21, 34.36)
	_add(out, "liyang", "栎阳", "city", 109.25, 34.60)
	_add(out, "chengdu", "成都", "city", 104.07, 30.66)

	# ---- 六国故地
	_add(out, "xinzheng", "新郑", "city", 113.74, 34.40)
	_add(out, "daliang", "大梁", "city", 114.30, 34.80)
	_add(out, "linji", "临济", "city", 115.51, 35.10)
	_add(out, "handan", "邯郸", "city", 114.49, 36.60)
	_add(out, "xindu", "信都", "city", 115.60, 37.10)
	_add(out, "jicheng", "蓟城", "city", 116.40, 39.90)
	_add(out, "linzi", "临淄", "capital", 118.31, 36.83)
	_add(out, "pengcheng", "彭城", "city", 117.18, 34.26)
	_add(out, "xutai", "盱台", "city", 118.42, 33.01)
	_add(out, "peixian", "沛县", "city", 116.94, 34.72)
	_add(out, "panyu", "番禺", "city", 113.26, 23.13)

	# ---- 西方
	_add(out, "roma", "罗马", "capital", 12.50, 41.90)
	_add(out, "athenai", "雅典", "city", 23.73, 37.98)
	_add(out, "alexandreia", "亚历山大", "capital", 29.92, 31.20)
	_add(out, "karthago", "迦太基", "capital", 10.32, 36.85)
	_add(out, "babylon", "巴比伦", "poi", 44.42, 32.54)

	# ---- 测试用：县城与村庄（层级放大的验证素材）
	_add(out, "v_lantian", "蓝田", "town", 109.32, 34.15)
	_add(out, "v_zhouzhi", "盩厔", "town", 108.22, 34.16)
	_add(out, "v_huyi", "鄠邑", "town", 108.60, 34.11)
	_add(out, "v_jingyang", "泾阳", "town", 108.84, 34.53)
	_add(out, "v_gaoling", "高陵", "town", 109.09, 34.53)
	_add(out, "v_liquan", "醴泉", "town", 108.43, 34.48)
	_add(out, "v_xingping", "兴平", "town", 108.49, 34.30)
	_add(out, "v_wugong", "武功", "town", 108.20, 34.26)
	_add(out, "v_weinan", "渭南", "town", 109.50, 34.50)
	_add(out, "v_huaxian", "华县", "town", 109.77, 34.51)
	_add(out, "v_pucheng", "蒲城", "town", 109.59, 34.95)
	_add(out, "v_dali", "大荔", "town", 109.94, 34.80)

	_add(out, "vv_xiaozhai", "小寨", "village", 108.95, 34.22)
	_add(out, "vv_qiaoshan", "桥山", "village", 108.79, 34.24)
	_add(out, "vv_xiliu", "细柳", "village", 108.82, 34.14)
	_add(out, "vv_majia", "马家堡", "village", 108.88, 34.30)
	_add(out, "vv_beitian", "北田", "village", 109.05, 34.26)
	_add(out, "vv_yanliang", "阎良", "village", 109.23, 34.66)

	# ---- 守者（虚构）
	_add(out, "kunlun", "昆仑", "poi", 80.00, 36.00)

	return out


static func _add(out: Array, id: String, label: String, kind: String,
		lon: float, lat: float) -> void:
	out.append(MapAnnotation.from_lonlat(id, label, lon, lat, kind))
