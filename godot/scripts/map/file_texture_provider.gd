class_name FileTextureProvider
extends MapTextureProvider

## ==============================================================
## 从文件读瓦片：给"以后放真实地形图"用
##
## 查找顺序（先项目内，再用户目录）：
##   res://data/tiles/z07/x123/y45.png
##   user://region_cache/z07_x123_y45.png
##
## 找不到就返回 null —— 系统层会自动退回程序生成。
## 也就是说：你**可以只放一部分地区的真实图**，其余仍是程序生成，
## 两者混用不会出问题。
## ==============================================================

const SEARCH_DIRS := [
	"res://data/tiles",
	"user://tiles",
]


## 只读，不生成
func can_generate() -> bool:
	return false


func try_cached(level: int, x: int, y: int) -> Image:
	# 1) 分目录形式：z07/x123/y45.png
	for root in SEARCH_DIRS:
		var p := "%s/z%02d/x%d/y%d.png" % [root, level, x, y]
		if FileAccess.file_exists(p):
			return Image.load_from_file(p)
	# 2) 扁平命名：z07_x123_y45.png
	for root in SEARCH_DIRS:
		var p2 := "%s/z%02d_x%d_y%d.png" % [root, level, x, y]
		if FileAccess.file_exists(p2):
			return Image.load_from_file(p2)
	return null
