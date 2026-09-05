# fox10.shutters — Home Assistant shutter control for the Omarchy bar

Controls all Home Assistant `cover.*` entities straight from the Omarchy top bar,
grouped by floor, with up/stop/down and a live position percentage.

```
┌──────────────────────────────────────────────────────────────────────┐
│  ☰  1 2 3 4            Mo 09:44            󰤨  󰂯  ▤  󰕾  󰖩  ⏻          │
└───────────────────────────────────────────────▲──────────────────────┘
                                                │
        ╭──────────────────────────────────────────────────────╮
        │  Shutters                                    ⟳   ⚙   │
        ├──────────────────────────────────────────────────────┤
        │  GROUND FLOOR                             ▲   ■   ▼  │
        │   Wohnzimmer                    100%      ▲   ■   ▼  │
        │   Küche                          45%      ▲   ■   ▼  │
        │   Terrassentür               ⟳   62%      ▲   ■   ▼  │
        ├──────────────────────────────────────────────────────┤
        │  FIRST FLOOR                              ▲   ■   ▼  │
        │   Schlafzimmer               [   35 ]     ▲   ■   ▼  │
        │   Kinderzimmer                    —       ▲   ■   ▼  │
        ╰──────────────────────────────────────────────────────╯
```

The interface is English; entity names come from Home Assistant
(`attributes.friendly_name`) and are shown exactly as HA reports them.

## Usage

| Action | Effect |
|---|---|
| Left-click the bar icon | Open / close the panel |
| Right-click | Reload state immediately |
| Middle-click | Open settings |
| Click a shutter row | Open the input field for an exact position |

### Setting an exact position

Clicking a shutter row (on the name or the percentage, not on ▲ / ■ / ▼) replaces
the percentage with an input field. The current value is pre-selected, so typing a
new number overwrites it directly.

| Input | Effect |
|---|---|
| Number `0`–`100`, then `⏎` | Moves the shutter to exactly that value (`cover.set_cover_position`) |
| `Esc` | Cancel, the percentage returns |
| Click elsewhere | Cancel |

`100` = fully open, `0` = fully closed — the same semantics as Home Assistant.
Values above 100 are clamped to 100; invalid input is discarded.

The field only appears for covers that are available **and** report the
`SET_POSITION` feature. Open/close-only drives keep the row unchanged.

The bar icon reflects the aggregate state:

| Glyph | Meaning |
|---|---|
| 󰖳 | all open |
| 󰂬 | partially open |
| 󰖰 | all closed |
| 󰓡 | at least one shutter is moving |
| 󰀨 (red) | error or not configured |

### Keyboard (inside the panel)

| Key | Effect |
|---|---|
| `j` / `k` or ↑ / ↓ | Change row (floor headers included) |
| `h` / `l` or ← / → | Move between ▲ / ■ / ▼ |
| `⏎` / `Space` | Trigger the selected button |
| `p` or `0`–`9` | Open the exact-position field for the current row |
| `r` | Reload |
| `s` | Settings |
| `Esc` | Leave settings, or close the panel |
| `Tab` | Next bar panel |

A floor header controls every shutter on that floor at once.

## Settings

Reachable via ⚙ in the panel, the `s` key, or a middle-click on the bar icon.
If no URL or token is stored yet, the panel opens here directly.

| Field | Description |
|---|---|
| **URL** | Base URL of Home Assistant, e.g. `https://home.example.com:8123`. If the scheme is missing, `https://` is added; a trailing `/` is stripped. |
| **Long-Lived Access Token** | Create it in Home Assistant under *Profile → Security → Long-lived access tokens*. Shown masked; 󰈈 reveals it, 󰅖 clears it. |
| **Test connection** | Checks URL + token and reports `Connected — N covers found`, `Invalid token (401)`, `Unreachable …` or `TLS error …`. Also reloads the cover list and the HA areas. |
| **Exclude** *(optional)* | Comma-separated `entity_id`s, `*` as wildcard (e.g. `cover.garage, cover.markise*`). Excluded covers disappear from the panel and the assignment list. The line below shows how many currently match. |
| **Floors** | Create, rename (󰏫), reorder (󰅃 / 󰅀) and delete (󰆴) floors. The order here is the section order in the panel. Covers of a deleted floor fall back to *Unassigned*. |
| **Assignment** | Pick a floor per cover, or `— ignore` to hide it. `— automatic` uses the HA areas/floors first, then a name heuristic (`*erdgeschoss*`, `*ground*`, `*og*`, `*upstairs*`, …). |
| **Idle interval** | Seconds between polls while the panel is closed (10–600, default 60). |
| **Open interval** | Seconds between polls while the panel is open (1–60, default 3). |

### Refreshing

After every command, and while a shutter is moving, the plugin polls once per
second so the percentage keeps up. If a request fails, a backoff from 5 s to 60 s
kicks in.

## Security

The token is stored **exclusively** in
`~/.local/state/omarchy/settings/shutters.json` with mode `0600` — never in
`~/.config/omarchy/shell.json`.

`ha.sh` hands it to `curl` via `--config -` on standard input, so it appears
neither in the process list (`ps`) nor in the shell history. When saving, the file
is moved into place through a temporary file created with `0600`.

> Plugins run unsandboxed inside the `omarchy-shell` process.

## Installation

```bash
# Already lives in ~/.config/omarchy/plugins/fox10.shutters/
omarchy-shell shell rescanPlugins
omarchy plugin enable fox10.shutters --section right
omarchy bar move fox10.shutters --section right    # optional, to reorder
```

Changes to files in the plugin directory are hot-reloaded automatically.
If a hot reload ever gets stuck: `omarchy restart shell`.

## IPC

```bash
omarchy-shell fox10.shutters toggle
omarchy-shell fox10.shutters refresh
omarchy-shell fox10.shutters settings
omarchy-shell fox10.shutters openAll     # raise every visible shutter
omarchy-shell fox10.shutters closeAll
omarchy-shell fox10.shutters stopAll
omarchy-shell fox10.shutters status      # open | closed | partial | moving | empty
```

Handy for Hyprland keybinds in `~/.config/hypr/bindings.conf`:

```
bindd = SUPER SHIFT, Up,   Shutters up,   exec, omarchy-shell fox10.shutters openAll
bindd = SUPER SHIFT, Down, Shutters down, exec, omarchy-shell fox10.shutters closeAll
```

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Red 󰀨 in the bar icon | URL/token missing, or the last request failed — open the panel and read the message. |
| `Invalid token (401)` | Token expired or revoked; create a new one in HA. |
| `Unreachable …` | Wrong host/port, or HA is offline. |
| `TLS error …` | Certificate not accepted (e.g. self-signed). |
| Stop button greyed out | The integration reports no `STOP` feature for this cover. |
| Clicking a row opens no input field | The cover reports no `SET_POSITION` feature, or is currently `unavailable`. Such rows show `—` instead of `%` and can only be driven with ▲ / ▼. |
| `Open` / `Closed` instead of `%` | The cover reports no `current_position`. |
| `—` and a dimmed row | Entity is `unavailable` / `unknown`. |
| No covers in the assignment list | Press *Test connection*, the list fills afterwards. |
| Everything lands in *Unassigned* | Your HA areas have no floors assigned. Set them in HA under *Settings → Areas*, or map the covers manually here. |

Plugin errors end up in the shell log:

```bash
journalctl --user -f | grep shutters
```

## Files

| File | Purpose |
|---|---|
| `manifest.json` | Plugin declaration (`kinds: ["bar-widget"]`) |
| `Panel.qml` | Bar button, popup, rows, keyboard control |
| `SettingsView.qml` | Settings interface |
| `Service.qml` | Settings storage, polling, commands |
| `Model.js` | Parsing, filtering, grouping, glyph logic (no QML dependency) |
| `ha.sh` | `curl` calls against the Home Assistant REST API |

Dependencies: `bash`, `curl`, `jq`.
