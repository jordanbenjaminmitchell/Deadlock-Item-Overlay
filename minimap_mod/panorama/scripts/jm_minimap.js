// Minimap Reminders by Jordan Mitchell
//
// Reads only what the HUD already shows (game clock, minimap icons) plus fixed
// spawn schedules. No game memory, no injection. Everything is drawn inside
// the minimap panel.
//
// Map positions for crate clusters, Urn pads, Rift bridges and power-ups come
// from Deadlock Labs (deadlocklabs.gg interactive map, "The Cursed Apple").
//
// Coordinates: (u, v) in 0..1 across the map, u = left to right with York on
// the left, v = top to bottom, as on the Hidden King minimap. The minimap
// panel is flipped as a whole for the other team, and this overlay is a child
// of it, so it flips with the map automatically.

(() => {
  "use strict";

  const BUILD_ID = "dev";
  const TAG = "[MinimapReminders]";
  const WARN_SECONDS = 20;     // countdowns appear this long before a spawn
  const MAX_ROWS = 6;
  const TICK = 0.25;           // seconds between updates
  const DEBUG = true;          // on-minimap status line while testing
  const DIAG = false;          // console dump of minimap classes (not needed now)

  // ---------- schedules (City Never Sleeps, build 6821) ----------
  const CAMP = {
    weak:   { name: "Small camp",  first: 120, respawn: 85 },
    medium: { name: "Medium camp", first: 300, respawn: 290 },
    large:  { name: "Large camp",  first: 480, respawn: 335 },
    vault:  { name: "Sinner's",    first: 480, respawn: 300 }
  };

  // Since City Never Sleeps the minimap paints camps onto a canvas instead of
  // icons, so their live state can't be read. Camps are tracked from the
  // schedule: up once spawned, and marked cleared when you stay at one for
  // CAMP_DWELL seconds (you most likely farmed it). Positions and names:
  // Deadlock Labs. [u, v, tier, name]; tier "vault" = Sinner's Sacrifice.
  const CAMPS = [
    [0.0699, 0.5, "large", "Docks"],
    [0.3457, 0.5586, "medium", "Haunted Lot Garage Down"],
    [0.1667, 0.5595, "weak", "Docks Authority"],
    [0.869, 0.6064, "medium", "Greenwich Chapel"],
    [0.9271, 0.5, "large", "Greenwich Gate"],
    [0.7202, 0.3266, "medium", "Theater Upstairs"],
    [0.7932, 0.4552, "weak", "Greenwich Club"],
    [0.1299, 0.4051, "medium", "Construction"],
    [0.2714, 0.5833, "large", "Basketball"],
    [0.2664, 0.5316, "medium", "Haunted Lot Bodega Down"],
    [0.7113, 0.4137, "large", "Theater Stage"],
    [0.6994, 0.4524, "medium", "Theater Down"],
    [0.2917, 0.381, "medium", "HQ"],
    [0.7083, 0.5893, "medium", "Nursery Downstairs"],
    [0.6801, 0.686, "large", "Chinatown Street"],
    [0.3363, 0.7039, "large", "Haunted Lot Warehouse"],
    [0.5893, 0.6622, "medium", "Chinatown Fish"],
    [0.2917, 0.6786, "medium", "Haunted Lot Storage"],
    [0.7649, 0.5804, "medium", "Greenwich Library Roof"],
    [0.2351, 0.4226, "medium", "HQ Roof"],
    [0.6458, 0.6808, "large", "Chinatown Bell"],
    [0.244, 0.6711, "medium", "SW Bodega Upstairs"],
    [0.7708, 0.3147, "medium", "NE Theater Upstairs"],
    [0.7932, 0.3973, "medium", "Greenwich Mansion Roof"],
    [0.2292, 0.6116, "medium", "Haunted Lot Roof"],
    [0.4397, 0.4568, "weak", "NW Utility South"],
    [0.5655, 0.5461, "weak", "SE Utility"],
    [0.6756, 0.4137, "medium", "Theater Stage"],
    [0.6112, 0.6298, "large", "Chinatown Alley"],
    [0.314, 0.5789, "medium", "Haunted Lot Alley"],
    [0.4107, 0.5402, "medium", "Dept Store"],
    [0.5908, 0.4613, "medium", "Oracle"],
    [0.099, 0.3017, "medium", "NW Bank"],
    [0.872, 0.7202, "medium", "SE Asylum"],
    [0.3869, 0.381, "medium", "Plaza Rink"],
    [0.3229, 0.3129, "large", "Plaza Corner"],
    [0.4613, 0.3185, "large", "Plaza Rink"],
    [0.3616, 0.381, "large", "Plaza Rink"],
    [0.6771, 0.3278, "medium", "Theater Lobby"],
    [0.6548, 0.3274, "medium", "Theater Upstairs"],
    [0.651, 0.5878, "vault", "Chinatown Bell"],
    [0.3482, 0.5744, "vault", "Haunted Lot Garage Up"],
    [0.6935, 0.3705, "vault", "Theater Balcony"],
    [0.6027, 0.5446, "vault", "Drug Store"],
    [0.3968, 0.4524, "vault", "Hotel"],
    [0.7693, 0.558, "vault", "Greenwich Library"],
    [0.2336, 0.4435, "vault", "York Radio"],
    [0.2247, 0.5551, "vault", "Docks Authority"],
    [0.7749, 0.4373, "vault", "Greenwich Club"],
    [0.3988, 0.3586, "vault", "Plaza Pit"],
    [0.3988, 0.4033, "vault", "Plaza Pit"]
  ];
  const CAMP_RADIUS = 0.022;   // map units: "standing at the camp"
  const CAMP_DWELL = 5;        // seconds at a live camp before it counts as cleared

  const BUFF_FIRST = 300, BUFF_EVERY = 300;          // power-ups on the bridges
  const URN_FIRST = 600, URN_EVERY = 300;            // Soul Urn, sides alternate
  const RIFT_EARLIEST = 600, RIFT_LATEST = 720;      // first Rift 11:00 +/- 1:00
  const RIFT_GAP_MIN = 360, RIFT_GAP_MAX = 480;      // then 7:00 +/- 1:00

  // Crate respawn after a group is cleared: street 3:00, tunnel 5:00,
  // Bell Tower / Plaza pit 3:00, above Mid Boss 3:00.
  const CRATE_GROUP = {
    s: { first: 180, respawn: 180 },
    t: { first: 300, respawn: 300 },
    l: { first: 300, respawn: 180 },
    m: { first: 600, respawn: 180 }
  };
  const CRATE_VISIT_RADIUS = 0.03; // in map units; walking this close = assume looted

  // [u, v, group, items, tough crates]  (Deadlock Labs, grouped within 3.5% of map width)
  const CRATES = [[0.515,0.682,"s",10,0],[0.394,0.579,"s",7,0],[0.45,0.615,"s",6,0],[0.56,0.578,"s",6,1],[0.525,0.623,"s",6,1],[0.489,0.572,"t",10,0],[0.551,0.385,"s",6,0],[0.48,0.32,"s",12,0],[0.642,0.383,"s",11,0],[0.449,0.418,"s",5,0],[0.594,0.42,"s",5,0],[0.475,0.377,"s",6,1],[0.497,0.43,"t",6,0],[0.624,0.555,"t",4,0],[0.673,0.536,"s",7,1],[0.563,0.574,"t",4,0],[0.32,0.455,"s",12,2],[0.65,0.679,"s",5,0],[0.626,0.61,"s",7,0],[0.688,0.578,"s",4,1],[0.705,0.648,"s",5,1],[0.586,0.618,"s",5,0],[0.58,0.723,"s",5,1],[0.636,0.737,"s",9,1],[0.641,0.566,"s",4,0],[0.492,0.504,"m",10,2],[0.524,0.505,"m",4,3],[0.728,0.593,"s",13,0],[0.778,0.55,"s",5,0],[0.914,0.453,"s",5,1],[0.784,0.472,"s",4,1],[0.8,0.422,"s",4,0],[0.786,0.379,"s",8,1],[0.741,0.418,"s",12,1],[0.736,0.352,"s",8,2],[0.626,0.446,"t",4,0],[0.328,0.558,"t",7,0],[0.222,0.575,"t",5,0],[0.286,0.677,"s",10,2],[0.352,0.615,"s",16,3],[0.293,0.612,"s",7,0],[0.263,0.544,"s",11,2],[0.246,0.632,"s",7,1],[0.222,0.603,"s",6,0],[0.327,0.522,"s",8,1],[0.304,0.564,"s",4,0],[0.683,0.38,"s",10,0],[0.709,0.46,"s",10,0],[0.711,0.312,"s",8,2],[0.666,0.447,"s",5,1],[0.672,0.33,"s",5,0],[0.613,0.302,"s",4,0],[0.33,0.381,"s",4,0],[0.428,0.272,"s",6,1],[0.374,0.353,"l",4,2],[0.273,0.335,"s",10,0],[0.365,0.409,"l",6,2],[0.423,0.325,"s",5,1],[0.269,0.412,"s",10,1],[0.139,0.395,"s",7,0],[0.087,0.553,"s",4,0],[0.788,0.227,"s",5,0],[0.855,0.678,"s",6,0],[0.902,0.692,"s",5,0],[0.735,0.778,"s",7,1],[0.242,0.759,"s",5,0],[0.181,0.768,"s",4,1],[0.149,0.286,"s",6,0],[0.286,0.212,"s",5,1],[0.328,0.259,"s",6,1],[0.368,0.267,"s",9,0]];

  // Fixed spots (Deadlock Labs). Mirrors are through the map center.
  const MID_BOSS = [0.4999, 0.5];
  const BUFF_SPOTS = [[0.317, 0.4937], [0.683, 0.5063]];
  const URN_SPOTS = [[0.1935, 0.5004], [0.7932, 0.5045]];
  const RIFT_SPOTS = [[0.0893, 0.5], [0.9107, 0.5]];

  // ---------- small helpers ----------
  const ok = (p) => !!(p && p.IsValid && p.IsValid());
  const log = (m) => { try { $.Msg(TAG + " " + m); } catch (e) {} };

  function fmt(sec) {
    sec = Math.max(0, Math.ceil(sec));
    const m = Math.floor(sec / 60), s = sec % 60;
    return m + ":" + (s < 10 ? "0" : "") + s;
  }

  function parseClock(text) {
    if (!text) return -1;
    const m = String(text).match(/(\d+):(\d\d)/);
    return m ? parseInt(m[1], 10) * 60 + parseInt(m[2], 10) : -1;
  }

  // Rough place names from map position (Hidden King orientation).
  function placeName(u, v) {
    if (Math.abs(u - 0.5) < 0.07) return Math.abs(v - 0.5) < 0.08 ? "Mid" : "Broadway";
    if (u < 0.2) return "York";
    if (u > 0.8) return "Greenwich";
    if (u < 0.5) return v < 0.5 ? "Plaza" : "Haunted Lot";
    return v < 0.5 ? "Theater" : "Chinatown";
  }
  const sideName = (u) => (u < 0.5 ? "York" : "Greenwich");

  // ---------- panels ----------
  const mm = $.GetContextPanel();   // the HudMinimap panel this layout builds
  let root = null, clockLabel = null;
  let layer = null, timers = null, nearestRing = null, vaultRing = null, meRing = null;
  const arrows = {};   // camp, vault, crate, buff, urn, rift
  const crateDots = [], spotDots = {}, ghosts = [];

  function findRoot() {
    let p = mm;
    while (p && p.GetParent && p.GetParent()) p = p.GetParent();
    return p;
  }

  function gameTime() {
    if (!ok(clockLabel)) {
      clockLabel = null;
      if (!ok(root)) root = findRoot();
      try {
        const bar = root && root.FindChildTraverse("TopBar");
        const found = bar ? bar.FindChildrenWithClassTraverse("GameTime") : null;
        if (found && found.length) clockLabel = found[0];
        if (!clockLabel && root) clockLabel = root.FindChildTraverse("GameTime");
      } catch (e) {}
    }
    return ok(clockLabel) ? parseClock(clockLabel.text) : -1;
  }

  function makePanel(type, parent, id, cls) {
    const p = $.CreatePanel(type, parent, id || "");
    p.hittest = false;
    p.hittestchildren = false;
    if (cls) for (const c of cls.split(" ")) p.AddClass(c);
    return p;
  }

  function ensureLayer() {
    if (ok(layer)) return true;
    if (!ok(mm)) return false;
    try {
      layer = mm.FindChildTraverse("JMLayer");
      if (!ok(layer)) layer = makePanel("Panel", mm, "JMLayer");
      for (let i = 0; i < CRATES.length; i++) {
        const c = CRATES[i];
        crateDots[i] = makePanel("Panel", layer, "JMCrate" + i, "jm_crate" + (c[3] + 2 * c[4] >= 10 ? " jm_big" : ""));
      }
      for (const key of ["buff0", "buff1", "urn0", "urn1", "rift0", "rift1"]) {
        spotDots[key] = makePanel("Panel", layer, "JMSpot_" + key, "jm_spot");
      }
      for (let i = 0; i < 8; i++) {
        const gp = makePanel("Panel", layer, "JMGhost" + i, "jm_ghost");
        ghosts.push({ panel: gp, label: makePanel("Label", gp, "", "jm_ghost_time") });
      }
      meRing = makePanel("Panel", layer, "JMMe", "jm_me");
      nearestRing = makePanel("Panel", layer, "JMNearest", "jm_nearest");
      vaultRing = makePanel("Panel", layer, "JMNearestVault", "jm_nearest jm_vault");
      for (const key of ["shop", "crate", "buff", "camp", "vault", "urn", "rift", "mid", "deliver"]) {
        arrows[key] = makePanel("Panel", layer, "JMArrow_" + key, "jm_arrow jm_arrow_" + key);
        makePanel("Panel", arrows[key], "", "jm_head");
      }
      timers = makePanel("Panel", mm, "JMTimers");
      log("loaded build " + BUILD_ID);
      return true;
    } catch (e) {
      log("layer error " + e);
      layer = null;
      return false;
    }
  }

  // ---------- reading the minimap ----------
  function size() {
    const w = Number(mm.actuallayoutwidth) || 0, h = Number(mm.actuallayoutheight) || 0;
    return w > 0 && h > 0 ? { w, h } : null;
  }

  function center(btn) {
    const x = Number(btn.actualxoffset), y = Number(btn.actualyoffset);
    // Hidden markers report a placeholder offset (around 3e38): treat those as "not on the map".
    if (!isFinite(x) || !isFinite(y) || Math.abs(x) > 100000 || Math.abs(y) > 100000) return null;
    return { x: x + (Number(btn.actuallayoutwidth) || 0) / 2, y: y + (Number(btn.actuallayoutheight) || 0) / 2 };
  }

  function scan() {
    let buttons = [];
    try { buttons = mm.FindChildrenWithClassTraverse("map_button") || []; } catch (e) {}
    const out = { player: null, midBoss: null, midUp: false, buffs: [], rift: null, riftWarning: false, urn: null,
                  urnReturn: null, holdingUrn: false, shops: [], enemies: [] };
    let ei = 0;
    for (const b of buttons) {
      if (!ok(b)) continue;
      const pos = center(b);
      if (!pos) continue;
      if (b.BHasClass("localplayer")) {
        out.player = pos;
        out.holdingUrn = b.BHasClass("holding_idol") || b.BHasClass("PlayerIsHoldingIdol");
        continue;
      }
      const hidden = b.visible === false;   // only trusted for markers that come and go (Rift, Urn)
      if (b.BHasClass("player") && b.BHasClass("enemy")) {
        const shown = b.visible !== false && !b.BHasClass("hide_button") && (Number(b.actuallayoutwidth) || 0) > 0;
        if (b.BHasClass("is_visible")) usesIsVisible = true;
        out.enemies.push({ key: b.id || ("enemy" + ei), pos, seen: shown && (!usesIsVisible || b.BHasClass("is_visible")),
                           dead: b.BHasClass("PlayerDead") });
        ei++;
        continue;
      }
      if (b.BHasClass("mid_boss")) {
        out.midBoss = pos;
        // Only the Mid-Boss marker's own state counts (the minimap-wide class showed "up" at 2:00).
        out.midUp = b.BHasClass("midboss_spawned") && !b.BHasClass("midboss_timer");
        out.midCls = MID_CLASSES.filter((c) => b.BHasClass(c)).join(",");
        continue;
      }
      if (b.BHasClass("idol_return_friendly") || (b.BHasClass("idol_return") && b.BHasClass("friend"))) { if (!hidden) out.urnReturn = pos; continue; }
      // Shops: only your team's (enemy shops won't sell to you).
      if (b.BHasClass("shop") && !b.BHasClass("shop_tunnel_exit")) {
        if (!b.BHasClass("enemy")) out.shops.push({ x: pos.x, y: pos.y, friend: b.BHasClass("friend") });
        continue;
      }
      if (b.BHasClass("bridge_buff") || b.BHasClass("powerup_spawn")) { out.buffs.push(pos); continue; }
      if (b.BHasClass("capture_point")) { if (!hidden) { out.rift = pos; out.riftWarning = b.BHasClass("koth_warning"); } continue; }
      if (b.BHasClass("idol_spawn")) { if (!hidden) out.urn = pos; continue; }
    }
    try {
      if (!out.holdingUrn && (mm.BHasClass("PlayerIsHoldingIdol") || (root && root.BHasClass("PlayerIsHoldingIdol")))) out.holdingUrn = true;
    } catch (e) {}
    return out;
  }
  let usesIsVisible = false;
  // Classes to report from the Mid-Boss marker, to learn its states (not spawned / soon / up).
  const MID_CLASSES = ["midboss_spawned", "midboss_timer", "active", "boss", "is_visible", "hasActivateEvent", "idolPulse", "hide_button", "dead_button_image"];   // once any enemy icon carries is_visible, hidden enemies lack it

  // Mid-Boss respawn time as the game shows it (a "midboss_timer" label), in seconds; -1 if not shown.
  function midBossTimer() {
    try {
      if (!ok(root)) root = findRoot();
      const found = root ? root.FindChildrenWithClassTraverse("midboss_timer") : null;
      if (found) for (const p of found) {
        const txt = p.text !== undefined ? p.text : null;
        const v = parseClock(txt);
        if (v >= 0) return v;
      }
    } catch (e) {}
    return -1;
  }

  // Map (u, v) <-> minimap pixels. Calibrated live from icons whose map
  // position is known (Mid Boss, the two bridge power-ups), so zoom, pan and
  // resolution are handled. Falls back to "map fills the panel".
  let calib = null;
  function calibrate(s, dim) {
    const c = s.midBoss;
    let scale = null;
    if (s.buffs.length >= 2) {
      let best = 0;
      for (let i = 0; i < s.buffs.length; i++)
        for (let j = i + 1; j < s.buffs.length; j++) {
          const d = Math.hypot(s.buffs[i].x - s.buffs[j].x, s.buffs[i].y - s.buffs[j].y);
          if (d > best) best = d;
        }
      const mapD = Math.hypot(BUFF_SPOTS[0][0] - BUFF_SPOTS[1][0], BUFF_SPOTS[0][1] - BUFF_SPOTS[1][1]);
      if (best > 10) scale = best / mapD;
    }
    if (c && scale) {
      calib = { cx: c.x, cy: c.y, sx: scale, sy: scale, live: true };
    } else if (c && calib && calib.live) {
      calib = Object.assign({}, calib, { cx: c.x, cy: c.y });
    } else if (!calib || !calib.live) {
      calib = { cx: dim.w * MID_BOSS[0], cy: dim.h * MID_BOSS[1], sx: dim.w, sy: dim.h, live: false };
    }
  }
  const toPx = (u, v) => ({ x: calib.cx + (u - MID_BOSS[0]) * calib.sx, y: calib.cy + (v - MID_BOSS[1]) * calib.sy });
  const toMap = (p) => ({ u: MID_BOSS[0] + (p.x - calib.cx) / calib.sx, v: MID_BOSS[1] + (p.y - calib.cy) / calib.sy });

  function place(panel, px, dim) {
    panel.style.position = ((px.x / dim.w) * 100).toFixed(3) + "% " + ((px.y / dim.h) * 100).toFixed(3) + "% 0px";
  }
  function show(panel, on) {
    if (ok(panel)) panel.SetHasClass("jm_on", !!on);
  }

  // Arrow from your icon toward a target, stopping short of the target's ring.
  // Lengths are converted to % of the minimap width, like every other position here.
  const ARROW_GAP = 12;          // pixels left before the target (ring radius + a little)
  const ARROW_START = 13;        // pixels skipped at your end, so the arrow starts outside your hero icon
  function aim(arrow, from, to, dim) {
    if (!ok(arrow)) return;
    if (!from || !to) { show(arrow, false); return; }
    const dx = to.x - from.x, dy = to.y - from.y, len = Math.hypot(dx, dy);
    if (len < ARROW_GAP + ARROW_START + 8 || len > 3 * Math.max(dim.w, dim.h)) { show(arrow, false); return; }
    try {
      const start = { x: from.x + dx / len * ARROW_START, y: from.y + dy / len * ARROW_START };
      place(arrow, start, dim);
      // Panorama wants whole layout pixels here; actual pixels / UI scale = layout pixels.
      const sc = Number(mm.actualuiscale_x) || 1;
      arrow.style.width = Math.max(1, Math.round((len - ARROW_GAP - ARROW_START) / sc)) + "px";
      arrow.style.transform = "rotateZ(" + Math.round(Math.atan2(dy, dx) * 180 / Math.PI) + "deg)";
      show(arrow, true);
      shownNow[arrow.id] = true;
    } catch (e) {
      show(arrow, false);
      if (!arrowError) { arrowError = String(e); log("arrow error " + e); }
    }
  }
  let arrowError = "";
  let shownNow = {};   // arrow panel id -> drawn this tick (for the key)

  // Key: one row per arrow (or marker) on screen right now, top-right of the minimap.
  const KEY_ROWS = [
    ["JMArrow_camp", "jm_arrow_camp", "Camp"],
    ["JMArrow_vault", "jm_arrow_vault", "Sinner's Sacrifice"],
    ["JMArrow_crate", "jm_arrow_crate", "Crates"],
    ["JMArrow_buff", "jm_arrow_buff", "Power-up"],
    ["JMArrow_mid", "jm_arrow_mid", "Mid-Boss"],
    ["JMArrow_urn", "jm_arrow_urn", "Soul Urn"],
    ["JMArrow_deliver", "jm_arrow_deliver", "Deliver Urn"],
    ["JMArrow_rift", "jm_arrow_rift", "Rift"],
    ["JMArrow_shop", "jm_arrow_shop", "Shop"],
    ["ghost", "jm_key_ghost", "Last seen enemy"]
  ];
  let keyPanel = null;
  const keyRows = {};
  function renderKey() {
    if (!ok(keyPanel)) {
      keyPanel = makePanel("Panel", mm, "JMKey");
      for (const [id, cls, text] of KEY_ROWS) {
        const row = makePanel("Panel", keyPanel, "", "jm_key_row");
        makePanel("Panel", row, "", "jm_key_swatch " + cls);
        const lab = makePanel("Label", row, "", "jm_key_text");
        lab.text = text;
        keyRows[id] = row;
      }
    }
    for (const [id] of KEY_ROWS) if (ok(keyRows[id])) keyRows[id].visible = !!shownNow[id];
  }

  // ---------- state ----------
  let lastT = -1;
  const campCleared = [];    // index -> game time we think it was cleared
  const campDwell = [];      // index -> game time you arrived at it
  const crateLooted = [];    // index -> game time the player passed through
  const buffTaken = [];      // bridge index -> game time you stood at it
  const lastSeen = {};       // enemy key -> { pos, t } where and when the minimap last showed them
  const GHOST_SECONDS = 45;  // how long a last-seen marker stays
  let riftLast = -1;         // game time the last Rift opened
  let riftWasUp = false;
  let riftWarnAt = -1;       // game time the minimap warning first appeared

  function resetMatch() {
    campCleared.length = 0;
    campDwell.length = 0;
    crateLooted.length = 0;
    buffTaken.length = 0;
    for (const k of Object.keys(lastSeen)) delete lastSeen[k];
    usesIsVisible = false;
    riftLast = -1;
    riftWasUp = false;
    riftWarnAt = -1;
    calib = null;
  }


  // ---------- diagnostics: which minimap classes exist right now ----------
  const DIAG_CLASSES = ["Frog", "HideOldZiplines", "HudMinimap", "MediumNeutralCamp", "NeutralCampImage", "NewMinimapBackgroundsContainer", "PlayerDead", "PlayerIsHoldingIdol", "PlayerIsSpeaking", "ShowNewMinimap", "SmallNeutralCamp", "StrongNeutralCamp", "active", "ammo", "arrowDown", "arrowLow", "arrowUp", "backgroundImage1", "backgroundImage2", "backgroundImage3", "blueLane", "bookworm_knight", "boss", "boss_barracks_icon", "boss_buildingzip", "boss_health", "boss_health_bg", "boss_health_bg_s2", "boss_health_s2", "boss_icon_t1", "boss_icon_t2", "boss_icon_t3", "boss_image", "button_fill", "button_image", "canPurchaseItem", "capture_point", "chesspiece_bishop", "chesspiece_pawn", "chesspiece_queen", "client_cone_fov", "connectedToHeroTesting", "corrupted_item_shop", "dead_button_image", "dl_midtown", "doorman_doorway", "enemy", "enlarge_entry", "escort", "favor_enemy_team", "favor_player_team", "forceShowMinimap", "friend", "gDetailView", "gScoreboardOpen", "github", "gold_dropping", "gold_spawn", "greenLane", "guided_arrow", "hasActivateEvent", "held_idol_image", "hero_button_image", "hide_button", "holding_idol", "hover_panel", "hover_panel_accurate", "idolFavorPreview", "idolPulse", "idolReturnTarget", "idol_dropping", "idol_return", "idol_return_enemy", "idol_return_friendly", "idol_return_snippet", "idol_spawn", "in_tunnels", "invert_map", "io", "isDefaultMap", "isDetailView", "is_underground", "is_visible", "koth_warning", "localplayer", "lowHealth", "map_button", "map_targeting", "midImage", "mid_boss", "mid_stairs", "midboss_spawned", "midboss_timer", "modifier_state_no_minimap", "necro_gravestone", "necro_skele", "neutral", "neutral_large", "neutral_medium", "neutral_spawn", "neutral_vault", "neutral_weak", "npc", "nurse_leech", "outpost", "pingIdol1", "pingIdol2", "pingIdol3", "ping_panel", "player", "playerWasClamped", "powerup_casting", "powerup_gun", "powerup_movement", "powerup_souls", "powerup_spawn", "powerup_survival", "precache", "purpleLane", "rejuv_crystal", "right_stairs", "shop", "shop_tunnel_exit", "showHitBox", "speaking_button_image", "spectate", "standup", "team1", "team2", "teleport_target", "teleporter_active", "teleporter_far", "teleporter_nearby", "teleporter_off", "teleporter_onRight", "tier1_shop", "trigger_secure_souls", "useZoomedMinimap", "yellowLane", "zipline_target", "zoomLevel", "zoomLevel0", "zoomLevel1", "zoomLevel10", "zoomLevel11", "zoomLevel2", "zoomLevel3", "zoomLevel4", "zoomLevel6", "zoomLevel7", "zoomLevel8", "zoomLevel9"];
  let lastDiag = -999;
  function diagnose(t) {
    if (!DIAG || t - lastDiag < 60) return;
    lastDiag = t;
    const parts = [];
    for (const c of DIAG_CLASSES) {
      let n = 0;
      try { n = (mm.FindChildrenWithClassTraverse(c) || []).length; } catch (e) {}
      if (n > 0) parts.push(c + "=" + n);
    }
    let kids = 0;
    try { kids = mm.GetChildCount(); } catch (e) {}
    log("diag " + fmt(t) + " children=" + kids);
    for (let i = 0; i < parts.length; i += 8) log("diag " + parts.slice(i, i + 8).join(" "));
    // Panel types and ids of direct children, to spot camp icons that use other names
    const types = {};
    try {
      for (let i = 0; i < kids; i++) {
        const ch = mm.GetChild(i);
        const key = (ch.paneltype || "?") + "#" + (ch.id || "");
        types[key] = (types[key] || 0) + 1;
      }
    } catch (e) {}
    const tk = Object.keys(types).map((k) => k + "=" + types[k]);
    for (let i = 0; i < tk.length; i += 8) log("diag kids " + tk.slice(i, i + 8).join(" "));
  }

  // ---------- one update ----------
  function tick() {
    $.Schedule(TICK, tick);
    try { update(); } catch (e) { log("tick error " + e); debug("ERROR " + e); }
  }

  let debugLabel = null;
  function debug(text) {
    if (!DEBUG) return;
    try {
      if (!ok(debugLabel)) debugLabel = mm.FindChildTraverse("JMDebug");
      if (ok(debugLabel)) debugLabel.text = "MR " + BUILD_ID + ": " + text;
    } catch (e) {}
  }

  // Only the normal match map has camps, crates, Urn and Rift. Street Brawl
  // (one lane, rounds that restart the clock) and the Hideout get nothing.
  const OFF_CLASSES = ["gamemode_streetbrawl", "gStreetBrawl", "connectedToHideout", "InHideout"];
  function offReason() {
    let p = mm;
    while (p && p.IsValid && p.IsValid()) {
      for (const c of OFF_CLASSES) {
        try { if (p.BHasClass(c)) return c; } catch (e) {}
      }
      p = p.GetParent ? p.GetParent() : null;
    }
    return null;
  }

  function update() {
    if (!ensureLayer()) { debug("could not create overlay layer"); return; }
    const off = offReason();
    if (off) {
      layer.visible = false; if (ok(timers)) timers.visible = false; if (ok(keyPanel)) keyPanel.visible = false;
      lastT = -1; resetMatch();
      debug("off (" + off + ")");
      return;
    }
    const dim = size();
    const t = gameTime();
    if (!dim || t < 0) {
      debug("waiting: size " + (dim ? dim.w + "x" + dim.h : "none") + ", clock " + (ok(clockLabel) ? "'" + clockLabel.text + "'" : "not found"));
      layer.visible = false; if (ok(timers)) timers.visible = false; return;
    }
    layer.visible = true;
    timers.visible = true;
    if (ok(keyPanel)) keyPanel.visible = true;
    if (t + 5 < lastT) resetMatch(); // clock went backwards: new match
    lastT = t;

    diagnose(t);
    shownNow = {};
    const s = scan();
    calibrate(s, dim);
    const rows = [];

    // 1) camps: schedule + "you stood there" clears, nearest live camp and nearest Sinner's Sacrifice
    const me = s.player ? toMap(s.player) : null;
    let nearest = -1, nearestD = Infinity, nearName = "";
    let nearV = -1, nearVD = Infinity;
    for (let i = 0; i < CAMPS.length; i++) {
      const c = CAMPS[i], info = CAMP[c[2]];
      const cleared = campCleared[i];
      const back = cleared === undefined ? info.first : cleared + info.respawn;
      const up = t >= back;
      if (me) {
        const d = Math.hypot(me.u - c[0], me.v - c[1]);
        if (up && d < CAMP_RADIUS) {
          if (campDwell[i] === undefined) campDwell[i] = t;
          else if (t - campDwell[i] >= CAMP_DWELL) { campCleared[i] = t; campDwell[i] = undefined; }
        } else {
          campDwell[i] = undefined;
        }
        if (up && c[2] === "vault") { if (d < nearVD) { nearVD = d; nearV = i; } }
        else if (up && d < nearestD) { nearestD = d; nearest = i; }
      }
      if (cleared !== undefined) {
        const due = back - t;
        if (due > 0 && due <= WARN_SECONDS) rows.push({ due, cls: "jm_camp", text: info.name + " \u00b7 " + c[3] });
      }
    }
    if (nearest >= 0) {
      place(nearestRing, toPx(CAMPS[nearest][0], CAMPS[nearest][1]), dim);
      nearName = CAMP[CAMPS[nearest][2]].name + " " + CAMPS[nearest][3];
    }
    show(nearestRing, nearest >= 0);
    if (nearV >= 0) place(vaultRing, toPx(CAMPS[nearV][0], CAMPS[nearV][1]), dim);
    show(vaultRing, nearV >= 0);
    // Arrows from your icon: blue to the nearest camp, pink to the nearest Sinner's Sacrifice.
    aim(arrows.camp, s.player, nearest >= 0 ? toPx(CAMPS[nearest][0], CAMPS[nearest][1]) : null, dim);
    aim(arrows.vault, s.player, nearV >= 0 ? toPx(CAMPS[nearV][0], CAMPS[nearV][1]) : null, dim);

    // first camp spawns (all camps of a size at once)
    const firsts = [["weak", "Small camps"], ["medium", "Medium camps"], ["large", "Large camps + Sinner's"]];
    for (const [type, label] of firsts) {
      const due = CAMP[type].first - t;
      if (due > 0 && due <= WARN_SECONDS) rows.push({ due, cls: "jm_camp", text: label + " · all" });
    }

    // 2) crate clusters: glow once spawned, hide after you walk through, back on respawn
    const pm = me;
    let nearC = -1, nearCD = Infinity;
    for (let i = 0; i < CRATES.length; i++) {
      const c = CRATES[i], g = CRATE_GROUP[c[2]];
      if (pm && t >= g.first && Math.hypot(pm.u - c[0], pm.v - c[1]) < CRATE_VISIT_RADIUS) crateLooted[i] = t;
      const looted = crateLooted[i] !== undefined && t - crateLooted[i] < g.respawn;
      if (ok(crateDots[i])) {
        place(crateDots[i], toPx(c[0], c[1]), dim);
        show(crateDots[i], t >= g.first && !looted);
      }
      if (pm && t >= g.first && !looted) {
        const d = Math.hypot(pm.u - c[0], pm.v - c[1]);
        if (d < nearCD) { nearCD = d; nearC = i; }
      }
    }

    aim(arrows.crate, s.player, nearC >= 0 ? toPx(CRATES[nearC][0], CRATES[nearC][1]) : null, dim);

    // 3) power-ups on the bridges: 5:00 and every 5:00
    const buffDue = t < BUFF_FIRST ? BUFF_FIRST - t : BUFF_EVERY - ((t - BUFF_FIRST) % BUFF_EVERY);
    const buffSoon = buffDue > 0 && buffDue <= WARN_SECONDS;
    if (buffSoon) rows.push({ due: buffDue, cls: "jm_buff", text: "Power-ups · both bridges" });
    BUFF_SPOTS.forEach((p, i) => { place(spotDots["buff" + i], toPx(p[0], p[1]), dim); show(spotDots["buff" + i], buffSoon); });
    // Arrow to the nearest power-up from each spawn until you have stood at that bridge.
    const buffSpawn = t < BUFF_FIRST ? -1 : BUFF_FIRST + Math.floor((t - BUFF_FIRST) / BUFF_EVERY) * BUFF_EVERY;
    let nearB = -1, nearBD = Infinity;
    BUFF_SPOTS.forEach((p, i) => {
      if (buffSpawn < 0) return;
      if (me && Math.hypot(me.u - p[0], me.v - p[1]) < CRATE_VISIT_RADIUS) buffTaken[i] = t;
      if (buffTaken[i] !== undefined && buffTaken[i] >= buffSpawn) return;
      const d = me ? Math.hypot(me.u - p[0], me.v - p[1]) : Infinity;
      if (d < nearBD) { nearBD = d; nearB = i; }
    });
    aim(arrows.buff, s.player, nearB >= 0 ? toPx(BUFF_SPOTS[nearB][0], BUFF_SPOTS[nearB][1]) : null, dim);

    // 4) Soul Urn: 10:00 and every 5:00. Actual pad once the icon shows.
    const urnDue = t < URN_FIRST ? URN_FIRST - t : URN_EVERY - ((t - URN_FIRST) % URN_EVERY);
    const urnSoon = urnDue > 0 && urnDue <= WARN_SECONDS;
    let urnText = "Soul Urn · York or Greenwich pad";
    let urnActual = null;
    if (s.urn) { urnActual = toMap(s.urn); urnText = "Soul Urn · " + sideName(urnActual.u) + " pad"; }
    aim(arrows.urn, s.player, s.urn, dim);
    if (urnSoon) rows.push({ due: urnDue, cls: "jm_urn", text: urnText });
    URN_SPOTS.forEach((p, i) => {
      const d = spotDots["urn" + i];
      place(d, toPx(p[0], p[1]), dim);
      const isActual = !!urnActual && Math.abs(urnActual.u - p[0]) < 0.1;
      d.SetHasClass("jm_actual", isActual);
      show(d, urnSoon && (!urnActual || isActual));
    });

    // 5) Unstable Rift: window from the schedule, exact once the game warns
    const riftUp = !!s.rift && !s.riftWarning;
    if (riftUp && !riftWasUp) riftLast = t;
    riftWasUp = riftUp;
    let riftRow = null, riftActual = null;
    if (s.rift && s.riftWarning) {
      if (riftWarnAt < 0) riftWarnAt = t;
      riftActual = toMap(s.rift);
      riftRow = { due: Math.max(0, riftWarnAt + WARN_SECONDS - t), cls: "jm_rift", text: "Rift · " + sideName(riftActual.u) + " bridge" };
    } else {
      riftWarnAt = -1;
    }
    if (!s.rift) {
      const lo = riftLast < 0 ? RIFT_EARLIEST : riftLast + RIFT_GAP_MIN;
      const hi = riftLast < 0 ? RIFT_LATEST : riftLast + RIFT_GAP_MAX;
      if (t >= lo - WARN_SECONDS && t <= hi) {
        riftRow = { due: Math.max(0, lo - t), cls: "jm_rift", text: "Rift window · until " + fmt(hi), window: true };
      }
    }
    if (riftRow) rows.push(riftRow);
    aim(arrows.rift, s.player, s.rift, dim);
    RIFT_SPOTS.forEach((p, i) => {
      const d = spotDots["rift" + i];
      place(d, toPx(p[0], p[1]), dim);
      const isActual = !!riftActual && Math.abs(riftActual.u - p[0]) < 0.1;
      d.SetHasClass("jm_actual", isActual);
      show(d, !!riftRow && (!riftActual || isActual));
    });

    // A thin white ring around your own icon, so the arrows clearly start from you.
    if (s.player) place(meRing, s.player, dim);
    show(meRing, !!s.player);

    // 6) Soul Urn delivery: while you carry it, arrow to your team's drop-off.
    aim(arrows.deliver, s.player, s.holdingUrn ? s.urnReturn : null, dim);

    // 7) Mid-Boss: arrow while it is up; countdown from the game's own respawn timer when shown.
    aim(arrows.mid, s.player, s.midUp ? s.midBoss : null, dim);
    const midT = s.midUp ? -1 : midBossTimer();
    if (midT > 0 && midT <= 60) rows.push({ due: midT, cls: "jm_mid", text: "Mid-Boss" });

    // 8) Nearest shop: always a faint arrow.
    let shop = null, shopD = Infinity;
    // If any shop is marked friendly, use only those; otherwise all shops not marked enemy.
    const anyFriend = s.shops.some((p) => p.friend);
    if (s.player) for (const p of s.shops) {
      if (anyFriend && !p.friend) continue;
      const d = Math.hypot(p.x - s.player.x, p.y - s.player.y);
      if (d < shopD) { shopD = d; shop = p; }
    }
    aim(arrows.shop, s.player, shop, dim);

    // 9) Last-seen enemies: a faded marker where an enemy dropped off the minimap, with seconds since.
    // (an icon that is hidden or removed both count as "not seen now")
    for (const key of Object.keys(lastSeen)) lastSeen[key].seenNow = false;
    for (const e of s.enemies) {
      if (e.dead) { delete lastSeen[e.key]; continue; }
      if (e.seen) lastSeen[e.key] = { pos: e.pos, t, seenNow: true };
    }
    let gi = 0;
    for (const key of Object.keys(lastSeen)) {
      const ls = lastSeen[key];
      const age = t - ls.t;
      if (ls.seenNow || age > GHOST_SECONDS) { if (age > GHOST_SECONDS) delete lastSeen[key]; continue; }
      if (gi >= ghosts.length) break;
      const g = ghosts[gi++];
      place(g.panel, ls.pos, dim);
      g.label.text = Math.max(1, Math.round(age)) + "s";
      g.panel.style.opacity = (0.95 - 0.6 * age / GHOST_SECONDS).toFixed(2);
      show(g.panel, true);
      shownNow.ghost = true;
    }
    for (; gi < ghosts.length; gi++) show(ghosts[gi].panel, false);

    render(rows);
    renderKey();
    debug(fmt(t) + " | me " + (me ? me.u.toFixed(3) + "," + me.v.toFixed(3) : "NO") +
      " | near " + (nearName || "-") + " | sinner " + (nearV >= 0 ? CAMPS[nearV][3] : "-") +
      " | calib " + (calib.live ? "live" : "fallback") + " | rows " + rows.length +
      " | enemies " + s.enemies.length + (usesIsVisible ? "v" : "") + " shops " + s.shops.length + (s.shops.some((p) => p.friend) ? "f" : "") +
      " | mid " + (s.midUp ? "up" : (midT >= 0 ? fmt(midT) : "-")) + " [" + (s.midCls || "") + "]" + " | urn " + (s.holdingUrn ? "HELD" : "-") + (s.urnReturn ? "+ret" : "") +
      (arrowError ? " | ARROW " + arrowError : ""));
  }

  // ---------- countdown stack ----------
  const rowPanels = [];
  function render(rows) {
    rows.sort((a, b) => a.due - b.due);
    rows.length = Math.min(rows.length, MAX_ROWS);
    for (let i = 0; i < MAX_ROWS; i++) {
      let r = rowPanels[i];
      if (!r || !ok(r.panel)) {
        const panel = makePanel("Panel", timers, "JMRow" + i, "jm_row");
        r = rowPanels[i] = {
          panel,
          time: makePanel("Label", panel, "", "jm_time"),
          text: makePanel("Label", panel, "", "jm_text"),
          cls: ""
        };
      }
      const row = rows[i];
      r.panel.visible = !!row;
      if (!row) continue;
      if (r.cls !== row.cls) {
        if (r.cls) r.panel.RemoveClass(r.cls);
        r.panel.AddClass(row.cls);
        r.cls = row.cls;
      }
      r.panel.SetHasClass("jm_now", !!row.window && row.due <= 0);
      r.time.text = row.window && row.due <= 0 ? "NOW?" : fmt(row.due);
      r.text.text = row.text;
    }
  }

  debug("script started");
  tick();
})();
