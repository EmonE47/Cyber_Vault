## =============================================================================
## GameUI.gd  —  Heads-Up Display + Game Over Screen
## Shows: Terminal progress, Alert level, AI state info, Win/Lose screen
## =============================================================================
extends Node2D

const TS := GameManager.TILE_SIZE

var _terminals_label : String  = "Terminals: 0 / 3"
var _alert_label     : String  = "SILENT"
var _ghost_state     : String  = "MOVING"
var _warden_state    : String  = "PATROL"
var _game_over       : bool    = false
var _winner          : String  = ""
var _hud_timer       : float   = 0.0
var _blink           : bool    = true

# Drawn fonts — small pixel rects
const CHAR_W := 6
const CHAR_H := 8
const CHARS  : Dictionary = {}   # No font needed, draw with draw_string via fallback

func _ready() -> void:
	z_index = 20
	GameManager.terminal_hacked.connect(_on_terminal_hacked)
	GameManager.alert_level_changed.connect(_on_alert_changed)
	GameManager.game_over.connect(_on_game_over)
	set_process(true)

func _process(delta: float) -> void:
	_hud_timer += delta
	if int(_hud_timer * 2) % 2 == 0:
		_blink = true
	else:
		_blink = false

	# Sync state labels from live nodes
	var level := get_tree().get_root().get_child(0)
	if level and level.has_meta("is_level"):
		var ghost   : Node2D = level.ghost_node
		var warden  : Node2D = level.warden_node
		if ghost:
			_ghost_state = _state_name(int(ghost.state))
		if warden:
			_warden_state = _warden_state_name(int(warden.state))
	queue_redraw()

func _state_name(s: int) -> String:
	match s:
		0: return "IDLE"
		1: return "MOVING"
		2: return "HACKING"
		3: return "HIDING"
		4: return "EVADING"
		5: return "ESCAPED"
		6: return "CAUGHT"
	return "?"

func _warden_state_name(s: int) -> String:
	match s:
		0: return "PATROL"
		1: return "INVESTIGATE"
		2: return "CHASE"
		3: return "SEARCH"
	return "?"

func _draw() -> void:
	if _game_over:
		_draw_game_over()
	else:
		_draw_hud()

func _draw_hud() -> void:
	var W := 800.0
	var H := 640.0

	# ── Top HUD bar ──────────────────────────────────────────────────────────
	draw_rect(Rect2(0, 0, W, 28), Color(0.04, 0.06, 0.12, 0.90))
	draw_rect(Rect2(0, 27, W, 1), Color(0.0, 0.7, 1.0, 0.6))

	# Title
	_draw_text("CYBER-VAULT", Vector2(10, 8), Color(0.0, 0.9, 1.0))

	# Terminal counter
	var t_col := Color(0.0, 1.0, 0.5) if GameManager.all_hacked() else Color(0.6, 0.8, 1.0)
	_draw_text("TERMINALS: %d/%d" % [GameManager.terminals_hacked, GameManager.total_terminals],
			   Vector2(200, 8), t_col)

	# Alert level
	var a_col := _alert_color()
	var a_txt := _alert_text()
	_draw_text("ALERT: " + a_txt, Vector2(430, 8), a_col)
	# Blinking dot for ALARM
	if GameManager.alert_level == GameManager.AlertLevel.ALARM and _blink:
		draw_circle(Vector2(570, 13), 5, a_col)

	# ── Ghost status (bottom-left) ────────────────────────────────────────────
	draw_rect(Rect2(0, H-30, 200, 30), Color(0.04, 0.06, 0.12, 0.85))
	draw_rect(Rect2(0, H-30, 200, 1),  Color(0.0, 0.7, 0.6, 0.5))
	_draw_text("GHOST  [A*]:", Vector2(6, H-22), Color(0.1, 0.8, 0.9))
	_draw_text(_ghost_state, Vector2(106, H-22), Color(0.0, 1.0, 0.6))

	# ── Warden status (bottom-right) ─────────────────────────────────────────
	draw_rect(Rect2(W-210, H-30, 210, 30), Color(0.04, 0.06, 0.12, 0.85))
	draw_rect(Rect2(W-210, H-30, 210, 1),  Color(1.0, 0.4, 0.0, 0.5))
	_draw_text("WARDEN [MM]:", Vector2(W-205, H-22), Color(1.0, 0.5, 0.1))
	_draw_text(_warden_state, Vector2(W-105, H-22), Color(1.0, 0.8, 0.0))

	# ── Heatmap legend (small) ────────────────────────────────────────────────
	if GameManager.alert_level >= GameManager.AlertLevel.SUSPICIOUS:
		draw_rect(Rect2(W-80, 35, 75, 40), Color(0.04, 0.06, 0.12, 0.85))
		_draw_text("HEATMAP", Vector2(W-78, 38), Color(0.8, 0.4, 0.1))
		# Gradient bar
		for i in range(8):
			var t := float(i) / 8.0
			draw_rect(Rect2(W-78 + float(i)*8, 50, 8, 12),
					  Color(t, 0.2 * (1.0-t), 0.0, 0.8))
		_draw_text("0   MAX", Vector2(W-78, 64), Color(0.6, 0.6, 0.6))

	# ── Mission goal reminder ─────────────────────────────────────────────────
	if GameManager.terminals_hacked < GameManager.total_terminals:
		_draw_text("GHOST: Hack all terminals then reach EXIT",
				   Vector2(10, H-52), Color(0.4, 0.6, 0.4, 0.7))
	else:
		if _blink:
			_draw_text(">> ESCAPE TO EXIT NOW! <<",
					   Vector2(10, H-52), Color(0.0, 1.0, 0.5))

func _draw_game_over() -> void:
	var W := 800.0
	var H := 640.0

	# Darken screen
	draw_rect(Rect2(0, 0, W, H), Color(0, 0, 0, 0.65))

	# Panel
	var px := W*0.5 - 200
	var py := H*0.5 - 110
	draw_rect(Rect2(px, py, 400, 220), Color(0.05, 0.07, 0.14))
	draw_rect(Rect2(px, py, 400, 220), Color(0.0, 0.7, 1.0, 0.8), false)

	# Title
	var title_col: Color
	var title_txt: String
	if _winner == "Ghost":
		title_col = Color(0.0, 1.0, 0.5)
		title_txt = "GHOST WINS!"
	else:
		title_col = Color(1.0, 0.3, 0.1)
		title_txt = "WARDEN WINS!"
	_draw_text_large(title_txt, Vector2(px + 40, py + 30), title_col, 2.5)

	# Subtitle
	var sub_txt: String
	if _winner == "Ghost":
		sub_txt = "All data stolen — vault breached."
	else:
		sub_txt = "Intruder neutralized — vault secured."
	_draw_text(sub_txt, Vector2(px + 20, py + 100), Color(0.8, 0.8, 0.8))

	# Stats
	_draw_text("Terminals hacked: %d / %d" % [GameManager.terminals_hacked, GameManager.total_terminals],
			   Vector2(px+20, py+125), Color(0.6, 0.9, 0.6))

	# Restart instruction
	if _blink:
		_draw_text("Press Q/R to Restart  |  ESC to Quit",
				   Vector2(px + 55, py + 175), Color(0.0, 0.85, 1.0))

func _input(event: InputEvent) -> void:
	if not _game_over:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_R or event.keycode == KEY_Q:
			get_tree().paused = false
			get_tree().reload_current_scene()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()
		get_tree().set_input_as_handled()

func _on_terminal_hacked(_id: int, _pos: Vector2) -> void:
	_terminals_label = "Terminals: %d / 3" % GameManager.terminals_hacked

func _on_alert_changed(level: int) -> void:
	pass   # Handled live in _draw

func _on_game_over(w: String) -> void:
	_game_over = true
	_winner    = w

func _alert_color() -> Color:
	match GameManager.alert_level:
		GameManager.AlertLevel.SILENT:     return Color(0.3, 0.8, 0.3)
		GameManager.AlertLevel.SUSPICIOUS: return Color(0.9, 0.8, 0.1)
		GameManager.AlertLevel.ALERT:      return Color(1.0, 0.5, 0.0)
		GameManager.AlertLevel.ALARM:      return Color(1.0, 0.1, 0.1)
	return Color.WHITE

func _alert_text() -> String:
	match GameManager.alert_level:
		GameManager.AlertLevel.SILENT:     return "SILENT"
		GameManager.AlertLevel.SUSPICIOUS: return "SUSPICIOUS"
		GameManager.AlertLevel.ALERT:      return "ALERT"
		GameManager.AlertLevel.ALARM:      return "ALARM !"
	return "?"

# ── Simple pixel-text renderer using draw_rect segments ──────────────────────
func _draw_text(text: String, pos: Vector2, col: Color, scale: float = 1.0) -> void:
	# Godot 4 has draw_string but needs a font — use system default fallback
	# We'll rely on SystemFont for actual text rendering
	var font := ThemeDB.fallback_font
	if font:
		draw_string(font, pos + Vector2(0, 12*scale),
					text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(11*scale), col)

func _draw_text_large(text: String, pos: Vector2, col: Color, scale: float) -> void:
	_draw_text(text, pos, col, scale)

# ── Event handlers ────────────────────────────────────────────────────────────
func _on_terminals_changed() -> void:
	queue_redraw()
