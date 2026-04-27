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

const MUSIC_BASE_DB        := -18.0
const MUSIC_FADE_SPEED     := 3.2
const MUSIC_MIX_RATE       := 22050.0
const MUSIC_BUFFER_SECONDS := 0.35
const SFX_BASE_DB          := -9.0
const SFX_MIX_RATE         := 22050.0
const SFX_BUFFER_SECONDS   := 0.35

const MUSIC_TRACK_CANDIDATES := [
	"res://audio/music/main_loop.ogg",
	"res://audio/music/main_loop.wav",
	"res://audio/music/main_loop.mp3",
	"res://audio/music/cyber_vault_loop.ogg",
	"res://audio/music/cyber_vault_loop.wav",
	"res://audio/music/cyber_vault_loop.mp3"
]
const HACK_SFX_CANDIDATES := [
	"res://audio/sfx/hack_short.ogg",
	"res://audio/sfx/hack_short.wav",
	"res://audio/sfx/hack_short.mp3"
]
const ALARM_SFX_CANDIDATES := [
	"res://audio/sfx/alarm_short.ogg",
	"res://audio/sfx/alarm_short.wav",
	"res://audio/sfx/alarm_short.mp3"
]

# ─── State ───────────────────────────────────────────────────────────────────
var game_state      : GameState  = GameState.MENU
var alert_level     : AlertLevel = AlertLevel.SILENT
var terminals_hacked: int        = 0
var total_terminals : int        = 3
var winner          : String     = ""
var master_volume   : float      = 0.75

# Probability heatmap [row][col] — float 0.0..1.0
# Used by Warden AI to predict Ghost location
var heatmap : Array = []

var _decay_timer: float = 0.0
var _last_hacking_clue_ms: int = -100000

var _track_music_player: AudioStreamPlayer
var _music_tracks: Array[AudioStream] = []
var _music_track_idx: int = 0
var _use_track_music: bool = false
var _track_music_level: float = 0.0

var _sfx_hack_player: AudioStreamPlayer
var _sfx_alarm_player: AudioStreamPlayer
var _sfx_hack_stream: AudioStream
var _sfx_alarm_stream: AudioStream
var _sfx_gen_player: AudioStreamPlayer
var _sfx_gen_stream: AudioStreamGenerator
var _sfx_gen_playback: AudioStreamGeneratorPlayback

# Procedural ambient tone (generated in real time, no external files needed)
var _music_player: AudioStreamPlayer
var _music_stream: AudioStreamGenerator
var _music_playback: AudioStreamGeneratorPlayback
var _music_phase_a: float = 0.0
var _music_phase_b: float = 0.0
var _music_amp: float = 0.0

const HACKING_CLUE_COOLDOWN_MS := 1200

# ─── Ready ───────────────────────────────────────────────────────────────────
func _ready() -> void:
	_init_heatmap()
	_setup_audio_system()
	set_process_unhandled_input(true)

func _process(delta: float) -> void:
	_update_audio(delta)
	if game_state != GameState.PLAYING:
		return
	_decay_timer += delta
	if _decay_timer >= 0.4:
		_decay_timer = 0.0
		_decay_heatmap()

func _unhandled_input(event: InputEvent) -> void:
	if game_state != GameState.GAME_OVER:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R or event.keycode == KEY_Q:
			restart_current_run()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ESCAPE:
			get_tree().quit()
			get_viewport().set_input_as_handled()

func restart_current_run() -> void:
	var tree := get_tree()
	if tree == null:
		return
	tree.paused = false
	var scene := tree.current_scene
	if scene != null and scene.scene_file_path != "":
		tree.call_deferred("change_scene_to_file", scene.scene_file_path)
		return
	tree.call_deferred("reload_current_scene")

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
	_play_hacking_sfx()
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
	_play_alarm_sfx()
	print("[GameManager] Terminal %d hacked (%d/%d)" % [tid, terminals_hacked, total_terminals])

func all_hacked() -> bool:
	return terminals_hacked >= total_terminals

func set_master_volume(value: float) -> void:
	master_volume = clampf(value, 0.0, 1.0)

func get_master_volume() -> float:
	return master_volume

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

# ─── Audio: Procedural Music Tone ────────────────────────────────────────────
func _setup_music_tone() -> void:
	_music_stream = AudioStreamGenerator.new()
	_music_stream.mix_rate = MUSIC_MIX_RATE
	_music_stream.buffer_length = MUSIC_BUFFER_SECONDS

	_music_player = AudioStreamPlayer.new()
	_music_player.stream = _music_stream
	_music_player.volume_db = MUSIC_BASE_DB
	_music_player.bus = "Master"
	add_child(_music_player)
	_music_player.play()

	_music_playback = _music_player.get_stream_playback() as AudioStreamGeneratorPlayback

func _update_music_tone(delta: float) -> void:
	if _music_playback == null:
		if _music_player != null and _music_player.playing:
			_music_playback = _music_player.get_stream_playback() as AudioStreamGeneratorPlayback
		return

	var target_amp := 0.18 * master_volume if game_state == GameState.PLAYING else 0.0
	_music_amp = lerpf(_music_amp, target_amp, minf(1.0, MUSIC_FADE_SPEED * delta))

	var frames := _music_playback.get_frames_available()
	if frames <= 0:
		return

	var base_freq := _music_frequency_for_alert()
	var now_sec := float(Time.get_ticks_msec()) / 1000.0
	var vibrato := 1.0 + 0.02 * sin(now_sec * 0.9)
	var phase_inc_a := TAU * (base_freq * vibrato) / MUSIC_MIX_RATE
	var phase_inc_b := TAU * (base_freq * 1.5) / MUSIC_MIX_RATE

	while frames > 0:
		# Blend a base sine with a soft harmonic for a subtle synth pad.
		var sample := (sin(_music_phase_a) * 0.72 + sin(_music_phase_b) * 0.28) * _music_amp
		_music_playback.push_frame(Vector2(sample, sample))
		_music_phase_a = wrapf(_music_phase_a + phase_inc_a, 0.0, TAU)
		_music_phase_b = wrapf(_music_phase_b + phase_inc_b, 0.0, TAU)
		frames -= 1

func _music_frequency_for_alert() -> float:
	match alert_level:
		AlertLevel.SILENT:
			return 164.81
		AlertLevel.SUSPICIOUS:
			return 196.00
		AlertLevel.ALERT:
			return 220.00
		AlertLevel.ALARM:
			return 261.63
		_:
			return 164.81

func _setup_audio_system() -> void:
	_setup_track_music_player()
	_setup_sfx_players()

	if _load_music_tracks():
		_use_track_music = true
		_start_track_music()
		print("[GameManager] Audio: using looped music track(s)")
	else:
		_use_track_music = false
		_setup_music_tone()
		print("[GameManager] Audio: no music files found, using synth fallback")

func _setup_track_music_player() -> void:
	_track_music_player = AudioStreamPlayer.new()
	_track_music_player.bus = "Master"
	_track_music_player.finished.connect(_on_track_music_finished)
	add_child(_track_music_player)

func _load_music_tracks() -> bool:
	_music_tracks.clear()
	for path in MUSIC_TRACK_CANDIDATES:
		if not ResourceLoader.exists(path):
			continue
		var res := load(path)
		if res is AudioStream:
			_music_tracks.append(res as AudioStream)
	return not _music_tracks.is_empty()

func _start_track_music() -> void:
	if _music_tracks.is_empty() or _track_music_player == null:
		return
	_music_track_idx = clampi(_music_track_idx, 0, _music_tracks.size() - 1)
	_track_music_player.stream = _music_tracks[_music_track_idx]
	if game_state == GameState.PLAYING:
		_track_music_player.play()

func _on_track_music_finished() -> void:
	if _music_tracks.is_empty() or _track_music_player == null:
		return
	_music_track_idx = (_music_track_idx + 1) % _music_tracks.size()
	_track_music_player.stream = _music_tracks[_music_track_idx]
	if game_state == GameState.PLAYING:
		_track_music_player.play()

func _setup_sfx_players() -> void:
	_sfx_hack_player = AudioStreamPlayer.new()
	_sfx_hack_player.bus = "Master"
	add_child(_sfx_hack_player)

	_sfx_alarm_player = AudioStreamPlayer.new()
	_sfx_alarm_player.bus = "Master"
	add_child(_sfx_alarm_player)

	_sfx_hack_stream = _load_first_audio(HACK_SFX_CANDIDATES)
	_sfx_alarm_stream = _load_first_audio(ALARM_SFX_CANDIDATES)

	_sfx_gen_stream = AudioStreamGenerator.new()
	_sfx_gen_stream.mix_rate = SFX_MIX_RATE
	_sfx_gen_stream.buffer_length = SFX_BUFFER_SECONDS

	_sfx_gen_player = AudioStreamPlayer.new()
	_sfx_gen_player.stream = _sfx_gen_stream
	_sfx_gen_player.volume_db = SFX_BASE_DB
	_sfx_gen_player.bus = "Master"
	add_child(_sfx_gen_player)
	_sfx_gen_player.play()
	_sfx_gen_playback = _sfx_gen_player.get_stream_playback() as AudioStreamGeneratorPlayback

func _load_first_audio(paths: Array) -> AudioStream:
	for path in paths:
		if not ResourceLoader.exists(path):
			continue
		var res := load(path)
		if res is AudioStream:
			return res as AudioStream
	return null

func _play_hacking_sfx() -> void:
	if _sfx_hack_stream != null and _sfx_hack_player != null:
		_sfx_hack_player.stream = _sfx_hack_stream
		_sfx_hack_player.volume_db = SFX_BASE_DB + linear_to_db(maxf(0.0001, master_volume))
		_sfx_hack_player.play()
		return
	_play_generated_sfx([
		{"freq": 740.0, "seconds": 0.09, "amp": 0.50},
		{"freq": 920.0, "seconds": 0.07, "amp": 0.40}
	])

func _play_alarm_sfx() -> void:
	if _sfx_alarm_stream != null and _sfx_alarm_player != null:
		_sfx_alarm_player.stream = _sfx_alarm_stream
		_sfx_alarm_player.volume_db = SFX_BASE_DB + linear_to_db(maxf(0.0001, master_volume))
		_sfx_alarm_player.play()
		return
	_play_generated_sfx([
		{"freq": 300.0, "seconds": 0.10, "amp": 0.65},
		{"freq": 0.0, "seconds": 0.03, "amp": 0.0},
		{"freq": 240.0, "seconds": 0.14, "amp": 0.70}
	])

func _play_generated_sfx(pattern: Array) -> void:
	if _sfx_gen_playback == null:
		if _sfx_gen_player != null and _sfx_gen_player.playing:
			_sfx_gen_playback = _sfx_gen_player.get_stream_playback() as AudioStreamGeneratorPlayback
		else:
			return

	var max_frames := _sfx_gen_playback.get_frames_available()
	if max_frames <= 0:
		return

	var written := 0
	for segment in pattern:
		var seg_freq: float = float(segment.get("freq", 0.0))
		var seg_seconds: float = float(segment.get("seconds", 0.05))
		var seg_amp: float = float(segment.get("amp", 0.5)) * master_volume
		var frames := int(seg_seconds * SFX_MIX_RATE)
		if frames <= 0:
			continue
		for i in range(frames):
			if written >= max_frames:
				return
			var env := 1.0 - absf((float(i) / maxf(1.0, float(frames - 1))) * 2.0 - 1.0)
			var sample := 0.0
			if seg_freq > 0.0:
				var t := float(i) / SFX_MIX_RATE
				sample = sin(TAU * seg_freq * t) * seg_amp * env
			_sfx_gen_playback.push_frame(Vector2(sample, sample))
			written += 1

func _update_audio(delta: float) -> void:
	if _use_track_music:
		_update_track_music(delta)
	else:
		_update_music_tone(delta)

func _update_track_music(delta: float) -> void:
	if _track_music_player == null:
		return

	var target_level := master_volume if game_state == GameState.PLAYING else 0.0
	_track_music_level = lerpf(_track_music_level, target_level, minf(1.0, MUSIC_FADE_SPEED * delta))
	_track_music_player.volume_db = MUSIC_BASE_DB + linear_to_db(maxf(0.0001, _track_music_level))

	if game_state == GameState.PLAYING:
		if not _track_music_player.playing and _track_music_player.stream != null:
			_track_music_player.play()
	elif _track_music_level <= 0.005 and _track_music_player.playing:
		_track_music_player.stop()
