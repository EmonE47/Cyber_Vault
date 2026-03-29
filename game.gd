extends Node2D

const TILE_SIZE = 40
const GRID_W = 20
const GRID_H = 15
const WORLD_W = GRID_W * TILE_SIZE
const WORLD_H = GRID_H * TILE_SIZE

const FRAME_MARGIN = 28
const HEADER_H = 72
const HEADER_GAP = 14
const PANEL_GAP = 24
const SIDEBAR_W = 320
const FOOTER_H = 92
const WORLD_OFFSET_X = FRAME_MARGIN
const WORLD_OFFSET_Y = FRAME_MARGIN + HEADER_H + HEADER_GAP
const SCREEN_W = WORLD_OFFSET_X + WORLD_W + PANEL_GAP + SIDEBAR_W + FRAME_MARGIN
const SCREEN_H = WORLD_OFFSET_Y + WORLD_H + PANEL_GAP + FOOTER_H + FRAME_MARGIN

const GHOST_STEP = 0.18
const GHOST_RUN_STEP = 0.11
const GHOST_MODE_HUMAN = 0
const GHOST_MODE_AI = 1
const GHOST_AI_DEPTH = 3
const WARDEN_STEP = 0.18
const WARDEN_RUN_STEP = 0.11
const WARDEN_VISION = 4
const HACK_TIME = 1.0

const MAP = [
	"####################",
	"#..TSS..#....#....X#",
	"#.####.#.##.#.###..#",
	"#..SS..#....#..SS..#",
	"#.####.####.#.####.#",
	"#.#..T....#.#....#.#",
	"#.#.#####.#.#.##.#.#",
	"#...#..SS.#...#....#",
	"###.#.###.###.#.####",
	"#...#..T..#...#....#",
	"#.###.###.###.#.##.#",
	"#.....#.....#.#....#",
	"#.###.#.#####.#.##.#",
	"#...............#..#",
	"####################"
]

const GHOST_START = Vector2i(1, 13)
const WARDEN_START = Vector2i(18, 3)
const DIRS = [
	Vector2i(1, 0),
	Vector2i(-1, 0),
	Vector2i(0, 1),
	Vector2i(0, -1)
]

const BG = Color(0.09, 0.1, 0.11)
const BG_ALT = Color(0.15, 0.16, 0.17)
const PANEL = Color(0.16, 0.17, 0.18, 0.97)
const PANEL_SOFT = Color(0.2, 0.21, 0.22, 0.94)
const PANEL_BORDER = Color(0.42, 0.43, 0.43, 0.96)
const PANEL_GLOW = Color(0.7, 0.72, 0.68, 0.16)
const FLOOR = Color(0.22, 0.23, 0.24)
const FLOOR_ALT = Color(0.25, 0.26, 0.27)
const GRID = Color(0.52, 0.52, 0.49, 0.18)
const WALL = Color(0.1, 0.1, 0.11)
const WALL_EDGE = Color(0.29, 0.29, 0.3)
const SLEEP_ROOM = Color(0.18, 0.25, 0.28)
const SLEEP_BORDER = Color(0.5, 0.59, 0.62)
const GHOST = Color(0.74, 0.77, 0.8)
const GHOST_ACCENT = Color(0.44, 0.53, 0.58)
const WARDEN = Color(0.47, 0.34, 0.31)
const WARDEN_ACCENT = Color(0.77, 0.64, 0.43)
const TERMINAL = Color(0.44, 0.67, 0.52)
const HACKED = Color(0.86, 0.66, 0.28)
const EXIT_OFF = Color(0.2, 0.22, 0.2)
const EXIT_ON = Color(0.39, 0.63, 0.43)
const TEXT = Color(0.91, 0.91, 0.88)
const DIM = Color(0.7, 0.71, 0.68)
const MUTED = Color(0.52, 0.53, 0.5)
const ALERT = Color(0.86, 0.57, 0.24)
const GOOD = Color(0.43, 0.64, 0.44)
const SHADE = Color(0, 0, 0, 0.8)

var font = null
var rng = RandomNumberGenerator.new()

var floor_tiles = []
var floor_lookup = {}
var wall_lookup = {}
var sleep_lookup = {}
var terminal_tiles = []
var terminal_lookup = {}
var terminal_approaches = []
var exit_tile = Vector2i.ZERO

var ghost_tile = GHOST_START
var ghost_prev_tile = GHOST_START
var ghost_facing = Vector2i(1, 0)
var ghost_timer = 0.0
var ghost_move_duration = GHOST_STEP
var ghost_mode = GHOST_MODE_HUMAN
var hack_target = null
var hack_timer = 0.0
var hacked_lookup = {}
var ghost_distance_cache = {}

var warden_tile = WARDEN_START
var warden_prev_tile = WARDEN_START
var warden_facing = Vector2i(-1, 0)
var warden_timer = 0.0
var warden_move_duration = WARDEN_STEP
var last_signal_tile = GHOST_START
var patrol_target = null
var signal_timer = 0.0
var ai_state = "PATROL"

var heat = []
var result_text = ""
var ambient_time = 0.0
var mission_time = 0.0
var briefing_visible = true


func _ready():
	font = ThemeDB.fallback_font
	rng.randomize()
	DisplayServer.window_set_size(Vector2i(SCREEN_W, SCREEN_H))
	build_map()
	reset_game()
	queue_redraw()


func build_map():
	floor_tiles.clear()
	floor_lookup.clear()
	wall_lookup.clear()
	sleep_lookup.clear()
	terminal_tiles.clear()
	terminal_lookup.clear()
	terminal_approaches.clear()
	exit_tile = Vector2i.ZERO

	for y in range(GRID_H):
		var row = MAP[y]
		for x in range(GRID_W):
			var tile = Vector2i(x, y)
			var cell = row.substr(x, 1)
			if cell == "#":
				wall_lookup[tile] = true
			else:
				floor_tiles.append(tile)
				floor_lookup[tile] = true
				if cell == "S":
					sleep_lookup[tile] = true
				elif cell == "T":
					terminal_tiles.append(tile)
					terminal_lookup[tile] = true
				elif cell == "X":
					exit_tile = tile

	build_terminal_approaches()


func reset_game():
	ghost_tile = GHOST_START
	ghost_prev_tile = GHOST_START
	ghost_facing = Vector2i(1, 0)
	ghost_timer = 0.0
	ghost_move_duration = GHOST_STEP
	hack_target = null
	hack_timer = 0.0
	hacked_lookup.clear()
	ghost_distance_cache.clear()

	warden_tile = WARDEN_START
	warden_prev_tile = WARDEN_START
	warden_facing = Vector2i(-1, 0)
	warden_timer = 0.0
	warden_move_duration = WARDEN_STEP
	last_signal_tile = ghost_tile
	patrol_target = null
	signal_timer = 0.0
	ai_state = "PATROL"

	heat.clear()
	for y in range(GRID_H):
		var row = []
		for x in range(GRID_W):
			row.append(0.0)
		heat.append(row)

	mission_time = 0.0
	result_text = ""
	queue_redraw()


func _unhandled_input(event):
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SHIFT, KEY_1, KEY_2, KEY_SPACE, KEY_ENTER]:
			briefing_visible = false

		if event.keycode == KEY_R:
			briefing_visible = false
			reset_game()
		elif event.keycode == KEY_1:
			set_ghost_mode(GHOST_MODE_HUMAN)
		elif event.keycode == KEY_2:
			set_ghost_mode(GHOST_MODE_AI)


func _process(delta):
	ambient_time += delta
	if briefing_visible:
		queue_redraw()
		return

	if result_text == "":
		mission_time += delta
		cool_heat(delta)
		update_ghost(delta)
		update_warden(delta)
		check_end_state()
	queue_redraw()


func update_ghost(delta):
	ghost_timer = maxf(0.0, ghost_timer - delta)

	if hack_target == null and ghost_timer <= 0.0:
		try_start_hack()

	if hack_target != null:
		if terminal_in_front() != hack_target:
			cancel_hack()
		else:
			hack_timer += delta
			if hack_timer >= HACK_TIME:
				hacked_lookup[hack_target] = true
				hack_target = null
				hack_timer = 0.0
		return

	if ghost_timer > 0.0:
		return

	var command = ghost_command()
	var move = command["move"]
	var running = command["run"]
	if move == Vector2i.ZERO:
		return

	var next = ghost_tile + move
	ghost_facing = move
	if is_walkable(next):
		ghost_prev_tile = ghost_tile
		ghost_tile = next
		if running:
			ghost_move_duration = GHOST_RUN_STEP
			ghost_timer = GHOST_RUN_STEP
			trigger_signal(ghost_tile, 4.5, 2, 1.25)
		else:
			ghost_move_duration = GHOST_STEP
			ghost_timer = GHOST_STEP


func ghost_input():
	if Input.is_key_pressed(KEY_W):
		return Vector2i(0, -1)
	if Input.is_key_pressed(KEY_S):
		return Vector2i(0, 1)
	if Input.is_key_pressed(KEY_A):
		return Vector2i(-1, 0)
	if Input.is_key_pressed(KEY_D):
		return Vector2i(1, 0)
	return Vector2i.ZERO


func is_running():
	return Input.is_key_pressed(KEY_SHIFT)


func ghost_command():
	if ghost_mode == GHOST_MODE_AI:
		return ghost_ai_command()
	return {"move": ghost_input(), "run": is_running()}


func ghost_ai_command():
	ghost_distance_cache.clear()
	var actions = ghost_ai_actions(ghost_tile, warden_tile)
	if actions.is_empty():
		return {"move": Vector2i.ZERO, "run": false}

	var best_action = actions[0]
	var best_score = -1_000_000
	var best_goal = 1_000_000
	var alpha = -1_000_000
	var beta = 1_000_000

	for action in actions:
		var next = ghost_tile + action["move"]
		var score = ghost_minimax_score(next, action["move"], warden_tile, warden_facing, GHOST_AI_DEPTH - 1, false, alpha, beta)
		score += ghost_action_score(action, next, warden_tile)
		var goal_distance = ghost_goal_distance(next, action["move"])
		if score > best_score:
			best_score = score
			best_goal = goal_distance
			best_action = action
		elif score == best_score and goal_distance < best_goal:
			best_goal = goal_distance
			best_action = action
		alpha = maxi(alpha, best_score)
		if beta <= alpha:
			break

	return best_action


func ghost_ai_actions(ghost_pos, guard_pos):
	var actions = []
	for step in DIRS:
		var next = ghost_pos + step
		if not is_walkable(next):
			continue
		actions.append({"move": step, "run": false})
		if manhattan(ghost_pos, guard_pos) >= 7:
			actions.append({"move": step, "run": true})
	return actions


func ghost_minimax_score(ghost_pos, ghost_facing_now, guard_pos, guard_facing_now, depth, ghost_turn, alpha, beta):
	if ghost_pos == guard_pos:
		return -1_000_000
	if guard_detects_tile_from(guard_pos, guard_facing_now, ghost_pos):
		return -900_000
	if all_hacked() and ghost_pos == exit_tile:
		return 950_000
	if depth <= 0:
		return evaluate_ghost_state(ghost_pos, ghost_facing_now, guard_pos, guard_facing_now)

	if ghost_turn:
		var best = -1_000_000
		var actions = ghost_ai_actions(ghost_pos, guard_pos)
		if actions.is_empty():
			return evaluate_ghost_state(ghost_pos, ghost_facing_now, guard_pos, guard_facing_now)
		for action in actions:
			var next = ghost_pos + action["move"]
			var score = ghost_minimax_score(next, action["move"], guard_pos, guard_facing_now, depth - 1, false, alpha, beta)
			score += ghost_action_score(action, next, guard_pos)
			best = maxi(best, score)
			alpha = maxi(alpha, best)
			if beta <= alpha:
				break
		return best

	var worst = 1_000_000
	for option in guard_options(guard_pos):
		var next_facing = guard_facing_now if option == guard_pos else option - guard_pos
		var score = ghost_minimax_score(ghost_pos, ghost_facing_now, option, next_facing, depth - 1, true, alpha, beta)
		worst = mini(worst, score)
		beta = mini(beta, worst)
		if beta <= alpha:
			break
	return worst


func evaluate_ghost_state(ghost_pos, ghost_facing_now, guard_pos, guard_facing_now):
	if ghost_pos == guard_pos:
		return -1_000_000
	if guard_detects_tile_from(guard_pos, guard_facing_now, ghost_pos):
		return -900_000

	var score = hacked_lookup.size() * 900
	if all_hacked():
		score += 1_400
	else:
		score -= (terminal_tiles.size() - hacked_lookup.size()) * 260

	var objective_distance = ghost_goal_distance(ghost_pos, ghost_facing_now)
	score -= objective_distance * (70 if all_hacked() else 52)

	if terminal_in_front_from(ghost_pos, ghost_facing_now) != null:
		score += 260

	var guard_distance = manhattan(ghost_pos, guard_pos)
	score += mini(guard_distance, 8) * 28
	if guard_distance <= 2:
		score -= 320
	elif guard_distance <= 4:
		score -= 120

	if sleep_lookup.has(ghost_pos):
		score += 35

	return score


func ghost_action_score(action, next_pos, guard_pos):
	var score = 0
	if action["run"]:
		score -= 22
		if all_hacked() or manhattan(next_pos, guard_pos) >= 8:
			score += 8
	if terminal_in_front_from(next_pos, action["move"]) != null:
		score += 220
	if sleep_lookup.has(next_pos):
		score += 14
	return score


func ghost_goal_distance(ghost_pos, ghost_facing_now):
	if all_hacked():
		return cached_path_distance(ghost_pos, exit_tile)

	if terminal_in_front_from(ghost_pos, ghost_facing_now) != null:
		return 0

	var best = 1_000_000
	for approach in terminal_approaches:
		if hacked_lookup.has(approach["terminal"]):
			continue
		if ghost_pos == approach["stand"] and ghost_facing_now == approach["facing"]:
			return 0
		if not is_walkable(approach["entry"]):
			continue
		var distance = cached_path_distance(ghost_pos, approach["entry"])
		if distance < 1_000_000:
			best = mini(best, distance + 1)

	if best < 1_000_000:
		return best

	var fallback = 1_000_000
	for terminal in terminal_tiles:
		if hacked_lookup.has(terminal):
			continue
		fallback = mini(fallback, manhattan(ghost_pos, terminal))
	return fallback if fallback < 1_000_000 else 0


func cached_path_distance(start, goal):
	var key = str(start) + "->" + str(goal)
	if ghost_distance_cache.has(key):
		return int(ghost_distance_cache[key])
	var distance = 1_000_000
	var path = astar_path(start, goal)
	if not path.is_empty():
		distance = maxi(0, path.size() - 1)
	ghost_distance_cache[key] = distance
	return distance


func build_terminal_approaches():
	terminal_approaches.clear()
	for terminal in terminal_tiles:
		for facing in DIRS:
			var stand = terminal - facing
			var entry = stand - facing
			if is_walkable(stand):
				terminal_approaches.append({
					"terminal": terminal,
					"stand": stand,
					"facing": facing,
					"entry": entry
				})


func set_ghost_mode(mode):
	if ghost_mode == mode:
		return
	ghost_mode = mode
	reset_game()


func try_start_hack():
	if ghost_timer > 0.0 or hack_target != null:
		return
	var target = terminal_in_front()
	if target != null:
		hack_target = target
		hack_timer = 0.0
		trigger_signal(ghost_tile, 10.0, 3, 3.0)


func cancel_hack():
	hack_target = null
	hack_timer = 0.0


func terminal_in_front():
	return terminal_in_front_from(ghost_tile, ghost_facing)


func terminal_in_front_from(from_tile, facing):
	var target = from_tile + facing
	if terminal_lookup.has(target) and not hacked_lookup.has(target):
		return target
	return null


func update_warden(delta):
	if warden_detects_tile(ghost_tile):
		result_text = "WARDEN WINS"
		return

	signal_timer = maxf(0.0, signal_timer - delta)

	warden_timer = maxf(0.0, warden_timer - delta)
	if warden_timer > 0.0:
		return

	var next = warden_tile
	var hot = hottest_heat_tile()
	var target = last_signal_tile if signal_timer > 0.0 else hot
	if target != null and manhattan(warden_tile, target) <= 5:
		ai_state = "INTERCEPT"
		next = alpha_beta_guard_move(warden_tile, warden_facing, target)
	elif signal_timer > 0.0:
		ai_state = "CHASE"
		next = next_step_toward(last_signal_tile)
	else:
		if hot != null:
			ai_state = "SEARCH"
			next = next_step_toward(hot)
		else:
			ai_state = "PATROL"
			if patrol_target == null or patrol_target == warden_tile:
				patrol_target = random_patrol_tile()
			next = next_step_toward(patrol_target)

	if next != warden_tile:
		warden_prev_tile = warden_tile
		warden_facing = next - warden_tile
	warden_tile = next
	warden_move_duration = warden_step_for_state()
	warden_timer = warden_move_duration

	if warden_detects_tile(ghost_tile):
		result_text = "WARDEN WINS"


func random_patrol_tile():
	var choices = []
	for tile in floor_tiles:
		if terminal_lookup.has(tile) or tile == exit_tile:
			continue
		if manhattan(tile, warden_tile) >= 4:
			choices.append(tile)
	if choices.is_empty():
		choices = floor_tiles.duplicate()
	return choices[rng.randi_range(0, choices.size() - 1)]


func warden_step_for_state():
	if ai_state == "CHASE" or ai_state == "INTERCEPT":
		return WARDEN_RUN_STEP
	return WARDEN_STEP


# A* pathfinding: the Warden uses this to move toward chase targets and hot search tiles.
func next_step_toward(target):
	if target == null or target == warden_tile:
		return warden_tile
	var path = astar_path(warden_tile, target)
	if path.size() > 1:
		return path[1]
	return warden_tile


func astar_path(start, goal):
	if start == goal:
		return [start]

	var open = [start]
	var came_from = {}
	var g_score = {}
	var closed = {}
	g_score[start] = 0

	while not open.is_empty():
		var current = open[0]
		var best = int(g_score[current]) + manhattan(current, goal)
		for tile in open:
			var score = int(g_score[tile]) + manhattan(tile, goal)
			if score < best:
				best = score
				current = tile

		if current == goal:
			var path = [goal]
			while path[path.size() - 1] != start:
				path.append(came_from[path[path.size() - 1]])
			path.reverse()
			return path

		open.erase(current)
		closed[current] = true

		for next in neighbors(current):
			if closed.has(next):
				continue
			var new_cost = int(g_score[current]) + 1
			if not g_score.has(next) or new_cost < int(g_score[next]):
				g_score[next] = new_cost
				came_from[next] = current
				if not open.has(next):
					open.append(next)

	return []


# Heatmap search: alarms and running noise paint nearby tiles so the Warden can hunt even
# without direct line-of-sight.
func add_heat(center, amount, radius):
	for y in range(maxi(0, center.y - radius), mini(GRID_H, center.y + radius + 1)):
		for x in range(maxi(0, center.x - radius), mini(GRID_W, center.x + radius + 1)):
			var tile = Vector2i(x, y)
			if not is_walkable(tile):
				continue
			var d = manhattan(center, tile)
			if d <= radius:
				var value = maxf(0.0, amount - d * (amount / float(radius + 1)))
				heat[y][x] = float(heat[y][x]) + value


func cool_heat(delta):
	for y in range(GRID_H):
		for x in range(GRID_W):
			heat[y][x] = maxf(0.0, float(heat[y][x]) - delta * 1.35)


func hottest_heat_tile():
	var best_tile = null
	var best_value = 0.8
	for tile in floor_tiles:
		var value = float(heat[tile.y][tile.x])
		if value > best_value:
			best_value = value
			best_tile = tile
		elif best_tile != null and value == best_value and manhattan(tile, warden_tile) < manhattan(best_tile, warden_tile):
			best_tile = tile
	if best_tile == warden_tile:
		heat[warden_tile.y][warden_tile.x] = 0.0
		return null
	return best_tile


# Alpha-beta minimax: when a signal is nearby, the Warden picks the move that leaves the
# Ghost's best reply with the weakest escape position around the current estimate.
func alpha_beta_guard_move(guard_pos, guard_facing_now, ghost_guess):
	var options = moving_guard_options(guard_pos)
	if guard_detects_tile_from(guard_pos, guard_facing_now, ghost_guess) and not options.has(guard_pos):
		options.insert(0, guard_pos)
	var best_move = guard_pos
	var best_score = 1_000_000
	var alpha = -1_000_000
	var beta = 1_000_000
	for option in options:
		var next_facing = guard_facing_now if option == guard_pos else option - guard_pos
		var score = alpha_beta_score(option, next_facing, ghost_guess, 3, false, alpha, beta)
		if score < best_score:
			best_score = score
			best_move = option
		elif score == best_score and manhattan(option, ghost_guess) < manhattan(best_move, ghost_guess):
			best_move = option
		beta = mini(beta, best_score)
	return best_move


func alpha_beta_score(guard_pos, guard_facing_now, ghost_pos, depth, guard_turn, alpha, beta):
	if guard_pos == ghost_pos:
		return -1_000 - depth * 10
	if guard_detects_tile_from(guard_pos, guard_facing_now, ghost_pos):
		return -900 - depth * 10
	if depth <= 0:
		return evaluate_guard_state(guard_pos, guard_facing_now, ghost_pos)

	if guard_turn:
		var best = 1_000_000
		for option in guard_options(guard_pos):
			var next_facing = guard_facing_now if option == guard_pos else option - guard_pos
			best = mini(best, alpha_beta_score(option, next_facing, ghost_pos, depth - 1, false, alpha, beta))
			beta = mini(beta, best)
			if beta <= alpha:
				break
		return best

	var worst = -1_000_000
	for option in guard_options(ghost_pos):
		worst = maxi(worst, alpha_beta_score(guard_pos, guard_facing_now, option, depth - 1, true, alpha, beta))
		alpha = maxi(alpha, worst)
		if beta <= alpha:
			break
	return worst


func evaluate_guard_state(guard_pos, guard_facing_now, ghost_pos):
	var score = manhattan(guard_pos, ghost_pos) * 10
	if guard_detects_tile_from(guard_pos, guard_facing_now, ghost_pos):
		score -= 120
	if ghost_pos != guard_pos and sign(ghost_pos.x - guard_pos.x) == guard_facing_now.x and guard_facing_now.x != 0:
		score -= 4
	if ghost_pos != guard_pos and sign(ghost_pos.y - guard_pos.y) == guard_facing_now.y and guard_facing_now.y != 0:
		score -= 4
	return score


func guard_options(tile):
	var out = [tile]
	out.append_array(neighbors(tile))
	return out


func moving_guard_options(tile):
	var out = neighbors(tile)
	if out.is_empty():
		out.append(tile)
	return out


func warden_detects_tile(target):
	return guard_detects_tile_from(warden_tile, warden_facing, target)


func guard_detects_tile_from(origin, facing, target):
	if target == origin:
		return true
	return vision_tiles(origin, facing, WARDEN_VISION).has(target)


func vision_tiles(origin, facing, length):
	var out = []
	if facing == Vector2i.ZERO:
		return out

	for tile in vision_candidates(origin, facing, length):
		if has_line_of_sight(origin, tile):
			out.append(tile)
	return out


func vision_candidates(origin, facing, length):
	var out = []
	if facing.x != 0:
		for step in range(1, length + 1):
			for side in range(-(step - 1), step):
				var tile = Vector2i(origin.x + facing.x * step, origin.y + side)
				if in_bounds(tile) and not out.has(tile):
					out.append(tile)
	else:
		for step in range(1, length + 1):
			for side in range(-(step - 1), step):
				var tile = Vector2i(origin.x + side, origin.y + facing.y * step)
				if in_bounds(tile) and not out.has(tile):
					out.append(tile)
	return out


func has_line_of_sight(origin, target):
	for tile in bresenham_line(origin, target):
		if tile == origin:
			continue
		if blocks_vision(tile):
			return false
	return true


func bresenham_line(origin, target):
	var out = []
	var x0 = origin.x
	var y0 = origin.y
	var x1 = target.x
	var y1 = target.y
	var dx = abs(x1 - x0)
	var dy = -abs(y1 - y0)
	var sx = 1 if x0 < x1 else -1
	var sy = 1 if y0 < y1 else -1
	var err = dx + dy

	while true:
		out.append(Vector2i(x0, y0))
		if x0 == x1 and y0 == y1:
			break
		var twice = err * 2
		if twice >= dy:
			err += dy
			x0 += sx
		if twice <= dx:
			err += dx
			y0 += sy

	return out


func neighbors(tile):
	var out = []
	for step in DIRS:
		var next = tile + step
		if is_walkable(next):
			out.append(next)
	return out


func is_walkable(tile):
	return floor_lookup.has(tile)


func blocks_vision(tile):
	return wall_lookup.has(tile) or sleep_lookup.has(tile)


func in_bounds(tile):
	return tile.x >= 0 and tile.y >= 0 and tile.x < GRID_W and tile.y < GRID_H


func manhattan(a, b):
	return abs(a.x - b.x) + abs(a.y - b.y)


func trigger_signal(center, amount, radius, duration):
	var signal_tile = approximate_signal_tile(center, radius)
	last_signal_tile = signal_tile
	signal_timer = maxf(signal_timer, duration)
	add_heat(signal_tile, amount, radius)


func approximate_signal_tile(center, radius):
	var candidates = []
	for y in range(maxi(0, center.y - radius), mini(GRID_H, center.y + radius + 1)):
		for x in range(maxi(0, center.x - radius), mini(GRID_W, center.x + radius + 1)):
			var tile = Vector2i(x, y)
			if not is_walkable(tile):
				continue
			if manhattan(center, tile) <= radius and tile != center:
				candidates.append(tile)
	if candidates.is_empty():
		return center
	return candidates[rng.randi_range(0, candidates.size() - 1)]


func all_hacked():
	return hacked_lookup.size() == terminal_tiles.size()


func check_end_state():
	if result_text != "":
		return
	if ghost_tile == warden_tile:
		result_text = "WARDEN WINS"
	elif all_hacked() and ghost_tile == exit_tile:
		result_text = "GHOST WINS"


func tile_rect(tile):
	return Rect2(
		WORLD_OFFSET_X + tile.x * TILE_SIZE,
		WORLD_OFFSET_Y + tile.y * TILE_SIZE,
		TILE_SIZE,
		TILE_SIZE
	)


func tile_center(tile):
	return tile_rect(tile).position + Vector2(TILE_SIZE * 0.5, TILE_SIZE * 0.5)


func actor_draw_position(current_tile, previous_tile, timer, duration):
	if previous_tile == current_tile or duration <= 0.0:
		return tile_center(current_tile)
	var progress = 1.0 - clampf(timer / duration, 0.0, 1.0)
	return tile_center(previous_tile).lerp(tile_center(current_tile), progress)


func _draw():
	draw_backdrop()
	draw_header()
	draw_world_frame()
	draw_world()
	draw_sidebar()
	draw_footer()
	if briefing_visible:
		draw_briefing_overlay()
	if result_text != "":
		draw_end_screen()


func draw_backdrop():
	draw_rect(Rect2(0, 0, SCREEN_W, SCREEN_H), BG)
	draw_rect(Rect2(0, 0, SCREEN_W, SCREEN_H * 0.45), alpha_color(BG_ALT, 0.32))
	for y in range(0, SCREEN_H, 20):
		draw_line(Vector2(0, y), Vector2(SCREEN_W, y), alpha_color(TEXT, 0.012), 1.0)
	for x in range(0, SCREEN_W, 64):
		draw_line(Vector2(x, 0), Vector2(x, SCREEN_H), alpha_color(PANEL_GLOW, 0.025), 1.0)
	draw_rect(Rect2(0, 0, SCREEN_W, 12), alpha_color(Color.BLACK, 0.18))
	draw_rect(Rect2(0, SCREEN_H - 12, SCREEN_W, 12), alpha_color(Color.BLACK, 0.22))


func draw_header():
	var rect = header_rect()
	var rect_end = rect.position + rect.size
	draw_panel(rect, PANEL, PANEL_BORDER)
	draw_string(font, rect.position + Vector2(20, 30), "MARK47", HORIZONTAL_ALIGNMENT_LEFT, -1, 30, TEXT)
	draw_string(font, rect.position + Vector2(20, 56), "FACILITY A17 // INTERNAL SECURITY FEED", HORIZONTAL_ALIGNMENT_LEFT, -1, 15, DIM)
	draw_chip(Rect2(rect.position.x + 250, rect.position.y + 18, 124, 26), ghost_mode_name().to_upper(), GHOST_ACCENT, true)
	draw_chip(Rect2(rect_end.x - 170, rect.position.y + 18, 150, 26), "THREAT " + danger_label(), danger_color(), true)
	draw_string(font, Vector2(rect_end.x - 220, rect.position.y + 34), "SECURITY STATE  " + short_ai_state(), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, ai_state_color())
	draw_string(font, Vector2(rect_end.x - 220, rect.position.y + 56), "ELAPSED  " + format_time(mission_time), HORIZONTAL_ALIGNMENT_LEFT, -1, 15, DIM)


func draw_world_frame():
	var outer = world_rect().grow(18)
	var rect = world_rect()
	var rect_end = rect.position + rect.size
	draw_panel(outer, PANEL, PANEL_BORDER)
	draw_rect(rect, alpha_color(Color(0.04, 0.04, 0.05), 0.86))
	draw_rect(rect.grow(8), alpha_color(Color.BLACK, 0.12), false, 1.0)
	draw_line(rect.position + Vector2(0, 1), Vector2(rect_end.x, rect.position.y + 1), alpha_color(TEXT, 0.12), 2.0)
	draw_line(rect.position + Vector2(1, 0), Vector2(rect.position.x + 1, rect_end.y), alpha_color(TEXT, 0.08), 2.0)
	draw_line(Vector2(rect.position.x, rect_end.y - 1), Vector2(rect_end.x, rect_end.y - 1), alpha_color(Color.BLACK, 0.28), 2.0)
	draw_line(Vector2(rect_end.x - 1, rect.position.y), Vector2(rect_end.x - 1, rect_end.y), alpha_color(Color.BLACK, 0.28), 2.0)
	draw_string(font, rect.position + Vector2(18, -8), "SECTOR A17 MAP", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, DIM)
	draw_string(font, Vector2(rect_end.x - 138, rect_end.y + 18), "VISION / NOISE", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, MUTED)
	draw_corner_bolts(outer)


func draw_world():
	for y in range(GRID_H):
		for x in range(GRID_W):
			var tile = Vector2i(x, y)
			var rect = tile_rect(tile)
			var wear = tile_wear(tile)
			if wall_lookup.has(tile):
				draw_rect(rect, WALL)
				draw_rect(rect.grow(-2), alpha_color(WALL_EDGE, 0.26 + wear * 0.08))
				draw_line(rect.position + Vector2(0, 1), rect.position + Vector2(rect.size.x, 1), alpha_color(TEXT, 0.05), 1.0)
				draw_line(rect.position + Vector2(1, 0), rect.position + Vector2(1, rect.size.y), alpha_color(TEXT, 0.04), 1.0)
				draw_line(rect.position + Vector2(rect.size.x - 1, 0), rect.position + Vector2(rect.size.x - 1, rect.size.y), alpha_color(Color.BLACK, 0.18), 1.0)
				draw_line(rect.position + Vector2(0, rect.size.y - 1), rect.position + Vector2(rect.size.x, rect.size.y - 1), alpha_color(Color.BLACK, 0.18), 1.0)
			else:
				var floor_color = FLOOR if (x + y) % 2 == 0 else FLOOR_ALT
				draw_rect(rect, floor_color)
				draw_line(rect.position + Vector2(0, rect.size.y - 1), rect.position + Vector2(rect.size.x, rect.size.y - 1), alpha_color(Color.BLACK, 0.12), 1.0)
				draw_line(rect.position + Vector2(rect.size.x - 1, 0), rect.position + Vector2(rect.size.x - 1, rect.size.y), alpha_color(Color.BLACK, 0.12), 1.0)
				draw_rect(Rect2(rect.position + Vector2(4, 4), Vector2(rect.size.x - 8, 6)), alpha_color(TEXT, 0.015 + wear * 0.018))
				if int(wear * 10.0) % 3 == 0:
					draw_line(rect.position + Vector2(8, 24), rect.position + Vector2(rect.size.x - 7, 20), alpha_color(Color.BLACK, 0.08), 1.0)
				draw_rect(rect, GRID, false, 1.0)
				if sleep_lookup.has(tile):
					var room = rect.grow(-4)
					draw_rect(room, alpha_color(SLEEP_ROOM, 0.95))
					draw_rect(room, alpha_color(SLEEP_BORDER, 0.55), false, 1.0)
					var bunk = Rect2(room.position + Vector2(5, 7), Vector2(room.size.x - 10, 11))
					draw_rect(bunk, alpha_color(TEXT, 0.08))
					draw_rect(Rect2(bunk.position + Vector2(2, 2), Vector2(bunk.size.x - 4, bunk.size.y - 4)), alpha_color(TEXT, 0.16))
					draw_rect(Rect2(room.position + Vector2(room.size.x - 8, 5), Vector2(4, room.size.y - 10)), alpha_color(SLEEP_BORDER, 0.24))
					draw_line(rect.position + Vector2(7, rect.size.y - 9), rect.position + Vector2(rect.size.x - 7, 9), alpha_color(SLEEP_BORDER, 0.12), 1.0)
				var heat_value = float(heat[y][x])
				if heat_value > 0.25:
					var alpha = minf(0.22, heat_value * 0.03)
					draw_circle(tile_center(tile), 8.0 + heat_value * 2.0, alpha_color(ALERT, alpha))

	for terminal in terminal_tiles:
		draw_terminal(terminal, terminal_tiles.find(terminal) + 1)

	draw_exit_tile()
	draw_vision_tiles()
	draw_world_scanlines()

	var ghost_pos = actor_draw_position(ghost_tile, ghost_prev_tile, ghost_timer, ghost_move_duration)
	var warden_pos = actor_draw_position(warden_tile, warden_prev_tile, warden_timer, warden_move_duration)
	draw_ghost_actor(ghost_pos)
	draw_warden_actor(warden_pos)

	if hack_target != null:
		draw_hack_feedback(ghost_pos)


func draw_terminal(terminal, index):
	var pulse = 0.5 + 0.5 * sin(ambient_time * 4.0 + float(index))
	var tile = tile_rect(terminal)
	var desk = Rect2(tile.position + Vector2(5, 23), Vector2(TILE_SIZE - 10, 8))
	var monitor_frame = Rect2(tile.position + Vector2(9, 8), Vector2(TILE_SIZE - 18, 12))
	var monitor_glow = HACKED if hacked_lookup.has(terminal) else TERMINAL
	draw_rect(desk, alpha_color(WALL_EDGE, 0.85))
	draw_rect(Rect2(desk.position + Vector2(2, 1), Vector2(desk.size.x - 4, desk.size.y - 2)), alpha_color(Color(0.11, 0.11, 0.12), 0.95))
	draw_rect(Rect2(tile.position + Vector2(TILE_SIZE * 0.5 - 1, 20), Vector2(2, 5)), alpha_color(WALL_EDGE, 0.9))
	draw_rect(monitor_frame, alpha_color(WALL_EDGE, 0.88))
	draw_rect(Rect2(monitor_frame.position + Vector2(2, 2), Vector2(monitor_frame.size.x - 4, monitor_frame.size.y - 4)), alpha_color(monitor_glow, 0.7 + pulse * 0.1))
	draw_line(monitor_frame.position + Vector2(3, monitor_frame.size.y - 4), monitor_frame.position + Vector2(monitor_frame.size.x - 3, monitor_frame.size.y - 4), alpha_color(TEXT, 0.1), 1.0)
	draw_rect(Rect2(tile.position + Vector2(12, 32), Vector2(TILE_SIZE - 24, 3)), alpha_color(Color.BLACK, 0.3))
	draw_string(font, tile.position + Vector2(5, 16), "PC" + str(index), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, TEXT)
	if hack_target == terminal:
		draw_rect(monitor_frame.grow(6), alpha_color(ALERT, 0.7), false, 2.0)
		draw_circle(tile_center(terminal), 18.0 + pulse * 5.0, alpha_color(ALERT, 0.12))


func draw_exit_tile():
	var pulse = 0.5 + 0.5 * sin(ambient_time * 3.2)
	var fill = EXIT_ON if all_hacked() else EXIT_OFF
	var rect = Rect2(exit_tile.x * TILE_SIZE + WORLD_OFFSET_X + 6, exit_tile.y * TILE_SIZE + WORLD_OFFSET_Y + 6, TILE_SIZE - 12, TILE_SIZE - 12)
	var half_w = rect.size.x * 0.5 - 2.0
	var left = Rect2(rect.position + Vector2(2, 2), Vector2(half_w, rect.size.y - 4))
	var right = Rect2(Vector2(rect.position.x + rect.size.x - half_w - 2.0, rect.position.y + 2), Vector2(half_w, rect.size.y - 4))
	draw_rect(rect, alpha_color(WALL_EDGE, 0.82))
	draw_rect(left, fill.darkened(0.12))
	draw_rect(right, fill)
	draw_line(Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + 3), Vector2(rect.position.x + rect.size.x * 0.5, rect.position.y + rect.size.y - 3), alpha_color(Color.BLACK, 0.28), 1.0)
	draw_rect(Rect2(rect.position + Vector2(6, 4), Vector2(rect.size.x - 12, 3)), alpha_color(TEXT, 0.08))
	draw_rect(Rect2(rect.position + Vector2(rect.size.x * 0.5 - 3, 6), Vector2(6, 4)), alpha_color(fill, 0.65 + pulse * 0.2))
	draw_string(font, rect.position + Vector2(6, 16), "EXIT", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, TEXT)


func draw_vision_tiles():
	if ai_state == "PATROL":
		return
	var pulse = 0.45 + 0.55 * sin(ambient_time * 7.0)
	for tile in vision_tiles(warden_tile, warden_facing, WARDEN_VISION):
		var rect = tile_rect(tile).grow(-10)
		draw_rect(rect, alpha_color(WARDEN, 0.05 + pulse * 0.04))
		draw_rect(rect, alpha_color(WARDEN_ACCENT, 0.14), false, 1.0)


func draw_world_scanlines():
	var rect = world_rect()
	for y in range(0, int(rect.size.y), 14):
		var start = rect.position + Vector2(0, y)
		draw_line(start, start + Vector2(rect.size.x, 0), alpha_color(TEXT, 0.016), 1.0)


func draw_ghost_actor(pos):
	var facing = unit_dir(ghost_facing)
	var side = Vector2(-facing.y, facing.x)
	var torso = PackedVector2Array([
		pos + side * 8.0 + facing * 2.0,
		pos + side * 6.0 - facing * 7.0,
		pos - side * 6.0 - facing * 7.0,
		pos - side * 8.0 + facing * 2.0
	])
	var leg_left = pos + side * 3.0 + facing * 8.0
	var leg_right = pos - side * 3.0 + facing * 8.0
	draw_circle(pos + Vector2(2, 3), 11.0, alpha_color(Color.BLACK, 0.22))
	draw_colored_polygon(torso, alpha_color(GHOST, 0.96))
	draw_circle(pos - facing * 10.0, 4.5, alpha_color(TEXT, 0.78))
	draw_circle(leg_left, 2.6, alpha_color(GHOST_ACCENT, 0.65))
	draw_circle(leg_right, 2.6, alpha_color(GHOST_ACCENT, 0.65))
	draw_line(pos - side * 5.0 - facing * 1.0, pos - side * 8.0 + facing * 4.0, alpha_color(GHOST_ACCENT, 0.55), 2.0)
	draw_line(pos + side * 5.0 - facing * 1.0, pos + side * 8.0 + facing * 4.0, alpha_color(GHOST_ACCENT, 0.55), 2.0)


func draw_warden_actor(pos):
	var facing = unit_dir(warden_facing)
	var side = Vector2(-facing.y, facing.x)
	var torso = PackedVector2Array([
		pos + side * 9.0 + facing * 1.0,
		pos + side * 7.0 - facing * 8.0,
		pos - side * 7.0 - facing * 8.0,
		pos - side * 9.0 + facing * 1.0
	])
	var beam = PackedVector2Array([
		pos + facing * 5.0,
		pos + facing * 30.0 + side * 10.0,
		pos + facing * 30.0 - side * 10.0
	])
	draw_circle(pos + Vector2(2, 3), 12.0, alpha_color(Color.BLACK, 0.24))
	draw_colored_polygon(beam, alpha_color(WARDEN_ACCENT, 0.055))
	draw_colored_polygon(torso, alpha_color(WARDEN, 0.96))
	draw_circle(pos - facing * 10.0, 4.6, alpha_color(TEXT, 0.74))
	draw_line(pos + side * 6.0 - facing * 1.0, pos + side * 11.0 + facing * 5.0, alpha_color(WARDEN_ACCENT, 0.68), 2.0)
	draw_line(pos - side * 6.0 - facing * 1.0, pos - side * 10.0 + facing * 6.0, alpha_color(WARDEN_ACCENT, 0.5), 2.0)
	draw_line(pos, pos + facing * 14.0, alpha_color(Color.BLACK, 0.38), 2.0)


func draw_hack_feedback(ghost_pos):
	var target_center = tile_center(hack_target)
	var pulse = 0.5 + 0.5 * sin(ambient_time * 8.0)
	draw_line(ghost_pos, target_center, alpha_color(TERMINAL, 0.45 + pulse * 0.25), 2.0)
	var back = Rect2(ghost_pos.x - 34, ghost_pos.y - 34, 68, 10)
	draw_rect(back, alpha_color(Color(0, 0, 0), 0.9))
	draw_rect(back, alpha_color(TERMINAL, 0.5), false, 1.0)
	var fill = clampf(hack_timer / HACK_TIME, 0.0, 1.0)
	draw_rect(Rect2(back.position + Vector2(2, 2), Vector2((back.size.x - 4) * fill, back.size.y - 4)), TERMINAL)


func draw_sidebar():
	var rect = sidebar_rect()
	var inset = 16.0
	var card_w = rect.size.x - inset * 2.0
	var x = rect.position.x + inset
	var y = rect.position.y + inset
	draw_panel(rect, PANEL, PANEL_BORDER)
	draw_mission_card(Rect2(x, y, card_w, 140))
	y += 152.0
	draw_systems_card(Rect2(x, y, card_w, 150))
	y += 162.0
	draw_intel_card(Rect2(x, y, card_w, 118))
	y += 130.0
	draw_controls_card(Rect2(x, y, card_w, 104))


func draw_mission_card(rect):
	draw_panel(rect, PANEL_SOFT, PANEL_BORDER)
	draw_card_title(rect, "MISSION", TERMINAL)
	draw_string(font, rect.position + Vector2(14, 52), "Move room to room, access the computers, and get out unseen.", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, TEXT)
	draw_text_lines([
		"Route: " + objective_summary(),
		"Rooms: pod rooms block the Warden's line of sight.",
		"Noise: sprinting and computer access leave a trace."
	], rect.position + Vector2(14, 74), 14, 19, DIM)
	var chip_y = rect.position.y + rect.size.y - 34
	draw_chip(Rect2(rect.position.x + 14, chip_y, 124, 24), "1 HUMAN PILOT", GHOST_ACCENT, ghost_mode == GHOST_MODE_HUMAN)
	draw_chip(Rect2(rect.position.x + 146, chip_y, 118, 24), "2 AI PILOT", GOOD, ghost_mode == GHOST_MODE_AI)


func draw_systems_card(rect):
	draw_panel(rect, PANEL_SOFT, PANEL_BORDER)
	draw_card_title(rect, "SYSTEMS", ALERT)
	var x = rect.position.x + 14
	var y = rect.position.y + 48
	var w = rect.size.x - 28
	draw_progress_bar(Rect2(x, y, w, 16), "COMPUTER ACCESS", hack_ratio(), TERMINAL, str(hacked_lookup.size()) + "/" + str(terminal_tiles.size()))
	y += 28
	draw_progress_bar(Rect2(x, y, w, 16), "NOISE TRACE", noise_ratio(), ALERT, trace_text())
	y += 28
	draw_progress_bar(Rect2(x, y, w, 16), "STEALTH INTEGRITY", stealth_ratio(), GOOD, danger_label())
	y += 28
	draw_progress_bar(Rect2(x, y, w, 16), "ROUTE READINESS", route_ratio(), EXIT_ON if all_hacked() else GHOST_ACCENT, route_text())


func draw_intel_card(rect):
	draw_panel(rect, PANEL_SOFT, PANEL_BORDER)
	draw_card_title(rect, "INTEL", GHOST_ACCENT)
	var x = rect.position.x + 14
	var y = rect.position.y + 52
	draw_stat_line(Vector2(x, y), "Warden state", pretty_ai_state(), ai_state_color())
	y += 22
	draw_stat_line(Vector2(x, y), "Contact range", str(manhattan(ghost_tile, warden_tile)) + " tiles", TEXT)
	y += 22
	draw_stat_line(Vector2(x, y), "Objective path", objective_distance_text(), TEXT)
	y += 22
	draw_stat_line(Vector2(x, y), "Signal", "ACTIVE" if signal_timer > 0.0 else "CLEAR", ALERT if signal_timer > 0.0 else GOOD)


func draw_controls_card(rect):
	draw_panel(rect, PANEL_SOFT, PANEL_BORDER)
	draw_card_title(rect, "CONTROLS", GOOD)
	draw_text_lines([
		"WASD move   Shift sprint",
		"Face a computer to start access",
		"1 human pilot   2 AI pilot   R reset"
	], rect.position + Vector2(14, 48), 14, 18, DIM)


func draw_footer():
	var rect = footer_rect()
	var right_x = rect.position.x + rect.size.x - 270
	draw_panel(rect, PANEL, PANEL_BORDER)
	draw_string(font, rect.position + Vector2(20, 34), status_banner_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, status_banner_color())
	draw_string(font, rect.position + Vector2(20, 58), status_hint_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, 14, DIM)
	draw_chip(Rect2(right_x, rect.position.y + 16, 118, 24), "MODE " + short_mode_name(), GHOST_ACCENT, true)
	draw_chip(Rect2(right_x + 126, rect.position.y + 16, 126, 24), "STATE " + short_ai_state(), ai_state_color(), ai_state != "PATROL")
	draw_string(font, Vector2(right_x, rect.position.y + 58), "Use cover, keep quiet, and chain clean breaches.", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, MUTED)


func draw_briefing_overlay():
	draw_rect(Rect2(0, 0, SCREEN_W, SCREEN_H), SHADE)
	var rect = Rect2((SCREEN_W - 560) * 0.5, (SCREEN_H - 300) * 0.5, 560, 300)
	draw_panel(rect, PANEL, PANEL_BORDER)
	draw_string(font, rect.position + Vector2(24, 44), "MISSION BRIEF", HORIZONTAL_ALIGNMENT_LEFT, -1, 28, TEXT)
	draw_string(font, rect.position + Vector2(24, 72), "MARK47 is inside the secured floor plan.", HORIZONTAL_ALIGNMENT_LEFT, -1, 16, DIM)
	draw_text_lines([
		"Access every computer before the exit door unlocks.",
		"Rooms with sleep pods block vision, but sprinting and access both leave a trace.",
		"Swap between human and AI pilot at any time with 1 and 2."
	], rect.position + Vector2(24, 112), 16, 26, DIM)
	draw_chip(Rect2(rect.position.x + 24, rect.position.y + 236, 240, 28), "SPACE OR MOVE TO DEPLOY", GOOD, true)
	draw_string(font, rect.position + Vector2(24, 286), "The clock starts when you move off the safe start tile.", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, MUTED)


func draw_end_screen():
	draw_rect(Rect2(0, 0, SCREEN_W, SCREEN_H), SHADE)
	var rect = Rect2((SCREEN_W - 460) * 0.5, (SCREEN_H - 228) * 0.5, 460, 228)
	var accent = GOOD if result_text == "GHOST WINS" else WARDEN
	draw_panel(rect, PANEL, accent)
	draw_string(font, rect.position + Vector2(24, 58), result_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 38, TEXT)
	draw_string(font, rect.position + Vector2(24, 92), end_screen_subtitle(), HORIZONTAL_ALIGNMENT_LEFT, -1, 16, alpha_color(accent, 0.95))
	draw_text_lines([
		"R restarts the run immediately.",
		"1 and 2 still switch between human and AI pilot.",
		"Use the room layout to plan a cleaner next route."
	], rect.position + Vector2(24, 132), 14, 22, DIM)


func draw_panel(rect, fill, border):
	draw_rect(rect, fill)
	draw_rect(rect, alpha_color(border, 0.92), false, 2.0)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, 4)), alpha_color(TEXT, 0.08))
	draw_line(rect.position + Vector2(0, rect.size.y - 1), rect.position + Vector2(rect.size.x, rect.size.y - 1), alpha_color(Color.BLACK, 0.25), 1.0)
	draw_line(rect.position + Vector2(rect.size.x - 1, 0), rect.position + Vector2(rect.size.x - 1, rect.size.y), alpha_color(Color.BLACK, 0.25), 1.0)


func draw_card_title(rect, text, color):
	draw_string(font, rect.position + Vector2(14, 24), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, color)
	draw_line(rect.position + Vector2(14, 32), rect.position + Vector2(rect.size.x - 14, 32), alpha_color(color, 0.22), 1.0)


func draw_chip(rect, label, color, active):
	var fill = alpha_color(color, 0.16 if active else 0.07)
	var border = alpha_color(color, 0.9 if active else 0.35)
	var text_color = color if active else DIM
	draw_rect(rect, fill)
	draw_rect(rect, border, false, 1.0)
	draw_string(font, rect.position + Vector2(10, 18), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, text_color)


func draw_progress_bar(rect, label, value, fill_color, value_text):
	draw_string(font, rect.position + Vector2(0, -6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)
	draw_string(font, Vector2(rect.position.x + rect.size.x - 78, rect.position.y - 6), value_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, TEXT)
	draw_rect(rect, alpha_color(Color(0, 0, 0), 0.6))
	draw_rect(rect, alpha_color(fill_color, 0.25), false, 1.0)
	var fill_w = maxf(0.0, (rect.size.x - 4.0) * clampf(value, 0.0, 1.0))
	draw_rect(Rect2(rect.position + Vector2(2, 2), Vector2(fill_w, rect.size.y - 4.0)), fill_color)


func draw_stat_line(position, label, value, value_color):
	draw_string(font, position, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, MUTED)
	draw_string(font, Vector2(position.x + 126, position.y), value, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, value_color)


func draw_text_lines(lines, position, size, line_height, color):
	var y = position.y
	for line in lines:
		draw_string(font, Vector2(position.x, y), line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
		y += line_height


func header_rect():
	return Rect2(FRAME_MARGIN, FRAME_MARGIN, SCREEN_W - FRAME_MARGIN * 2, HEADER_H)


func world_rect():
	return Rect2(WORLD_OFFSET_X, WORLD_OFFSET_Y, WORLD_W, WORLD_H)


func sidebar_rect():
	return Rect2(WORLD_OFFSET_X + WORLD_W + PANEL_GAP, WORLD_OFFSET_Y, SIDEBAR_W, WORLD_H)


func footer_rect():
	return Rect2(FRAME_MARGIN, WORLD_OFFSET_Y + WORLD_H + PANEL_GAP, SCREEN_W - FRAME_MARGIN * 2, FOOTER_H)


func alpha_color(color, alpha):
	return Color(color.r, color.g, color.b, alpha)


func draw_corner_bolts(rect):
	var points = [
		rect.position + Vector2(12, 12),
		Vector2(rect.position.x + rect.size.x - 12, rect.position.y + 12),
		Vector2(rect.position.x + 12, rect.position.y + rect.size.y - 12),
		rect.position + rect.size - Vector2(12, 12)
	]
	for point in points:
		draw_circle(point, 3.0, alpha_color(Color.BLACK, 0.32))
		draw_circle(point, 1.6, alpha_color(TEXT, 0.2))


func tile_wear(tile):
	return abs(sin(float(tile.x) * 1.91 + float(tile.y) * 1.37 + float(tile.x * tile.y) * 0.11))


func unit_dir(dir):
	if dir == Vector2i.ZERO:
		return Vector2.RIGHT
	return Vector2(dir.x, dir.y).normalized()


func hack_ratio():
	if terminal_tiles.is_empty():
		return 0.0
	return float(hacked_lookup.size()) / float(terminal_tiles.size())


func noise_ratio():
	var local_heat = float(heat[ghost_tile.y][ghost_tile.x]) / 6.0
	return clampf(maxf(signal_timer / 3.0, local_heat), 0.0, 1.0)


func danger_ratio():
	if briefing_visible:
		return 0.18
	if result_text == "WARDEN WINS":
		return 1.0
	var proximity = clampf(1.0 - float(manhattan(ghost_tile, warden_tile) - 1) / 10.0, 0.0, 1.0)
	var line = 1.0 if warden_detects_tile(ghost_tile) else 0.0
	return clampf(maxf(line, maxf(signal_timer / 3.0, proximity * 0.8)), 0.0, 1.0)


func stealth_ratio():
	return clampf(1.0 - danger_ratio(), 0.0, 1.0)


func route_ratio():
	var distance = objective_distance()
	if distance >= 1_000_000:
		return 0.0
	return clampf(1.0 - float(mini(distance, GRID_W + GRID_H)) / float(GRID_W + GRID_H), 0.0, 1.0)


func objective_distance():
	ghost_distance_cache.clear()
	return ghost_goal_distance(ghost_tile, ghost_facing)


func objective_distance_text():
	var distance = objective_distance()
	if distance >= 1_000_000:
		return "unknown"
	return str(distance) + " steps"


func objective_summary():
	if all_hacked():
		return "The exit door is unlocked. Move to the marked exit."
	if hack_target != null:
		return "Computer access in progress. Hold your position."
	if terminal_in_front() != null:
		return "Computer in reach. Hold steady to start access."
	return "Clear the remaining rooms before the Warden converges."


func pretty_ai_state():
	match ai_state:
		"CHASE":
			return "Pursuing"
		"INTERCEPT":
			return "Intercepting"
		"SEARCH":
			return "Investigating"
		_:
			return "Patrolling"


func short_ai_state():
	match ai_state:
		"CHASE":
			return "CHASE"
		"INTERCEPT":
			return "INTERCEPT"
		"SEARCH":
			return "SEARCH"
		_:
			return "PATROL"


func ai_state_color():
	match ai_state:
		"CHASE":
			return ALERT
		"INTERCEPT":
			return WARDEN
		"SEARCH":
			return GHOST_ACCENT
		_:
			return GOOD


func danger_label():
	var value = danger_ratio()
	if value >= 0.72:
		return "HIGH"
	if value >= 0.4:
		return "MED"
	return "LOW"


func danger_color():
	match danger_label():
		"HIGH":
			return WARDEN
		"MED":
			return ALERT
		_:
			return GOOD


func trace_text():
	if signal_timer > 0.0:
		return str(snapped(signal_timer, 0.1)) + "s"
	return "CLEAR"


func route_text():
	if all_hacked():
		return "EXIT"
	return objective_distance_text()


func status_banner_text():
	if result_text == "GHOST WINS":
		return "Objective complete. The operator reached the exit."
	if result_text == "WARDEN WINS":
		return "Security made visual contact. Mission failed."
	if hack_target != null:
		return "Accessing computer. Hold position and keep your facing."
	if all_hacked():
		return "All computers accessed. Reach the exit door now."
	if signal_timer > 0.0:
		return "Noise trace active. Break line of sight and move immediately."
	if terminal_in_front() != null:
		return "Computer ready. Pause here to begin access."
	return "Move quietly through the rooms and stay out of the Warden's view."


func status_hint_text():
	if ghost_mode == GHOST_MODE_AI:
		return "AI pilot is moving between rooms while balancing distance and exposure."
	if hack_target != null:
		return "You can cancel the access by turning away or stepping off the computer."
	if all_hacked():
		return "The exit is the marked door inside the right side of the floor plan."
	return "Pod rooms are hard cover. Sprint only when you can absorb the noise."


func status_banner_color():
	if result_text == "GHOST WINS":
		return GOOD
	if result_text == "WARDEN WINS":
		return WARDEN
	if hack_target != null:
		return TERMINAL
	if all_hacked():
		return EXIT_ON
	if signal_timer > 0.0:
		return ALERT
	return TEXT


func end_screen_subtitle():
	if result_text == "GHOST WINS":
		return "Every computer was accessed before security closed the floor."
	return "The Warden confirmed visual contact and stopped the operation."


func short_mode_name():
	if ghost_mode == GHOST_MODE_AI:
		return "AI"
	return "HUMAN"


func format_time(total_seconds):
	var total = int(total_seconds)
	var minutes = total / 60
	var seconds = total % 60
	return "%02d:%02d" % [minutes, seconds]


func ghost_mode_name():
	if ghost_mode == GHOST_MODE_AI:
		return "AI Ghost"
	return "Human Ghost"
