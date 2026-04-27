class_name Level
## =============================================================================
## Level.gd  —  Main Scene Controller
## Handles: procedural layout generation, AStarGrid2D setup,
## spawning Ghost/Warden/Terminals, and UI creation.
## =============================================================================
extends Node2D

const TS   := GameManager.TILE_SIZE      # 40
const COLS := GameManager.GRID_COLS      # 20
const ROWS := GameManager.GRID_ROWS      # 16

## Tile IDs
const TILE_FLOOR        := 0
const TILE_WALL         := 1
const TILE_TERMINAL     := 2
const TILE_EXIT         := 3
const TILE_GHOST_SPAWN  := 4
const TILE_WARDEN_SPAWN := 5
const TILE_SLEEP        := 6

const TERMINAL_COUNT := 3
const SLEEP_COUNT    := 5

# Avoid generating exactly the same layout twice in a row.
static var _last_layout_signature: String = ""

## ─── Runtime Layout Data ─────────────────────────────────────────────────────
var level_map: Array = []
var terminal_defs: Array = []          # [col, row, id]
var sleep_cells: Array[Vector2i] = []
var exit_cell: Vector2i = Vector2i(17, 1)
var ghost_spawn: Vector2i = Vector2i(10, 14)
var warden_spawn: Vector2i = Vector2i(1, 14)

var rng: RandomNumberGenerator = RandomNumberGenerator.new()

## ─── AStarGrid2D shared across Ghost ─────────────────────────────────────────
var astar: AStarGrid2D = AStarGrid2D.new()

## ─── Node references ──────────────────────────────────────────────────────────
var ghost_node: Node2D
var warden_node: Node2D
var ui_node: CanvasLayer
var terminal_nodes: Array[Node2D] = []

## ─── Colors ───────────────────────────────────────────────────────────────────
const C_FLOOR     := Color(0.08, 0.10, 0.16)
const C_FLOOR_LN  := Color(0.12, 0.15, 0.22)
const C_GRASS     := Color(0.22, 0.56, 0.16)
const C_DIRT      := Color(0.36, 0.20, 0.08)
const C_DIRT_DARK := Color(0.24, 0.12, 0.04)
const C_STONE     := Color(0.28, 0.28, 0.32)
const C_EXIT      := Color(0.2,  0.90, 0.3)
const C_SLEEP     := Color(0.4,  0.2,  0.6)

## ─── Ready ────────────────────────────────────────────────────────────────────
func _ready() -> void:
	set_meta("is_level", true)
	rng.seed = int(Time.get_ticks_usec())
	_generate_layout()
	_build_astar()
	_spawn_terminals()
	_spawn_ghost()
	_spawn_warden()
	_build_ui()
	GameManager.start_game()
	set_process(true)

func _process(_delta: float) -> void:
	queue_redraw()

## ─── Procedural Generation ───────────────────────────────────────────────────
func _generate_layout() -> void:
	for _attempt in range(80):
		_init_empty_map()
		_carve_backbone_corridors()
		_add_random_walls()
		if not _place_special_cells():
			continue
		if not _validate_layout():
			continue
		var sig := _build_layout_signature()
		if sig == _last_layout_signature:
			continue
		_last_layout_signature = sig
		print("[Level] Generated procedural layout")
		return

	print("[Level] Fallback layout used")
	_build_fallback_layout()

func _init_empty_map() -> void:
	level_map.clear()
	terminal_defs.clear()
	sleep_cells.clear()

	for r in range(ROWS):
		var row: Array = []
		for c in range(COLS):
			var tile := TILE_FLOOR
			if r == 0 or c == 0 or r == ROWS - 1 or c == COLS - 1:
				tile = TILE_WALL
			row.append(tile)
		level_map.append(row)

func _carve_backbone_corridors() -> void:
	var h1 := rng.randi_range(3, ROWS - 4)
	var h2 := rng.randi_range(3, ROWS - 4)
	var v1 := rng.randi_range(3, COLS - 4)
	var v2 := rng.randi_range(3, COLS - 4)

	for x in range(1, COLS - 1):
		_set_tile(Vector2i(x, h1), TILE_FLOOR)
		_set_tile(Vector2i(x, h2), TILE_FLOOR)
	for y in range(1, ROWS - 1):
		_set_tile(Vector2i(v1, y), TILE_FLOOR)
		_set_tile(Vector2i(v2, y), TILE_FLOOR)

func _add_random_walls() -> void:
	for _i in range(rng.randi_range(20, 30)):
		var horizontal := rng.randf() < 0.55
		var len := rng.randi_range(2, 5)
		var start := Vector2i(rng.randi_range(1, COLS - 2), rng.randi_range(1, ROWS - 2))
		for j in range(len):
			var c := start + (Vector2i(j, 0) if horizontal else Vector2i(0, j))
			if not _in_inner_bounds(c):
				continue
			if rng.randf() < 0.86:
				_set_tile(c, TILE_WALL)

	# Soften dense blocks to preserve movement freedom.
	for r in range(2, ROWS - 2):
		for c in range(2, COLS - 2):
			var cell := Vector2i(c, r)
			if _tile(cell) != TILE_WALL:
				continue
			var around := 0
			for d in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
				if _tile(cell + d) == TILE_WALL:
					around += 1
			if around >= 4 and rng.randf() < 0.6:
				_set_tile(cell, TILE_FLOOR)

func _place_special_cells() -> bool:
	var reserved: Dictionary = {}

	exit_cell = _pick_exit_cell()
	if exit_cell == Vector2i(-1, -1):
		return false
	reserved[exit_cell] = true

	var terminals := _pick_terminal_cells(reserved)
	if terminals.size() != TERMINAL_COUNT:
		return false

	terminal_defs.clear()
	for i in range(terminals.size()):
		var tc: Vector2i = terminals[i]
		reserved[tc] = true
		terminal_defs.append([tc.x, tc.y, i + 1])

	sleep_cells = _pick_sleep_cells(reserved, SLEEP_COUNT)
	if sleep_cells.size() < 4:
		return false
	for sc in sleep_cells:
		reserved[sc] = true

	ghost_spawn = _pick_spawn_cell(reserved, true, Vector2i(-1, -1))
	if ghost_spawn == Vector2i(-1, -1):
		return false
	reserved[ghost_spawn] = true

	warden_spawn = _pick_spawn_cell(reserved, false, ghost_spawn)
	if warden_spawn == Vector2i(-1, -1):
		return false

	_set_tile(exit_cell, TILE_EXIT)
	for td in terminal_defs:
		_set_tile(Vector2i(td[0], td[1]), TILE_TERMINAL)
	for sc in sleep_cells:
		_set_tile(sc, TILE_SLEEP)
	_set_tile(ghost_spawn, TILE_GHOST_SPAWN)
	_set_tile(warden_spawn, TILE_WARDEN_SPAWN)

	return true

func _pick_exit_cell() -> Vector2i:
	var edge_cells: Array[Vector2i] = []
	for r in range(1, ROWS - 1):
		for c in range(1, COLS - 1):
			var cell := Vector2i(c, r)
			if _tile(cell) != TILE_FLOOR:
				continue
			if _cell_open_degree(cell) < 2:
				continue
			if c <= 2 or c >= COLS - 3 or r <= 2 or r >= ROWS - 3:
				edge_cells.append(cell)
	if edge_cells.is_empty():
		return Vector2i(-1, -1)
	return edge_cells[rng.randi_range(0, edge_cells.size() - 1)]

func _pick_terminal_cells(reserved: Dictionary) -> Array[Vector2i]:
	var zones := [Vector2i(1, 6), Vector2i(7, 12), Vector2i(13, 18)]
	var picked: Array[Vector2i] = []

	for zone in zones:
		var choices: Array[Vector2i] = []
		for r in range(1, ROWS - 1):
			for c in range(zone.x, zone.y + 1):
				var cell := Vector2i(c, r)
				if reserved.has(cell):
					continue
				if _tile(cell) != TILE_FLOOR:
					continue
				if _cell_open_degree(cell) < 2:
					continue
				if _manhattan(cell, exit_cell) < 4:
					continue
				choices.append(cell)
		if choices.is_empty():
			return []
		picked.append(choices[rng.randi_range(0, choices.size() - 1)])

	for i in range(picked.size()):
		for j in range(i + 1, picked.size()):
			if _manhattan(picked[i], picked[j]) < 6:
				return []
	return picked

func _pick_sleep_cells(reserved: Dictionary, count: int) -> Array[Vector2i]:
	var candidates: Array[Vector2i] = []
	for r in range(1, ROWS - 1):
		for c in range(1, COLS - 1):
			var cell := Vector2i(c, r)
			if reserved.has(cell):
				continue
			if _tile(cell) != TILE_FLOOR:
				continue
			if _cell_open_degree(cell) < 2:
				continue
			if _manhattan(cell, exit_cell) < 3:
				continue
			var near_terminal := false
			for td in terminal_defs:
				if _manhattan(cell, Vector2i(td[0], td[1])) < 3:
					near_terminal = true
					break
			if near_terminal:
				continue
			candidates.append(cell)

	var shuffled := _shuffle_cells(candidates)
	var picked: Array[Vector2i] = []
	for c in shuffled:
		var valid := true
		for s in picked:
			if _manhattan(c, s) < 4:
				valid = false
				break
		if valid:
			picked.append(c)
			if picked.size() >= count:
				break
	return picked

func _pick_spawn_cell(reserved: Dictionary, for_ghost: bool, other_spawn: Vector2i) -> Vector2i:
	var candidates: Array[Vector2i] = []
	for r in range(1, ROWS - 1):
		for c in range(1, COLS - 1):
			var cell := Vector2i(c, r)
			if reserved.has(cell):
				continue
			if _tile(cell) != TILE_FLOOR:
				continue
			if _cell_open_degree(cell) < 2:
				continue
			if for_ghost:
				if _manhattan(cell, exit_cell) < 7:
					continue
			else:
				if other_spawn != Vector2i(-1, -1) and _manhattan(cell, other_spawn) < 8:
					continue
			candidates.append(cell)

	if candidates.is_empty():
		return Vector2i(-1, -1)
	return candidates[rng.randi_range(0, candidates.size() - 1)]

func _validate_layout() -> bool:
	if not _has_path(ghost_spawn, warden_spawn):
		return false
	if not _has_path(ghost_spawn, exit_cell):
		return false
	for td in terminal_defs:
		if not _has_path(ghost_spawn, Vector2i(td[0], td[1])):
			return false
		if not _has_path(warden_spawn, Vector2i(td[0], td[1])):
			return false

	for i in range(sleep_cells.size()):
		for j in range(i + 1, sleep_cells.size()):
			if _manhattan(sleep_cells[i], sleep_cells[j]) < 4:
				return false

	return true

func _build_fallback_layout() -> void:
	_init_empty_map()
	terminal_defs = [[3, 1, 1], [3, 5, 2], [9, 10, 3]]
	sleep_cells = [Vector2i(1,2), Vector2i(17,2), Vector2i(5,5), Vector2i(13,5), Vector2i(9,9)]
	exit_cell = Vector2i(17, 1)
	ghost_spawn = Vector2i(10, 14)
	warden_spawn = Vector2i(1, 14)

	for td in terminal_defs:
		_set_tile(Vector2i(td[0], td[1]), TILE_TERMINAL)
	for sc in sleep_cells:
		_set_tile(sc, TILE_SLEEP)
	_set_tile(exit_cell, TILE_EXIT)
	_set_tile(ghost_spawn, TILE_GHOST_SPAWN)
	_set_tile(warden_spawn, TILE_WARDEN_SPAWN)

func _build_layout_signature() -> String:
	var parts: Array[String] = []
	for r in range(ROWS):
		var row := ""
		for c in range(COLS):
			row += str(level_map[r][c])
		parts.append(row)
	return "|".join(parts)

## ─── AStarGrid2D Setup ───────────────────────────────────────────────────────
func _build_astar() -> void:
	astar.region = Rect2i(0, 0, COLS, ROWS)
	astar.cell_size = Vector2(TS, TS)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.update()
	for r in range(ROWS):
		for c in range(COLS):
			if int(level_map[r][c]) == TILE_WALL:
				astar.set_point_solid(Vector2i(c, r), true)

## ─── Spawning ────────────────────────────────────────────────────────────────
func _spawn_terminals() -> void:
	terminal_nodes.clear()
	for td in terminal_defs:
		var t_script := load("res://scripts/Terminal.gd")
		var t := Node2D.new()
		t.set_script(t_script)
		t.set_meta("terminal_id", td[2])
		t.set_meta("terminal_cell", Vector2i(td[0], td[1]))
		add_child(t)
		terminal_nodes.append(t)

func _spawn_ghost() -> void:
	var g_script := load("res://scripts/Ghost.gd")
	ghost_node = Node2D.new()
	ghost_node.set_script(g_script)
	ghost_node.level = self
	ghost_node.cell = ghost_spawn
	add_child(ghost_node)

func _spawn_warden() -> void:
	var w_script := load("res://scripts/Warden.gd")
	warden_node = Node2D.new()
	warden_node.set_script(w_script)
	warden_node.level = self
	warden_node.cell = warden_spawn
	add_child(warden_node)
	call_deferred("_link_agents")

func _build_ui() -> void:
	ui_node = CanvasLayer.new()
	ui_node.layer = 10
	var ui_script := load("res://scripts/GameUI.gd")
	var ui := Node2D.new()
	ui.set_script(ui_script)
	ui_node.add_child(ui)
	add_child(ui_node)

## ─── Drawing ─────────────────────────────────────────────────────────────────
func _draw() -> void:
	_draw_tiles()
	_draw_heatmap_overlay()

func _draw_tiles() -> void:
	for r in range(ROWS):
		for c in range(COLS):
			var x := c * TS
			var y := r * TS
			var v: int = level_map[r][c]
			match v:
				TILE_FLOOR, TILE_GHOST_SPAWN, TILE_WARDEN_SPAWN:
					_draw_floor(x, y)
				TILE_WALL:
					_draw_wall(x, y)
				TILE_TERMINAL:
					_draw_floor(x, y)
				TILE_EXIT:
					_draw_floor(x, y)
					_draw_exit(x, y)
				TILE_SLEEP:
					_draw_sleep_room(x, y)

func _draw_floor(x: int, y: int) -> void:
	draw_rect(Rect2(x, y, TS, TS), C_FLOOR)
	draw_rect(Rect2(x, y, TS, 1), C_FLOOR_LN)
	draw_rect(Rect2(x, y, 1, TS), C_FLOOR_LN)

func _draw_wall(x: int, y: int) -> void:
	draw_rect(Rect2(x, y, TS, TS), C_DIRT)
	draw_rect(Rect2(x, y, TS, 7), C_GRASS)
	draw_rect(Rect2(x + 4, y + 12, 8, 6), C_DIRT_DARK)
	draw_rect(Rect2(x + 20, y + 18, 10, 7), C_DIRT_DARK)
	draw_rect(Rect2(x + 8, y + 26, 7, 5), C_DIRT_DARK)
	draw_rect(Rect2(x + 26, y + 10, 8, 5), C_DIRT_DARK)
	draw_rect(Rect2(x, y + TS - 6, TS, 6), C_STONE)
	draw_rect(Rect2(x, y, TS, 3), Color(0.35, 0.70, 0.25))
	draw_rect(Rect2(x, y, TS, 1), Color(0.1, 0.3, 0.05))
	draw_rect(Rect2(x, y, 1, TS), Color(0.15, 0.15, 0.20))
	draw_rect(Rect2(x + TS - 1, y, 1, TS), Color(0.05, 0.05, 0.08))
	draw_rect(Rect2(x, y + TS - 1, TS, 1), Color(0.05, 0.05, 0.08))

func _draw_exit(x: int, y: int) -> void:
	var inner := Rect2(x + 3, y + 3, TS - 6, TS - 6)
	draw_rect(inner, Color(0.0, 0.15, 0.05), false)
	draw_rect(Rect2(x + 2, y + 2, TS - 4, TS - 4), C_EXIT, false)
	draw_rect(Rect2(x + 2, y + 2, TS - 4, TS - 4), Color(C_EXIT, 0.15))
	draw_rect(Rect2(x + 10, y + 17, TS - 20, 5), C_EXIT)
	draw_rect(Rect2(x + 17, y + 10, 5, TS - 20), C_EXIT)

func _draw_sleep_room(x: int, y: int) -> void:
	draw_rect(Rect2(x, y, TS, TS), C_SLEEP)
	draw_rect(Rect2(x, y, TS, 2), Color(0.8, 0.4, 1.0))
	draw_rect(Rect2(x, y, 2, TS), Color(0.8, 0.4, 1.0))
	draw_rect(Rect2(x + TS - 2, y, 2, TS), Color(0.8, 0.4, 1.0))
	draw_rect(Rect2(x, y + TS - 2, TS, 2), Color(0.8, 0.4, 1.0))
	draw_rect(Rect2(x + 5, y + 10, 5, TS - 20), Color(0.6, 0.3, 0.8))
	draw_rect(Rect2(x + 15, y + 10, 5, TS - 20), Color(0.6, 0.3, 0.8))

func _draw_heatmap_overlay() -> void:
	if GameManager.alert_level < GameManager.AlertLevel.SUSPICIOUS:
		return
	for r in range(ROWS):
		for c in range(COLS):
			if int(level_map[r][c]) == TILE_WALL:
				continue
			var h: float = GameManager.heatmap[r][c]
			if h > 0.25:
				draw_rect(
					Rect2(c * TS, r * TS, TS, TS),
					Color(1.0, 0.2, 0.0, (h - 0.25) * 0.35)
				)

## ─── Public Helpers (used by Ghost/Warden) ──────────────────────────────────
func is_walkable(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= COLS or cell.y < 0 or cell.y >= ROWS:
		return false
	return int(level_map[cell.y][cell.x]) != TILE_WALL

func get_cell_value(cell: Vector2i) -> int:
	if cell.x < 0 or cell.x >= COLS or cell.y < 0 or cell.y >= ROWS:
		return TILE_WALL
	return int(level_map[cell.y][cell.x])

func find_path(from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
	var raw := astar.get_id_path(from_cell, to_cell)
	var result: Array[Vector2i] = []
	for v in raw:
		result.append(Vector2i(v))
	return result

func get_neighbors(cell: Vector2i) -> Array[Vector2i]:
	var dirs: Array[Vector2i] = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]
	var result: Array[Vector2i] = []
	for d in dirs:
		var n: Vector2i = cell + d
		if is_walkable(n):
			result.append(n)
	return result

func is_sleep_room(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.x >= COLS or cell.y < 0 or cell.y >= ROWS:
		return false
	return int(level_map[cell.y][cell.x]) == TILE_SLEEP

func get_terminal_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for td in terminal_defs:
		cells.append(Vector2i(td[0], td[1]))
	return cells

func get_sleep_room_cells() -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for c in sleep_cells:
		cells.append(c)
	return cells

func get_exit_cell() -> Vector2i:
	return exit_cell

func get_ghost_spawn() -> Vector2i:
	return ghost_spawn

func get_warden_spawn() -> Vector2i:
	return warden_spawn

func get_dynamic_patrol_route() -> Array[Vector2i]:
	var route: Array[Vector2i] = []
	route.append(exit_cell)
	for td in terminal_defs:
		route.append(Vector2i(td[0], td[1]))

	var probe_points: Array[Vector2i] = [
		Vector2i(2, int(ROWS / 2)),
		Vector2i(int(COLS / 2), 2),
		Vector2i(COLS - 3, int(ROWS / 2)),
		Vector2i(int(COLS / 2), ROWS - 3),
		Vector2i(int(COLS / 2), int(ROWS / 2))
	]
	for probe in probe_points:
		var n: Vector2i = _nearest_walkable(probe)
		if n != Vector2i(-1, -1):
			route.append(n)

	return _dedupe_cells(route)

## ─── Internal Utility ────────────────────────────────────────────────────────
func _tile(cell: Vector2i) -> int:
	return int(level_map[cell.y][cell.x])

func _set_tile(cell: Vector2i, value: int) -> void:
	level_map[cell.y][cell.x] = value

func _in_inner_bounds(cell: Vector2i) -> bool:
	return cell.x >= 1 and cell.x < COLS - 1 and cell.y >= 1 and cell.y < ROWS - 1

func _manhattan(a: Vector2i, b: Vector2i) -> int:
	return abs(a.x - b.x) + abs(a.y - b.y)

func _cell_open_degree(cell: Vector2i) -> int:
	var degree := 0
	var dirs: Array[Vector2i] = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]
	for d in dirs:
		var n: Vector2i = cell + d
		if _in_inner_bounds(n) and _tile(n) != TILE_WALL:
			degree += 1
	return degree

func _has_path(from_cell: Vector2i, to_cell: Vector2i) -> bool:
	if not _in_inner_bounds(from_cell) or not _in_inner_bounds(to_cell):
		return false
	if _tile(from_cell) == TILE_WALL or _tile(to_cell) == TILE_WALL:
		return false

	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [from_cell]
	var idx := 0
	visited[from_cell] = true

	while idx < queue.size():
		var cur: Vector2i = queue[idx]
		idx += 1
		if cur == to_cell:
			return true
		var dirs: Array[Vector2i] = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]
		for d in dirs:
			var n: Vector2i = cur + d
			if not _in_inner_bounds(n):
				continue
			if _tile(n) == TILE_WALL:
				continue
			if visited.has(n):
				continue
			visited[n] = true
			queue.append(n)

	return false

func _shuffle_cells(cells: Array[Vector2i]) -> Array[Vector2i]:
	var result := cells.duplicate()
	for i in range(result.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Vector2i = result[i]
		result[i] = result[j]
		result[j] = tmp
	return result

func _nearest_walkable(origin: Vector2i) -> Vector2i:
	if _in_inner_bounds(origin) and _tile(origin) != TILE_WALL:
		return origin
	for r in range(1, 6):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var c := origin + Vector2i(dx, dy)
				if _in_inner_bounds(c) and _tile(c) != TILE_WALL:
					return c
	return Vector2i(-1, -1)

func _dedupe_cells(cells: Array[Vector2i]) -> Array[Vector2i]:
	var used: Dictionary = {}
	var result: Array[Vector2i] = []
	for c in cells:
		if c == Vector2i(-1, -1):
			continue
		if used.has(c):
			continue
		used[c] = true
		result.append(c)
	return result

## ─── Agent Linking (called after both are spawned) ──────────────────────────
func _link_agents() -> void:
	ghost_node.level = self
	warden_node.level = self
	ghost_node.warden = warden_node
	warden_node.ghost = ghost_node
	print("[Level] Agents linked: Ghost <-> Warden")
