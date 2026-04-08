## =============================================================================
## GameManager.gd  —  Autoload Singleton
## Manages global game state, alert system, probability heatmap,
## terminal progress, and win/lose conditions.
## =============================================================================
extends Node

# ─── Signals ─────────────────────────────────────────────────────────────────
signal terminal_hacked(terminal_id: int, world_pos: Vector2)
signal hacking_started(terminal_id: int, world_pos: Vector2)
signal alarm_triggered(world_pos: Vector2)
signal alert_level_changed(new_level: int)
signal ghost_escaped()
signal ghost_caught()
signal game_over(winner: String)

# ─── Enums ───────────────────────────────────────────────────────────────────
enum GameState  { MENU, PLAYING, GAME_OVER }
enum AlertLevel { SILENT=0, SUSPICIOUS=1, ALERT=2, ALARM=3 }

# ─── Constants ───────────────────────────────────────────────────────────────
const TILE_SIZE    : int = 40
const GRID_COLS    : int = 20
const GRID_ROWS    : int = 16

# ─── State ───────────────────────────────────────────────────────────────────
var game_state      : GameState  = GameState.MENU
var alert_level     : AlertLevel = AlertLevel.SILENT
var terminals_hacked: int        = 0
var total_terminals : int        = 3
var winner          : String     = ""

# Probability heatmap [row][col] — float 0.0..1.0
# Used by Warden AI to predict Ghost location
var heatmap : Array = []

var _decay_timer: float = 0.0
var _last_hacking_clue_ms: int = -100000

const HACKING_CLUE_COOLDOWN_MS := 1200

# ─── Ready ───────────────────────────────────────────────────────────────────
func _ready() -> void:
	_init_heatmap()

func _process(delta: float) -> void:
	if game_state != GameState.PLAYING:
		return
	_decay_timer += delta
	if _decay_timer >= 0.4:
		_decay_timer = 0.0
		_decay_heatmap()

# ─── Game Control ─────────────────────────────────────────────────────────────
func start_game() -> void:
	game_state       = GameState.PLAYING
	alert_level      = AlertLevel.SILENT
	terminals_hacked = 0
	winner           = ""
	_init_heatmap()
	print("[GameManager] Game started")

func end_game(w: String) -> void:
	if game_state == GameState.GAME_OVER:
		return
	game_state = GameState.GAME_OVER
	winner     = w
	game_over.emit(w)
	if w == "Ghost":
		ghost_escaped.emit()
		print("[GameManager] Ghost WINS — escaped with all data!")
	else:
		ghost_caught.emit()
		print("[GameManager] Warden WINS — Ghost captured!")

# ─── Terminal System ──────────────────────────────────────────────────────────
func on_hacking_started(tid: int, wpos: Vector2) -> void:
	# Corner case protection: repeated hack start/abort loops should not flood clues.
	var now_ms := Time.get_ticks_msec()
	if now_ms - _last_hacking_clue_ms < HACKING_CLUE_COOLDOWN_MS:
		return
	_last_hacking_clue_ms = now_ms

	hacking_started.emit(tid, wpos)
	_set_alert(AlertLevel.SUSPICIOUS)
	_add_heat_world(wpos, 0.55, 4)
	print("[GameManager] Hacking clue from terminal %d at %s" % [tid, str(world_to_cell(wpos))])

func on_terminal_hacked(tid: int, wpos: Vector2) -> void:
	terminals_hacked += 1
	terminal_hacked.emit(tid, wpos)
	# Hacking triggers a full alarm at the terminal's location
	_set_alert(AlertLevel.ALARM)
	_add_heat_world(wpos, 1.0, 5)
	alarm_triggered.emit(wpos)
	print("[GameManager] Terminal %d hacked (%d/%d)" % [tid, terminals_hacked, total_terminals])

func all_hacked() -> bool:
	return terminals_hacked >= total_terminals

# ─── Alert System ─────────────────────────────────────────────────────────────
func raise_suspicion(wpos: Vector2) -> void:
	_set_alert(AlertLevel.SUSPICIOUS)
	_add_heat_world(wpos, 0.3, 2)

func on_noise(wpos: Vector2, intensity: float) -> void:
	if intensity >= 0.7:
		_set_alert(AlertLevel.ALERT)
	else:
		_set_alert(AlertLevel.SUSPICIOUS)
	_add_heat_world(wpos, intensity, 3)

func on_visual_contact(wpos: Vector2) -> void:
	_set_alert(AlertLevel.ALARM)
	_add_heat_world(wpos, 1.0, 4)

func _set_alert(lv: AlertLevel) -> void:
	if lv > alert_level:
		alert_level = lv
		alert_level_changed.emit(int(alert_level))

# ─── Heatmap ─────────────────────────────────────────────────────────────────
## The heatmap represents the Warden's probabilistic belief of Ghost location.
## High values = Warden thinks Ghost is likely there.
func _init_heatmap() -> void:
	heatmap.clear()
	for _r in range(GRID_ROWS):
		var row: Array = []
		for _c in range(GRID_COLS):
			row.append(0.1)      # Uniform prior
		heatmap.append(row)

func _add_heat_world(wpos: Vector2, intensity: float, radius: int) -> void:
	_add_heat_cell(world_to_cell(wpos), intensity, radius)

func _add_heat_cell(cell: Vector2i, intensity: float, radius: int) -> void:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var c := Vector2i(cell.x + dx, cell.y + dy)
			if _in_bounds(c):
				var dist  := Vector2(float(dx), float(dy)).length()
				var fade  := maxf(0.0, 1.0 - dist / float(radius + 1))
				heatmap[c.y][c.x] = minf(1.0, heatmap[c.y][c.x] + intensity * fade)

## Natural decay — old information becomes less reliable over time
func _decay_heatmap() -> void:
	for r in range(GRID_ROWS):
		for c in range(GRID_COLS):
			heatmap[r][c] = maxf(0.05, heatmap[r][c] * 0.96)

func get_heat(cell: Vector2i) -> float:
	if _in_bounds(cell):
		return heatmap[cell.y][cell.x]
	return 0.0

## Returns the hottest cell within search_radius of near_cell
func hottest_near(near_cell: Vector2i, search_radius: int = 6) -> Vector2i:
	var best     := near_cell
	var best_val := -1.0
	for dy in range(-search_radius, search_radius + 1):
		for dx in range(-search_radius, search_radius + 1):
			var c := Vector2i(near_cell.x + dx, near_cell.y + dy)
			if _in_bounds(c) and heatmap[c.y][c.x] > best_val:
				best_val = heatmap[c.y][c.x]
				best     = c
	return best

## Returns globally hottest cell
func hottest_global() -> Vector2i:
	var best     := Vector2i(1, 1)
	var best_val := -1.0
	for r in range(GRID_ROWS):
		for c in range(GRID_COLS):
			if heatmap[r][c] > best_val:
				best_val = heatmap[r][c]
				best     = Vector2i(c, r)
	return best

# ─── Coordinate Helpers ───────────────────────────────────────────────────────
func world_to_cell(wpos: Vector2) -> Vector2i:
	return Vector2i(int(wpos.x) / TILE_SIZE, int(wpos.y) / TILE_SIZE)

func cell_to_world_center(cell: Vector2i) -> Vector2:
	return Vector2(
		cell.x * TILE_SIZE + TILE_SIZE * 0.5,
		cell.y * TILE_SIZE + TILE_SIZE * 0.5
	)

func _in_bounds(cell: Vector2i) -> bool:
	return cell.x >= 0 and cell.x < GRID_COLS \
	   and cell.y >= 0 and cell.y < GRID_ROWS
