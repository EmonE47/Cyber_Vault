# 🔐 Cyber-Vault — AI Stealth Game
### Godot 4.2 | Third-Year University AI Project

---

## 🎮 Overview

**Cyber-Vault** is a 2D AI-driven hide-and-seek stealth game set inside a high-tech data vault. Two AI agents compete with opposing objectives:

| Agent | Role | AI Algorithm |
|-------|------|-------------|
| 🟦 **Ghost** | Infiltrator / Data Thief | **A\* Pathfinding** (safety-weighted) |
| 🔴 **Warden** | Security Guard | **Minimax** (alpha-beta pruning) + Heatmap |

---

## 🤖 AI Systems

### Ghost — A* Pathfinding (Safety-Weighted)
The Ghost uses **A\* (A-Star)** graph search to navigate the vault grid:

```
f(n) = g(n) + h(n) + safety_weight(n)
```

- `g(n)` — cost from start
- `h(n)` — Manhattan distance heuristic to goal
- `safety_weight(n)` — penalty for cells near Warden's FOV

The Ghost builds a **danger map** around the Warden's position each frame.  
Cells inside the Warden's vision cone receive high cost penalties, causing  
A* to automatically route the Ghost through shadows and blind spots.

**State Machine:**
```
IDLE → MOVING → HACKING → MOVING → (repeat) → MOVING → ESCAPED
                    ↕                    ↕
                 HIDING              EVADING
```

### Warden — Minimax with Alpha-Beta Pruning
When the Ghost is spotted, the Warden switches to **Minimax** to compute the optimal interception move:

```
function minimax(state, depth, maximizing, α, β):
    if depth == 0: return evaluate(state)
    if maximizing (Warden):
        best = -∞
        for each warden_move:
            val = minimax(new_state, depth-1, false, α, β)
            best = max(best, val);  α = max(α, best)
            if β ≤ α: break  // Alpha cutoff
        return best
    else (Ghost):
        best = +∞
        for each ghost_move:
            val = minimax(new_state, depth-1, true, α, β)
            best = min(best, val);  β = min(β, best)
            if β ≤ α: break  // Beta cutoff
        return best
```

**Evaluation Function:**
- Distance-to-Ghost (closer = higher Warden score)
- Blocking bonus (between Ghost and exit)
- Heatmap value bonus

**Probability Heatmap (Global):**
- All game events (sounds, alarms, terminal hacks) add heat at their location
- Heat diffuses spatially (Gaussian-like falloff)
- Heat decays over time (exponential decay: × 0.96 every 0.4s)
- Warden uses heatmap for SEARCH state when Ghost is lost

**Warden State Machine:**
```
PATROL → INVESTIGATE → CHASE (Minimax active) → SEARCH (Heatmap guided)
   ↑__________________________↓___________________↑
```

---

## 🕹️ Mechanics

### Vision System
- Warden has a **90° forward FOV cone** with range 6 tiles
- FOV uses **raycasting** — walls block vision
- Ghost can hide behind walls to break line-of-sight

### Sound System
- Ghost sprinting emits noise at 0.6 intensity
- Warden detects noise → raises alert level → investigates

### Hacking
- Ghost must stand still at terminal for **3 seconds**
- Progress bar visible above Ghost during hack
- Completion triggers **ALARM** at terminal position

### Alert Levels
| Level | Trigger | Warden Behavior |
|-------|---------|-----------------|
| SILENT | Default | Slow patrol |
| SUSPICIOUS | Noise heard | Investigate |
| ALERT | Loud noise | Faster search |
| ALARM | Terminal hacked / Spotted | Chase mode + Minimax |

---

## 🏆 Win Conditions

- **Ghost Wins** — Hack all 3 terminals + reach EXIT (EX)
- **Warden Wins** — Catch Ghost (within 1.4 tiles distance)

---

## 🗺️ Level Layout

```
T1 = Terminal 1 (col 3, row 1)     EX = Exit (col 17, row 1)
T2 = Terminal 2 (col 3, row 5)
T3 = Terminal 3 (col 9, row 10)
Ghost spawns at (10, 14) — bottom center
Warden spawns at (1, 14) — bottom left
```

---

## 🔧 Setup

1. Install **Godot Engine 4.2+** from [godotengine.org](https://godotengine.org)
2. Open Godot → **Import** → select `project.godot`
3. Press **F5** (or ▶ Play) to run

---

## 📁 Project Structure

```
cyber_vault/
├── project.godot          # Engine configuration
├── scenes/
│   └── Main.tscn          # Main game scene
└── scripts/
    ├── GameManager.gd     # Autoload: game state, heatmap, alerts
    ├── Level.gd           # Level layout, A* grid, tile drawing, spawning
    ├── Ghost.gd           # Ghost AI (A* + stealth decision tree)
    ├── Warden.gd          # Warden AI (Minimax + heatmap patrol)
    ├── Terminal.gd        # Hackable terminal objects
    └── GameUI.gd          # HUD, alerts, win/lose screen
```

---

## 📐 Technical Notes

- **Tile Size**: 40×40 pixels  
- **Grid**: 20×16 = 800×640 viewport  
- **All visuals**: Procedurally drawn (no external assets required)  
- **Block style**: Minecraft-style grass blocks (green top, dirt body, stone base)  
- **Character style**: Blocky 3D-ish pixel art (Ghost = teal shirt, Warden = red uniform)  
- **A* implementation**: Uses Godot 4's built-in `AStarGrid2D` with custom weight scaling  
- **Minimax depth**: 4 half-moves (~2 per agent) with alpha-beta pruning  

---

*Developed for Third-Year University AI & Game Design module*
