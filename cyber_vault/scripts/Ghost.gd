class_name Ghost
## =============================================================================
## Ghost.gd  —  Infiltrator AI Agent
## AI Algorithm: A* Pathfinding (safety-weighted) + Stealth Decision Tree
##
## Behaviour:
##   IDLE       → Wait for game to start
##   MOVING     → Follow A* path to next objective (terminal or exit)
##   HACKING    → Stationary at terminal, progress bar fills
##   HIDING     → Crouch behind wall when Warden FOV gets close
##   EVADING    → Emergency reroute away from detected zone
##   ESCAPED    → Reached exit after all terminals hacked — wins
## =============================================================================
extends Node2D

# ─── Constants ────────────────────────────────────────────────────────────────
const TS            := GameManager.TILE_SIZE
const MOVE_SPEED    := 0.18   # seconds per tile (normal)
const HIDE_SPEED    := 0.30   # slower when hiding/cautious
const FAST_SPEED    := 0.10   # sprinting (generates noise!)
const HACK_TIME     := 3.0    # seconds to hack one terminal
const NOISE_THRESH  := 0.15   # movement faster than this creates noise
const FOV_SAFE_DIST := 3      # cells away from Warden FOV to feel safe

# ─── Enums ────────────────────────────────────────────────────────────────────
enum State { IDLE, MOVING, HACKING, HIDING, EVADING, ESCAPED, CAUGHT }

# ─── References set by Level.gd ───────────────────────────────────────────────
var level     : Node2D   # Level.gd instance
var warden    : Node2D   # Warden.gd instance (set after spawn)

# ─── Objective queue ──────────────────────────────────────────────────────────
# Ghost hacks terminals in order, then exits
var objective_queue: Array[Vector2i] = []
var current_target : Vector2i        = Vector2i(-1, -1)

# ─── Path & Movement ──────────────────────────────────────────────────────────
var cell          : Vector2i = Level.GHOST_SPAWN
var path          : Array[Vector2i] = []
var move_timer    : float    = 0.0
var current_speed : float    = MOVE_SPEED

# ─── State ────────────────────────────────────────────────────────────────────
var state         : State    = State.IDLE
var hack_timer    : float    = 0.0
var hide_timer    : float    = 0.0
var current_hack_terminal : Node2D = null

# ─── Safety map ───────────────────────────────────────────────────────────────
# Cells near Warden FOV get a higher A* weight (Ghost avoids them)
var safety_weights: Dictionary = {}

# ─── Animation ────────────────────────────────────────────────────────────────
var anim_tick     : float = 0.0
var facing_right  : bool  = true

# ─── Ready ────────────────────────────────────────────────────────────────────
func _ready() -> void:
	position = GameManager.cell_to_world_center(cell)
	z_index  = 5

	# Build objective queue: T3 → T2 → T1 → EXIT (nearest-first heuristic)
	_build_objective_queue()

	# Connect to game events
	GameManager.game_over.connect(_on_game_over)
	GameManager.alarm_triggered.connect(_on_alarm)

	# Give Warden a moment to spawn before we start
	await get_tree().create_timer(0.5).timeout
	state = State.MOVING
	_plan_next_objective()
	print("[Ghost] AI started — targeting %d terminals then escape" % objective_queue.size())

# ─── Objective Queue ─────────────────────────────────────────────────────────
func _build_objective_queue() -> void:
	# Sort terminals by distance from spawn (greedy nearest-first)
	var terminals_sorted: Array[Vector2i] = []
	for td in Level.TERMINAL_DEFS:
		terminals_sorted.append(Vector2i(td[0], td[1]))

	# Simple nearest-first sorting from ghost spawn
	var start := cell
	while terminals_sorted.size() > 0:
		var nearest_idx := 0
		var nearest_dist := 9999
		for i in range(terminals_sorted.size()):
			var d := (terminals_sorted[i] - start).length()
			if d < nearest_dist:
				nearest_dist = d
				nearest_idx  = i
		objective_queue.append(terminals_sorted[nearest_idx])
		start = terminals_sorted[nearest_idx]
		terminals_sorted.remove_at(nearest_idx)
	# Final objective: exit
	objective_queue.append(Level.EXIT_CELL)

# ─── Process ─────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if GameManager.game_state != GameManager.GameState.PLAYING:
		return

	anim_tick += delta
	_update_safety_map()
	_decide(delta)
	queue_redraw()

func _decide(delta: float) -> void:
	match state:
		State.IDLE:
			pass
		State.MOVING:
			_do_moving(delta)
		State.HACKING:
			_do_hacking(delta)
		State.HIDING:
			_do_hiding(delta)
		State.EVADING:
			_do_evading(delta)

# ─── A* Safety-Weighted Pathfinding ──────────────────────────────────────────
## Ghost's core intelligence: safety-weighted A*.
## Cells near the Warden's field of view incur a penalty cost,
## so the Ghost routes around dangerous areas automatically.
func _get_safe_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	# Apply safety weights to astar grid temporarily
	_apply_weights_to_astar()
	var raw_path: Array = level.astar.get_id_path(from, to)
	# Restore default weights
	_restore_astar_weights()

	var result: Array[Vector2i] = []
	for v in raw_path:
		result.append(Vector2i(v))
	return result

func _apply_weights_to_astar() -> void:
	for cell_key in safety_weights:
		var w: float = safety_weights[cell_key]
		if not level.astar.is_point_solid(cell_key):
			level.astar.set_point_weight_scale(cell_key, 1.0 + w * 6.0)

func _restore_astar_weights() -> void:
	for cell_key in safety_weights:
		if not level.astar.is_point_solid(cell_key):
			level.astar.set_point_weight_scale(cell_key, 1.0)

## Build a danger map around the Warden's position & facing
func _update_safety_map() -> void:
	safety_weights.clear()
	if warden == null:
		return
	var w_cell: Vector2i = warden.cell
	var fov_range: int   = warden.fov_range

	# Cells within Warden's FOV cone get maximum penalty
	for r in range(-fov_range, fov_range + 1):
		for c in range(-fov_range, fov_range + 1):
			var nc := Vector2i(w_cell.x + c, w_cell.y + r)
			if level.is_walkable(nc):
				var dist := float(max(abs(c), abs(r)))
				# Check if in warden's actual FOV
				if _warden_can_see(nc):
					safety_weights[nc] = maxf(0.0, 1.0 - dist / fov_range)
				else:
					# Slight penalty for being near Warden even outside FOV
					safety_weights[nc] = maxf(0.0, (0.4 - dist / (fov_range * 2)))

func _warden_can_see(target_cell: Vector2i) -> bool:
	if warden == null:
		return false
	return warden.can_see_cell(target_cell)

# ─── Moving State ─────────────────────────────────────────────────────────────
func _do_moving(delta: float) -> void:
	# Stealth check: if warden is dangerously close, switch to hiding
	if _warden_too_close(2):
		_enter_hiding()
		return

	if path.is_empty():
		# Reached objective
		_on_reached_objective()
		return

	move_timer += delta
	if move_timer >= current_speed:
		move_timer = 0.0
		_step_path()

func _step_path() -> void:
	if path.is_empty():
		return
	var next_cell := path[0]
	path.remove_at(0)

	# Facing direction
	facing_right = next_cell.x >= cell.x

	# Ghost moves slowly by default, but can sprint (generates noise)
	var speed_factor := 1.0
	if GameManager.alert_level >= GameManager.AlertLevel.ALERT:
		speed_factor = 0.6    # Sprint when alarmed
		current_speed = FAST_SPEED
	else:
		current_speed = MOVE_SPEED

	# Noise emission — fast movement detected by Warden
	if current_speed < NOISE_THRESH + 0.05:
		var noise_pos := GameManager.cell_to_world_center(next_cell)
		GameManager.on_noise(noise_pos, 0.6)

	cell     = next_cell
	position = GameManager.cell_to_world_center(cell)

# ─── Hacking State ────────────────────────────────────────────────────────────
func _do_hacking(delta: float) -> void:
	hack_timer += delta

	# Abort if Warden gets too close
	if _warden_too_close(3):
		hack_timer = 0.0
		state      = State.EVADING
		_plan_evasion()
		return

	if hack_timer >= HACK_TIME:
		hack_timer = 0.0
		_complete_hack()

func _complete_hack() -> void:
	if current_hack_terminal != null:
		var tid  : int     = current_hack_terminal.get_meta("terminal_id")
		var wpos : Vector2 = position
		GameManager.on_terminal_hacked(tid, wpos)
		current_hack_terminal.set_meta("hacked", true)
		current_hack_terminal = null

	# Plan next objective after brief pause
	await get_tree().create_timer(0.3).timeout
	state = State.MOVING
	_plan_next_objective()

# ─── Hiding State ─────────────────────────────────────────────────────────────
func _do_hiding(delta: float) -> void:
	hide_timer += delta
	if hide_timer > 2.5 and not _warden_too_close(FOV_SAFE_DIST):
		state      = State.MOVING
		hide_timer = 0.0
		_plan_next_objective()   # Replan with fresh safety map

func _enter_hiding() -> void:
	state      = State.HIDING
	hide_timer = 0.0
	print("[Ghost] Hiding — Warden too close!")
	# Small noise suppression movement to nearest shadow
	var shadow := _find_nearest_shadow()
	if shadow != cell:
		path = [shadow]

# ─── Evading State ────────────────────────────────────────────────────────────
func _do_evading(delta: float) -> void:
	_do_moving(delta)
	if path.is_empty() and not _warden_too_close(FOV_SAFE_DIST):
		state = State.MOVING
		_plan_next_objective()

func _plan_evasion() -> void:
	# Find safest reachable cell away from Warden
	var w_cell: Vector2i = warden.cell if warden else cell
	var best_cell := cell
	var best_dist := 0
	for neighbor in level.get_neighbors(cell):
		var d := int((neighbor - w_cell).length_squared())
		if d > best_dist:
			best_dist = d
			best_cell = neighbor
	path = [best_cell]
	print("[Ghost] Evading to %s" % str(best_cell))

# ─── Objective Planning ───────────────────────────────────────────────────────
func _plan_next_objective() -> void:
	if objective_queue.is_empty():
		return
	current_target = objective_queue[0]
	path = _get_safe_path(cell, current_target)
	if path.is_empty() and cell != current_target:
		# Fallback: try direct path ignoring safety
		path = level.find_path(cell, current_target)
	print("[Ghost] Planned path to %s (%d steps)" % [str(current_target), path.size()])

func _on_reached_objective() -> void:
	if objective_queue.is_empty():
		return
	var obj := objective_queue[0]
	if cell == obj or (cell - obj).length() < 1.5:
		objective_queue.remove_at(0)
		# Is this a terminal?
		var terminal := _terminal_at_cell(obj)
		if terminal != null and not terminal.get_meta("hacked", false):
			current_hack_terminal = terminal
			state      = State.HACKING
			hack_timer = 0.0
			print("[Ghost] Hacking terminal at %s" % str(obj))
		elif obj == Level.EXIT_CELL:
			if GameManager.all_hacked():
				state = State.ESCAPED
				GameManager.end_game("Ghost")
				print("[Ghost] ESCAPED with all data!")
			else:
				# Not done yet, replan
				objective_queue.append(Level.EXIT_CELL)
				if not objective_queue.is_empty():
					_plan_next_objective()
		else:
			_plan_next_objective()

# ─── Helpers ─────────────────────────────────────────────────────────────────
func _warden_too_close(min_dist: int) -> bool:
	if warden == null:
		return false
	return int((cell - warden.cell).length()) <= min_dist or warden.can_see_cell(cell)

func _terminal_at_cell(c: Vector2i) -> Node2D:
	if level == null:
		return null
	for t in level.terminal_nodes:
		if t.get_meta("terminal_cell", Vector2i(-1,-1)) == c:
			return t
	return null

func _find_nearest_shadow() -> Vector2i:
	# Prefer cells not in Warden's FOV and surrounded by walls
	var best      := cell
	var best_score := -1
	for neighbor in level.get_neighbors(cell):
		var score := 0
		if not _warden_can_see(neighbor):
			score += 3
		# Prefer cells next to walls (cover)
		for d in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
			if not level.is_walkable(neighbor + d):
				score += 1
		if score > best_score:
			best_score = score
			best       = neighbor
	return best

func _on_game_over(_w: String) -> void:
	if _w != "Ghost":
		state = State.CAUGHT
	set_process(false)

func _on_alarm(_pos: Vector2) -> void:
	if state == State.HACKING:
		return   # Committed to hack — finish it
	# Replan with updated safety map on alarm
	await get_tree().create_timer(0.1).timeout
	if state == State.MOVING:
		_plan_next_objective()

# ─── Drawing (Minecraft-style character like Image 3) ─────────────────────────
func _draw() -> void:
	var s  := float(TS) * 0.85
	var ox := -s * 0.5
	var oy := -s * 0.5

	# Leg animation
	var leg_sway := sin(anim_tick * 8.0) * 3.0 if state == State.MOVING else 0.0

	# Shadow
	_draw_shadow_ellipse(Vector2(0, oy + s * 0.95), s * 0.35, s * 0.08, Color(0,0,0,0.3))

	# ── Body (blue shirt with overalls — like Image 3) ──
	# Overalls straps (orange/brown)
	draw_rect(Rect2(ox+s*0.22, oy+s*0.40, s*0.12, s*0.38), Color(0.72, 0.42, 0.10))
	draw_rect(Rect2(ox+s*0.60, oy+s*0.40, s*0.12, s*0.38), Color(0.72, 0.42, 0.10))
	# Main shirt (teal/blue — infiltrator color)
	draw_rect(Rect2(ox+s*0.20, oy+s*0.42, s*0.60, s*0.35), Color(0.10, 0.55, 0.70))

	# ── Legs ──
	draw_rect(Rect2(ox+s*0.22, oy+s*0.77, s*0.24, s*0.22),
			  Color(0.20, 0.25, 0.50), false)  # outline
	draw_rect(Rect2(ox+s*0.22+1, oy+s*0.77+leg_sway,  s*0.22, s*0.20), Color(0.20, 0.25, 0.50))
	draw_rect(Rect2(ox+s*0.54,   oy+s*0.77-leg_sway,  s*0.22, s*0.20), Color(0.18, 0.22, 0.45))
	# Boots
	draw_rect(Rect2(ox+s*0.20+1, oy+s*0.95+leg_sway,  s*0.24, s*0.06), Color(0.25, 0.15, 0.05))
	draw_rect(Rect2(ox+s*0.52,   oy+s*0.95-leg_sway,  s*0.24, s*0.06), Color(0.25, 0.15, 0.05))

	# ── Head ──
	# Skin tone
	draw_rect(Rect2(ox+s*0.18, oy+s*0.05, s*0.64, s*0.36), Color(0.90, 0.72, 0.56))
	# Hair (brown — like Image 3)
	draw_rect(Rect2(ox+s*0.16, oy,         s*0.68, s*0.14), Color(0.45, 0.23, 0.08))
	draw_rect(Rect2(ox+s*0.16, oy+s*0.05, s*0.10, s*0.20), Color(0.45, 0.23, 0.08)) # sideburn L
	draw_rect(Rect2(ox+s*0.74, oy+s*0.05, s*0.10, s*0.20), Color(0.45, 0.23, 0.08)) # sideburn R
	# Cap / Helmet (dark gray for stealth)
	draw_rect(Rect2(ox+s*0.14, oy-s*0.02, s*0.72, s*0.10), Color(0.20, 0.22, 0.28))
	draw_rect(Rect2(ox+s*0.08, oy+s*0.06, s*0.20, s*0.05), Color(0.20, 0.22, 0.28)) # brim

	# Eyes (blue — like Image 3)
	var blink_h := 0.07 if int(anim_tick * 3) % 12 != 0 else 0.02
	draw_rect(Rect2(ox+s*0.28, oy+s*0.18, s*0.14, s*blink_h), Color(0.15, 0.40, 0.90))
	draw_rect(Rect2(ox+s*0.58, oy+s*0.18, s*0.14, s*blink_h), Color(0.15, 0.40, 0.90))
	# Pupils
	draw_rect(Rect2(ox+s*0.32, oy+s*0.19, s*0.06, s*0.05), Color(0.05, 0.10, 0.30))
	draw_rect(Rect2(ox+s*0.62, oy+s*0.19, s*0.06, s*0.05), Color(0.05, 0.10, 0.30))
	# Mouth
	draw_rect(Rect2(ox+s*0.34, oy+s*0.30, s*0.32, s*0.04), Color(0.60, 0.30, 0.25))

	# ── Sword (small, like Image 3 — only when moving/idle) ──
	if state != State.HACKING:
		var sx := s * 0.82 if facing_right else -s * 0.30
		var sy := oy + s * 0.40
		# Hilt (brown)
		draw_rect(Rect2(ox+sx, sy + s*0.10, s*0.10, s*0.06), Color(0.50, 0.28, 0.05))
		# Blade (silver)
		draw_rect(Rect2(ox+sx+s*0.03, sy, s*0.04, s*0.12), Color(0.80, 0.85, 0.90))
		# Gem (red — like Image 3)
		draw_rect(Rect2(ox+sx+s*0.02, sy+s*0.11, s*0.06, s*0.06), Color(0.90, 0.15, 0.10))

	# ── State indicators ──
	match state:
		State.HACKING:
			# Hacking progress ring / bar above head
			var hack_frac := hack_timer / HACK_TIME
			draw_rect(Rect2(ox+s*0.1, oy-s*0.20, s*0.80, s*0.08), Color(0.1, 0.1, 0.1))
			draw_rect(Rect2(ox+s*0.1, oy-s*0.20, s*0.80*hack_frac, s*0.08), Color(0.0, 0.9, 0.4))
			# Glow effect
			draw_circle(Vector2(0, oy*0.5), s*0.08, Color(0.0, 0.9, 0.4, 0.4))
		State.HIDING:
			# Dim overlay — crouching
			draw_rect(Rect2(ox, oy, s, s), Color(0, 0, 0, 0.3))
		State.EVADING:
			# Orange outline — running!
			draw_rect(Rect2(ox-2, oy-2, s+4, s+4), Color(1.0, 0.5, 0.0, 0.6), false)

	# Flip if facing left
	if not facing_right:
		pass   # Simple approach: just draw mirrored via scale in transform

func _draw_shadow_ellipse(center: Vector2, radiusX: float, radiusY: float, color: Color, filled: bool = true, lineWidth: float = 1.0, antialiased: bool = false) -> void:
	var pts: PackedVector2Array = PackedVector2Array()
	for i in range(16):
		var angle := float(i) / 16.0 * TAU
		pts.append(center + Vector2(cos(angle) * radiusX, sin(angle) * radiusY))
	draw_colored_polygon(pts, color)
