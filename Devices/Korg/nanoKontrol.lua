-----------------------------------------------------------------------------------------------
-- nanoKontrol.lua
-- Korg NanoKONTROL Mk1 - fixed-position track volume, pan, mute, solo/cue and transport mapping
-- (solo "property" mode only has an effect while the Force's SOLO button is in "solo tracks" mode)
-----------------------------------------------------------------------------------------------

local deviceName = "nanoKontrol";
local midiChannel = 0;
local faderCCStart = 2;
local faderCCEnd = 10;
local knobCCStart = 11;
local knobCCEnd = 19;
local muteCCStart = 20;
local muteCCEnd = 28;
local soloCCStart = 29;
local soloCCEnd = 37;

-- Single buttons: all momentary, they act on press only (value > 0).
local toStartCC = 38;
local playCC = 39;
local redoCC = 40;
local arrangeCC = 41;
local stopAllCC = 42;
local samplerCC = 43;
local singleCCs = { toStartCC, playCC, redoCC, arrangeCC, stopAllCC, samplerCC };
local isSingleCC = {};
for _, c in ipairs(singleCCs) do
    isSingleCC[c] = true;
end

-- Redo changes the project. When true, CC40 must be pressed twice in a row (with no other
-- control touched in between) before it acts, to protect against accidental presses.
local redoRequiresConfirm = false;

-- Engine mode names tried, in order, to open the sampler (names are not documented; a
-- failed request logs the available mode names). A request counts as done when the current
-- mode name contains "sampl".
local samplerModeNames = { "Sampler", "Sample", "Sample Edit" };

-- CC41 cycles through the arranger tabs in this order: Arranger, Grid, Clip, List, then
-- back to Arranger. If the current mode is not one of them, the first press enters the
-- Arranger. Each view is requested by trying its names in order. "needle" is the text a
-- mode name contains for that view (used only as a fallback to detect the current view).
local arrangeViews = {
    { label = "arranger", needle = "arrang", names = { "Arrange", "Arranger", "Arrangement", "Song" } },
    { label = "grid", needle = "grid", names = { "Grid", "Grid View", "Grid Editor", "Arranger Grid" } },
    { label = "clip", needle = "clip", names = { "Clip Editor", "Clip", "Clip View", "Arranger Clip" } },
    { label = "list", needle = "list", names = { "List Edit", "List", "List View", "Arranger List" } },
};

-- Solo/cue buttons: "emulate" presses the Force's own buttons (needed for "CUE tracks" mode):
-- SOLO, then the lower-row button of that track. "property" drives track.Solo instead (only
-- works with the Force SOLO button in "solo tracks" mode).
local soloMode = "emulate";
-- Name prefix of the Force button row to press in "emulate" mode: "trackAssign" or "trackSelect".
local cueButtonPrefix = "trackAssign";
-- Lower-row mode to switch back to after each emulated cue / mute press ("recArm", "mute",
-- "clipStop"), or nil to leave the Force in the mode the press selected. The script cannot
-- read the Force's current mode, so this is a fixed choice.
local restoreMode = "recArm";

-- Mute buttons: "property" toggles track.Mute directly (the Force's lower-row mode is not
-- touched). "emulate" presses the Force's MUTE button, then the track's lower-row button,
-- then restoreMode - use it if "property" has no effect.
local muteMode = "property";

-- Logging. Failures are always logged (repeated ones are throttled); with verbose = true
-- every button press and mode request is logged as well.
-- Read with: journalctl -u acvs -o cat --no-pager | grep NanoKontrol
local verbose = false;

-- Diagnostics (off by default).
local enableProbes = false;     -- log API objects at load time
local probeCC = nil;            -- optional spare button CC: dump track[0] state on press
local logMonitor = false;       -- log mpc.tracks.GetTrackMonitorState on every solo message

-- State
local isLoaded = false;
local redoArmed = false;
local soloListenerTarget = nil;
local errorCounts = {};

-- Every CC this script registers.
local allCCs = {};
for i = faderCCStart, faderCCEnd do allCCs[#allCCs + 1] = i; end
for i = knobCCStart, knobCCEnd do allCCs[#allCCs + 1] = i; end
for i = muteCCStart, muteCCEnd do allCCs[#allCCs + 1] = i; end
for i = soloCCStart, soloCCEnd do allCCs[#allCCs + 1] = i; end
for _, c in ipairs(singleCCs) do allCCs[#allCCs + 1] = c; end
if probeCC ~= nil then allCCs[#allCCs + 1] = probeCC; end

------------------------------------ LOGGING / SAFETY ------------------------------------

local function logInfo(message)
    if verbose then
        print("NanoKontrol: " .. message);
    end
end

-- Logs the first few occurrences of an error per label, then every 100th, so a faulty
-- control cannot flood the journal.
local function logError(label, err)
    local n = (errorCounts[label] or 0) + 1;
    errorCounts[label] = n;
    if n <= 5 or n % 100 == 0 then
        print("NanoKontrol: " .. label .. " failed (x" .. n .. "): " .. tostring(err));
    end
end

local function callSafe(label, fn, ...)
    local ok, err = pcall(fn, ...);
    if not ok then
        logError(label, err);
    end
    return ok;
end

------------------------------------ TRACK HANDLERS ------------------------------------

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
    local track = getTrackAtSlot(cc - faderCCStart);
    if track == nil then
        return;
    end

    -- NanoKONTROL faders are 0..127. MPC track volume is normalized 0..1.
    track.Volume.value = clamp(value / 127.0, 0.0, 1.0);
end

local function handleKnob(cc, value)
    local track = getTrackAtSlot(cc - knobCCStart);
    if track == nil then
        return;
    end

    -- MPC track pan is 0..1, with 0.5 as the centre position.
    track.Pan.value = clamp(value / 127.0, 0.0, 1.0);
end

-- Presses and releases a Force button. Returns true only if both calls succeeded.
local function pressForce(name)
    local b = mpc.force and mpc.force[name];
    if b == nil or b.Press == nil or b.Release == nil then
        logError("force." .. tostring(name), "button missing");
        return false;
    end

    local ok1, e1 = pcall(b.Press);
    local ok2, e2 = pcall(b.Release);
    if not ok1 then
        logError("force." .. name .. ".Press", e1);
    end
    if not ok2 then
        logError("force." .. name .. ".Release", e2);
    end
    logInfo("force." .. name .. " press=" .. tostring(ok1) .. " release=" .. tostring(ok2));
    return ok1 and ok2;
end

local function doublePressForce(name)
    local b = mpc.force and mpc.force[name];
    if b == nil or b.DoublePress == nil then
        logError("force." .. tostring(name) .. ".DoublePress", "button missing");
        return;
    end

    if callSafe("force." .. name .. ".DoublePress", b.DoublePress) then
        logInfo("force." .. name .. " DoublePress ok");
    end
end

-- Emulates "mode button, then the track's lower-row button, then back to restoreMode".
-- Aborts if the mode button cannot be pressed; always restores once the mode was changed.
local function emulateLowerRow(modeButton, slotIndex)
    if not pressForce(modeButton) then
        return;
    end

    pressForce(cueButtonPrefix .. (slotIndex + 1));

    if restoreMode ~= nil then
        pressForce(restoreMode);
    end
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
        emulateLowerRow("mute", slotIndex);
        return;
    end

    -- One toggle per message, so the track still toggles correctly if its mute state was
    -- changed by hand on the Force and the button's own on/off state is out of step.
    callSafe("SetMute", track.SetMute, not track.Mute.value);
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
        emulateLowerRow("solo", slotIndex);
        return;
    end

    -- Buttons are set to toggle in the Kontrol Editor: 127 = on, 0 = off.
    callSafe("SetSolo", track.SetSolo, value > 0);
end

------------------------------------ MODE / VIEW SWITCHING ------------------------------------

local function currentModeName()
    local cm = mpc.engineMode and mpc.engineMode.CurrentMode;
    return cm and tostring(cm.value) or "";
end

local function availableModesText()
    local em = mpc.engineMode;
    if em == nil or em.GetAvailableModes == nil then
        return "(unavailable)";
    end

    local ok, modes = pcall(em.GetAvailableModes);
    if not ok or type(modes) ~= "table" then
        return "(unavailable)";
    end

    local names = {};
    for _, v in pairs(modes) do
        names[#names + 1] = tostring(v);
    end
    return table.concat(names, ",");
end

-- Tries each name until the mode changes (stopOnChange) or its name contains `needle`.
-- Logs a failure, including the available mode names, if nothing worked.
local function requestMode(label, names, needle, stopOnChange)
    local em = mpc.engineMode;
    if em == nil or em.RequestModeChange == nil then
        logError(label, "engineMode.RequestModeChange unavailable");
        return false;
    end

    local before = currentModeName();
    for _, name in ipairs(names) do
        callSafe(label .. ".RequestModeChange", em.RequestModeChange, name);
        local current = currentModeName();
        logInfo(label .. " request '" .. name .. "' -> CurrentMode '" .. current .. "'");

        if stopOnChange then
            -- done as soon as the mode changed at all (the new mode's name may differ
            -- from the requested one)
            if current ~= before then
                return true;
            end
        elseif string.find(string.lower(current), needle, 1, true) then
            return true;
        end
    end

    logError(label, "mode did not change (was '" .. before .. "'); available modes: " ..
        availableModesText());
    return false;
end

local function handleArrange()
    local current = string.lower(currentModeName());

    -- Which view are we in? First an exact match against the known mode names, then
    -- (as a fallback) a name that contains the view's keyword. The matrix / clip-launch
    -- modes are never treated as an arranger view.
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
    logInfo("arrange -> " .. view.label .. " (mode was '" .. currentModeName() .. "')");
    requestMode("arrange " .. view.label, view.names, view.needle, true);
end

------------------------------------ SINGLE BUTTONS ------------------------------------

local function handleRedo()
    if redoRequiresConfirm and not redoArmed then
        redoArmed = true;
        logInfo("redo armed: press again to confirm");
        return;
    end

    redoArmed = false;
    callSafe("Redo", mpc.commandManager.Redo);
end

local function handleSingle(cc, value)
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
        callSafe("JumpToPulse", mpc.sequencer.JumpToPulse, 0);
    elseif cc == redoCC then
        handleRedo();
    elseif cc == arrangeCC then
        handleArrange();
    elseif cc == samplerCC then
        requestMode("sampler", samplerModeNames, "sampl", false);
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
    -- The listener is removed again in OnUnload.
    local t0 = mpc.tracks.normalTracks[0];
    if t0 ~= nil and t0.Solo ~= nil and t0.Solo.listen ~= nil then
        local okl, errl = pcall(t0.Solo.listen, t0.Solo, function(...)
            print("NanoKontrol: track[0].Solo changed -> " .. tostring((...)));
        end, deviceName);
        if okl then
            soloListenerTarget = t0.Solo;
        end
        print("NanoKontrol: Solo listener ok=" .. tostring(okl) .. " " .. tostring(errl));
    end

    print("NanoKontrol: ---- cue probes end ----");
end

------------------------------------ MIDI DISPATCH ------------------------------------

local function dispatchCC(cc, value)
    -- Any other control touched cancels a pending Redo confirmation.
    if cc ~= redoCC then
        redoArmed = false;
    end

    if cc >= faderCCStart and cc <= faderCCEnd then
        handleFader(cc, value);
    elseif cc >= knobCCStart and cc <= knobCCEnd then
        handleKnob(cc, value);
    elseif cc >= muteCCStart and cc <= muteCCEnd then
        handleMute(cc, value);
    elseif cc >= soloCCStart and cc <= soloCCEnd then
        handleSolo(cc, value);
    elseif isSingleCC[cc] then
        handleSingle(cc, value);
    elseif probeCC ~= nil and cc == probeCC and value > 0 then
        logTrackState("manual");
    end
end

local function removeAllCCs()
    for _, c in ipairs(allCCs) do
        pcall(nanoKontrol.mappings.script.RemoveCCToScript, midiChannel, c);
    end
end

--------------------------- REQUIRED FUNCTIONS -------------------------
---------------------------- Called from C++ ---------------------------

function nanoKontrol.HandleMIDINoteOn(channel, note, velocity) end

function nanoKontrol.HandleMIDINoteOff(channel, note, velocity) end

function nanoKontrol.HandleMIDISysex(sysexChars) end

function nanoKontrol.HandleTimer() end

function nanoKontrol.HandleMIDICC(channel, cc, value)
    if type(channel) ~= "number" or type(cc) ~= "number" or type(value) ~= "number" then
        return;
    end

    if channel ~= midiChannel then
        return;
    end

    -- A failing control must never throw into the host.
    callSafe("CC" .. tostring(cc), dispatchCC, cc, value);
end

function nanoKontrol.OnLoad()
    if isLoaded then
        return;
    end

    local ok, err = pcall(function()
        for _, c in ipairs(allCCs) do
            nanoKontrol.mappings.script.AddCCToScript(midiChannel, c);
        end
    end);

    if not ok then
        -- Roll back; isLoaded stays false so a later OnLoad can try again.
        print("NanoKontrol: OnLoad failed while registering CCs: " .. tostring(err));
        removeAllCCs();
        return;
    end

    isLoaded = true;
    redoArmed = false;

    if enableProbes then
        local okp, errp = pcall(runProbes);
        if not okp then
            print("NanoKontrol: probes failed: " .. tostring(errp));
        end
    end
end

function nanoKontrol.OnUnload()
    isLoaded = false;
    redoArmed = false;

    if soloListenerTarget ~= nil then
        pcall(soloListenerTarget.stopListening, soloListenerTarget, deviceName);
        soloListenerTarget = nil;
    end

    removeAllCCs();
end
