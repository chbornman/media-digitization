-- audit.lua — scene-split audit overlay for mpv.
-- Read-only: this script never writes to any input file.
--
-- Run via the `audit` wrapper in this directory, or directly:
--   mpv --script=audit.lua \
--       --script-opts-append=audit-scenes=/path/to/scenes.csv \
--       --script-opts-append=audit-mkv_dir=/path/to/mkvs \
--       --script-opts-append=audit-mp4_dir=/path/to/mp4s \
--       master.dv

local mp      = require 'mp'
local msg     = require 'mp.msg'
local utils   = require 'mp.utils'
local options = require 'mp.options'

local opts = { scenes = "", mkv_dir = "", mp4_dir = "" }
options.read_options(opts, "audit")

-- ---- CSV parsing --------------------------------------------------
local function split_csv(line)
  local fields = {}
  for field in (line .. ","):gmatch("([^,]*),") do
    fields[#fields + 1] = field
  end
  return fields
end

local function parse_scenes_csv(path)
  if path == "" then return nil, "no --scenes provided" end
  local f, err = io.open(path, "r")
  if not f then return nil, err end
  local lines = {}
  for line in f:lines() do lines[#lines + 1] = line end
  f:close()
  if #lines == 0 then return nil, "empty CSV" end
  local i = 1
  if lines[1]:sub(1, 13) == "Timecode List" then i = 2 end
  local header = split_csv(lines[i] or "")
  local cols = {}
  for k, name in ipairs(header) do cols[name] = k end
  local si = cols["Start Time (seconds)"]
  local ei = cols["End Time (seconds)"]
  if not si or not ei then
    return nil, "CSV missing Start/End Time (seconds) columns"
  end
  local scenes = {}
  for j = i + 1, #lines do
    local row = split_csv(lines[j])
    local s = tonumber(row[si])
    local e = tonumber(row[ei])
    if s and e then scenes[#scenes + 1] = { s, e } end
  end
  return scenes
end

-- ---- Slice file discovery -----------------------------------------
local function list_files(dir, ext)
  if dir == nil or dir == "" then return {} end
  local entries = utils.readdir(dir, "files")
  if not entries then return {} end
  local out, suffix = {}, "." .. ext
  for _, name in ipairs(entries) do
    if name:sub(-#suffix) == suffix then
      out[#out + 1] = utils.join_path(dir, name)
    end
  end
  table.sort(out)
  return out
end

-- ---- Time formatting ----------------------------------------------
local function fmt_tc(s)
  if not s or s ~= s or s < 0 then s = 0 end
  local t = math.floor(s)
  return string.format("%d:%02d:%02d",
    math.floor(t / 3600), math.floor(t / 60) % 60, t % 60)
end

-- ---- Init ---------------------------------------------------------
local scenes, parse_err = parse_scenes_csv(opts.scenes)
if not scenes then
  msg.error("scene-audit: " .. (parse_err or "cannot parse scenes CSV"))
  return
end
msg.info(string.format("scene-audit: %d scenes from %s", #scenes, opts.scenes))

local mkv = list_files(opts.mkv_dir, "mkv")
local mp4 = list_files(opts.mp4_dir, "mp4")
local compare_enabled = #mkv > 0 and #mp4 > 0
if compare_enabled and (#mkv ~= #scenes or #mp4 ~= #scenes) then
  msg.warn(string.format(
    "count mismatch: scenes=%d mkv=%d mp4=%d — compare may misalign",
    #scenes, #mkv, #mp4))
end

local state = {
  pos = 0,
  duration = 0,
  current = 1,             -- 1-based scene index
  visible = true,
  zoom = true,             -- zoom timeline to a window around current scene
  compare_active = false,
  master_path = nil,
  master_pos = 0,
  pending_master_restore = false,
}

local function update_current()
  if #scenes == 0 then return end
  if state.pos < scenes[1][1] then state.current = 1; return end
  local lo, hi = 1, #scenes
  while lo < hi do
    local mid = lo + math.floor((hi - lo + 1) / 2)
    if scenes[mid][1] <= state.pos then lo = mid else hi = mid - 1 end
  end
  state.current = lo
end

-- ---- ASS drawing --------------------------------------------------
local overlay = mp.create_osd_overlay("ass-events")

local function ass_rect(x1, y1, x2, y2, color, alpha)
  alpha = alpha or "00"
  return string.format(
    "{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%s&}{\\p1}" ..
    "m %d %d l %d %d l %d %d l %d %d{\\p0}",
    color, alpha, x1, y1, x2, y1, x2, y2, x1, y2)
end

local function ass_text(x, y, anchor, size, color, text)
  return string.format(
    "{\\an%d\\pos(%d,%d)\\bord1\\shad0\\fs%d\\1c&H%s&\\3c&H000000&}%s",
    anchor, x, y, size, color, text)
end

-- ASS colors are &HBBGGRR& — these constants are stored in that order.
local C_TRACK       = "555555"
local C_START_OTHER = "508855"  -- muted green: start tick (top half) for non-current scenes
local C_STOP_OTHER  = "555088"  -- muted red:   stop tick  (bot half) for non-current scenes
local C_CUT_IN      = "40C870"  -- bright green: start of current scene
local C_CUT_OUT     = "4060E0"  -- red-orange:   end of current scene
local C_CUR_BAND    = "557766"  -- darker green: shade current scene's span
local C_PLAYHEAD    = "FFFFFF"

local function compute_view()
  if not state.zoom or state.duration <= 0 then
    return 0, math.max(state.duration, 1)
  end
  -- Window size scales with the current scene's duration but is clamped so
  -- extreme scenes don't produce extreme zooms.
  local sc = scenes[state.current]
  local scene_dur = (sc and (sc[2] - sc[1])) or 30
  local window = math.max(12, math.min(120, scene_dur * 2.5))
  -- Anchor on the playhead (left-biased so you see more of what's coming).
  -- This makes the view slide smoothly with continuous playback and never
  -- jump when the playhead crosses a cut.
  local vs = state.pos - window * 0.35
  local ve = state.pos + window * 0.65
  if vs < 0 then ve = ve - vs; vs = 0 end
  if ve > state.duration then
    vs = math.max(0, vs - (ve - state.duration))
    ve = state.duration
  end
  if ve - vs < 1 then ve = vs + 1 end
  return vs, ve
end

local function draw()
  if state.compare_active or not state.visible then
    overlay:remove(); return
  end
  local d = mp.get_property_native("osd-dimensions")
  if not d or (d.w or 0) <= 0 then return end
  -- Draw in a virtual 1080-row canvas: ASS scales it to whatever the real
  -- display is, so a 4K screen automatically gets ~2× crisper text.
  local H = 1080
  local W = math.floor(d.w / d.h * H + 0.5)
  overlay.res_x, overlay.res_y = W, H

  local items = {}
  local function add(s) items[#items + 1] = s end

  local TL_H, TL_PAD = 72, 16
  local TL_TOP = H - TL_H
  local TL_MID = math.floor(TL_TOP + TL_H / 2)
  local KEY_H  = 60   -- extra space above timeline for shortcut legend

  -- Translucent strip behind both shortcuts and timeline.
  add(ass_rect(0, TL_TOP - KEY_H, W, H, "000000", "88"))

  -- Keyboard shortcut legend (two lines, just above the timeline).
  local keys_line1 = "Space play/pause    ←/→ ±1s    ↑/↓ ±5s    Ctrl+←/→ prev/next cut    ,/. frame step    click timeline to seek"
  local keys_line2 = "c compare    Esc exit compare    z toggle zoom    h hide overlay    q quit"
  add(ass_text(TL_PAD, TL_TOP - KEY_H + 8,  7, 18, "DDDDDD", keys_line1))
  add(ass_text(TL_PAD, TL_TOP - KEY_H + 32, 7, 18, "DDDDDD", keys_line2))

  -- Timeline track.
  add(ass_rect(TL_PAD, TL_MID - 2, W - TL_PAD, TL_MID + 2, C_TRACK))

  if state.duration > 0 and #scenes > 0 then
    local vs, ve = compute_view()
    local view_span = ve - vs
    local span = W - 2 * TL_PAD
    local function tx(t)
      local x = TL_PAD + math.floor((t - vs) / view_span * span)
      if x < TL_PAD then x = TL_PAD end
      if x > W - TL_PAD then x = W - TL_PAD end
      return x
    end

    -- Current scene span shaded on the track.
    local sc = scenes[state.current]
    if sc then
      add(ass_rect(tx(sc[1]), TL_MID - 4, tx(sc[2]), TL_MID + 4, C_CUR_BAND))
    end

    -- Cut ticks: starts live in the TOP half (above the track line), stops
    -- live in the BOTTOM half. Each scene boundary is both the stop of one
    -- scene and the start of the next, so we draw two half-height ticks at
    -- the same x — separated visually by which side of the track they sit on.
    local function start_tick(x, color)
      local w = (color == C_CUT_IN) and 1 or 0
      add(ass_rect(x - w, TL_TOP + 3, x + w + 1, TL_MID - 1, color))
    end
    local function stop_tick(x, color)
      local w = (color == C_CUT_OUT) and 1 or 0
      add(ass_rect(x - w, TL_MID + 1, x + w + 1, TL_TOP + TL_H - 3, color))
    end

    for i = 1, #scenes do
      local t = scenes[i][1]
      if t >= vs and t <= ve then
        local x = tx(t)
        -- Top half: start of scene i.
        start_tick(x, (i == state.current) and C_CUT_IN or C_START_OTHER)
        -- Bottom half: stop of scene i-1 (every boundary except t=0 is also a stop).
        if i > 1 then
          stop_tick(x, ((i - 1) == state.current) and C_CUT_OUT or C_STOP_OTHER)
        end
      end
    end
    -- The very last scene's end has no following scene-start, so draw it alone.
    local last_end = scenes[#scenes][2]
    if last_end >= vs and last_end <= ve and last_end > scenes[#scenes][1] then
      stop_tick(tx(last_end),
        (#scenes == state.current) and C_CUT_OUT or C_STOP_OTHER)
    end

    -- Playhead (only if in view; it always should be in zoom mode).
    if state.pos >= vs and state.pos <= ve then
      local x = tx(state.pos)
      add(ass_rect(x - 1, TL_TOP + 2, x + 2, TL_TOP + TL_H - 2, C_PLAYHEAD))
    end

    -- View-range labels at strip edges when zoomed.
    if state.zoom then
      add(ass_text(TL_PAD,     TL_TOP + TL_H - 20, 7, 16, "AAAAAA", fmt_tc(vs)))
      add(ass_text(W - TL_PAD, TL_TOP + TL_H - 20, 9, 16, "AAAAAA", fmt_tc(ve)))
    end
  end

  -- Timecode + current scene info (top-left).
  local info = string.format("%s / %s", fmt_tc(state.pos), fmt_tc(state.duration))
  local sc = scenes[state.current]
  if sc then
    info = info .. string.format("\\Nscene %d/%d  %s – %s  (%.1fs)",
      state.current, #scenes, fmt_tc(sc[1]), fmt_tc(sc[2]), sc[2] - sc[1])
    if compare_enabled then
      info = info .. "  [c to compare]"
    end
  end
  add(ass_text(28, 28, 7, 28, "FFFFFF", info))

  -- Surrounding scenes (top-right).
  local lines = {}
  for offset = -3, 3 do
    local idx = state.current + offset
    local s = scenes[idx]
    if s then
      local marker = (offset == 0) and "▶" or " "
      lines[#lines + 1] = string.format("%s scene %3d  %s – %s  (%.0fs)",
        marker, idx, fmt_tc(s[1]), fmt_tc(s[2]), s[2] - s[1])
    end
  end
  if #lines > 0 then
    add(ass_text(W - 28, 28, 9, 22, "EEEEEE", table.concat(lines, "\\N")))
  end

  overlay.data = table.concat(items, "\n")
  overlay:update()
end

-- ---- Periodic redraw (10 Hz is plenty for a playhead) -------------
mp.add_periodic_timer(0.1, function()
  local p = mp.get_property_number("time-pos")
  if p then state.pos = p; update_current() end
  draw()
end)

mp.observe_property("duration", "number", function(_, v)
  if v then state.duration = v; draw() end
end)
mp.observe_property("osd-dimensions", "native", function() draw() end)

-- ---- File-loaded: capture master path, finish compare-exit --------
mp.register_event("file-loaded", function()
  if not state.master_path then
    state.master_path = mp.get_property("path")
    msg.info("master = " .. tostring(state.master_path))
  end
  if state.pending_master_restore then
    state.pending_master_restore = false
    mp.commandv("seek", state.master_pos, "absolute", "exact")
    mp.set_property_bool("pause", true)
  end
end)

-- ---- Navigation ---------------------------------------------------
local function seek_to(s)
  mp.commandv("seek", s, "absolute", "exact")
end

local function jump_cut(direction)
  if state.compare_active or #scenes == 0 then return end
  if direction > 0 then
    for i = 1, #scenes do
      if scenes[i][1] > state.pos + 0.01 then seek_to(scenes[i][1]); return end
    end
  else
    local target = 0
    for i = #scenes, 1, -1 do
      if scenes[i][1] < state.pos - 0.5 then target = scenes[i][1]; break end
    end
    seek_to(target)
  end
end

-- ---- Compare mode -------------------------------------------------
local function enter_compare()
  if state.compare_active then return end
  if not compare_enabled then
    mp.osd_message("compare needs --mkv-dir and --mp4-dir", 2)
    return
  end
  local idx = state.current
  if idx < 1 or idx > math.min(#mkv, #mp4) then
    mp.osd_message("no slice for scene " .. idx, 2)
    return
  end
  state.master_pos = state.pos
  state.compare_active = true
  overlay:remove()
  mp.set_property_native("external-files", { mp4[idx] })
  mp.set_property("lavfi-complex", "[vid1] [vid2] hstack [vo]")
  mp.set_property("aid", "1")
  mp.commandv("loadfile", mkv[idx], "replace")
  mp.set_property_bool("pause", false)
  mp.osd_message("compare scene " .. idx, 1.5)
end

local function exit_compare()
  if not state.compare_active then return end
  state.compare_active = false
  mp.set_property("lavfi-complex", "")
  mp.set_property_native("external-files", {})
  state.pending_master_restore = true
  mp.commandv("loadfile", state.master_path, "replace")
end

-- ---- Mouse: click the timeline strip to seek ----------------------
local function on_click()
  if state.compare_active or not state.visible or state.duration <= 0 then
    return
  end
  local p = mp.get_property_native("mouse-pos")
  local d = mp.get_property_native("osd-dimensions")
  if not p or not d or d.w == 0 or d.h == 0 then return end
  -- mouse-pos is in real pixels; the overlay is drawn in a virtual
  -- 1080-row canvas. Convert the click into virtual coords so the
  -- hit-test against the timeline geometry matches draw().
  local H_v = 1080
  local W_v = math.floor(d.w / d.h * H_v + 0.5)
  local x_v = p.x * W_v / d.w
  local y_v = p.y * H_v / d.h
  local TL_H, TL_PAD = 72, 16
  local TL_TOP = H_v - TL_H
  if y_v < TL_TOP - 4 then return end
  local span = W_v - 2 * TL_PAD
  if span <= 0 then return end
  -- When zoomed, map the click into the current view range rather than
  -- the whole master, so clicking the visible bar lands where you'd expect.
  local vs, ve
  if state.zoom and scenes[state.current] then
    local sc = scenes[state.current]
    local scene_dur = sc[2] - sc[1]
    local window = math.max(12, math.min(120, scene_dur * 2.5))
    vs = state.pos - window * 0.35
    ve = state.pos + window * 0.65
    if vs < 0 then ve = ve - vs; vs = 0 end
    if ve > state.duration then
      vs = math.max(0, vs - (ve - state.duration)); ve = state.duration
    end
  else
    vs, ve = 0, state.duration
  end
  local t = vs + (x_v - TL_PAD) / span * (ve - vs)
  if t < 0 then t = 0 end
  if t > state.duration then t = state.duration end
  seek_to(t)
end

-- ---- Key bindings -------------------------------------------------
local function seek_rel(dt) mp.commandv("seek", dt, "relative", "exact") end

-- Primary nav: arrows for seek, Ctrl+arrows for cut jumps.
mp.add_forced_key_binding("LEFT",       "audit-back-1s",   function() seek_rel(-1) end)
mp.add_forced_key_binding("RIGHT",      "audit-fwd-1s",    function() seek_rel( 1) end)
mp.add_forced_key_binding("UP",         "audit-back-5s",   function() seek_rel(-5) end)
mp.add_forced_key_binding("DOWN",       "audit-fwd-5s",    function() seek_rel( 5) end)
mp.add_forced_key_binding("ctrl+LEFT",  "audit-prev-cut-arr", function() jump_cut(-1) end)
mp.add_forced_key_binding("ctrl+RIGHT", "audit-next-cut-arr", function() jump_cut( 1) end)

-- Legacy / muscle-memory aliases.
mp.add_forced_key_binding("[",         "audit-back-1s-alt", function() seek_rel(-1) end)
mp.add_forced_key_binding("]",         "audit-fwd-1s-alt",  function() seek_rel( 1) end)
mp.add_forced_key_binding("PGUP",      "audit-prev-cut",    function() jump_cut(-1) end)
mp.add_forced_key_binding("PGDWN",     "audit-next-cut",    function() jump_cut( 1) end)
mp.add_forced_key_binding("c",         "audit-compare",   enter_compare)
mp.add_forced_key_binding("ESC",       "audit-exit-cmp",  function() if state.compare_active then exit_compare() end end)
mp.add_forced_key_binding("h",         "audit-toggle-ui", function() state.visible = not state.visible; draw() end)
mp.add_forced_key_binding("z",         "audit-toggle-zoom", function() state.zoom = not state.zoom; draw() end)
mp.add_forced_key_binding("MBTN_LEFT", "audit-click",     on_click)

msg.info("scene-audit loaded — c=compare  Esc=exit  PgUp/PgDn=cut  z=zoom  h=hide UI")
