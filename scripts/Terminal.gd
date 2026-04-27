## =============================================================================
## Terminal.gd  —  Hackable Data Terminal
## Each terminal stores data the Ghost must extract.
## When Ghost is adjacent and starts hacking, progress builds until complete.
## Hacking triggers an alarm alerting the Warden.
## =============================================================================
extends Node2D

const TS := GameManager.TILE_SIZE

var terminal_id   : int      = 0
var terminal_cell : Vector2i = Vector2i.ZERO
var hacked        : bool     = false
var _pulse_timer  : float    = 0.0

func _ready() -> void:
	terminal_id   = get_meta("terminal_id",   0)
	terminal_cell = get_meta("terminal_cell", Vector2i(0,0))
	position      = GameManager.cell_to_world_center(terminal_cell)
	z_index       = 3
	set_meta("hacked", false)
	GameManager.terminal_hacked.connect(_on_any_hacked)
	set_process(true)

func _process(delta: float) -> void:
	_pulse_timer += delta
	# Check if this terminal has been hacked
	hacked = get_meta("hacked", false)
	queue_redraw()

func _on_any_hacked(tid: int, _pos: Vector2) -> void:
	if tid == terminal_id:
		hacked = true
		set_meta("hacked", true)

func _draw() -> void:
	var s  := float(TS)
	var hs := s * 0.5
	var ox := -hs
	var oy := -hs

	if hacked:
		_draw_hacked(ox, oy, s)
	else:
		_draw_active(ox, oy, s)

func _draw_active(ox: float, oy: float, s: float) -> void:
	var pulse: float = abs(sin(_pulse_timer * 2.5)) * 0.4 + 0.6

	# Terminal base (dark metallic)
	draw_rect(Rect2(ox+s*0.10, oy+s*0.20, s*0.80, s*0.70), Color(0.10, 0.12, 0.18))

	# Screen (glowing cyan)
	var screen_col := Color(0.0, 0.7*pulse, 0.85*pulse)
	draw_rect(Rect2(ox+s*0.15, oy+s*0.24, s*0.70, s*0.46), screen_col)

	# Screen content (scrolling lines of text)
	var line_col := Color(0.0, 1.0*pulse, 0.9*pulse, 0.8)
	var line_offset := int(_pulse_timer * 20) % int(s * 0.40)
	for i in range(5):
		var ly := oy + s*0.28 + float(i) * s*0.08 - float(line_offset) * 0.2
		if ly > oy+s*0.24 and ly < oy+s*0.68:
			draw_rect(Rect2(ox+s*0.18, ly, s*0.64 * (0.5 + 0.5*randf()), s*0.03), line_col)

	# Keyboard / base
	draw_rect(Rect2(ox+s*0.15, oy+s*0.72, s*0.70, s*0.10), Color(0.15, 0.16, 0.22))

	# Border glow
	draw_rect(Rect2(ox+s*0.10, oy+s*0.20, s*0.80, s*0.70),
			  Color(0.0, 0.85*pulse, 1.0*pulse), false)

	# Label "T1/T2/T3"
	var terminal_id_var: int = terminal_id
	# Draw number as small squares pattern
	_draw_label(ox, oy, s, "T%d" % terminal_id_var, Color(0.0, 1.0, 0.9))

func _draw_hacked(ox: float, oy: float, s: float) -> void:
	# Terminal base (same)
	draw_rect(Rect2(ox+s*0.10, oy+s*0.20, s*0.80, s*0.70), Color(0.10, 0.12, 0.18))

	# Screen (red — hacked/compromised)
	draw_rect(Rect2(ox+s*0.15, oy+s*0.24, s*0.70, s*0.46), Color(0.60, 0.05, 0.05))

	# X mark on screen
	draw_line(Vector2(ox+s*0.20, oy+s*0.28), Vector2(ox+s*0.80, oy+s*0.66),
			  Color(1.0, 0.3, 0.3), 3.0)
	draw_line(Vector2(ox+s*0.80, oy+s*0.28), Vector2(ox+s*0.20, oy+s*0.66),
			  Color(1.0, 0.3, 0.3), 3.0)

	# "BREACH" indicator
	draw_rect(Rect2(ox+s*0.10, oy+s*0.20, s*0.80, s*0.70),
			  Color(1.0, 0.1, 0.1), false)

func _draw_label(ox: float, oy: float, s: float, text: String, col: Color) -> void:
	# Draw a tiny pixel label at top of terminal
	var lx := ox + s * 0.5 - float(text.length()) * 3.5
	var ly := oy + s * 0.10
	# Simple block letters (just a colored rectangle + darker text indicator)
	draw_rect(Rect2(lx-2, ly-2, float(text.length())*7+4, 10), Color(0,0,0,0.7))
	# Draw each character as simple pattern (T=2 rects, digit varies)
	for i in range(text.length()):
		var cx := lx + float(i) * 7
		var ch := text[i]
		if ch == "T":
			draw_rect(Rect2(cx, ly, 6, 2), col)
			draw_rect(Rect2(cx+2, ly+2, 2, 6), col)
		elif ch == "1":
			draw_rect(Rect2(cx+2, ly, 2, 8), col)
		elif ch == "2":
			draw_rect(Rect2(cx, ly, 6, 2), col)
			draw_rect(Rect2(cx+4, ly+2, 2, 3), col)
			draw_rect(Rect2(cx, ly+4, 6, 2), col)
			draw_rect(Rect2(cx, ly+6, 2, 2), col)
			draw_rect(Rect2(cx, ly+7, 6, 1), col)
		elif ch == "3":
			draw_rect(Rect2(cx, ly, 6, 2), col)
			draw_rect(Rect2(cx+4, ly+2, 2, 3), col)
			draw_rect(Rect2(cx, ly+4, 6, 2), col)
			draw_rect(Rect2(cx+4, ly+6, 2, 2), col)
			draw_rect(Rect2(cx, ly+7, 6, 1), col)
