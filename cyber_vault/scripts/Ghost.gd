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
const HACK_TIME     := 2.0    # seconds to hack one terminal
const NOISE_THRESH  := 0.15   # movement faster than this creates noise
const FOV_SAFE_DIST := 4      # cells away from Warden FOV to feel safe
const REPLAN_INTERVAL := 0.20
const REFUGE_COLLISION_LIMIT := 6.5
const POST_SAFE_COMMIT_TIME := 1.8
const SAFE_ROOM_EXIT_MIN_DIST := 4
const LOOP_REPLAN_LIMIT := 6
const LOOP_STUCK_SECONDS := 2.2
const RECENT_CELL_LIMIT := 10

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
var cell          : Vector2i = Vector2i(10, 14)
var path          : Array[Vector2i] = []
var move_timer    : float    = 0.0
var current_speed : float    = MOVE_SPEED
var replan_timer  : float    = 0.0
var refuge_cell   : Vector2i = Vector2i(-1, -1)
var post_safe_commit_timer: float = 0.0
var _last_plan_log_target: Vector2i = Vector2i(-999, -999)
var _last_plan_log_steps: int = -1
var _last_plan_log_ms: int = -100000
var _last_progress_cell: Vector2i = Vector2i(-1, -1)
var _stuck_timer: float = 0.0
var _recent_cells: Array[Vector2i] = []
var _same_plan_repeat_count: int = 0
var _last_planned_target: Vector2i = Vector2i(-1, -1)
var _last_planned_steps: int = -1

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
	if level != null and level.has_method("get_ghost_spawn"):
		cell = level.get_ghost_spawn()
	position = GameManager.cell_to_world_center(cell)
	z_index  = 5

	# Build objective queue: T3 → T2 → T1 → EXIT (nearest-first heuristic)
	_build_objective_queue()

	# Connect to game events
	GameManager.game_over.connect(_on_game_over)
	GameManager.alarm_triggered.connect(_on_alarm)

	# Give Warden a moment to spawn before we start
	await get_tree().create_timer(0.5).timeout
	_last_progress_cell = cell
	_recent_cells = [cell]
	state = State.MOVING
	_plan_next_objective()
	print("[Ghost] AI started — targeting %d terminals then escape" % objective_queue.size())

# ─── Objective Queue ─────────────────────────────────────────────────────────
func _build_objective_queue() -> void:
	objective_queue.clear()

	# Sort terminals by distance from spawn (greedy nearest-first)
	var terminals_sorted: Array[Vector2i] = []
	if level != null and level.has_method("get_terminal_cells"):
		for t in level.get_terminal_cells():
			terminals_sorted.append(t)

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
	objective_queue.append(_exit_cell())

# ─── Process ─────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if GameManager.game_state != GameManager.GameState.PLAYING:
		return
	if _is_caught_by_warden_now():
		_on_caught_by_warden()
		return
	if post_safe_commit_timer > 0.0:
		post_safe_commit_timer = maxf(0.0, post_safe_commit_timer - delta)

	anim_tick += delta
	_update_safety_map()
	_decide(delta)
	_update_loop_guard(delta)
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
	# If danger is detected, seek refuge first, then fallback to evasion.
	# After leaving a safe room, keep a short commitment window to avoid ping-pong loops.
	var soft_danger := _is_in_danger(false)
	var strict_danger := _is_in_danger(true)
	if strict_danger or (soft_danger and post_safe_commit_timer <= 0.0):
		if _plan_danger_response():
			return
		_enter_hiding()
		return

	if path.is_empty():
		# Replan if objective not reached yet (prevents deadlock when route is invalidated).
		if _has_reached_cell(current_target):
			_on_reached_objective()
		else:
			replan_timer += delta
			if replan_timer >= REPLAN_INTERVAL:
				replan_timer = 0.0
				_plan_next_objective()
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
	_push_recent_cell(cell)

# ─── Hacking State ────────────────────────────────────────────────────────────
func _do_hacking(delta: float) -> void:
	hack_timer += delta

	# Abort if danger rises while hacking and route to safety.
	if _is_in_danger(true):
		hack_timer = 0.0
		if not _plan_danger_response():
			state = State.EVADING
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
	if not path.is_empty():
		move_timer += delta
		if move_timer >= HIDE_SPEED:
			move_timer = 0.0
			_step_path()
		return

	# If already sheltered inside a sleep room, leave hiding after a short cooldown
	# when Warden is not adjacent.
	if level != null and level.is_sleep_room(cell):
		hide_timer += delta
		var can_exit := hide_timer >= 0.8 and not _is_in_danger(true) and _distance_to_warden() >= SAFE_ROOM_EXIT_MIN_DIST
		if can_exit:
			if _plan_after_safe_room_exit():
				state = State.MOVING
				hide_timer = 0.0
				refuge_cell = Vector2i(-1, -1)
			else:
				# Stay hidden if every terminal route is still too risky.
				hide_timer = 0.4
		return

	if _is_in_danger(false) and not level.is_sleep_room(cell):
		replan_timer += delta
		if replan_timer >= REPLAN_INTERVAL:
			replan_timer = 0.0
			if _plan_danger_response():
				return

	hide_timer += delta
	if hide_timer > 2.0 and not _is_in_danger(false):
		state      = State.MOVING
		hide_timer = 0.0
		refuge_cell = Vector2i(-1, -1)
		_plan_next_objective()   # Replan with fresh safety map

func _enter_hiding() -> void:
	state      = State.HIDING
	hide_timer = 0.0
	move_timer = 0.0
	print("[Ghost] Hiding — Warden too close!")
	# Small noise suppression movement to nearest shadow
	var shadow := _find_nearest_shadow()
	if shadow != cell:
		path = [shadow]

# ─── Evading State ────────────────────────────────────────────────────────────
func _do_evading(delta: float) -> void:
	if _is_in_danger(false) and _plan_danger_response():
		return

	if path.is_empty():
		state = State.MOVING
		_plan_next_objective()
		return

	move_timer += delta
	if move_timer >= FAST_SPEED:
		move_timer = 0.0
		_step_path()

	if path.is_empty() and not _warden_too_close(FOV_SAFE_DIST):
		state = State.MOVING
		_plan_next_objective()

func _plan_evasion() -> void:
	# Find safest reachable cell away from Warden
	var w_cell: Vector2i = warden.cell if warden else cell
	var best_cell := cell
	var best_score := -INF
	for neighbor in level.get_neighbors(cell):
		var dist_score := float((neighbor - w_cell).length_squared())
		var danger_penalty := float(safety_weights.get(neighbor, 0.0)) * 8.0
		var vision_penalty := 8.0 if _warden_can_see(neighbor) else 0.0
		var loop_penalty := _recent_visit_penalty(neighbor) * 3.0
		var score := dist_score - danger_penalty - vision_penalty - loop_penalty
		if score > best_score:
			best_score = score
			best_cell = neighbor
	path = [best_cell]
	print("[Ghost] Evading to %s" % str(best_cell))

# ─── Objective Planning ───────────────────────────────────────────────────────
func _plan_next_objective() -> void:
	# Drop stale hacked terminals from front of queue.
	while not objective_queue.is_empty():
		var front := objective_queue[0]
		var front_terminal := _terminal_at_cell(front)
		if front_terminal != null and front_terminal.get_meta("hacked", false):
			objective_queue.remove_at(0)
			continue
		break

	if objective_queue.is_empty():
		objective_queue.append(_exit_cell())

	if objective_queue.is_empty():
		return
	current_target = objective_queue[0]
	path = _get_safe_path(cell, current_target)
	if path.is_empty() and cell != current_target:
		# Fallback: try direct path ignoring safety
		path = level.find_path(cell, current_target)
	replan_timer = 0.0
	_update_plan_repeat_counter(current_target, path.size())
	if _same_plan_repeat_count >= LOOP_REPLAN_LIMIT and not _has_reached_cell(current_target):
		_same_plan_repeat_count = 0
		state = State.EVADING
		_plan_evasion()
		return
	_log_plan_path(current_target, path.size())

func _plan_after_safe_room_exit() -> bool:
	var remaining := _remaining_unhacked_terminals()
	if remaining.is_empty():
		objective_queue.clear()
		objective_queue.append(_exit_cell())
		_plan_next_objective()
		return true

	var nearest_terminal := Vector2i(-1, -1)
	var nearest_route: Array[Vector2i] = []
	var nearest_len := 999999

	for t in remaining:
		var route := _path_to_cell(t)
		if route.is_empty() and t != cell:
			continue
		if route.size() < nearest_len:
			nearest_len = route.size()
			nearest_terminal = t
			nearest_route = route

	var chosen := nearest_terminal
	if chosen == Vector2i(-1, -1):
		# Corner case: no reachable terminal route now; keep objectives and retry default planning.
		return false

	var nearest_risk := _path_collision_risk(nearest_route)
	var chosen_risk := nearest_risk
	if nearest_risk > REFUGE_COLLISION_LIMIT:
		# Nearest terminal is risky; choose safer terminal using same risk-based strategy.
		var best_score := INF
		chosen_risk = INF
		for t in remaining:
			var route := _path_to_cell(t)
			if route.is_empty() and t != cell:
				continue
			var risk := _path_collision_risk(route)
			var score := risk * 3.2 + float(route.size()) * 0.35 + _terminal_access_cost(t) * 0.28
			if score < best_score:
				best_score = score
				chosen = t
				chosen_risk = risk

	# Do not leave safe room if selected route is still highly risky.
	if chosen_risk > REFUGE_COLLISION_LIMIT:
		return false

	_rebuild_objective_queue_with_priority(chosen)
	post_safe_commit_timer = POST_SAFE_COMMIT_TIME
	_plan_next_objective()
	return true

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
			GameManager.on_hacking_started(int(terminal.get_meta("terminal_id", 0)), position)
			print("[Ghost] Hacking terminal at %s" % str(obj))
		elif obj == _exit_cell():
			if GameManager.all_hacked():
				state = State.ESCAPED
				GameManager.end_game("Ghost")
				print("[Ghost] ESCAPED with all data!")
			else:
				# Not done yet, replan
				objective_queue.append(_exit_cell())
				if not objective_queue.is_empty():
					_plan_next_objective()
		else:
			_plan_next_objective()

# ─── Helpers ─────────────────────────────────────────────────────────────────
func _warden_too_close(min_dist: int) -> bool:
	if warden == null:
		return false
	var dist_close := int((cell - warden.cell).length()) <= min_dist
	if level != null and level.is_sleep_room(cell):
		return dist_close
	return dist_close or warden.can_see_cell(cell)

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

func _is_in_danger(strict: bool) -> bool:
	if warden == null:
		return false
	if level != null and level.is_sleep_room(cell):
		# Sleep room grants visual safety; only immediate proximity is dangerous.
		return _warden_too_close(1)
	if warden.can_see_cell(cell):
		return true
	var dist := int((cell - warden.cell).length())
	if strict:
		return dist <= 3
	return dist <= 2 or (GameManager.alert_level >= GameManager.AlertLevel.ALERT and dist <= 4)

func _plan_danger_response() -> bool:
	if level == null:
		return false

	var sleep_rooms: Array[Vector2i] = _get_sleep_rooms()
	if sleep_rooms.is_empty():
		return false

	var nearest_room := Vector2i(-1, -1)
	var nearest_path: Array[Vector2i] = []
	var nearest_dist := 999999

	for room in sleep_rooms:
		var route := _path_to_cell(room)
		if route.is_empty() and room != cell:
			continue
		if route.size() < nearest_dist:
			nearest_dist = route.size()
			nearest_room = room
			nearest_path = route

	if nearest_room == Vector2i(-1, -1):
		return false

	var nearest_risk := _path_collision_risk(nearest_path)
	if nearest_risk <= REFUGE_COLLISION_LIMIT:
		state = State.HIDING
		refuge_cell = nearest_room
		path = nearest_path
		hide_timer = 0.0
		move_timer = 0.0
		return true

	# Nearest refuge has collision risk; pick safer strategic alternative.
	var best_room := nearest_room
	var best_path := nearest_path
	var best_score := INF
	for room in sleep_rooms:
		var route := _path_to_cell(room)
		if route.is_empty() and room != cell:
			continue
		var risk := _path_collision_risk(route)
		var access_cost := _terminal_access_cost(room)
		var score := risk * 3.2 + float(route.size()) * 0.35 + access_cost * 0.28
		if score < best_score:
			best_score = score
			best_room = room
			best_path = route

	state = State.HIDING
	refuge_cell = best_room
	path = best_path
	hide_timer = 0.0
	move_timer = 0.0
	return true

func _get_sleep_rooms() -> Array[Vector2i]:
	var rooms: Array[Vector2i] = []
	if level.has_method("get_sleep_room_cells"):
		for c in level.get_sleep_room_cells():
			rooms.append(c)
		return rooms

	for r in range(GameManager.GRID_ROWS):
		for c in range(GameManager.GRID_COLS):
			var cell_pos := Vector2i(c, r)
			if level.is_sleep_room(cell_pos):
				rooms.append(cell_pos)
	return rooms

func _path_to_cell(target: Vector2i) -> Array[Vector2i]:
	var safe_path := _get_safe_path(cell, target)
	if safe_path.is_empty() and target != cell:
		safe_path = level.find_path(cell, target)
	return safe_path

func _predict_warden_cells(steps: int) -> Array[Vector2i]:
	var predicted: Array[Vector2i] = []
	if warden == null:
		return predicted
	var warden_cell_any = warden.get("cell")
	var last: Vector2i = cell
	if warden_cell_any is Vector2i:
		last = warden_cell_any
	predicted.append(last)

	var wpath_any = warden.get("path")
	var wpath: Array = []
	if wpath_any is Array:
		wpath = wpath_any

	var idx := 0
	for _i in range(steps):
		if idx < wpath.size():
			last = Vector2i(wpath[idx])
			idx += 1
		predicted.append(last)

	return predicted

func _path_collision_risk(route: Array[Vector2i]) -> float:
	if warden == null:
		return 0.0
	var horizon := maxi(6, route.size() + 2)
	var predicted := _predict_warden_cells(horizon)
	if predicted.is_empty():
		return 0.0

	var risk := 0.0
	var prev_g := cell
	for i in range(route.size()):
		var g: Vector2i = route[i]
		var idx := mini(i + 1, predicted.size() - 1)
		var w: Vector2i = predicted[idx]
		var w_prev: Vector2i = predicted[maxi(0, idx - 1)]

		var dist := float((g - w).length())
		if dist < 0.1:
			risk += 10.0
		elif dist <= 1.0:
			risk += 6.0
		elif dist <= 2.0:
			risk += 2.0

		if g == w_prev and prev_g == w:
			risk += 7.0
		if _warden_can_see(g):
			risk += 2.0
		risk += float(safety_weights.get(g, 0.0)) * 3.0
		prev_g = g

	return risk

func _terminal_access_cost(from_cell: Vector2i) -> float:
	if level == null:
		return 0.0
	var costs: Array[float] = []
	for t in level.terminal_nodes:
		if t.get_meta("hacked", false):
			continue
		var tc: Vector2i = t.get_meta("terminal_cell", Vector2i(-1, -1))
		if tc == Vector2i(-1, -1):
			continue
		costs.append(float((from_cell - tc).length()))

	if costs.is_empty():
		return float((from_cell - _exit_cell()).length())

	costs.sort()
	var sample := mini(2, costs.size())
	var total := 0.0
	for i in range(sample):
		total += costs[i]
	return total / float(sample)

func _remaining_unhacked_terminals() -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if level == null:
		return result
	for t in level.terminal_nodes:
		if t.get_meta("hacked", false):
			continue
		var tc: Vector2i = t.get_meta("terminal_cell", Vector2i(-1, -1))
		if tc != Vector2i(-1, -1):
			result.append(tc)
	return result

func _rebuild_objective_queue_with_priority(priority_terminal: Vector2i) -> void:
	var remaining := _remaining_unhacked_terminals()
	objective_queue.clear()

	if remaining.is_empty():
		objective_queue.append(_exit_cell())
		return

	var ordered: Array[Vector2i] = []
	if priority_terminal != Vector2i(-1, -1) and remaining.has(priority_terminal):
		ordered.append(priority_terminal)
		remaining.erase(priority_terminal)

	var start := priority_terminal if priority_terminal != Vector2i(-1, -1) else cell
	while not remaining.is_empty():
		var best_idx := 0
		var best_dist := 999999
		for i in range(remaining.size()):
			var d := (remaining[i] - start).length()
			if d < best_dist:
				best_dist = d
				best_idx = i
		ordered.append(remaining[best_idx])
		start = remaining[best_idx]
		remaining.remove_at(best_idx)

	for t in ordered:
		objective_queue.append(t)
	objective_queue.append(_exit_cell())

func _has_reached_cell(target: Vector2i) -> bool:
	if target == Vector2i(-1, -1):
		return false
	return cell == target or (cell - target).length() < 1.5

func _distance_to_warden() -> int:
	if warden == null:
		return 999
	return int((cell - warden.cell).length())

func _push_recent_cell(c: Vector2i) -> void:
	if _recent_cells.is_empty() or _recent_cells[_recent_cells.size() - 1] != c:
		_recent_cells.append(c)
	if _recent_cells.size() > RECENT_CELL_LIMIT:
		_recent_cells.remove_at(0)

func _recent_visit_penalty(c: Vector2i) -> float:
	var count := 0
	for rc in _recent_cells:
		if rc == c:
			count += 1
	return float(count)

func _is_oscillating() -> bool:
	var n := _recent_cells.size()
	if n < 4:
		return false
	var a: Vector2i = _recent_cells[n - 1]
	var b: Vector2i = _recent_cells[n - 2]
	var c: Vector2i = _recent_cells[n - 3]
	var d: Vector2i = _recent_cells[n - 4]
	return a == c and b == d and a != b

func _update_plan_repeat_counter(target: Vector2i, steps: int) -> void:
	if target == _last_planned_target and abs(steps - _last_planned_steps) <= 1:
		_same_plan_repeat_count += 1
	else:
		_same_plan_repeat_count = 0
	_last_planned_target = target
	_last_planned_steps = steps

func _update_loop_guard(delta: float) -> void:
	var active_motion_state := state == State.MOVING or state == State.HIDING or state == State.EVADING
	if active_motion_state and not path.is_empty():
		if cell == _last_progress_cell:
			_stuck_timer += delta
		else:
			_stuck_timer = 0.0
			_last_progress_cell = cell

	if _stuck_timer >= LOOP_STUCK_SECONDS or _is_oscillating():
		_stuck_timer = 0.0
		_recent_cells.clear()
		_recent_cells.append(cell)
		if not _plan_danger_response():
			state = State.EVADING
			_plan_evasion()

func _log_plan_path(target: Vector2i, steps: int) -> void:
	var now_ms := Time.get_ticks_msec()
	var is_duplicate := target == _last_plan_log_target and steps == _last_plan_log_steps and (now_ms - _last_plan_log_ms) < 2000
	if is_duplicate:
		return
	_last_plan_log_target = target
	_last_plan_log_steps = steps
	_last_plan_log_ms = now_ms
	print("[Ghost] Planned path to %s (%d steps)" % [str(target), steps])

func _exit_cell() -> Vector2i:
	if level != null and level.has_method("get_exit_cell"):
		return level.get_exit_cell()
	return Vector2i(17, 1)

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

func _is_caught_by_warden_now() -> bool:
	if warden == null or level == null:
		return false
	if level.is_sleep_room(cell):
		return false
	return float((cell - warden.cell).length()) <= 1.4

func _on_caught_by_warden() -> void:
	state = State.CAUGHT
	if GameManager.game_state != GameManager.GameState.GAME_OVER:
		GameManager.end_game("Warden")

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
