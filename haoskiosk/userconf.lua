--[=[
Add-on: HAOS Kiosk Display (haoskiosk)
File: userconf.lua for HA minimal browser run on server
Version: 1.3.8
Copyright Jeff Kosowsky
Date: November 2026

Code does the following:
    - Sets browser window to fullscreen
    - Sets zooms level to value of $ZOOM_LEVEL (default 100%)
    - Sets new tab and window default to blank page (about:blank)
    - Loads every URL in 'passthrough' mode so that you can type text as needed without triggering browser commands
    - Auto login to Home Assistant using $HA_USERNAME and $HA_PASSWORD
    - Redefines key to return to normal mode (used for commands) from 'passthrough' mode to: 'Ctl+Alt+Esc'
      (rather than just 'Esc') to prevent unintended  returns to normal mode and activation of unwanted commands
    - Adds <Ctrl-r> binding to reload browser screen (all modes)
    - Adds <Ctrl-Left> and <Ctrl-Right> bindings, to move backwards and forwards respectively in the browser history
    - Adds <Ctrl-Alt-Left> and <Ctrl-Alt-Right> bindings to move to previous and next tabs respectively
    - Note <Ctrl-Alt-Shift-Left> and <Ctrl-Alt-Shift-Right> bindings move to previous and next windows (but defined in Openbox window manager bindings, not here
    - Adds <Ctrl-Alt-t> and <Ctrl-Alt-Shift-t> for new and close tab respectively
    - Adds <Ctrl-Alt-w> for new and close window
    - Prevent printing of '--PASS THROUGH--' status line when in 'passthrough' mode
    - Set up periodic browser refresh every $BROWSWER_REFRESH seconds (disabled if 0)
      NOTE: Original method injected JS to refresh page, now using native luakit view:reload command for more robustness
            Also, every HARD_RELOAD_FREQ refreshes, we also fully refresh the cash
      NOTE: this is important since console messages overwrite dashboards
    - Kill current luakit and restart if any page fails to reload MAX_LOAD_FAILURES in a row
    - Auto-reload page (with backoff) if the WebKit web process crashes, instead of leaving the
      'Web process crashed' error page up until the next refresh
    - Disable WebKit hardware acceleration (GPU compositing) unless $HARDWARE_ACCELERATION is true
    - Keep page at configured $ZOOM_LEVEL: log zoom changes and restore the configured zoom if the
      rendered zoom drifts (checked every 60s and after each page load)
    - If $FRONTEND_DEBUG is true, log dashboard page activity (page loads/unloads, HA websocket drops and
      reconnects) and a periodic heartbeat with DOM size and browser/X process memory and CPU use
    - Allows for configurable browser $ZOOM_LEVEL
    - Set theme based on $HA_THEME.
      If no theme is set (or if set to '{}' or 'Home Assistant') then the default theme is used with light or dark depending on the value of $DARK_MODE
      Similarly, if the theme has both light and dark modes, then the value of $DARK_MODE determines the underlying mode.
      If theme is set to '{"dark":true} or {"dark":false} then the default theme is dark or light respectively, regardless of the value of $DARK_MODE
    - Set Home Assistant sidebar visibility using $HA_SIDEBAR environment variables
    - Set 'browser_mod-browser-id' to fixed value 'haos_kiosk'
    - If using onscreen keyboard, hide keyboard after page (re)load
    - Prevent session restore by overloading 'session.restore
]=]

-- -----------------------------------------------------------------------
-- Load required Luakit modules
local window = require "window"
local webview = require "webview"
local settings = require "settings"
local modes = package.loaded["modes"]

-- -----------------------------------------------------------------------
-- Configurable variables
local new_escape_key = "<Control-Mod1-Escape>" -- Ctl+Alt+Esc
local HARD_RELOAD_FREQ = 10  -- Frequency of fully reloading cache when refreshing page
local MAX_LOAD_FAILURES = 5  -- Maximum number of consecutive page (re)load failures per view before restarting luakit


-- Load in environment variables to configure options
local defaults = {
    HA_USERNAME = "",
    HA_PASSWORD = "",
    HA_URL = "http://localhost:8123",
    DARK_MODE = true,
    HA_SIDEBAR = "",
    HA_THEME = "",

    LOGIN_DELAY = 1,
    ZOOM_LEVEL = 100,
    BROWSER_REFRESH = 600,
                        }
local username = os.getenv("HA_USERNAME") or defaults.HA_USERNAME
local password = os.getenv("HA_PASSWORD") or defaults.HA_PASSWORD

local ha_url = os.getenv("HA_URL") or defaults.HA_URL  -- Starting URL
if not ha_url:match("^https?://[%w%.%-%%:]+[/%?%#]?[/%w%.%-%?%#%=%%]*$") then
    msg.warn("Invalid HA_URL value: '%s'; defaulting to %s", os.getenv("HA_URL") or "", defaults.HA_URL)
    ha_url = defaults.HA_URL
end
ha_url = string.gsub(ha_url, "/+$", "") -- Strip trailing '/'
local ha_url_base = ha_url:match("^(https?://[%w%.%-%%:]+)") or ha_url
ha_url_base = string.gsub(ha_url_base, "/+$", "") -- Strip trailing '/'

local raw_dark_mode = os.getenv("DARK_MODE")
if raw_dark_mode == nil then
    dark_mode = defaults.DARK_MODE
else
    dark_mode = raw_dark_mode:lower()
    if dark_mode == "true" then
        dark_mode = true
    elseif dark_mode == "false" then
        dark_mode = false
    else
       dark_mode = defaults.DARK_MODE
    end
end

local raw_sidebar = os.getenv("HA_SIDEBAR") or defaults.HA_SIDEBAR -- Valid entries: full (or ""), narrow, none,
local valid_sidebars = {
    full = '',
    none = '"always_hidden"',
    narrow = '"auto"',
    [""] = ''
}
local sidebar = valid_sidebars[(raw_sidebar or ""):lower()] or ''
if sidebar == '' and raw_sidebar ~= "" and raw_sidebar ~= defaults.HA_SIDEBAR then
    msg.warn("Invalid HA_SIDEBAR value: '%s'; defaulting to unset", raw_sidebar)
    sidebar = ''
end

local theme = os.getenv("HA_THEME") or "" -- Any installed theme name (e.g., "midnight", "google", "minimal"), or empty to not override
if theme ~= "" then
   local firstchar = theme:sub(1,1)
   if firstchar ~= '"' and firstchar ~= "'" and firstchar ~= '{' then
       theme = '"' .. theme .. '"' -- Wrap in quotes
   end
    msg.info("Forcing HA_THEME to: %s", theme)
end

local login_delay = tonumber(os.getenv("LOGIN_DELAY")) or defaults.LOGIN_DELAY -- Delay in seconds before auto-login
if login_delay <= 0 then
    msg.warn("Invalid LOGIN_DELAY value: '%s'; defaulting to %d", os.getenv("LOGIN_DELAY") or "", defaults.LOGIN_DELAY)
    login_delay = defaults.LOGIN_DELAY
end

local zoom_level = tonumber(os.getenv("ZOOM_LEVEL")) or defaults.ZOOM_LEVEL
if zoom_level <= 0 then
    msg.warn("Invalid ZOOM_LEVEL value: '%s'; defaulting to %d", os.getenv("ZOOM_LEVEL") or "", defaults.ZOOM_LEVEL)
    zoom_level = defaults.ZOOM_LEVEL
end

local browser_refresh = tonumber(os.getenv("BROWSER_REFRESH")) or defaults.BROWSER_REFRESH  -- Refresh interval in seconds
if browser_refresh < 0 then
    msg.warn("Invalid BROWSER_REFRESH value: '%s'; defaulting to %d", os.getenv("BROWSER_REFRESH") or "", defaults.BROWSER_REFRESH)
    browser_refresh = defaults.BROWSER_REFRESH
end

local onscreen_keyboard = os.getenv("ONSCREEN_KEYBOARD") == "true"

-- GPU compositing is off by default: WebKitGTK's threaded compositor can abort the
-- web process ("pure virtual method called" / SIGABRT), which leaves a "Web process crashed" page
local hardware_acceleration = os.getenv("HARDWARE_ACCELERATION") == "true"

-- Extra logging about the dashboard page (see "Frontend debug logging" below)
local frontend_debug = os.getenv("FRONTEND_DEBUG") == "true"

msg.info("USERNAME=%s; URL=%s; DARK_MODE=%s; SIDEBAR=%s; THEME=%s; LOGIN_DELAY=%.1f, ZOOM_LEVEL=%d, BROWSER_REFRESH=%d,  ONSCREEN_KEYBOARD=%s, FRONTEND_DEBUG=%s",
    username, ha_url, tostring(dark_mode), sidebar, theme, login_delay, zoom_level, browser_refresh, tostring(onscreen_keyboard), tostring(frontend_debug))

-- -----------------------------------------------------------------------
-- Forward console messages to stdout
settings.set_setting("webview.enable_write_console_messages_to_stdout", true)

-- Prefer Dark mode if set to true
settings.application.prefer_dark_mode = dark_mode

-- Set window to fullscreen
window.add_signal("init", function(w)
    w.win.fullscreen = true
end)

-- Set zoom level for windows (default 100%)
settings.webview.zoom_level = zoom_level

-- Render without GPU compositing unless explicitly enabled
if not hardware_acceleration then
    settings.webview.hardware_acceleration_policy = "never"
    settings.webview.enable_accelerated_2d_canvas = false
    msg.info("Hardware acceleration disabled (software rendering)")
end

-- Set default new tab and window to blank page, rather than commercial luakit page
settings.window.home_page    = "about:blank"
settings.window.new_tab_page = "about:blank"

-- Prevent session restore by overloading 'session.restore'
local session = require "session"
session.restore = function()
    return nil
end

-- Force new URLs from new 'luakit' instances to launch in current/last active tab of first window
-- Note requires patch to /usr/share/luakit/lib/unique_instance.lua
local unique_instance = require "unique_instance"
unique_instance.open_link_in_current_tab  = true

-- -----------------------------------------------------------------------
-- Helper functions
local function single_quote_escape(str) -- Single quote strings before injection into JS
    if not str or str == "" then return str end
    str = str:gsub("\\", "\\\\")
    str = str:gsub("'", "\\'")
    str = str:gsub("\n", "\\n")
    str = str:gsub("\r", "\\r")
    return str
end

-- -----------------------------------------------------------------------
-- Per-view weak table to track last URL for refresh debugging/reset detection
local consecutive_load_failures = setmetatable({}, { __mode = "k" })  -- Weak keys per view to count consecutive reload failures

-- Auto-recover from web-process crashes instead of leaving luakit's
-- "Web process crashed" page up until the next scheduled refresh.
-- Backs off (3s, 6s, 12s ... up to 5 min) if crashes repeat within 15 minutes.
local crash_times = setmetatable({}, { __mode = "k" })
webview.add_signal("init", function(view)
    view:add_signal("crashed", function(v)
        local now = os.time()
        local recent = {}
        for _, t in ipairs(crash_times[v] or {}) do
            if now - t < 900 then recent[#recent + 1] = t end
        end
        recent[#recent + 1] = now
        crash_times[v] = recent
        local delay = math.floor(math.min(3 * 2 ^ (#recent - 1), 300))
        msg.warn("Web process CRASHED (%d in last 15 min); reloading in %ds: %s", #recent, delay, v.uri or "unknown")
        local t = timer { interval = delay * 1000 }
        t:add_signal("timeout", function()
            t:stop()
            if v.is_alive then
                msg.info("Reloading after web process crash: %s", v.uri or "unknown")
                v:reload()
            end
        end)
        t:start()
    end)
end)

-- Keep the page at the configured zoom level.
-- The zoom can end up at 100% even though luakit applied it: on HAOS (luakit 2.3.6, WebKitGTK ~2.48)
-- WebKit was seen resetting zoom-level to 1.0 a fraction of a second after luakit set it on page
-- commit, so after a load/reload it was 140% or 100% depending on timing. luakit's <Control-Scroll>
-- zoom binding also stays active in 'passthrough' mode. Previously only another reload could fix it,
-- so with browser_refresh = 0 it stayed wrong. So:
--   - Log every settled zoom change, with the luakit code that made it (if any)
--   - Every ZOOM_CHECK_INTERVAL seconds, and shortly after each page load, measure the zoom the page
--     is actually rendered at (outerWidth/innerWidth) and restore the configured zoom if it differs
local ZOOM_CHECK_INTERVAL = 60   -- Seconds between zoom checks
local ZOOM_TOLERANCE = 0.03      -- Allowed difference between rendered and configured zoom factor
local ZOOM_MEASURE_JS = "(window.innerWidth > 0 && window.outerWidth > 0) ? String(window.outerWidth / window.innerWidth) : '0'"
local zoom_timers = setmetatable({}, { __mode = "k" })  -- Per-view periodic check timers
local zoom_logged = setmetatable({}, { __mode = "k" })  -- Per-view last logged zoom (percent)

local function pct(factor) return math.floor(factor * 100 + 0.5) end

local function configured_zoom(v)
    return (settings.get_setting_for_view(v, "webview.zoom_level") or zoom_level) / 100
end

local function zoom_change_source()  -- Luakit lib files/lines in the current call stack, if any
    local src = {}
    for file, line in debug.traceback():gmatch("([%w_]+%.lua):(%d+)") do
        if file ~= "userconf.lua" and #src < 3 then src[#src + 1] = file .. ":" .. line end
    end
    return #src > 0 and (" via " .. table.concat(src, " < ")) or ""
end

local function check_zoom(v, reason)
    if not v.is_alive or not v.uri or v.uri == "about:blank" then return end
    v:eval_js(ZOOM_MEASURE_JS, { callback = function(ret, err)
        local rendered = tonumber(ret)
        if err or not rendered or rendered <= 0 or not v.is_alive then return end
        local want = configured_zoom(v)
        if math.abs(rendered - want) > ZOOM_TOLERANCE then
            msg.warn("ZOOM DRIFT (%s): page rendered at %d%%, view zoom_level %d%%, configured %d%%; restoring",
                     reason, pct(rendered), pct(v.zoom_level), pct(want))
            -- Setting the same value is a no-op, so nudge first when the property already matches
            -- (luakit itself resets to 1.0 before applying any zoom other than 1.0)
            if math.abs(v.zoom_level - want) < 0.001 and want == 1.0 then v.zoom_level = 1.01 end
            v.zoom_level = want
        end
    end })
end

webview.add_signal("init", function(view)
    -- Log settled zoom changes (luakit briefly sets 1.0 before each change, so wait for it to settle)
    local pending, source = nil, ""
    view:add_signal("property::zoom_level", function(v)
        if not pending then source = zoom_change_source() end
        if pending then return end
        pending = timer { interval = 250 }
        pending:add_signal("timeout", function()
            pending:stop(); pending = nil
            if not v.is_alive then return end
            local z = pct(v.zoom_level)
            if z ~= zoom_logged[v] then
                zoom_logged[v] = z
                msg.info("Zoom level now %d%% (configured %d%%)%s", z, pct(configured_zoom(v)), source)
            end
        end)
        pending:start()
    end)

    -- Check shortly after each page load (catches WebKit dropping the zoom after a crash)
    view:add_signal("load-status", function(v, status)
        if status ~= "finished" then return end
        local t = timer { interval = 2000 }
        t:add_signal("timeout", function() t:stop(); check_zoom(v, "after load") end)
        t:start()
    end)

    -- Periodic check (catches drift while the page just sits there, e.g. with browser_refresh = 0)
    local periodic = timer { interval = ZOOM_CHECK_INTERVAL * 1000 }
    periodic:add_signal("timeout", function()
        if view.is_alive then check_zoom(view, "periodic") else periodic:stop() end
    end)
    zoom_timers[view] = periodic
    periodic:start()
    view:add_signal("destroy", function() periodic:stop() end)
end)

-- -----------------------------------------------------------------------
-- Frontend debug logging (only if $FRONTEND_DEBUG is true)
-- Logs what the dashboard page itself is doing, to help explain a blank or redrawn screen and memory
-- growth. (JS errors are already in the log via the console forwarding above, so they are only counted.)
--   - Each page load start, including reloads triggered from inside the page
--   - Page unload (with how long the page was up) and hidden/visible changes
--   - HA websocket disconnects, reconnects (with downtime) and failed reconnect attempts
--   - Every FRONTEND_HEARTBEAT seconds: page uptime, DOM size (including shadow DOM), websocket state,
--     JS errors since load, and memory (RSS) and CPU use (since the last heartbeat, % of one core) of the
--     luakit, WebKit and X processes, with all other processes summed as "other"
--   - With each heartbeat, the container's memory split (process memory, page cache, shared memory, kernel,
--     SysV shared memory segments) and luakit's Lua heap, for growth that per-process RSS does not show
-- Page-side events are written with console.* (forwarded to stdout), all lines are prefixed "FRONTEND:"
local FRONTEND_HEARTBEAT = 600  -- Seconds between heartbeat lines

if frontend_debug then
    local js_frontend_monitor = [[
        (function() {
            if (window.__kioskFrontendDebug) return;  // Once per page load
            const d = window.__kioskFrontendDebug = { loaded: Date.now(), errors: 0, conn: null };
            const log = (level, text) => console[level]('FRONTEND: ' + text);
            const secs = (since) => Math.round((Date.now() - since) / 1000);

            window.addEventListener('error', () => { d.errors++; });  // Counted only: WebKit already logs them
            window.addEventListener('unhandledrejection', () => { d.errors++; });
            document.addEventListener('visibilitychange', () => log('info', 'page ' + document.visibilityState));
            window.addEventListener('pagehide', () => log('info', 'page unloading after ' + secs(d.loaded) + 's'));

            // HA websocket events (window.hassConnection only exists on HA frontend pages)
            let tries = 0;
            (function attach() {
                if (!window.hassConnection) {
                    if (++tries < 10) setTimeout(attach, 1000);
                    return;
                }
                window.hassConnection.then(({ conn }) => {
                    d.conn = conn;
                    let down = 0;
                    conn.addEventListener('disconnected', () => { down = Date.now(); log('warn', 'HA websocket disconnected'); });
                    conn.addEventListener('ready', () => log('info', 'HA websocket reconnected' + (down ? ' after ' + secs(down) + 's' : '')));
                    conn.addEventListener('reconnect-error', (c, err) => log('warn', 'HA websocket reconnect failed (' + err + ')'));
                    log('info', 'watching HA websocket (HA ' + (conn.haVersion || '?') + ')');
                }).catch((err) => log('warn', 'HA websocket not available: ' + err));
            })();
        })();
    ]]

    local js_frontend_heartbeat = [[
        (function() {
            const d = window.__kioskFrontendDebug;
            if (!d) return 'monitor not loaded on this page';
            let nodes = 0;
            const walk = (root) => {
                const w = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT);
                for (let el = w.nextNode(); el; el = w.nextNode()) {
                    nodes++;
                    if (el.shadowRoot) walk(el.shadowRoot);
                }
            };
            walk(document);
            const up = Math.round((Date.now() - d.loaded) / 60000);
            return 'page up ' + Math.floor(up / 60) + 'h' + String(up % 60).padStart(2, '0') + 'm, ' +
                   nodes + ' DOM nodes, websocket ' + (d.conn ? (d.conn.connected ? 'connected' : 'DISCONNECTED') : 'n/a') +
                   ', ' + document.visibilityState + ', ' + d.errors + ' JS errors';
        })()
    ]]

    local CLK_TCK = 100  -- Kernel clock ticks per second for /proc/<pid>/stat CPU times (USER_HZ, 100 on Linux)
    local function count_cpus()
        local n = 0
        local f = io.open("/proc/cpuinfo")
        if f then
            for line in f:lines() do if line:match("^processor%s*:") then n = n + 1 end end
            f:close()
        end
        return math.max(n, 1)
    end
    local function uptime()  -- Seconds since boot, fractional
        local f = io.open("/proc/uptime")
        local t = f and tonumber((f:read("*l") or ""):match("^(%S+)"))
        if f then f:close() end
        return t
    end

    -- Memory (RSS) and CPU use per process name since the previous call, e.g.
    -- "WebKitWebProcess 312 MB 9%, Xorg 60 MB 2%, luakit 170 MB 1%, other 40 MB 0%" (CPU as % of one core)
    local process_names = { WebKitWebProces = "WebKitWebProcess", WebKitNetworkPr = "WebKitNetworkProcess",
                            luakit = "luakit", Xorg = "Xorg" }  -- /proc comm names are cut at 15 characters
    local last_ticks, last_uptime = {}, nil
    local function process_stats()
        local rss, ticks, names = {}, {}, {}
        local ls = io.popen("ls /proc 2>/dev/null")
        if not ls then return "NA" end
        for pid in ls:lines() do
            if pid:match("^%d+$") then
                local f = io.open("/proc/" .. pid .. "/stat")
                local stat = f and f:read("*l")
                if f then f:close() end
                local comm, rest = (stat or ""):match("^%d+ %((.*)%) (.*)$")
                if comm then
                    local name = process_names[comm] or (comm:match("^WebKit") and comm) or "other"
                    local fields = {}
                    for x in rest:gmatch("%S+") do fields[#fields + 1] = x end  -- fields[12], [13] = utime, stime
                    local s = io.open("/proc/" .. pid .. "/status")
                    local kb = s and tonumber((s:read("*a") or ""):match("VmRSS:%s*(%d+)")) or 0
                    if s then s:close() end
                    if not rss[name] then names[#names + 1] = name; rss[name] = 0; ticks[name] = 0 end
                    rss[name] = rss[name] + kb
                    ticks[name] = ticks[name] + (tonumber(fields[12]) or 0) + (tonumber(fields[13]) or 0)
                end
            end
        end
        ls:close()
        local now = uptime()
        local elapsed = (now and last_uptime) and (now - last_uptime) or nil
        table.sort(names, function(a, b)
            if a == "other" or b == "other" then return b == "other" and a ~= "other" end
            return a < b
        end)
        local parts = {}
        for _, n in ipairs(names) do
            local cpu = ""
            if elapsed and elapsed > 0 then  -- A name new since the last call started within the interval
                cpu = string.format(" %d%%", math.floor(math.max(0, ticks[n] - (last_ticks[n] or 0)) / CLK_TCK / elapsed * 100 + 0.5))
            end
            parts[#parts + 1] = string.format("%s %d MB%s", n, math.floor(rss[n] / 1024 + 0.5), cpu)
        end
        last_ticks, last_uptime = ticks, now
        return #parts > 0 and table.concat(parts, ", ") or "NA"
    end
    process_stats()  -- Baseline, so the first heartbeat reports CPU use since startup

    -- Container-wide memory (cgroup v2), for growth that per-process RSS does not show: anon (process memory),
    -- file (page cache; the "active" part is counted in the add-on's memory figure but is reclaimable), shmem
    -- (shared memory and tmpfs), kernel, plus SysV shared memory segments (unattached ones are leaked)
    local function container_memory()
        -- The container's own cgroup: "/" with a private cgroup namespace, the full path with the host's
        local c = io.open("/proc/self/cgroup")
        local path = c and (c:read("*a") or ""):match("0::(%S+)") or "/"
        if c then c:close() end
        local f = io.open("/sys/fs/cgroup" .. (path == "/" and "" or path) .. "/memory.stat")
        if not f then return "NA" end
        local st = {}
        for line in f:lines() do
            local k, v = line:match("^(%S+) (%d+)$")
            if k then st[k] = tonumber(v) end
        end
        f:close()
        local function mb(b) return math.floor((b or 0) / 1048576 + 0.5) end
        local shm_count, shm_bytes, shm_unattached = 0, 0, 0
        local s = io.open("/proc/sysvipc/shm")
        if s then
            s:read("*l")  -- Header
            for line in s:lines() do
                local fields = {}
                for x in line:gmatch("%S+") do fields[#fields + 1] = x end  -- [4] = size, [7] = nattch
                shm_count = shm_count + 1
                shm_bytes = shm_bytes + (tonumber(fields[4]) or 0)
                if fields[7] == "0" then shm_unattached = shm_unattached + 1 end
            end
            s:close()
        end
        return string.format("anon %d MB, file %d MB (active %d MB), shmem %d MB, kernel %d MB; SysV shm %d segments %d MB (%d unattached)",
            mb(st.anon), mb(st.file), mb(st.active_file), mb(st.shmem), mb(st.kernel or st.slab),
            shm_count, mb(shm_bytes), shm_unattached)
    end

    webview.add_signal("init", function(view)
        local pending = nil  -- Unanswered heartbeat request {id, sent} (page busy or hung)
        local request_id = 0

        view:add_signal("load-status", function(v, status)
            if not v.uri or v.uri == "about:blank" then return end
            if status == "provisional" then
                pending = nil  -- An answer from the old page may never come
                msg.info("FRONTEND: page load started: %s", v.uri)
            elseif status == "finished" then
                v:eval_js(js_frontend_monitor, { source = "frontend_debug.js", no_return = true })
            end
        end)

        local heartbeat = timer { interval = FRONTEND_HEARTBEAT * 1000 }
        heartbeat:add_signal("timeout", function()
            if not view.is_alive then heartbeat:stop(); return end
            if not view.uri or view.uri == "about:blank" then return end
            msg.info("FRONTEND: memory: container %s; luakit Lua heap %d KB", container_memory(), math.floor(collectgarbage("count")))
            if pending then  -- Don't queue more requests behind an unanswered one
                msg.warn("FRONTEND: heartbeat: page not answering for %ds; processes: %s", os.time() - pending.sent, process_stats())
                return
            end
            request_id = request_id + 1
            local id = request_id
            pending = { id = id, sent = os.time() }
            view:eval_js(js_frontend_heartbeat, { callback = function(ret, err)
                if not pending or pending.id ~= id then return end  -- Stale: page was reloaded since
                local late = os.time() - pending.sent
                pending = nil
                msg.info("FRONTEND: heartbeat: %s%s; processes: %s", err and ("page error: " .. tostring(err)) or tostring(ret),
                         late >= FRONTEND_HEARTBEAT and string.format(" (answered after %ds)", late) or "", process_stats())
            end })
        end)
        heartbeat:start()
        view:add_signal("destroy", function() heartbeat:stop() end)
    end)

    msg.info("Frontend debug logging enabled (heartbeat every %ds; process CPU is %% of one core, %d cores)",
             FRONTEND_HEARTBEAT, count_cpus())
end

-- -----------------------------------------------------------------------

-- Auto-login to homeassistant (if on HA url) and set 'sidebar settings

local ha_settings_applied = setmetatable({}, { __mode = "k" }) -- Flag to track if HA settings have already been applied in this session

webview.add_signal("init", function(view)
    ha_settings_applied[view] = false  -- Set theme and sidebar settings once  per view

    -- Listen for page load status events
    view:add_signal("load-status", function(v, status)  -- Note do NOT used "load-finished" since doesn't handle redirects properly

        -- Restart luakit if consecutive_load_failures > MAX_LOAD_FAILURES
        if status == "failed" then
            consecutive_load_failures[v] = (consecutive_load_failures[v] or 0) + 1

            if consecutive_load_failures[v] < MAX_LOAD_FAILURES then
                msg.warn("Page load failed (%d/%d): %s", consecutive_load_failures[v], MAX_LOAD_FAILURES, v.uri or "unknown")
             else
                local ffi = require("ffi")
                ffi.cdef("int getpid(void);")
                local luakit_pid = ffi.C.getpid()

                local url = v.uri or ha_url
                msg.error("RESTARTING Luakit (PID=%d) after %d page load failures: %s", luakit_pid, MAX_LOAD_FAILURES, url)
                -- Send kill signal to current luakit pid, wait to complete kill, wait for dbus to fully disconnect, remove /tmp ipc file, launch new luakit, echo PID
                local cmd = string.format([[
                  (kill %d;
                   while kill -0 %d 2>/dev/null; do sleep 0.1; done;
                   sleep 2;
                   rm -f /tmp/luakit-%d-* 2>/dev/null;
                   luakit '%s' &
                   echo "New Luakit PID=$!") &
                ]], luakit_pid, luakit_pid, luakit_pid, url)
                os.execute(cmd)
            end

        elseif status ~= "finished" then return end  -- Only proceed when the page is fully loaded
            consecutive_load_failures[v] = 0  -- Reset consecutive load failures counter

         -- Print RSS  memory consumption
        local mem_file = io.open("/proc/self/statm", "r")
        local rss_mb = "NA"
        if mem_file then
            local rss_pages = tonumber(mem_file:read("*a"):match("%S+%s+(%S+)"))
            mem_file:close()
            if rss_pages then
                rss_mb = math.floor(rss_pages * 4 / 1024)  -- Approximate MB (page size ~4kB on most systems)
            end
        end
        msg.info("URL: %s (RSS: %s MB)", v.uri, rss_mb) -- DEBUG

        -- Hide onscreen keyboard (if enabled) after page (re)load
        -- NOTE: this is needed since 'onboard' doesn't always hide keyboard unless focus explicitly lost
        if onscreen_keyboard then
            msg.info("Hiding onscreen keyboard...")
            luakit.spawn("dbus-send --type=method_call --dest=org.onboard.Onboard /org/onboard/Onboard/Keyboard org.onboard.Onboard.Keyboard.Hide")
        end

        -- Force passthrough mode on every page load so don't inadvertently type commands in kiosk
        webview.window(v):set_mode("passthrough")

        -- Set up auto-login for Home Assistant
        -- Check if current URL matches the Home Assistant auth page
        if v.uri:match("^" .. ha_url_base .. "/auth/authorize%?response_type=code") then
            msg.info("Authorizing: %s", v.uri) -- DEBUG
            -- JavaScript to auto-fill and submit the login form
            local js_auto_login = string.format([[
                setTimeout(function() {
                    try {
                        // 2026.4+ working version uses shadowRoot; preserve backward-compatibility
                        const haInputs = document.querySelectorAll('ha-input');
                        const usernameField = haInputs[0]?.shadowRoot?.querySelector('wa-input')?.shadowRoot?.querySelector('input[autocomplete="username"]')
                            || document.querySelector('input[autocomplete="username"]');
                        const passwordField = haInputs[1]?.shadowRoot?.querySelector('wa-input')?.shadowRoot?.querySelector('input[autocomplete="current-password"]')
                            || document.querySelector('input[autocomplete="current-password"]');
                        const haCheckbox = document.querySelector('ha-checkbox');
                        const submitButton = document.querySelector('ha-button');

                        if (usernameField && passwordField) {  // Note post 2026.4 requires 'change' event oo
                            usernameField.value = '%s';
                            usernameField.dispatchEvent(new Event('input', { bubbles: true }));
                            usernameField.dispatchEvent(new Event('change', { bubbles: true }));

                            passwordField.value = '%s';
                            passwordField.dispatchEvent(new Event('input', { bubbles: true }));
                            passwordField.dispatchEvent(new Event('change', { bubbles: true }));

                            console.log('Auto-login: fields filled + events dispatched');
                        } else {
                            console.log('Auto-login failed: missing elements', {
                                username: !!usernameField,
                                password: !!passwordField,
                                submit: !!submitButton
                            });
                        }

                        if (haCheckbox) {
                            haCheckbox.setAttribute('checked', '');
                            haCheckbox.dispatchEvent(new Event('change', { bubbles: true }));
                        }

                        if (submitButton) submitButton.click();
                    } catch(e) { console.warn('Auto-login JS error:', e); }
                }, %d);
            ]], single_quote_escape(username), single_quote_escape(password), login_delay * 1000)

            msg.info("Logging in: (username: %s): %s", username, v.uri) -- DEBUG
            v:eval_js(js_auto_login, { source = "auto_login.js", no_return = true })  -- Execute the login script
        end

        -- Set Home Assistant theme and sidebar visibility after dashboard load
        if not ha_settings_applied[v] -- Check if not set yet and current URL starts with ha_url but not an auth page
           and (v.uri .. "/"):match("^" .. ha_url_base .. "/") -- Note ha_url was stripped of trailing slashes
           and not v.uri:match("^" .. ha_url_base .. "/auth/") then

            local js_settings = string.format([[
                try {
                    // Set browser_mod browser ID to "haos_kiosk"
                    localStorage.setItem('browser_mod-browser-id', 'haos_kiosk');

                    // Set sidebar visibility
                    const sidebar = '%s';
                    const currentSidebar = localStorage.getItem('dockedSidebar') || '';

                    if (sidebar !== currentSidebar) {
                        if (sidebar !== "") {
                            localStorage.setItem('dockedSidebar', sidebar);
                        } else {
                            localStorage.removeItem('dockedSidebar');
                        }
                    }

                    // Set theme if specified
                    const theme = '%s';
                    const currentTheme = localStorage.getItem('selectedTheme') || '';

                    if (theme !== currentTheme) {
                        if (theme !== "") {
                            localStorage.setItem('selectedTheme', theme);
                        } else {
                            localStorage.removeItem('selectedTheme');
                        }
                    }
//                    console.log("Setting sidebar: " + currentSidebar + " -> " + sidebar + " [Result=" + localStorage.getItem('dockedSidebar') +
//		                "]; theme: " + currentTheme + " -> " + theme + " [Result=" + localStorage.getItem('selectedTheme') + "]"); // DEBUG

//                  localStorage.setItem('DebugLog', "Setting sidebar: " + currentSidebar + " -> " + sidebar + " [Result=" + localStorage.getItem('dockedSidebar') +
//		                                     "]; theme: " + currentTheme + " -> " + theme + "[Result=" + localStorage.getItem('selectedTheme') + "]"); // DEBUG
                } catch (err) {
                    console.error(err);
                    console.log("FAILED to set: Sidebar: " + sidebar + "  Theme: " + theme + " [" + err + "]"); // DEBUG
                    localStorage.setItem('DebugLog', "FAILED to set: Sidebar: " + sidebar + "  Theme: " + theme); // DEBUG
                }
            ]], single_quote_escape(sidebar), single_quote_escape(theme))

            v:eval_js(js_settings, { source = "ha_settings.js", no_return = true })
            msg.info("Applying HA settings on dashboard %s: theme=%s sidebar=%s", v.uri, theme, sidebar) -- DEBUG

            ha_settings_applied[v] = true   -- Mark in Lua session as settings applied
        end

        -- Suppress known harmless unhandled promise rejections in kiosk environment
        --   - Service worker / script load failures during reloads
        --   - View transition errors when monitor/document is hidden (common when screen off)
        -- Prevents page aborts/504s while keeping real errors visible
        local js_suppress_errors = [[
            window.addEventListener('unhandledrejection', function(e) {
                const reason = e.reason;
                let suppress = false;

                if (reason) {
                    const msg = typeof reason.message === 'string' ? reason.message : '';
                    const name = (reason.name || '').toLowerCase();

                    if (msg.includes('sw-modern.js') ||
                        msg.includes('load failed') ||
                        msg.includes('service worker') ||
                        name === 'invalidstateerror' &&
                            (msg.includes('document visibility state is hidden') ||
                             msg.includes('view transition')) ||
                        reason === '[object Object]' ||
                        msg === '' ||                    // Empty message common in HA reconnect bugs
                        typeof reason === 'object') {    // Catch generic objects
                        suppress = true;
                    }
                }

                if (suppress) {
                    console.warn('Suppressed known kiosk-safe unhandled rejection:', reason);
                    e.preventDefault(); // Prevent abort, potential load failure or error cascade
                }
            });
        ]]

        -- Inject suppress_errors script into the webview (once per load-finished)
        v:eval_js(js_suppress_errors, { source = "suppress_kiosk_errors.js", no_return = true })

        -- Add HA websocket recovery monitor and force reload if dead (common after reconnect failures)
        local js_ws_recovery = [[
            (function() {
                if (window.ha_ws_recovery_interval) return;  // Only once
                window.ha_ws_recovery_interval = setInterval(function() {
                    if (window.APP && window.APP.connection && !window.APP.connection.connected) {
                        console.warn('HA websocket dead >10s - forcing reload for recovery');
                        location.reload();
                    }
                }, 10000);  // Check every 10 seconds
            })();
        ]]

        -- Inject websocket recovery monitor script into the webview (once per load-finished)
        v:eval_js(js_ws_recovery, { source = "ws_recovery.js", no_return = true })

    end)

    -- If browser_refresh set, then refresh browser every browser_refresh seconds after page finished/loaded/reloaded
    if browser_refresh > 0 then

       -- Check page visibility and set per-view flag so can skip refreshing non-visible pages
        --[=[  COMMENT-OUT FOR NOW since kiosks typically have only a single visible page
        local page_visible = true  -- Per-view visibility (optimistic default to 'true')

        -- Inject JS on every load-finished
        view:add_signal("load-status", function(v, status)
            if status ~= "finished" then return end

            -- Evaluate document.visibilityState and update page_visible
            v:eval_js([[
                (function() {
                    return document.visibilityState;
                })();
            ]], {
                callback = function(state)
                    page_visible = (state == "visible")
                    msg.info("DEBUG: page visibility set to '%s': %s", state, v.uri) -- DEBUG
                end,
                error_callback = function(err)
                    msg.warn("ERROR: Couldn't determine page visibility: %s (%s)", v.uri, err)
                end,
            })
        end)
	]=]

	-- Refresh browser logic
        local refresh_timer = nil  -- Per-view refresh timer
        local hard_reload_count = 0
        local function reset_refresh_timer()
            if not view.uri or view.uri == "about:blank" then return end -- Invalid or blank URL

            if refresh_timer then  -- Refresh existing timer
                msg.info("Restarting refresh timer (%ds): %s", browser_refresh, view.uri)
		refresh_timer:stop()   -- Stop current countdown
		refresh_timer:start()  -- Restart from full interval
            else  -- Initialize new timer
                msg.info("Initializing refresh timer (%ds): %s", browser_refresh, view.uri)
                refresh_timer = timer { interval = browser_refresh * 1000 }
                refresh_timer:add_signal("timeout", function(t)
                    if not view.is_alive then
                        msg.info("DEBUG: Skipping reload - webview not alive [shouldn't happen]")
                        return
                    end

		    if not view.uri or view.uri == "about:blank" then return end

		    --[=[ COMMENT-OUT if not testing visibility
		    if not page_visible then
		        msg.info("Skipping reload - page not visible")
			return
                    end
		    ]=]

  		    hard_reload_count = hard_reload_count + 1
  		    local bypass_cache = (hard_reload_count % HARD_RELOAD_FREQ == 0)  -- Hard reload  every 10th
                    msg.info("RELOADING%s: %s", bypass_cache and " [HARD]" or "", view.uri)
       		    view:reload(bypass_cache)
                end)
                refresh_timer:start()
            end
        end

        -- Initial set refresh timer (in case already loaded)
        reset_refresh_timer()

        -- Start/restart on finished loads when URI is valid
        view:add_signal("load-status", function(v, status)
            if status ~= "finished" then return end
	    reset_refresh_timer()
        end)

        -- Also on manual reloads
        view:add_signal("reload", function()
            reset_refresh_timer()
        end)

        -- *** CLEANUP: Stop and delete refresh timer when this webview is destroyed ***
        view:add_signal("destroy", function()
            if refresh_timer then
                msg.info("DEBUG: Webview destroyed - stopping and discarding refresh timer")
                refresh_timer:stop()
                refresh_timer = nil  -- Allow garbage collection
            end
        end)

    end
end)
-- -----------------------------------------------------------------------
-- Tab and Window functions


-- Close window unless last window (to avoid quitting luakit)
local function close_win_not_last(w)
    if #luakit.windows > 1 then
        w:close_win()
    else
        msg.warn("WARNING: This is the last window — not closing.")
    end
end

-- -----------------------------------------------------------------------
-- Redefine <Esc> to 'new_escape_key' (e.g., Ctl+Alt+Esc>) to exit current mode and enter normal mode
--
modes.remove_binds({"passthrough"}, {"<Escape>"})

modes.add_binds("all", {   -- Add to all modes (note  modes other than 'passhtrough' still accept Escape too)
    {new_escape_key, "Switch to normal mode", function(w)
        w:set_prompt()
        w:set_mode() -- Use this if not redefining 'default_mode' since defaults to "normal"
     end },
})

-- Clear the command line when entering passthrough instead of typing '-- PASS THROUGH --'
modes.get_modes()["passthrough"].enter = function(w)
    w:set_prompt()            -- Clear the command line prompt
    w:set_input()             -- Activate the input field (e.g., URL bar or form)
    w.view.can_focus = true   -- Ensure the webview can receive focus
    w.view:focus()            -- Focus the webview for keyboard input
end

-- -----------------------------------------------------------------------
modes.add_binds("all", {
    -- Browser history and reload
    { "<Control-r>",                    "Reload page",                          function(w) w:reload() end },
    { "<Control-Left>",                 "Go back in the browser history",       function(w, m) w:back(m.count) end },
    { "<Control-Right>",                "Go forward in the browser history",    function(w, m) w:forward(m.count) end },

    -- New/Close tab and window
    { "<Control-Mod1-t>",               "Open new tab",                         function(w) w:new_tab() end },
    { "<Control-Mod1-Shift-t>",         "Close current tab",                    function(w) w:close_tab() end },
    { "<Control-Mod1-w>",               "Open new window",                      function() window.new() end },
--    { "<Control-Mod1-Shift-w>",         "Close current window",                 function(w) w:close_win() end },
    { "<Control-Mod1-Shift-w>",         "Close current window",                 function(w) close_win_not_last(w) end },

    -- Tab navigation
    { "<Control-Mod1-Left>",            "Go to previous tab",                  function(w) w:prev_tab() end },
    { "<Control-Mod1-Right>",           "Go to next tab",                      function(w) w:next_tab() end },

    -- Window navigation (Use Window manager bindings)
    -- Ctrl+Alt+Shift+Left (or Shift+Alt+Tab) for "Go to previous window"
    -- Ctrl+Alt+Sift+Right (or Alt+Tab) for "Go to next window"
})

-- -----------------------------------------------------------------------
