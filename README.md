# qlib

`qlib` is a CC:Tweaked turtle toolkit API which features state persistence,
fuel policy, smart movement, and a UI control panel.

## Requirements

- CC:Tweaked with the turtle API
- A GPS network for calibration and absolute-direction movement (optional)

Relative movement remains available without GPS. Fuel checks, reserve protection,
dig blacklisting, and state checkpoints are handled by the movement layer.

## Modules

- `conf.lua` — store and load qlib settings
- `fuel.lua` — manage fuel levels, reserves, and refueling
- `mvmt.lua` — move the turtle, handles digging, and calibrates GPS position
- `task.lua` — save persistent state info like facing, position, task
- `util.lua` — share helpers for coordinates, direction, text, vectors
- `pkgr.lua` — build modularized packages
- `pack.lua` — compress a directory into a single file installer
- `main.lua` — control a turtle via interactive UI panel

## Running

Install this directory as `qlib` on the turtle, then run:

```text
qlib/main
```

The first run creates `.rcgpt/conf.cfg` and `.rcgpt/task.state` in the current
working directory. Configuration defaults are defined near the top of
`conf.lua`.

## Packaging Installer

From the deployment root containing the `qlib` directory, run:

```text
qlib/pack rcGPT.lua
```
