class_name Warden
## =============================================================================
## Warden.gd  —  Security Guard AI Agent
## AI Algorithm: Minimax with Alpha-Beta Pruning + Probability Heatmap
##
## Behaviour:
##   PATROL     → Follow fixed patrol route; use heatmap to pick waypoints
##   INVESTIGATE→ Move toward last known noise/alarm location
##   CHASE      → Ghost spotted! Use Minimax to predict & intercept optimal path
##   SEARCH     → Ghost lost; scan heatmap-hottest cells systematically
## =============================================================================
extends Node2D

# ─── Constants ────────────────────────────────────────────────────────────────
const TS            := GameManager.TILE_SIZE
const PATROL_SPEED  := 0.30   # seconds per tile (slow patrol)
const CHASE_SPEED   := 0.20   # faster when chasing
const SEARCH_SPEED  := 0.25
const CATCH_DIST    := 1.4   # cells — catching distance
const FOV_ANGLE_DEG := 90.0   # degrees
const CATCH_RADIUS  : float = 1.4
const SEARCH_LOOP_LIMIT := 5

# ─── Exposed to Ghost.gd ──────────────────────────────────────────────────────
var fov_range : int = 6        # cells the Warden can see forward

# ─── Enums ────────────────────────────────────────────────────────────────────
enum State { PATROL, INVESTIGATE, CHASE, SEARCH }
enum Facing { RIGHT=0, LEFT=1, DOWN=2, UP=3 }

# ─── References ───────────────────────────────────────────────────────────────
var level    : Node2D
var ghost    : Node2D   # Set by Level after both spawned

# ─── Position ─────────────────────────────────────────────────────────────────
var cell      : Vector2i = Vector2i(1, 14)
var facing    : Facing   = Facing.RIGHT
var path      : Array[Vector2i] = []
var move_timer: float = 0.0
var speed     : float = PATROL_SPEED

# ─── State ────────────────────────────────────────────────────────────────────
var state       : State   = State.PATROL
var last_seen   : Vector2i = Vector2i(-1, -1)   # Ghost's last known cell
var target_cell : Vector2i = Vector2i(-1, -1)
var search_cells: Array[Vector2i] = []
var memory_locked_until_terminal_hacked: bool = false
var _ghost_was_in_safe_room: bool = false
var _last_search_hot: Vector2i = Vector2i(-1, -1)
var _same_search_hot_count: int = 0

# ─── Minimax config ──────────────────────────────────────────────────────────
const MINIMAX_DEPTH := 4      # Look-ahead depth (2 full rounds each)

# ─── Patrol route ─────────────────────────────────────────────────────────────
var patrol_route   : Array[Vector2i] = []
var patrol_idx     : int             = 0

# ─── Vision cone polygon (for drawing) ───────────────────────────────────────
var fov_poly: PackedVector2Array = PackedVector2Array()

# ─── Animation ────────────────────────────────────────────────────────────────
var anim_tick : float = 0.0

# ─── Ready ────────────────────────────────────────────────────────────────────
func _ready() -> void:
	if level != null and level.has_method("get_warden_spawn"):
		cell = level.get_warden_spawn()
	position = GameManager.cell_to_world_center(cell)
	z_index  = 4
	_build_patrol_route()
	GameManager.game_over.connect(_on_game_over)
	GameManager.alarm_triggered.connect(_on_alarm)
	GameManager.hacking_started.connect(_on_hacking_started)
	GameManager.terminal_hacked.connect(_on_terminal_hacked)

	await get_tree().create_timer(0.8).timeout
	state = State.PATROL
	_plan_patrol()

# ─── Patrol Route ─────────────────────────────────────────────────────────────
func _build_patrol_route() -> void:
	if level != null and level.has_method("get_dynamic_patrol_route"):
		patrol_route = level.get_dynamic_patrol_route()
		if not patrol_route.is_empty():
			return

	# Warden patrols a loop covering all terminal areas
	patrol_route = [
		Vector2i(1, 1),    # Near T1
		Vector2i(3, 1),    # T1 area
		Vector2i(3, 5),    # T2 area
		Vector2i(9, 3),    # Center top
		Vector2i(17, 1),   # Exit area (guard the exit!)
		Vector2i(17, 7),   # Right side
		Vector2i(9, 10),   # T3 area
		Vector2i(5, 13),   # Bottom center
		Vector2i(1, 8),    # Left corridor
		Vector2i(1, 1),    # Back to start
	]

# ─── Process ─────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if GameManager.game_state != GameManager.GameState.PLAYING:
		return
	anim_tick += delta
	_update_fov_polygon()
	_check_catch()
	_update_safe_room_memory_state()
	_check_vision()
	_update_ai(delta)
	queue_redraw()

# ─── AI Decision Loop ─────────────────────────────────────────────────────────
func _update_ai(delta: float) -> void:
	move_timer += delta
	if move_timer < speed:
		return
	move_timer = 0.0

	match state:
		State.PATROL:
			_do_patrol()
		State.INVESTIGATE:
			_do_investigate()
		State.CHASE:
			_do_chase()
		State.SEARCH:
			_do_search()

# ─── Patrol ───────────────────────────────────────────────────────────────────
func _do_patrol() -> void:
	speed = PATROL_SPEED
	if path.is_empty():
		_plan_patrol()
		return
	_step()

func _plan_patrol() -> void:
	if patrol_route.is_empty():
		patrol_route = [cell]
	var target := patrol_route[patrol_idx % patrol_route.size()]
	patrol_idx += 1
	path = level.find_path(cell, target)

# ─── Investigate ──────────────────────────────────────────────────────────────
func _do_investigate() -> void:
	speed = SEARCH_SPEED
	if path.is_empty() or cell == target_cell:
		# Reached target — scan around then return to patrol
		state = State.SEARCH
		_plan_search_from(cell)
		return
	_step()

# ─── Chase (uses Minimax) ─────────────────────────────────────────────────────
func _do_chase() -> void:
	speed = CHASE_SPEED
	if ghost == null or not _can_see_ghost():
		# Lost the Ghost — switch to search
		print("[Warden] Lost ghost! Switching to SEARCH")
		state = State.SEARCH
		var anchor := last_seen
		if memory_locked_until_terminal_hacked or not _is_valid_search_cell(anchor):
			anchor = cell
		_plan_search_from(anchor)
		return

	# ── MINIMAX: compute best intercept move ──────────────────────────────────
	var best_move := _minimax_best_move()
	if best_move != cell:
		path = [best_move]
	_step()

## Minimax entry point — returns best next cell for Warden to move to
## Warden = MAXIMIZER (maximizes ghost proximity / capture score)
## Ghost   = MINIMIZER (minimizes proximity / avoids capture)
func _minimax_best_move() -> Vector2i:
	var ghost_cell: Vector2i = ghost.cell if ghost else cell
	var best_cell  := cell
	var best_score := -INF
	var alpha      := -INF
	var beta       := INF

	for move in level.get_neighbors(cell):
		var score := _minimax(move, ghost_cell, MINIMAX_DEPTH - 1, false, alpha, beta)
		if score > best_score:
			best_score = score
			best_cell  = move
		alpha = maxf(alpha, best_score)
	return best_cell

## Recursive Minimax with Alpha-Beta Pruning
## warden_c: Warden's hypothetical cell
## ghost_c:  Ghost's hypothetical cell
## maximizing: true = Warden's turn, false = Ghost's turn
func _minimax(warden_c: Vector2i, ghost_c: Vector2i,
			  depth: int, maximizing: bool, alpha: float, beta: float) -> float:
	# Base case: terminal state or max depth
	if depth == 0 or _is_caught(warden_c, ghost_c):
		return _evaluate(warden_c, ghost_c)

	if maximizing:
		# Warden picks move that maximizes score (closes distance)
		var best := -INF
		for move in level.get_neighbors(warden_c):
			var val := _minimax(move, ghost_c, depth - 1, false, alpha, beta)
			best  = maxf(best, val)
			alpha = maxf(alpha, best)
			if beta <= alpha:
				break   # ── Alpha cutoff (pruning) ──
		return best
	else:
		# Ghost picks move that minimizes score (maximizes distance)
		var best := INF
		for move in level.get_neighbors(ghost_c):
			var val := _minimax(warden_c, move, depth - 1, true, alpha, beta)
			best = minf(best, val)
			beta = minf(beta, best)
			if beta <= alpha:
				break   # ── Beta cutoff (pruning) ──
		return best

## Evaluation function for Minimax leaf nodes
## Returns high score when Warden is close to Ghost (good for Warden)
func _evaluate(warden_c: Vector2i, ghost_c: Vector2i) -> float:
	var dist    := float((warden_c - ghost_c).length())
	var score   := 20.0 - dist   # Closer = higher score

	# Bonus for blocking path to exit
	var exit := _exit_cell()
	var exit_dist_ghost  := float((ghost_c - exit).length())
	var exit_dist_warden := float((warden_c - exit).length())
	if exit_dist_warden < exit_dist_ghost:
		score += 5.0   # Warden is between Ghost and exit

	# Bonus for being near hacked terminals (Ghost needs to revisit)
	score += GameManager.get_heat(warden_c) * 3.0

	return score

func _is_caught(warden_c: Vector2i, ghost_c: Vector2i) -> bool:
	return (warden_c - ghost_c).length() <= CATCH_DIST

# ─── Search (heatmap-guided) ──────────────────────────────────────────────────
func _do_search() -> void:
	speed = SEARCH_SPEED
	if path.is_empty() or cell == target_cell:
		# Reached this search point — pick next hottest cell
		var hot := GameManager.hottest_near(cell, 7)
		if hot == _last_search_hot:
			_same_search_hot_count += 1
		else:
			_same_search_hot_count = 0
		_last_search_hot = hot

		if _same_search_hot_count >= SEARCH_LOOP_LIMIT:
			_same_search_hot_count = 0
			state = State.PATROL
			_plan_patrol()
			return

		if hot != cell:
			target_cell = hot
			path        = level.find_path(cell, hot)
			if path.is_empty() and cell != hot:
				state = State.PATROL
				_plan_patrol()
				return
		else:
			# Heatmap cold — return to patrol
			state = State.PATROL
			_plan_patrol()
		return
	_step()

func _plan_search_from(start: Vector2i) -> void:
	var anchor := start
	if not _is_valid_search_cell(anchor):
		anchor = cell
	var hot := GameManager.hottest_near(anchor, 6)
	if not _is_valid_search_cell(hot):
		hot = anchor
	target_cell = hot
	path        = level.find_path(cell, hot)
	if path.is_empty() and cell != hot:
		state = State.PATROL
		_plan_patrol()
		return
	print("[Warden] Searching toward hottest cell %s" % str(hot))

# ─── Movement Step ────────────────────────────────────────────────────────────
func _step() -> void:
	if path.is_empty():
		return
	var next := path[0]
	path.remove_at(0)

	# Update facing direction
	var diff := next - cell
	if   diff.x > 0: facing = Facing.RIGHT
	elif diff.x < 0: facing = Facing.LEFT
	elif diff.y > 0: facing = Facing.DOWN
	else:             facing = Facing.UP

	cell     = next
	position = GameManager.cell_to_world_center(cell)

# ─── Vision & Detection ───────────────────────────────────────────────────────
func _check_vision() -> void:
	if ghost == null:
		return
	if _can_see_ghost():
		last_seen = ghost.cell
		GameManager.on_visual_contact(ghost.position)
		if state != State.CHASE:
			state = State.CHASE
			print("[Warden] Ghost SPOTTED at %s — CHASE!" % str(ghost.cell))

func _can_see_ghost() -> bool:
	if ghost == null:
		return false
	# Ghost is invisible in sleep rooms
	if level and level.is_sleep_room(ghost.cell):
		return false
	return can_see_cell(ghost.cell)

## Checks if a cell is within the Warden's FOV cone (no ray-blocking for simplicity)
func can_see_cell(target_cell: Vector2i) -> bool:
	var diff := target_cell - cell
	if diff == Vector2i.ZERO:
		return true
	var dist := diff.length()
	if dist > fov_range:
		return false

	# Direction vector to target
	var dir_to := Vector2(float(diff.x), float(diff.y)).normalized()

	# Warden's facing direction vector
	var facing_dir := _facing_vec()

	# Angle check
	var dot   := facing_dir.dot(dir_to)
	var angle := rad_to_deg(acos(clampf(dot, -1.0, 1.0)))
	if angle > FOV_ANGLE_DEG * 0.5:
		return false

	# Simple line-of-sight: check intermediate cells
	for i in range(1, int(dist) + 1):
		var check_pos := Vector2(cell.x, cell.y) + facing_dir * float(i)
		var check_cell := Vector2i(int(check_pos.x + 0.5), int(check_pos.y + 0.5))
		if not level.is_walkable(check_cell) and check_cell != target_cell:
			return false
	return true

func _facing_vec() -> Vector2:
	match facing:
		Facing.RIGHT: return Vector2(1, 0)
		Facing.LEFT:  return Vector2(-1, 0)
		Facing.DOWN:  return Vector2(0, 1)
		_:            return Vector2(0, -1)

# ─── Catch Check ──────────────────────────────────────────────────────────────
func _check_catch() -> void:
	if ghost == null:
		return
	# Ghost is safe in sleep rooms
	if level and level.is_sleep_room(ghost.cell):
		return
	if float((cell - ghost.cell).length()) <= CATCH_DIST:
		print("[Warden] CAUGHT the Ghost!")
		GameManager.end_game("Warden")

# ─── Event Handlers ───────────────────────────────────────────────────────────
func _on_alarm(wpos: Vector2) -> void:
	memory_locked_until_terminal_hacked = false
	var alarm_cell := GameManager.world_to_cell(wpos)
	last_seen      = alarm_cell
	if state != State.CHASE:
		state       = State.INVESTIGATE
		target_cell = alarm_cell
		path        = level.find_path(cell, alarm_cell)
		print("[Warden] Alarm! Investigating %s" % str(alarm_cell))

func _on_terminal_hacked(tid: int, wpos: Vector2) -> void:
	memory_locked_until_terminal_hacked = false
	_on_alarm(wpos)

func _on_hacking_started(tid: int, wpos: Vector2) -> void:
	if memory_locked_until_terminal_hacked:
		return
	if ghost != null and _can_see_ghost():
		return
	if state == State.CHASE:
		state = State.SEARCH
	var clue_cell := GameManager.world_to_cell(wpos)
	last_seen = clue_cell
	state = State.INVESTIGATE
	target_cell = clue_cell
	path = level.find_path(cell, clue_cell)
	print("[Warden] Hacking clue detected near %s" % str(clue_cell))

func _on_game_over(_w: String) -> void:
	set_process(false)

func _update_safe_room_memory_state() -> void:
	if ghost == null or level == null:
		return
	var ghost_cell_any = ghost.get("cell")
	if not (ghost_cell_any is Vector2i):
		return
	var ghost_cell: Vector2i = ghost_cell_any
	var ghost_in_safe: bool = level.is_sleep_room(ghost_cell)
	if ghost_in_safe and not _ghost_was_in_safe_room and not memory_locked_until_terminal_hacked:
		memory_locked_until_terminal_hacked = true
		last_seen = Vector2i(-1, -1)
		if state == State.CHASE or state == State.INVESTIGATE:
			state = State.SEARCH
			_plan_search_from(cell)
		print("[Warden] Ghost entered safe room — last known location forgotten")
	_ghost_was_in_safe_room = ghost_in_safe

func _is_valid_search_cell(c: Vector2i) -> bool:
	if level == null:
		return false
	return level.is_walkable(c)

# ─── FOV Polygon ─────────────────────────────────────────────────────────────
func _update_fov_polygon() -> void:
	fov_poly.clear()
	var origin := Vector2.ZERO   # Local space
	fov_poly.append(origin)
	var fv     := _facing_vec()
	var rays   := 12
	var half   := deg_to_rad(FOV_ANGLE_DEG * 0.5)
	for i in range(rays + 1):
		var t   := float(i) / float(rays)
		var ang: float = lerp(-half, half, t)
		var rot := fv.rotated(ang)
		# Cast ray
		var end_cell := Vector2i(-1, -1)
		for step in range(1, fov_range + 1):
			var tc := cell + Vector2i(int(rot.x * step + 0.5), int(rot.y * step + 0.5))
			if not level.is_walkable(tc):
				break
			end_cell = tc
		if end_cell == Vector2i(-1, -1):
			end_cell = cell
		var local_end := GameManager.cell_to_world_center(end_cell) - position
		fov_poly.append(local_end + rot.normalized() * (TS * 0.5))

# ─── Drawing (Minecraft-style guard — different face/hat from Ghost) ──────────
func _draw() -> void:
	# ── FOV Cone (semi-transparent cyan) ──────────────────────────────────────
	if fov_poly.size() > 2:
		var col := Color(0.0, 0.8, 1.0, 0.12)
		if state == State.CHASE:
			col = Color(1.0, 0.3, 0.0, 0.20)
		elif state == State.INVESTIGATE:
			col = Color(1.0, 0.9, 0.0, 0.15)
		draw_colored_polygon(fov_poly, col)
		draw_polyline(fov_poly, Color(0.0, 0.8, 1.0, 0.4), 1.0)

	var s  := float(TS) * 0.85
	var ox := -s * 0.5
	var oy := -s * 0.5

	# Leg animation
	var leg_sway := sin(anim_tick * 7.0) * 3.0 if state != State.PATROL or not path.is_empty() else 0.0

	# Shadow
	_draw_shadow_ellipse(Vector2(0, oy + s * 0.95), s*0.35, s*0.08, Color(0,0,0,0.3))

	# ── Body (red uniform — guard color) ──────────────────────────────────────
	draw_rect(Rect2(ox+s*0.18, oy+s*0.40, s*0.64, s*0.38), Color(0.75, 0.12, 0.12))
	# Belt
	draw_rect(Rect2(ox+s*0.18, oy+s*0.66, s*0.64, s*0.06), Color(0.30, 0.20, 0.05))
	# Badge
	draw_rect(Rect2(ox+s*0.35, oy+s*0.48, s*0.14, s*0.10), Color(0.90, 0.80, 0.10))

	# ── Legs ──
	draw_rect(Rect2(ox+s*0.20+1, oy+s*0.75+leg_sway,  s*0.24, s*0.22), Color(0.18, 0.18, 0.35))
	draw_rect(Rect2(ox+s*0.52,   oy+s*0.75-leg_sway,  s*0.24, s*0.22), Color(0.15, 0.15, 0.30))
	# Boots
	draw_rect(Rect2(ox+s*0.18+1, oy+s*0.95+leg_sway,  s*0.26, s*0.06), Color(0.15, 0.08, 0.02))
	draw_rect(Rect2(ox+s*0.50,   oy+s*0.95-leg_sway,  s*0.26, s*0.06), Color(0.15, 0.08, 0.02))

	# ── Head (different features from Ghost) ──────────────────────────────────
	# Skin
	draw_rect(Rect2(ox+s*0.18, oy+s*0.05, s*0.64, s*0.36), Color(0.85, 0.68, 0.52))
	# Hair (short black)
	draw_rect(Rect2(ox+s*0.16, oy,         s*0.68, s*0.12), Color(0.08, 0.08, 0.10))
	# Guard hat (blue)
	draw_rect(Rect2(ox+s*0.12, oy-s*0.08, s*0.76, s*0.12), Color(0.10, 0.20, 0.70))
	draw_rect(Rect2(ox+s*0.06, oy+s*0.00, s*0.88, s*0.07), Color(0.08, 0.15, 0.58))  # Brim
	# Hat badge (gold star shape — simple cross)
	draw_rect(Rect2(ox+s*0.42, oy-s*0.07, s*0.16, s*0.05), Color(0.90,0.80,0.10))
	draw_rect(Rect2(ox+s*0.48, oy-s*0.10, s*0.04, s*0.11), Color(0.90,0.80,0.10))

	# Stern eyes (brown/dark, closer together — different from Ghost)
	var blink_h2 := 0.07 if int(anim_tick * 3) % 15 != 0 else 0.02
	draw_rect(Rect2(ox+s*0.27, oy+s*0.17, s*0.14, s*blink_h2), Color(0.35, 0.18, 0.05))
	draw_rect(Rect2(ox+s*0.55, oy+s*0.17, s*0.14, s*blink_h2), Color(0.35, 0.18, 0.05))
	# Eyebrows (furrowed)
	draw_rect(Rect2(ox+s*0.25, oy+s*0.13, s*0.18, s*0.04), Color(0.08, 0.05, 0.02))
	draw_rect(Rect2(ox+s*0.53, oy+s*0.13, s*0.18, s*0.04), Color(0.08, 0.05, 0.02))
	# Moustache
	draw_rect(Rect2(ox+s*0.30, oy+s*0.28, s*0.40, s*0.05), Color(0.20, 0.10, 0.04))

	# ── Flashlight (torch in hand) ────────────────────────────────────────────
	var fv  := _facing_vec()
	var tx  := fv.x * s * 0.55
	var ty  := fv.y * s * 0.20 + oy + s * 0.55
	draw_rect(Rect2(ox+s*0.5+tx-3, ty-2, 10, 6), Color(0.80, 0.70, 0.20))

	# ── Alert indicator ──────────────────────────────────────────────────────
	match state:
		State.CHASE:
			# Red ! above head
			draw_rect(Rect2(-3, oy-s*0.22, 6, s*0.14), Color(1.0, 0.1, 0.1))
			draw_rect(Rect2(-3, oy-s*0.04, 6, 6),      Color(1.0, 0.1, 0.1))
		State.INVESTIGATE:
			# Yellow ? above head
			draw_rect(Rect2(-6, oy-s*0.22, 12, s*0.14), Color(1.0, 0.9, 0.0, 0.8))

func _draw_shadow_ellipse(center: Vector2, radiusX: float, radiusY: float, color: Color, filled: bool = true, lineWidth: float = 1.0, antialiased: bool = false) -> void:
	var pts := PackedVector2Array()
	for i in range(16):
		var ang := float(i) / 16.0 * TAU
		pts.append(center + Vector2(cos(ang)*radiusX, sin(ang)*radiusY))
	draw_colored_polygon(pts, color)

func _exit_cell() -> Vector2i:
	if level != null and level.has_method("get_exit_cell"):
		return level.get_exit_cell()
	return Vector2i(17, 1)
