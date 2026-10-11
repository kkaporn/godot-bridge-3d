extends SceneTree

# Launches the REAL editor (windowed, so the GPU/RenderingDevice exists) with the
# probe plugin enabled, and forwards the editor's stdout. --quit-after is a
# backstop so a hung editor can never outlive this run.

func _init() -> void:
	var exe := OS.get_executable_path()
	var proj := ProjectSettings.globalize_path("res://")
	var out := []
	var args := ["--editor", "--path", proj, "--quit-after", "9000"]
	print("RUN_EDITOR args=", args)
	var code := OS.execute(exe, args, out, true)
	print("EDITOR_EXIT=", code)
	for line in out:
		print("| ", line)
	quit()
