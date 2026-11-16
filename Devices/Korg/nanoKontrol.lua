-----------------------------------------------------------------------------------------------
-- nanoKontrol.lua
-- Korg NanoKONTROL Mk1 - fixed-position track volume, pan, solo/cue, mute and transport mapping
-- (solo "property" mode only has an effect while the Force's SOLO button is in "solo tracks" mode)
-----------------------------------------------------------------------------------------------

local midiChannel = 0;
local faderCCStart = 2;
local faderCCEnd = 10;
local knobCCStart = 11;
local knobCCEnd = 19;
local soloCCStart = 29;
local soloCCEnd = 37;
local muteCCStart = 20;
local muteCCEnd = 28;

-- Single buttons: all momentary, they act on press only (value > 0).
local toStartCC = 38;
local playCC = 39;
local redoCC = 40;
local arrangeCC = 41;
local stopAllCC = 42;
local samplerCC = 43;
local extraCCs = { toStartCC, playCC, redoCC, arrangeCC, stopAllCC, samplerCC };
local isExtraCC = {};
for _, c in ipairs(extraCCs) do
    isExtraCC[c] = true;
end

-- Engine mode names tried, in order, to open the sampler / arrange view (names are not
-- documented; the log shows the real ones). A request counts as done when the current mode
-- name contains the "needle" text.
local samplerModeNames = { "Sampler", "Sample", "Sample Edit" };
-- CC41 cycles through the arranger tabs in this order: Arranger, Grid, Clip, List, then
-- back to Arranger. If the current mode is not one of them, the first press enters the
-- Arranger. Each view is requested by trying its names in order (the real names are not
-- documented; every request is logged with the resulting CurrentMode). "needle" is the
-- text the mode name must contain for the request to count as done.
local arrangeViews = {
    { label = "arranger", needle = "arrang", names = { "Arrange", "Arranger", "Arrangement", "Song" } },
    { label = "grid", needle = "grid", names = { "Grid", "Grid View", "Grid Editor", "Arranger Grid" } },
    { label = "clip", needle = "clip", names = { "Clip Editor", "Clip", "Clip View", "Arranger Clip" } },
    { label = "list", needle = "list", names = { "List Edit", "List", "List View", "Arranger List" } },
};

-- Set to true to log the API objects at load time while looking for a CUE control.
-- Read with: journalctl -u acvs -o cat --no-pager | grep NanoKontrol
local enableProbes = false;

-- Optional: a spare nanoKONTROL button CC. Each press dumps track[0]'s state again,
-- so you can toggle CUE by hand on the Force and compare before/after. nil = off.
local probeCC = nil;

-- Solo/cue buttons: "property" drives track.Solo (works with the Force SOLO button in
-- "solo tracks" mode). "emulate" presses the Force's own buttons instead (experimental,
-- meant for "CUE tracks" mode): SOLO, then the lower-row button of that track.
local soloMode = "emulate";
-- Name prefix of the Force button row to press in "emulate" mode: "trackAssign" or "trackSelect".
local cueButtonPrefix = "trackAssign";
-- Lower-row mode to switch back to after each cue press ("recArm", "mute", "clipStop"),
-- or nil to leave the Force in solo/cue mode. The script cannot read the Force's current
-- mode, so this is a fixed choice: set it to the mode you normally work in.
local restoreMode = "recArm";

-- Mute buttons: "property" toggles track.Mute directly (the Force's lower-row mode is not
-- touched, so it stays in Rec Arm). "emulate" presses the Force's MUTE button, then the
-- track's lower-row button, then restoreMode - use it if "property" has no effect.
local muteMode = "property";

-- Logs mpc.tracks.GetTrackMonitorState(0..7) on every nanoKONTROL solo message, to see
-- whether it follows the Force's CUE state (toggle CUE by hand on the Force, then press
-- any nanoKONTROL solo button and compare the logged values).
local logMonitor = false;

local isLoaded = false;

local function clamp(value, minValue, maxValue)
    if value < minValue then
        return minValue;
    end
    if value > maxValue then
        return maxValue;
    end
    return value;
end

local function getTrackAtSlot(slotIndex)
    if slotIndex < 0 or slotIndex >= mpc.tracks.normalTracks.Count.value then
        return nil;
    end

    return mpc.tracks.normalTracks[slotIndex];
end

local function handleFader(cc, value)
    local slotIndex = cc - faderCCStart;
    local track = getTrackAtSlot(slotIndex);

    if track == nil then
        return;
    end

    -- NanoKONTROL faders are 0..127. MPC track volume is normalized 0..1.
    track.Volume.value = clamp(value / 127.0, 0.0, 1.0);
end

local function handleKnob(cc, value)
    local slotIndex = cc - knobCCStart;
    local track = getTrackAtSlot(slotIndex);

    if track == nil then
        return;
    end

    -- MPC track pan is 0..1, with 0.5 as the centre position.
    track.Pan.value = clamp(value / 127.0, 0.0, 1.0);
end

local function pressForce(name)
    local b = mpc.force and mpc.force[name];
    if b == nil or b.Press == nil or b.Release == nil then
        print("NanoKontrol: force." .. tostring(name) .. " missing");
        return;
    end

    local ok1, e1 = pcall(b.Press);
    local ok2, e2 = pcall(b.Release);
    print("NanoKontrol: force." .. name .. " press=" .. tostring(ok1) ..
        " release=" .. tostring(ok2) .. " " .. tostring(e1) .. " " .. tostring(e2));
end

local function logMonitorStates(label)
    local fn = mpc.tracks.GetTrackMonitorState;
    print("NanoKontrol: monitor " .. label .. " fn type=" .. type(fn));

    -- Try the call forms for track 0 and 1 and log ok / type / value for each.
    for i = 0, 1 do
        local forms = {
            { "(self,i)", function() return fn(mpc.tracks, i); end },
            { "(i)", function() return fn(i); end },
            { "(i+1)", function() return fn(i + 1); end },
        };
        for _, f in ipairs(forms) do
            local ok, r = pcall(f[2]);
            print("NanoKontrol: monitor track=" .. i .. " form=" .. f[1] .. " ok=" .. tostring(ok) ..
                " type=" .. type(r) .. " value=" .. tostring(r));
        end
    end
end

local function handleMute(cc, value)
    local slotIndex = cc - muteCCStart;
    local track = getTrackAtSlot(slotIndex);

    if track == nil then
        return;
    end

    if muteMode == "emulate" then
        -- Every message (127 or 0) is one toggle, like one press on the Force.
        pressForce("mute");
        pressForce(cueButtonPrefix .. (slotIndex + 1));
        if restoreMode ~= nil then
            pressForce(restoreMode);
        end
        return;
    end

    -- One toggle per message, so the track still toggles correctly if its mute state was
    -- changed by hand on the Force and the button's own on/off state is out of step.
    local ok, err = pcall(track.SetMute, not track.Mute.value);
    if not ok then
        print("NanoKontrol: SetMute failed: " .. tostring(err));
    end
end

local function handleSolo(cc, value)
    local slotIndex = cc - soloCCStart;
    local track = getTrackAtSlot(slotIndex);

    if logMonitor then
        logMonitorStates("cc=" .. tostring(cc) .. " value=" .. tostring(value));
    end

    if track == nil then
        return;
    end

    if soloMode == "emulate" then
        -- Every message (127 or 0) is one toggle, like one press on the Force.
        pressForce("solo");
        pressForce(cueButtonPrefix .. (slotIndex + 1));
        if restoreMode ~= nil then
            pressForce(restoreMode);
        end
        return;
    end

    -- Buttons are set to toggle in the Kontrol Editor: 127 = on, 0 = off.
    local ok, err = pcall(track.SetSolo, value > 0);
    if not ok then
        print("NanoKontrol: SetSolo failed: " .. tostring(err));
    end
end

----------------------------- CUE PROBES (diagnostic) -----------------------------

-- One log line per member, so journalctl does not wrap long lists.
local function logMembers(name, obj)
    if type(obj) ~= "table" then
        print("NanoKontrol: members " .. name .. " = " .. type(obj));
        return;
    end

    local names = {};
    for k, v in pairs(obj) do
        names[#names + 1] = tostring(k) .. "=" .. type(v);
    end
    table.sort(names);

    print("NanoKontrol: members " .. name .. " (" .. #names .. ")");
    for _, n in ipairs(names) do
        print("NanoKontrol:   " .. name .. "." .. n);
    end
end

local function logTrackState(label)
    local track = mpc.tracks and mpc.tracks.normalTracks and mpc.tracks.normalTracks[0];
    if track == nil or track.GetState == nil then
        print("NanoKontrol: " .. label .. " track[0].GetState unavailable");
        return;
    end

    local ok, state = pcall(track.GetState, track);
    if not ok then
        -- some objects may expect the call without self
        ok, state = pcall(track.GetState);
    end

    if type(state) == "table" then
        local keys = {};
        for k, v in pairs(state) do
            keys[#keys + 1] = tostring(k) .. "=" .. tostring(v);
        end
        table.sort(keys);
        print("NanoKontrol: " .. label .. " track[0] state (table, " .. #keys .. " entries)");
        for _, e in ipairs(keys) do
            print("NanoKontrol:   " .. e);
        end
    else
        print("NanoKontrol: " .. label .. " track[0] state ok=" .. tostring(ok) .. " " .. tostring(state));
    end
end

-- Walk the whole API tree and report names that look cue / monitor related.
local function findNames(root, rootName, patterns, maxDepth)
    local seen, hits = {}, {};

    local function walk(o, path, depth)
        if type(o) ~= "table" or seen[o] or depth > maxDepth then
            return;
        end
        seen[o] = true;

        for k, v in pairs(o) do
            local name = tostring(k);
            local lower = string.lower(name);
            for _, p in ipairs(patterns) do
                if string.find(lower, p, 1, true) then
                    hits[#hits + 1] = path .. "." .. name .. " (" .. type(v) .. ")";
                    break;
                end
            end
            walk(v, path .. "." .. name, depth + 1);
        end
    end

    walk(root, rootName, 0);
    return hits;
end

local function runProbes()
    print("NanoKontrol: ---- cue probes start ----");

    logMembers("force", mpc.force);
    logMembers("force.solo", mpc.force and mpc.force.solo);
    logMembers("controlSurface.solo", mpc.controlSurface and mpc.controlSurface.solo);
    logMembers("tracks", mpc.tracks);

    local hits = findNames(mpc, "mpc",
        { "cue", "pfl", "monitor", "listen", "headphone", "prelisten" }, 5);
    print("NanoKontrol: name search found " .. #hits .. " hits");
    for i = 1, math.min(#hits, 80) do
        print("NanoKontrol: hit " .. hits[i]);
    end

    local ok, h = pcall(mpc.tracks.Help, mpc.tracks);
    print("NanoKontrol: tracks.Help ok=" .. tostring(ok) .. " " .. tostring(h));

    logTrackState("load");

    -- Report changes made by hand on the Force (SOLO / CUE button), if the property notifies.
    local t0 = mpc.tracks.normalTracks[0];
    if t0 ~= nil and t0.Solo ~= nil and t0.Solo.listen ~= nil then
        local okl, errl = pcall(t0.Solo.listen, t0.Solo, function(...)
            print("NanoKontrol: track[0].Solo changed -> " .. tostring((...)));
        end, "nanoKontrol");
        print("NanoKontrol: Solo listener ok=" .. tostring(okl) .. " " .. tostring(errl));
    end

    print("NanoKontrol: ---- cue probes end ----");
end

----------------------------- SINGLE BUTTONS -----------------------------

local function callSafe(label, fn, ...)
    local ok, err = pcall(fn, ...);
    if not ok then
        print("NanoKontrol: " .. label .. " failed: " .. tostring(err));
    end
    return ok;
end

local function doublePressForce(name)
    local b = mpc.force and mpc.force[name];
    if b == nil or b.DoublePress == nil then
        print("NanoKontrol: force." .. tostring(name) .. ".DoublePress missing");
        return;
    end

    local ok, err = pcall(b.DoublePress);
    print("NanoKontrol: force." .. name .. " DoublePress ok=" .. tostring(ok) .. " " .. tostring(err));
end

local function requestMode(label, names, needle, stopOnChange)
    local em = mpc.engineMode;
    if em == nil or em.RequestModeChange == nil then
        print("NanoKontrol: engineMode.RequestModeChange unavailable");
        return;
    end

    -- Log the real mode names so the name lists can be corrected if none of them works.
    local okm, modes = pcall(em.GetAvailableModes);
    if okm and type(modes) == "table" then
        local m = {};
        for _, v in pairs(modes) do
            m[#m + 1] = tostring(v);
        end
        print("NanoKontrol: available modes " .. table.concat(m, ","));
    end

    local cm = em.CurrentMode;
    local before = cm and tostring(cm.value) or "?";
    for _, name in ipairs(names) do
        pcall(em.RequestModeChange, name);
        local current = cm and tostring(cm.value) or "?";
        print("NanoKontrol: " .. label .. " mode request '" .. name .. "' -> CurrentMode " .. current);
        if stopOnChange then
            -- done as soon as the mode changed at all (the new mode's name may differ
            -- from the requested one)
            if current ~= before then
                break;
            end
        elseif string.find(string.lower(current), needle, 1, true) then
            break;
        end
    end
end

local function currentModeName()
    local cm = mpc.engineMode and mpc.engineMode.CurrentMode;
    return cm and tostring(cm.value) or "";
end

local function handleArrange()
    local current = string.lower(currentModeName());

    -- Which view are we in? First an exact match against the known mode names, then
    -- (as a fallback) a name that contains the view's keyword. The matrix / clip-launch
    -- modes are never treated as an arranger view, even if their names contain "clip".
    local currentIndex = nil;
    for i, v in ipairs(arrangeViews) do
        for _, n in ipairs(v.names) do
            if current == string.lower(n) then
                currentIndex = i;
                break;
            end
        end
        if currentIndex then
            break;
        end
    end

    if currentIndex == nil and not string.find(current, "matrix", 1, true) then
        for _, i in ipairs({ 2, 3, 4, 1 }) do
            if string.find(current, arrangeViews[i].needle, 1, true) then
                currentIndex = i;
                break;
            end
        end
    end

    local nextIndex = currentIndex and ((currentIndex % #arrangeViews) + 1) or 1;
    local view = arrangeViews[nextIndex];
    print("NanoKontrol: arrange -> " .. view.label .. " (mode was '" .. currentModeName() .. "')");
    requestMode("arrange " .. view.label, view.names, view.needle, true);
end

local function handleExtra(cc, value)
    if value <= 0 then
        return;     -- momentary buttons: act on press only
    end

    if cc == playCC then
        -- Play only: never stops a running sequencer.
        if not mpc.sequencer.Playing.value then
            callSafe("TogglePlay", mpc.sequencer.TogglePlay);
        end
    elseif cc == stopAllCC then
        doublePressForce("stop");
    elseif cc == toStartCC then
        callSafe("JumpToPulse(0)", mpc.sequencer.JumpToPulse, 0);
    elseif cc == redoCC then
        callSafe("Redo", mpc.commandManager.Redo);
    elseif cc == arrangeCC then
        handleArrange();
    elseif cc == samplerCC then
        requestMode("sampler", samplerModeNames, "sampl");
    end
end

--------------------------- REQUIRED FUNCTIONS -------------------------
---------------------------- Called from C++ ---------------------------

function nanoKontrol.HandleMIDINoteOn(channel, note, velocity) end

function nanoKontrol.HandleMIDINoteOff(channel, note, velocity) end

function nanoKontrol.HandleMIDISysex(sysexChars) end

function nanoKontrol.HandleTimer() end

function nanoKontrol.HandleMIDICC(channel, cc, value)
    if channel ~= midiChannel then
        return;
    end

    if cc >= faderCCStart and cc <= faderCCEnd then
        handleFader(cc, value);
    elseif cc >= knobCCStart and cc <= knobCCEnd then
        handleKnob(cc, value);
    elseif cc >= soloCCStart and cc <= soloCCEnd then
        handleSolo(cc, value);
    elseif cc >= muteCCStart and cc <= muteCCEnd then
        handleMute(cc, value);
    elseif isExtraCC[cc] then
        handleExtra(cc, value);
    elseif probeCC ~= nil and cc == probeCC and value > 0 then
        logTrackState("manual");
    end
end

function nanoKontrol.OnLoad()
    if isLoaded then
        return;
    end
    isLoaded = true;

    for i = faderCCStart, faderCCEnd do
        nanoKontrol.mappings.script.AddCCToScript(midiChannel, i);
    end

    for i = knobCCStart, knobCCEnd do
        nanoKontrol.mappings.script.AddCCToScript(midiChannel, i);
    end

    for i = soloCCStart, soloCCEnd do
        nanoKontrol.mappings.script.AddCCToScript(midiChannel, i);
    end

    for i = muteCCStart, muteCCEnd do
        nanoKontrol.mappings.script.AddCCToScript(midiChannel, i);
    end

    for _, c in ipairs(extraCCs) do
        nanoKontrol.mappings.script.AddCCToScript(midiChannel, c);
    end

    if probeCC ~= nil then
        nanoKontrol.mappings.script.AddCCToScript(midiChannel, probeCC);
    end

    if enableProbes then
        local ok, err = pcall(runProbes);
        if not ok then
            print("NanoKontrol: probes failed: " .. tostring(err));
        end
    end
end

function nanoKontrol.OnUnload()
    isLoaded = false;

    for i = faderCCStart, faderCCEnd do
        nanoKontrol.mappings.script.RemoveCCToScript(midiChannel, i);
    end

    for i = knobCCStart, knobCCEnd do
        nanoKontrol.mappings.script.RemoveCCToScript(midiChannel, i);
    end

    for i = soloCCStart, soloCCEnd do
        nanoKontrol.mappings.script.RemoveCCToScript(midiChannel, i);
    end

    for i = muteCCStart, muteCCEnd do
        nanoKontrol.mappings.script.RemoveCCToScript(midiChannel, i);
    end

    for _, c in ipairs(extraCCs) do
        nanoKontrol.mappings.script.RemoveCCToScript(midiChannel, c);
    end

    if probeCC ~= nil then
        nanoKontrol.mappings.script.RemoveCCToScript(midiChannel, probeCC);
    end
end
