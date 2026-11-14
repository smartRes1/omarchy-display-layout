.pragma library

// One saved layout per combination of connected displays. The layouts live in
// a marked block at the end of ~/.config/hypr/monitors.lua, which Omarchy
// loads on every Hyprland start and reload. The block holds:
//
//   - a `-- data:` comment with the layouts as JSON, so the panel can read
//     them back without parsing Lua;
//   - the same layouts as a Lua table, plus a few lines that pick the one
//     matching the displays plugged in now, and again whenever a display is
//     plugged in or out.
//
// Everything outside the block is left as it is.

var BEGIN = "-- BEGIN display-layout"
var END = "-- END display-layout"
var DATA = "-- data: "

// A laptop panel is known by its connector; an external display by its
// description (make, model, serial), so it is the same display on any port.
function isInternal(name) {
  return /^(eDP|LVDS|DSI)/.test(name)
}

function monitorId(monitor) {
  if (isInternal(monitor.name) || !monitor.description) return monitor.name
  return "desc:" + monitor.description
}

// The key of a combination: the ids of its displays, sorted.
function profileKey(monitors) {
  var ids = []
  for (var i = 0; i < monitors.length; i++) ids.push(monitorId(monitors[i]))
  ids.sort()
  return ids.join(" + ")
}

function findBlock(text) {
  var start = text.indexOf(BEGIN)
  if (start === -1) return null
  var end = text.indexOf(END, start)
  if (end === -1) return null
  end += END.length
  if (text.charAt(end) === "\n") end++
  return { start: start, end: end }
}

// { key: [{ output, mode, position, scale, transform }] } from the file's
// block, or {} when it has none (or one that can't be read).
function readProfiles(text) {
  var block = findBlock(String(text || ""))
  if (!block) return {}
  var lines = text.slice(block.start, block.end).split("\n")
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].indexOf(DATA) !== 0) continue
    try {
      var data = JSON.parse(lines[i].slice(DATA.length))
      return data && typeof data.profiles === "object" && data.profiles ? data.profiles : {}
    } catch (e) {
      return {}
    }
  }
  return {}
}

// The rules that put the displays where they are now.
function rulesFor(monitors) {
  var rules = []
  for (var i = 0; i < monitors.length; i++) {
    var m = monitors[i]
    var rule = { output: monitorId(m), mode: m.mode, position: m.x + "x" + m.y, scale: m.scale }
    if (m.transform) rule.transform = m.transform
    rules.push(rule)
  }
  rules.sort(function(a, b) { return a.output < b.output ? -1 : a.output > b.output ? 1 : 0 })
  return rules
}

function luaString(value) {
  return "\"" + String(value).replace(/[\\"]/g, "\\$&").replace(/[\x00-\x1f]/g, function(c) {
    return "\\" + c.charCodeAt(0)
  }) + "\""
}

function luaNumber(value) {
  var n = Number(value)
  return isFinite(n) ? String(Math.round(n * 1000) / 1000) : "1"
}

function renderBlock(profiles) {
  var keys = Object.keys(profiles).sort()
  var out = []
  out.push(BEGIN)
  out.push("-- Written by the Display Layout plugin: one layout per combination of")
  out.push("-- connected displays. Arrange them in the panel and save; edits made here")
  out.push("-- by hand are replaced on the next save.")
  out.push(DATA + JSON.stringify({ version: 1, profiles: profiles }))
  out.push("do")
  out.push("  local profiles = {")
  for (var i = 0; i < keys.length; i++) {
    out.push("    [" + luaString(keys[i]) + "] = {")
    var rules = profiles[keys[i]] || []
    for (var j = 0; j < rules.length; j++) {
      var r = rules[j]
      var fields = [
        "output = " + luaString(r.output),
        "mode = " + luaString(r.mode || "preferred"),
        "position = " + luaString(r.position),
        "scale = " + luaNumber(r.scale)
      ]
      if (r.transform) fields.push("transform = " + Math.round(Number(r.transform)))
      out.push("      { " + fields.join(", ") + " },")
    }
    out.push("    },")
  }
  out.push("  }")
  out.push("")
  out.push("  local function id(monitor)")
  out.push("    local name = monitor.name or \"\"")
  out.push("    local internal = name:match(\"^eDP\") or name:match(\"^LVDS\") or name:match(\"^DSI\")")
  out.push("    if internal or not monitor.description or monitor.description == \"\" then return name end")
  out.push("    return \"desc:\" .. monitor.description")
  out.push("  end")
  out.push("")
  out.push("  -- The layout whose displays are exactly the ones connected now. `gone` is")
  out.push("  -- a display Hyprland still lists while it reports its removal.")
  out.push("  local function apply(gone)")
  out.push("    local present, count = {}, 0")
  out.push("    for _, monitor in ipairs(hl.get_monitors()) do")
  out.push("      if monitor.name ~= gone and not monitor.is_mirror then")
  out.push("        present[id(monitor)] = true")
  out.push("        count = count + 1")
  out.push("      end")
  out.push("    end")
  out.push("    for _, profile in pairs(profiles) do")
  out.push("      local matches = #profile == count")
  out.push("      for _, rule in ipairs(profile) do matches = matches and present[rule.output] == true end")
  out.push("      if matches then")
  out.push("        for _, rule in ipairs(profile) do hl.monitor(rule) end")
  out.push("        return")
  out.push("      end")
  out.push("    end")
  out.push("  end")
  out.push("")
  out.push("  apply()")
  out.push("  hl.on(\"monitor.added\", function() apply() end)")
  out.push("  hl.on(\"monitor.removed\", function(monitor)")
  out.push("    local name = monitor and monitor.name")
  out.push("    hl.timer(function() apply(name) end, { type = \"oneshot\", timeout = 1 })")
  out.push("  end)")
  out.push("end")
  out.push(END)
  return out.join("\n") + "\n"
}

// The file with its block replaced by one holding `profiles`, or appended
// when it had none.
function writeProfiles(text, profiles) {
  text = String(text || "")
  var block = findBlock(text)
  var rendered = renderBlock(profiles)
  if (block) return text.slice(0, block.start) + rendered + text.slice(block.end)
  if (text.length > 0 && text.charAt(text.length - 1) !== "\n") text += "\n"
  return text + (text.length > 0 ? "\n" : "") + rendered
}
