# Audio Drop-In Paths

Put your music and SFX files in these locations to override the procedural fallback audio.

## Looped Music (background)
Use one of these file names:

- `res://audio/music/main_loop.ogg`
- `res://audio/music/main_loop.wav`
- `res://audio/music/main_loop.mp3`
- `res://audio/music/cyber_vault_loop.ogg`
- `res://audio/music/cyber_vault_loop.wav`
- `res://audio/music/cyber_vault_loop.mp3`

## Event SFX
Hacking sound (played when hacking starts):

- `res://audio/sfx/hack_short.ogg`
- `res://audio/sfx/hack_short.wav`
- `res://audio/sfx/hack_short.mp3`

Alarm sound (played when terminal is hacked):

- `res://audio/sfx/alarm_short.ogg`
- `res://audio/sfx/alarm_short.wav`
- `res://audio/sfx/alarm_short.mp3`

## Notes
- If no files are found, the game uses generated synth/tone audio fallback.
- Music files are played in a looped playlist (single file loops by replaying).
- The in-game volume slider controls both music and SFX.
