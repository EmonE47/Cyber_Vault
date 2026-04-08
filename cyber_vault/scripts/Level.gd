class_name Level
## =============================================================================
## Level.gd  —  Main Scene Controller
## Handles: level layout definition, tile drawing (Minecraft-style blocks),
## AStarGrid2D setup, spawning Ghost/Warden/Terminals, and UI creation.
## =============================================================================
extends Node2D

const TS   := GameManager.TILE_SIZE      # 40
const COLS := GameManager.GRID_COLS      # 20
const ROWS := GameManager.GRID_ROWS      # 16

## ─── Level Map ───────────────────────────────────────────────────────────────
## 0=floor  1=wall  2=terminal  3=exit  4=ghost_spawn  5=warden_spawn
const LEVEL_MAP: Array = [
	[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
	[1,0,0,2,0,0,0,0,0,0,0,0,0,0,0,0,0,3,0,1],
	[1,0,1,1,0,1,1,0,1,0,1,1,0,1,0,1,1,0,0,1],
	[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],
	[1,1,0,1,1,1,0,1,1,0,1,1,1,0,1,1,0,1,0,1],
	[1,0,0,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],
	[1,0,1,1,0,1,0,1,1,0,1,0,1,1,0,1,0,1,1,1],
	[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],
	[1,1,0,1,1,0,1,1,0,1,1,0,1,1,0,1,0,1,0,1],
	[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],
	[1,0,1,0,0,0,1,0,0,2,1,0,0,1,0,0,1,0,0,1],
	[1,0,0,0,0,0,0,1,0,0,0,1,0,0,0,0,0,0,0,1],
	[1,1,0,1,0,1,1,0,1,0,1,0,1,1,0,1,0,1,0,1],
	[1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],
	[1,5,0,0,0,0,0,0,0,0,4,0,0,0,0,0,0,0,0,1],
	[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1],
]

# Terminal info [col, row, id]
const TERMINAL_DEFS: Array = [
	[3,  1, 1],   # T1 – top-left area
	[3,  5, 2],   # T2 – middle-left
	[9, 10, 3],   # T3 – lower center
]
const EXIT_CELL     := Vector2i(17, 1)
const GHOST_SPAWN   := Vector2i(10, 14)
const WARDEN_SPAWN  := Vector2i(1,  14)

## ─── AStarGrid2D shared across Ghost ─────────────────────────────────────────
var astar: AStarGrid2D = AStarGrid2D.new()

## ─── Node references ──────────────────────────────────────────────────────────
var ghost_node   : Node2D
var warden_node  : Node2D
var ui_node      : CanvasLayer
var terminal_nodes: Array[Node2D] = []

## ─── Colors ───────────────────────────────────────────────────────────────────
const C_FLOOR     := Color(0.08, 0.10, 0.16)
const C_FLOOR_LN  := Color(0.12, 0.15, 0.22)
const C_GRASS     := Color(0.22, 0.56, 0.16)
const C_DIRT      := Color(0.36, 0.20, 0.08)
const C_DIRT_DARK := Color(0.24, 0.12, 0.04)
const C_STONE     := Color(0.28, 0.28, 0.32)
const C_TERMINAL  := Color(0.0,  0.80, 0.90)
const C_EXIT      := Color(0.2,  0.90, 0.3)
const C_HUD_BG    := Color(0.05, 0.05, 0.10, 0.85)

## ─── Ready ────────────────────────────────────────────────────────────────────
func _ready() -> void:
	set_meta("is_level", true)
	_build_astar()
	_spawn_terminals()
	_spawn_ghost()
	_spawn_warden()
	_build_ui()
	GameManager.start_game()
	set_process(true)

func _process(_delta: float) -> void:
	queue_redraw()   # Redraw every frame (tiles + HUD)

## ─── AStarGrid2D Setup ───────────────────────────────────────────────────────
func _build_astar() -> void:
	astar.region     = Rect2i(0, 0, COLS, ROWS)
	astar.cell_size  = Vector2(TS, TS)
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar.update()
	for r in range(ROWS):
		for c in range(COLS):
			var v: int = LEVEL_MAP[r][c]
			if v == 1:
				astar.set_point_solid(Vector2i(c, r), true)

## ─── Spawning ────────────────────────────────────────────────────────────────
func _spawn_terminals() -> void:
	for td in TERMINAL_DEFS:
		var t_script := load("res://scripts/Terminal.gd")
		var t        := Node2D.new()
		t.set_script(t_script)
		t.set_meta("terminal_id",   td[2])
		t.set_meta("terminal_cell", Vector2i(td[0], td[1]))
		add_child(t)
		terminal_nodes.append(t)
	# Also mark exit visually (no script needed)

func _spawn_ghost() -> void:
	var g_script := load("res://scripts/Ghost.gd")
	ghost_node   = Node2D.new()
	ghost_node.set_script(g_script)
	ghost_node.set_meta("level", self)
	add_child(ghost_node)

func _spawn_warden() -> void:
	var w_script := load("res://scripts/Warden.gd")
	warden_node  = Node2D.new()
	warden_node.set_script(w_script)
	warden_node.set_meta("level", self)
	add_child(warden_node)
	call_deferred("_link_agents")

func _build_ui() -> void:
	ui_node = CanvasLayer.new()
	ui_node.layer = 10
	var ui_script := load("res://scripts/GameUI.gd")
	var ui        := Node2D.new()
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
			var v: int = LEVEL_MAP[r][c]
			match v:
				0, 4, 5:
					_draw_floor(x, y)
				1:
					_draw_wall(x, y)
				2:
					_draw_floor(x, y)
					# Terminal drawn by Terminal.gd
				3:
					_draw_floor(x, y)
					_draw_exit(x, y)

func _draw_floor(x: int, y: int) -> void:
	draw_rect(Rect2(x, y, TS, TS), C_FLOOR)
	# Subtle grid lines
	draw_rect(Rect2(x, y, TS, 1),  C_FLOOR_LN)
	draw_rect(Rect2(x, y, 1,  TS), C_FLOOR_LN)

## Minecraft-style grass block (matches Image 2)
func _draw_wall(x: int, y: int) -> void:
	# Base dirt body
	draw_rect(Rect2(x, y, TS, TS), C_DIRT)
	# Grass top band
	draw_rect(Rect2(x, y, TS, 7), C_GRASS)
	# Dirt texture patches
	draw_rect(Rect2(x+4,  y+12, 8, 6),  C_DIRT_DARK)
	draw_rect(Rect2(x+20, y+18, 10, 7), C_DIRT_DARK)
	draw_rect(Rect2(x+8,  y+26, 7, 5),  C_DIRT_DARK)
	draw_rect(Rect2(x+26, y+10, 8, 5),  C_DIRT_DARK)
	# Stone bottom strip
	draw_rect(Rect2(x, y+TS-6, TS, 6), C_STONE)
	# Grass highlight (brighter green at very top)
	draw_rect(Rect2(x, y, TS, 3), Color(0.35, 0.70, 0.25))
	# Block outline
	draw_rect(Rect2(x,    y,    TS, 1),  Color(0.1, 0.3, 0.05))   # top
	draw_rect(Rect2(x,    y,    1,  TS), Color(0.15, 0.15, 0.20)) # left
	draw_rect(Rect2(x+TS-1, y, 1, TS),  Color(0.05, 0.05, 0.08)) # right
	draw_rect(Rect2(x, y+TS-1, TS, 1),  Color(0.05, 0.05, 0.08)) # bottom

func _draw_exit(x: int, y: int) -> void:
	var inner := Rect2(x+3, y+3, TS-6, TS-6)
	draw_rect(inner, Color(0.0, 0.15, 0.05), false)
	draw_rect(Rect2(x+2, y+2, TS-4, TS-4), C_EXIT, false)
	draw_rect(Rect2(x+2, y+2, TS-4, TS-4), Color(C_EXIT, 0.15))
	# "EX" label drawn in draw_string — using a simple rect cross instead
	draw_rect(Rect2(x+10, y+17, TS-20, 5), C_EXIT)
	draw_rect(Rect2(x+17, y+10, 5,   TS-20), C_EXIT)

## Subtle heatmap debug overlay (semi-transparent red)
func _draw_heatmap_overlay() -> void:
	if GameManager.alert_level < GameManager.AlertLevel.SUSPICIOUS:
		return
	for r in range(ROWS):
		for c in range(COLS):
			if int(LEVEL_MAP[r][c]) == 1:
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
	return int(LEVEL_MAP[cell.y][cell.x]) != 1

func get_cell_value(cell: Vector2i) -> int:
	if cell.x < 0 or cell.x >= COLS or cell.y < 0 or cell.y >= ROWS:
		return 1
	return int(LEVEL_MAP[cell.y][cell.x])

func find_path(from_cell: Vector2i, to_cell: Vector2i) -> Array[Vector2i]:
	var raw := astar.get_id_path(from_cell, to_cell)
	var result: Array[Vector2i] = []
	for v in raw:
		result.append(Vector2i(v))
	return result

## Returns walkable neighbors of a cell
func get_neighbors(cell: Vector2i) -> Array[Vector2i]:
	var dirs: Array[Vector2i] = [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]
	var result: Array[Vector2i] = []
	for d in dirs:
		var n: Vector2i = cell + d
		if is_walkable(n):
			result.append(n)
	return result

## ─── Agent Linking (called after both are spawned) ────────────────────────
## We use call_deferred so both _ready() calls have completed before linking
func _link_agents() -> void:
	ghost_node.level  = self
	warden_node.level = self
	ghost_node.warden = warden_node
	warden_node.ghost = ghost_node
	print("[Level] Agents linked: Ghost <-> Warden")
