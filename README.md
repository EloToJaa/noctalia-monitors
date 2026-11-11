# noctalia-monitors

A [Noctalia](https://github.com/noctalia-dev/noctalia-shell) plugin for managing monitors from a panel:
position, resolution, refresh rate, scale, rotation, variable refresh and enable/disable.

Works with [Umbriel](https://github.com/noctalia-dev/umbriel), Hyprland and niri (any wlroots-style compositor can edit and apply).

> Work in progress. The behaviour is modelled on the native monitor dialog in
> [noctalia#4330](https://github.com/noctalia-dev/noctalia/pull/4330).

## How it works

Umbriel exposes outputs over IPC (`umbriel outputs --json`, `umbriel subscribe outputs`) but has no runtime action for
changing mode, position or scale. It does implement `wlr-output-management`, so the plugin reads state from Umbriel and
applies changes with [`wlr-randr`](https://sr.ht/~emersion/wlr-randr/), as one atomic configuration. After an apply
the previous layout is kept for a confirm-or-revert countdown, so a bad mode never strands you on a black screen.

`wlr-randr` changes last until the compositor restarts, so the panel can also **Save** the layout (see below).

## Layout

```
monitors/     the plugin (id elotoja/monitors): plugin.toml, bar.luau, panel.luau, identify.luau (layer), service.luau, model.luau, translations/
tests/        unit tests for the pure logic in monitors/model.luau
nix/          Home Manager module
flake.nix     packages.default = a Noctalia plugin *source* containing monitors/
```

## Install

### Nix flake (Home Manager)

```nix
# flake.nix
inputs.noctalia-monitors = {
  url = "github:EloToJaa/noctalia-monitors";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

```nix
# home-manager config (needs the Noctalia Home Manager module)
{
  imports = [inputs.noctalia-monitors.homeModules.default];
  programs.noctalia-monitors.enable = true;
}
```

The module installs `wlr-randr`, adds a `path` plugin source pointing at the package and enables `elotoja/monitors`. It never edits your compositor config. With `programs.noctalia-monitors.layoutFiles = ["umbriel"];` it only creates an empty, writable layout file (`~/.config/umbriel/monitors.toml`) so you can include it yourself (see below). Equivalent manual config for Noctalia:

```toml
[plugins]
enabled = ["elotoja/monitors"]

[[plugins.source]]
name     = "noctalia-monitors"
kind     = "path"
location = "/nix/store/...-noctalia-monitors"
enabled  = true
```

### Without Nix

Add `https://github.com/EloToJaa/noctalia-monitors` as a git source in **Settings → Plugins**, or copy `monitors/` to
`~/.local/share/noctalia/plugins/monitors/`, then enable the plugin.

## Usage

```sh
noctalia msg panel-toggle elotoja/monitors:panel
```

Or add the **Monitors** control-center tile (Settings → Control Center), or the **Monitors** widget to the bar (Settings → Bar): a monitor icon that opens the panel, with a tooltip of every
output's mode and a countdown while a change waits for confirmation.

**Moving monitors:** in the layout map, drag a monitor by its middle onto the edge of another one. It is placed flush
against that edge, monitors in the way are pushed aside, and any gap it leaves is closed. The placement controls
(side, anchor, alignment, exact X/Y) below the map fine-tune the result. Nothing changes on screen until you press
**Apply**.

**Identify:** the button next to the monitor chips shows each monitor's connector name (for example `HDMI-A-1`) and
resolution on its own screen for a few seconds, so you can tell which is which.

Scripting (also handy for testing without a mouse):

```sh
noctalia msg plugin elotoja/monitors:panel all drop DP-2 HDMI-A-1:left_of    # same as the drag
noctalia msg plugin elotoja/monitors:panel all identify                      # same as the button
noctalia msg plugin elotoja/monitors:service all apply '{"DP-1":{...}}'      # drafts as JSON
noctalia msg plugin elotoja/monitors:service all confirm                     # or: revert
```

## Development

```sh
nix develop      # luau, luau-lsp, wlr-randr, jq, just
just test        # unit tests
just deploy      # copy the plugin to ~/.local/share/noctalia/plugins for a live test
```

## License

MIT

## Known issues

- **Umbriel 0.1.0 can abort when a headless (virtual) output is disabled and re-enabled through
  `wlr-output-management`** (`types/wlr_output_management_v1.c: head_send_state: Assertion 'found' failed`).
  Seen while testing with `umbriel output-create`; real monitors are unaffected so far. Avoid toggling virtual outputs.
- Applied changes only last until Umbriel restarts unless you **Save** them and include the saved file (next section).
- Hyprland and niri support is untested on a real session (the author runs Umbriel). The state-reading and file
  generation paths are unit-tested and were exercised against real `wlr-randr --json` data, but not inside those
  compositors. Reports welcome.

## Making a layout permanent

**Save** writes the live layout to a file the compositor can include. Once the file exists, every change you **Keep**
updates it, and reverted changes are never saved. The panel shows the exact include line until your main config has it.
**Copy config** copies the same text if you would rather paste it into your own config.

| Compositor | Saved file                    | Add to your main config                                  |
| ---------- | ----------------------------- | -------------------------------------------------------- |
| Umbriel    | `~/.config/umbriel/monitors.toml` | `[include.optional]` / `files = ["~/.config/umbriel/monitors.toml"]` |
| Hyprland (Lua, `hyprland.lua`) | `~/.config/hypr/monitors.lua` | `pcall(require, "monitors")` |
| Hyprland (hyprlang, `hyprland.conf`) | `~/.config/hypr/monitors.conf` | `source = ~/.config/hypr/monitors.conf` |
| niri 26.04+ | `~/.config/niri/monitors.kdl` | `include optional=true "~/.config/niri/monitors.kdl"` |

`$XDG_CONFIG_HOME` is honoured. Notes:

- Umbriel's includes merge by table key, so the file sits next to your own `[output.*]` settings (such as `workspaces`).
- Hyprland: the format follows whichever of `hyprland.lua` / `hyprland.conf` exists (Lua wins). `pcall` keeps a missing
  file from breaking the config. Put the include after any `monitor` rules of your own so the saved layout wins.
- niri: older versions have no `optional=true`, so use `include "monitors.kdl"` and make sure the file exists (the Nix
  module's `layoutFiles = ["niri"]` creates an empty one). niri includes are positional: put it after your own
  `output` blocks.
- With `programs.noctalia-monitors.layoutFiles = ["umbriel" "hyprland" "niri"]` (any subset) the Home Manager module
  creates the empty file, so a non-optional include never fails.

## Compositors

The plugin detects the session (Umbriel socket, `HYPRLAND_INSTANCE_SIGNATURE`, `NIRI_SOCKET`) or follows the
**Compositor** setting under Settings → Plugins. Anything else that implements `wlr-output-management` works for editing
and applying, without a saved-layout file. Umbriel state is pushed over its event stream; the others are polled through
`wlr-randr --json` every two seconds.
