# Greater Game

A Godot 4.7 first-person arena shooter prototype inspired by time-bending shooters.

## Play

- `WASD`: move
- `Shift`: sprint
- `Space`: jump
- Left mouse: shoot
- `R`: reload
- Right mouse: hold slow time
- `E`: time burst, spends slow charge to clear nearby enemy shots and damage close enemies
- `Q`: dash
- `1-4`: switch unlocked weapons
- `Esc`: pause/settings menu
- `F5`: restart

## Loop

Enemies spawn in escalating waves, chase, strafe, and shoot at you. Time crawls when you stand still, speeds up as you move or fire, and can be manually frozen while you have slow charge. Kills refill slow charge and build short combos.

Pickups can restore ammo or health, boost speed, shield damage, overcharge shots, add a stronger damage buff, grant short infinite ammo, reset dash, or unlock weapons from crates. Crates can unlock shotgun, sniper, SMG, and railgun. Enemy waves start with basic enemies and add runners, snipers, and bruisers as the wave number climbs.

The pause/menu screen has Play, Settings, and Info tabs. Settings currently cover mouse sensitivity, difficulty, and damage flash.

## LAN Multiplayer

Use the `Lobby` tab from the menu:

- Host: choose a port and press `HOST LAN GAME`. The game generates a short lobby code.
- Join by code: enter the host's lobby code and press `JOIN BY CODE`. The game searches the LAN and connects automatically.
- Join by IP: if LAN broadcast is blocked, enter the host machine's local IP address and port, then press `JOIN BY IP`.
- Start/resume from the `Play` tab after hosting or joining.

The host controls wave spawning and enemy simulation, then syncs enemy positions, health, deaths, wave counts, enemy bullets, and pickups to everyone else. Connected players get their own first-person body, player movement is synchronized, and player bullets can damage/take out other players in the same lobby.

If you die in a LAN lobby, the game shows a `YOU DIED` screen with the current lobby code/IP details and a `RESPAWN` button. Respawning keeps you in the same lobby instead of kicking you back out. Menus and death screens block movement, shooting, abilities, and local damage until you press Play or Respawn.
