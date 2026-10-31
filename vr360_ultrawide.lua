-- vr360_ultrawide.lua
-- mpv script: fill an ultrawide monitor (default 3840x1080, 32:9)
-- with 360 videos instead of showing the 16:9 flattened sphere between black
-- pillarbox bars. Nothing is re-encoded.
--
-- Two source formats are handled:
--   equirect  one 2:1 panorama, tagged "Spherical Mapping: equirectangular"
--   eac       YouTube's equi-angular cubemap: six cube faces in a 3x2 grid
--             ("split screen"), tagged in the WebM as Matroska ProjectionType 3
--             (mesh), which ffmpeg ignores.
--             Unfolded live to a 3840x1920 panorama with v360 (CPU, linear interp:
--             cubic only reached ~0.8x real time in mpv), then the same modes apply.
--
-- Modes (Alt+m cycles):
--   trim     (default) cut off the bottom 22.7% (the ground below the camera,
--            where tripods, selfie sticks and channel logo patches sit), then
--            stretch the rest to the screen's aspect. vr360-trim=0 keeps it all.
--   stretch  whole frame stretched to the screen's aspect, logo patch included.
--   band     no stretching: a 1:1 pixel crop of the full 360 degrees around,
--            +-45 deg up/down. Alt+UP/DOWN moves the band.
--   view     v360 cylindrical reprojection (CPU, upscales a smaller part of the
--            sphere; softer). Alt+LEFT/RIGHT turn, Alt+UP/DOWN tilt, Alt+=/- FOV.
--
-- Untagged files play normally, so this can stay loaded for mixed playlists.
-- Other keys: Alt+0 reset   Alt+v off/on   Alt+f force equirect   Alt+c force cubemap
-- Options (--script-opts=vr360-mode=band,vr360-w=5120,vr360-h=1440,...):
--   mode, w, h (screen size), trim (fraction cut from bottom), hfov, pitch, interp

local mp = require 'mp'
local msg = require 'mp.msg'
local options = require 'mp.options'

local o = { mode = 'trim', w = 3840, h = 1080, trim = 0.227,
            hfov = 240, pitch = 0, interp = 'cubic' }
options.read_options(o, 'vr360')

local MODES = { 'trim', 'stretch', 'band', 'view' }
local LABEL = 'vr360'
local UNFOLD_W, UNFOLD_H, UNFOLD_INTERP = 3840, 1920, 'linear'
local HFOV_MIN, HFOV_MAX = 90, 360
local state = { on = false, src = 'e', mode = o.mode, yaw = 0, pitch = o.pitch,
                hfov = o.hfov, band_shift = 0, vf = false }

-- Size of the frames the VO crops/scales: the unfolded panorama for a cubemap.
local function video_size()
    if state.src == 'eac' then return UNFOLD_W, UNFOLD_H end
    return mp.get_property_number('current-tracks/video/demux-w'),
           mp.get_property_number('current-tracks/video/demux-h')
end

-- Vertical FOV that keeps pixels square for a cylindrical output:
-- x spans hfov (radians) and y spans 2*tan(vfov/2), at a w:h aspect.
local fit  -- defined below; apply_mode and the reconfig observer share it

local function vfov_for(hfov)
    local half = (o.h / o.w) * math.rad(hfov) / 2
    return math.deg(2 * math.atan(half))
end

local function view_filter()
    return string.format(
        'v360=input=%s:output=cylindrical:w=%d:h=%d:h_fov=%.2f:v_fov=%.2f:yaw=%.2f:pitch=%.2f:interp=%s',
        state.src, o.w, o.h, state.hfov, vfov_for(state.hfov), state.yaw, state.pitch, o.interp)
end

local function unfold_filter()
    return string.format('v360=input=eac:output=e:w=%d:h=%d:interp=%s',
        UNFOLD_W, UNFOLD_H, UNFOLD_INTERP)
end

-- Install (or with nil, remove) our v360 filter. v360 needs frames in RAM;
-- 360 files are already on software decoding (see on_preloaded).
local function set_vf(graph)
    if state.vf then
        mp.command('vf remove @' .. LABEL)
        state.vf = false
    end
    if graph then
        mp.commandv('vf', 'add', '@' .. LABEL .. ':lavfi=[' .. graph .. ']')
        state.vf = true
    end
end

local function clear()
    set_vf(nil)
    mp.set_property('video-crop', '')
    mp.set_property('video-aspect-override', '-1')
end

local function set_if_changed(prop, value)
    if mp.get_property(prop) ~= value then mp.set_property(prop, value) end
end

-- Crop and aspect for trim/stretch/band. The aspect override is applied to the
-- decoded frame (before our v360 unfold) and the crop to the frame the VO gets,
-- so scale the override by shown/decoded size to land exactly on the screen's
-- aspect with no bars. Returns the crop height and y offset.
fit = function()
    local vw, vh = video_size()
    local dw = mp.get_property_number('current-tracks/video/demux-w')
    local dh = mp.get_property_number('current-tracks/video/demux-h')
    if not (vw and vh and dw and dh) then return 0, 0 end
    local ch, y = vh, 0
    if state.mode == 'trim' then
        ch = math.floor(vh * (1 - o.trim) / 2) * 2
    elseif state.mode == 'band' then
        ch = math.min(vh, math.floor(vw * o.h / o.w / 2) * 2)
        local max_shift = (vh - ch) / 2
        state.band_shift = math.max(-max_shift, math.min(max_shift, state.band_shift))
        y = math.floor((vh - ch) / 2 - state.band_shift)
    end
    if state.mode == 'band' then
        set_if_changed('video-aspect-override', '-1.000000')
    else
        set_if_changed('video-aspect-override',
            string.format('%.6f', o.w / o.h * (ch / dh) * (dw / vw)))
    end
    set_if_changed('video-crop', ch == vh and '' or string.format('%dx%d+0+%d', vw, ch, y))
    return ch, y
end

local function apply_mode()
    local tag = state.src == 'eac' and '360 cubemap' or '360'
    if state.mode == 'view' then
        mp.set_property('video-crop', '')
        mp.set_property('video-aspect-override', '-1')
        set_vf(view_filter())
        mp.osd_message(string.format('%s: view  yaw %+.0f  pitch %+.0f  fov %.0fx%.0f',
            tag, state.yaw, state.pitch, state.hfov, vfov_for(state.hfov)), 2)
        return
    end
    set_vf(state.src == 'eac' and unfold_filter() or nil)
    local _, vh = video_size()
    local crop_h, crop_y = fit()
    if state.mode == 'stretch' then
        mp.osd_message(tag .. ': stretch (whole frame)', 2)
    elseif state.mode == 'trim' then
        mp.osd_message(string.format('%s: trim (bottom %.1f%% cut, stretched)', tag, o.trim * 100), 2)
    else  -- band
        local deg_per_row = 180 / vh
        mp.osd_message(string.format('%s: band (no stretch)  %+.0f to %+.0f deg',
            tag, 90 - (crop_y + crop_h) * deg_per_row, 90 - crop_y * deg_per_row), 2)
    end
end

local function enable(src)
    state.on, state.src = true, src or state.src
    apply_mode()
end

local function disable()
    if not state.on then return end
    clear()
    state.on = false
    mp.osd_message('360 off', 2)
end

local function cycle_mode()
    if not state.on then return end
    for i, m in ipairs(MODES) do
        if m == state.mode then state.mode = MODES[i % #MODES + 1]; break end
    end
    apply_mode()
end

-- View-mode rotation: v360's yaw/pitch runtime commands are relative and
-- accumulate (in the rotated frame, so pitch then yaw would tilt the horizon),
-- so a turn rebuilds the filter with absolute angles instead.
local function turn(dyaw)
    if not state.on or state.mode ~= 'view' then return end
    state.yaw = (state.yaw + dyaw + 180) % 360 - 180
    apply_mode()
end

local function tilt(step)
    if not state.on then return end
    if state.mode == 'band' then
        local _, vh = video_size()
        state.band_shift = state.band_shift + step * vh / 180  -- step in degrees
        apply_mode()
    elseif state.mode == 'view' then
        state.pitch = math.max(-60, math.min(60, state.pitch + step))
        apply_mode()
    end
end

-- View-mode FOV: absolute runtime commands, no filter rebuild; fall back to a
-- rebuild if this libavfilter rejects a command.
local function zoom(step)
    if not state.on or state.mode ~= 'view' then return end
    state.hfov = math.max(HFOV_MIN, math.min(HFOV_MAX, state.hfov + step))
    for _, c in ipairs({ { 'h_fov', state.hfov }, { 'v_fov', vfov_for(state.hfov) } }) do
        -- target 'v360' so the auto-inserted scaler doesn't reject the command
        if not mp.commandv('vf-command', LABEL, c[1], string.format('%.2f', c[2]), 'v360') then
            msg.warn('vf-command ' .. c[1] .. ' failed; rebuilding filter')
            apply_mode()
            return
        end
    end
    mp.osd_message(string.format('360: view  fov %.0fx%.0f', state.hfov, vfov_for(state.hfov)), 2)
end

local function is_equirect(path)
    local r = mp.command_native({
        name = 'subprocess', capture_stdout = true, playback_only = false,
        -- plain -show_streams: older ffprobe builds lack the stream_side_data section
        args = { 'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_streams', path },
    })
    if r.status ~= 0 then
        msg.warn('ffprobe failed (status ' .. tostring(r.status) .. ') for ' .. path)
        return false
    end
    return r.stdout:find('projection=equirectangular', 1, true) ~= nil
end

-- YouTube cubemap WebMs carry, in the track header, a Matroska Projection
-- element (ID 0x7670, then its size as a 1-8 byte EBML vint) whose first child
-- is ProjectionType (ID 0x7671, size 0x81) = 3 (mesh). The bare child bytes
-- also turn up by chance in compressed video, so require the parent ID right
-- before it and only search the header area.
local function is_youtube_cubemap(path)
    local f = io.open(path, 'rb')
    if not f then return false end
    local head = f:read(64 * 1024) or ''
    f:close()
    local start = 1
    while true do
        local i = head:find('\118\113\129\3', start, true)  -- 0x76 0x71 0x81 0x03
        if not i then return false end
        for len = 1, 8 do
            local p = i - len - 2
            if p >= 1 and head:sub(p, p + 1) == '\118\112' then  -- 0x76 0x70
                -- EBML vint: the leading 1 bit of the first size byte gives its length
                local first = head:byte(p + 2)
                if first >= 2 ^ (8 - len) and first < 2 ^ (9 - len) then return true end
            end
        end
        start = i + 1
    end
end

-- Detect before decoders are created, so every 360 file starts, and stays, on
-- software decoding (file-local: the next file gets the user's hwdec back).
-- Never switch hwdec while playing: in testing (mpv 0.37, NVIDIA 580), nvdec
-- frames handed to vo=gpu-next hit an NVIDIA MMU fault (Xid 31) at a mode switch
-- and hung mpv; nvdec-copy + v360 stalled (5.1 s of video per 60 s). Software
-- decoding kept real time on a 32-thread CPU: 4K VP9 6x, 8K AV1 3.4x.
local detected = nil
mp.add_hook('on_preloaded', 50, function()
    local path = mp.get_property('path')
    detected = nil
    if path and is_equirect(path) then
        detected = 'e'
    elseif path and is_youtube_cubemap(path) then
        detected = 'eac'
    end
    if detected then mp.set_property('file-local-options/hwdec', 'no') end
end)

-- Alt+f / Alt+c on an untagged file: the decoder is already running, so this
-- is the one place hwdec changes mid-file.
local function force(src)
    if mp.get_property('hwdec-current', 'no') ~= 'no' then
        mp.set_property('file-local-options/hwdec', 'no')
    end
    enable(src)
end

mp.register_event('file-loaded', function()
    local path = mp.get_property('path')
    state.yaw, state.pitch, state.hfov, state.band_shift = 0, o.pitch, o.hfov, 0
    if detected == 'e' then
        msg.info('equirectangular 360 video detected: ' .. path)
        enable('e')
    elseif detected == 'eac' then
        msg.info('YouTube cubemap (EAC) 360 video detected: ' .. path)
        enable('eac')
    else
        disable()
    end
end)

-- Filter rebuilds and hwdec changes reconfigure the video; re-apply the crop,
-- which mpv drops while it does not fit the frame being shown.
mp.observe_property('video-out-params', 'native', function(_, p)
    if p and state.on and state.mode ~= 'view' then fit() end
end)

local function bind(key, name, fn, repeatable)
    mp.add_forced_key_binding(key, name, fn, repeatable and { repeatable = true } or nil)
end

bind('Alt+m', 'vr360-mode', cycle_mode)
bind('Alt+LEFT', 'vr360-yaw-left', function() turn(-15) end, true)
bind('Alt+RIGHT', 'vr360-yaw-right', function() turn(15) end, true)
bind('Alt+Shift+LEFT', 'vr360-yaw-left-big', function() turn(-90) end, true)
bind('Alt+Shift+RIGHT', 'vr360-yaw-right-big', function() turn(90) end, true)
bind('Alt+UP', 'vr360-tilt-up', function() tilt(5) end, true)
bind('Alt+DOWN', 'vr360-tilt-down', function() tilt(-5) end, true)
bind('Alt+=', 'vr360-fov-wider', function() zoom(20) end, true)
bind('Alt+-', 'vr360-fov-narrower', function() zoom(-20) end, true)
bind('Alt+0', 'vr360-reset', function()
    state.yaw, state.pitch, state.hfov, state.band_shift = 0, o.pitch, o.hfov, 0
    if state.on then apply_mode() end
end)
bind('Alt+v', 'vr360-toggle', function() if state.on then disable() else enable() end end)
bind('Alt+f', 'vr360-force', function() force('e') end)
bind('Alt+c', 'vr360-force-cubemap', function() force('eac') end)
