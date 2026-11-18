# Minimap Reminders

A Deadlock HUD mod by **Jordan Mitchell**. It only touches the minimap, and only uses what the HUD already shows (the game clock and minimap icons) plus fixed spawn schedules. It does not read game memory or inject anything.

Built for game build 6821 (City Never Sleeps, Oct 26 2026).

## What it does

- **Blue glow** on the live camp nearest to you.
- **Arrows from your icon**, each in its own color:
  - Blue: nearest camp that should be up. Pink (with a pink ring): nearest Sinner's Sacrifice. Both follow the camp schedule and the "you stood there" clears below, so they move on after you farm one.
  - Green (thinner): nearest crate cluster that is glowing.
  - Purple: nearest bridge power-up, from each 5:00 spawn until you have stood at that bridge.
  - Gold: the Soul Urn pad, once the game shows the Urn.
  - Teal: the Unstable Rift bridge, once the game shows it (warning or open).
  - Orange: the Mid-Boss while it is up. Its respawn countdown joins the countdown stack in the last minute, read from the game's own Mid-Boss timer.
  - Thick gold: while you carry the Soul Urn, your team's drop-off point.
  - Faint white: the nearest shop your team can use, always.
- **Last-seen enemies:** when an enemy drops off the minimap, a faded red ring stays where they were last shown, with the seconds since (up to 45 seconds). It disappears when they show up again or die.
- **Green glow** on crate clusters once they have spawned. A cluster goes dark after you walk through it and comes back when it should respawn. The game does not show crates on the minimap, so this is map knowledge, not live info.
- **Countdowns at the top-left of the minimap**, starting 20 seconds before each spawn:
  - Camps: first spawns (small 2:00, medium 5:00, large and Sinner's 8:00), then each camp's own respawn after you see it cleared (small 1:25, medium 4:50, large 5:35, Sinner's 5:00), with a rough place name.
  - Power-ups on both bridges: 5:00, then every 5:00.
  - Soul Urn: 10:00, then every 5:00. Shows the actual pad once the Urn icon appears.
  - Unstable Rift: shows the possible window (first 10:00 to 12:00, then 6 to 8 minutes after the last one). When the game's own 20 second warning appears, it switches to an exact countdown with the bridge.
- Dim gold rings mark possible spawn spots for the Urn, Rift and power-ups while their countdown is up. A spot turns solid when the game shows the actual one.

## Files

| Source | Compiled (goes in the VPK) |
| --- | --- |
| `panorama/layout/hud_minimap.xml` | `panorama/layout/hud_minimap.vxml_c` |
| `panorama/styles/jm_minimap.css` | `panorama/styles/jm_minimap.vcss_c` |
| `panorama/scripts/jm_minimap.js` | `panorama/scripts/jm_minimap.vjs_c` |

`hud_minimap.xml` is the game's own minimap layout from build 6821 with two lines added (one style include, one script include). If a patch changes the stock minimap layout, re-copy the new stock file and add those two lines again.

## Build and install

This folder now ships inside the Deadlock Item Overlay (`minimap_mod\`). The overlay rebuilds and installs the mod by itself, hidden, whenever these sources change or a game patch removed it, as long as Deadlock is closed. Its log is `data\minimap_mod.log`. Without the Reduced CSDK it installs the prebuilt `pak98_dir.vpk` kept in this folder.


Needs Reduced CSDK 12 (extract it to `C:\Reduced_CSDK_12`, not inside OneDrive) and Steam running. Close Deadlock, then double-click `build_and_install.bat`. It compiles, packs `pak98_dir.vpk`, copies it to `addons` and checks `gameinfo.gi`.

Manual install:

1. Put `pak98_dir.vpk` in `Deadlock\game\citadel\addons\`.
2. In `Deadlock\game\citadel\gameinfo.gi`, under `SearchPaths`, the line `Game citadel/addons` must sit directly above `Game citadel`. A backup of the original is kept as `gameinfo.gi.jm_backup`.
3. Start Deadlock. Game patches and Steam "Verify integrity" reset `gameinfo.gi`, so redo step 2 after those.

## Known limits

- Conflicts with any other mod that replaces `hud_minimap.xml` (for example Mid and Bridge Buff Timer). Lower pak numbers win.
- Place names come from map position and are approximate.
- Crate glow is a guess after the first spawn: the game does not tell anyone which crates are broken.
- Client-side HUD mods are generally tolerated, but there is no official Valve policy. Use at your own risk.

## Credits

- Map positions for crate clusters, Urn pads, Rift bridges and power-ups: [Deadlock Labs interactive map](https://deadlocklabs.gg/tools/map/).
- Spawn timings: Deadlock patch notes (June 30 and July 9, 2026), deadlock.wiki and Deadlock Labs.
- Minimap panel structure and the game clock approach were learned from Hantu-Raya's open-source [Deadlock mods collection](https://github.com/Hantu-Raya/Deadlock-mods-collection) (Apache-2.0). No code was copied.
