extends Control

## 主界面：标题 + 开始游戏

@onready var _start: Button = $Center/StartButton
@onready var _title: Label = $Center/Title
@onready var _ver: Label = $Version

var _starting := false


func _ready() -> void:
	_start.pressed.connect(_on_start)
	_start.grab_focus()
	# 从标题场景进来时是闭着眼的，这里睁眼
	if Engine.has_singleton("Wake") or get_node_or_null("/root/Wake") != null:
		var wake := get_node_or_null("/root/Wake")
		if wake != null:
			await get_tree().process_frame
			await wake.reveal()
	_maybe_capture()


func _on_start() -> void:
	if _starting:
		return
	_starting = true
	_start.disabled = true
	_title.text = "正在睁眼…"

	var wake := get_node_or_null("/root/Wake")
	if wake != null:
		await wake.cover()

	await get_tree().create_timer(0.15).timeout
	get_tree().change_scene_to_file("res://scenes/main.tscn")


func _maybe_capture() -> void:
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	if out.is_empty():
		return
	for i in 20:
		await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(out)
	print("[Menu] screenshot -> " + out)
	get_tree().quit()
