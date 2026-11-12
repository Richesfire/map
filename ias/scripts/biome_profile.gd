extends Resource
## 单种地貌的资源配置（《地貌分类系统》第五节）
class_name BiomeProfile

@export var id: String = ""
@export var display_name: String = ""
@export var category: String = ""
@export var subtype: String = ""

# 高度置换堆
@export var disp_tiles: Array[int] = []
@export var disp_amp: float = 2.0
@export var disp_scale: float = 400.0

# 地表纹理堆（索引到程序图集）
@export var tex_tiles: Array[int] = []

# 环境杂物堆密度
@export var grass: float = 0.0
@export var shrub: float = 0.0
@export var rock: float = 0.0
@export var tree: float = 0.0
