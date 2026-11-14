# Display Layout for Omarchy

Arrange your displays with the mouse, and keep **one layout per combination
of connected displays**. Docked at your desk with two monitors, at the office
with one, or on the laptop alone: each setup gets its own saved arrangement,
applied automatically when you plug displays in or out.

An [Omarchy](https://omarchy.org) shell plugin.

## Install

```bash
omarchy plugin add https://github.com/smartRes1/omarchy-display-layout.git --enable
```

`--enable` asks where to put the bar button. Open the panel with:

- the bar button (monitor icon), or
- `omarchy-shell shell toggle smartres1.display-layout`, e.g. bound to a key in
  `~/.config/hypr/bindings.lua`:

  ```lua
  o.bind("SUPER + CTRL + M", "Arrange displays", "omarchy-shell shell toggle smartres1.display-layout")
  ```

## Use

1. Drag a display and let go. It snaps to the nearest edge of another display,
   and its top, middle or bottom (left, middle, right) edge snaps into line
   when you drop it close by. The layout is applied right away, so you can
   try the mouse across the edges.
2. **Save** (Enter) keeps it as the layout for exactly these displays.
   **Discard** (Esc) goes back to the saved layout.

The subtitle tells you whether the current combination already has a saved
layout.

## How it works

Saving writes a marked block at the end of `~/.config/hypr/monitors.lua`,
which Omarchy already loads:

```lua
-- BEGIN display-layout
-- data: {"version":1,"profiles":{...}}
do
  local profiles = { ... }   -- one entry per combination
  ...                        -- picks the matching one on start and on hotplug
end
-- END display-layout
```

- Everything outside the block is left untouched. The first save keeps a copy
  of the file as `monitors.lua.before-display-layout`.
- External displays are identified by their description (make, model, serial),
  so a display keeps its place whichever port it is plugged into. The laptop
  panel is identified by its connector (`eDP-1`).
- Each saved layout stores position, scale, mode and rotation. Scale and
  rotation come from what Hyprland shows when you save. Set them in Omarchy's
  Display panel or in `monitors.lua` first.
- A combination without a saved layout falls back to your own rules in
  `monitors.lua`.
- A `monitors.lua` that is a symlink (dotfiles) is written in place and stays
  a symlink.

To remove everything, delete the block between `-- BEGIN display-layout` and
`-- END display-layout`, then run `omarchy plugin remove smartres1.display-layout`.

## Languages

English and German. More translations are welcome: add `i18n/<code>.json`
(codes as in `$OMARCHY_PATH/default/i18n/locales.json`).

## License

MIT
