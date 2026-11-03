class_name MapTextureProvider
extends RefCounted

## ==============================================================
## 地图瓦片资源提供者（抽象）
##
## 地图**系统**只认这个接口：给一块瓦片（级别 + 格号 + 覆盖范围），
## 它要么立刻返回一张图，要么分帧生成。
##
## 具体图从哪来由子类决定：
##   * ProceduralTextureProvider —— 按噪声现算（现在用的）
##   * FileTextureProvider       —— 读预先做好的图片（以后放真实地形图）
##
## 这样换资源生产方式不用改地图系统。
## ==============================================================


## 先问有没有现成的（磁盘缓存 / 预制资源）。有就直接返回，没有返回 null。
func try_cached(_level: int, _x: int, _y: int) -> Image:
	return null


## 开始生成一块瓦片。span_deg 是瓦片覆盖的经纬度跨度，px 是像素边长。
func begin(_world: MapWorld, _level: int, _x: int, _y: int, _span_deg: float, _px: int) -> void:
	pass


## 分帧推进。返回进度 0~1（1 表示完成）。
func step(_max_rows: int) -> float:
	return 1.0


func is_done() -> bool:
	return true


## 取走生成好的图（取走后任务清空）。
func take() -> Image:
	return null


## 是否支持"生成"（File 提供者只读不生成）
func can_generate() -> bool:
	return true
