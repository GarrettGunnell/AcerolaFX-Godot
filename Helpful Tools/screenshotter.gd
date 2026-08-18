extends Node

var screenshot_folder: String = "res://screenshots"

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("take_screenshot"):
		if not DirAccess.dir_exists_absolute(screenshot_folder):
			DirAccess.make_dir_recursive_absolute(screenshot_folder)

		var screenshot: Image = get_viewport().get_texture().get_image()

		var timestamp : String = Time.get_datetime_string_from_system().replace(":", "-").replace(" ", "_")
		var path : String = "%s/screenshot_%s.png" % [screenshot_folder, timestamp]

		screenshot.save_png(path)
