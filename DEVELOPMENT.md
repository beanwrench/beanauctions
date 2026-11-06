# BeanAuctions: developer notes

A BeamNG.drive **career mode** mod that adds a salvage auction and an OBD-II scan tool.

Built and tested on BeamNG.drive **0.40.4** (West Coast USA).

## Features

### Salvage auctions
- A rotating stock of about 10 lots: salvage-title wrecks, "runs bad" clean-title cars, and high-mileage runners.
- **Pre-bid** at any time by setting a max bid. Each lot then goes to a **live auction** with a "going once / going twice" countdown, and your max bid bids for you.
- AI bidders only see the seller's condition report. **Hidden faults** are real, so a lot that looks cheap might have a dead transmission.
- **Fast travel & inspect:** the car spawns at the auction yard and walking up to it reveals the hidden faults.
- **Collection:** after winning, pick the car up at the yard, have it towed to your garage (5-minute wait), or pay for an instant tow.
- **Buyer fees** are tiered (roughly 7–12% plus $100), like real salvage auctions.
- Lots, bids and won cars persist with your career save.

### Scan tool
- Plug into any owned, spawned car within 15 m to read trouble codes generated from its **actual part condition**. This covers auction faults and damage you cause yourself (overheating, spun bearings, broken parts).
- Each fault comes with a repair and a realistic price: parts plus book labor hours at $125/h.

| Fault | Codes | Typical repair |
|---|---|---|
| Misfire / ECU | P0300, P0351, P0606 | Coils, plugs, ECU reflash (~$470) |
| Engine damage | P0300, P0325 (+P0217 / P0524 / P0335) | Engine rebuild (~$3,100+) |
| Transmission | P0700, P0730 | Transmission rebuild (~$2,200+) |
| Cooling | P0217, P2560 | Radiator replacement |
| Turbo | P0299 | Turbo replacement |
| Broken body/chassis part | B1A00 | Part replacement |

## How to use (in game)
Go to any career **garage computer**. There are two new entries:
- **Salvage Auctions** opens the auction site (Find Vehicles, Live Auctions and My Bids tabs).
- **Scan Tool** opens the same site on the scan tool tab.

Press **Esc** or the **✕** to close the site.

## Install

**From a zip:** drop `beanauctions.zip` into
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\` and start (or restart) BeamNG.

**From source (unpacked):** copy or clone this repository to
`%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\unpacked\beanauctions\`.

The mod needs a **career** save. It loads automatically when career mode starts, because every `.lua` file in `lua/ge/extensions/career/modules/` is picked up by the career loader.

## Project layout

```
lua/ge/extensions/career/modules/beanAuctions.lua  auctions, consignment, tablet bridge, browser access
lua/ge/extensions/career/modules/beanScanTool.lua  Bean Diag: diagnosis, repair, refurbishing
lua/ge/extensions/career/modules/beanValue.lua     vehicle value: parts-based mileage, restored-classic premium
lua/ge/extensions/career/modules/beanChopShop.lua  chop shop button in Part Customization
lua/ge/extensions/core/input/actions/beanauctions.json  B / Esc input actions
settings/inputmaps/keyboard_beanauctions.json      default key bindings
ui/beanauctions/index.html                         the tablet and website (single file: HTML, CSS and JS)
```

Every file, extension, input action, action-filter group and saved file uses a `bean` prefix so nothing
collides with the game or other mods. Keep it that way: the repository rules forbid overwriting game data.

**How the UI works:** Lua injects a full-screen `<iframe>` (`/ui/beanauctions/index.html`) into the game UI with `be:executeJS`. The page calls back with `parent.bngApi.engineLua("career_modules_beanAuctions.uiAction(...)")`. Lua pushes the full state into the page about every 1.2 s through `window.baState(json)`.

## Development

1. Link the repo into the game instead of copying it. A junction needs no admin rights:
   ```powershell
   cmd /c mklink /J "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current\mods\unpacked\beanauctions" "C:\path\to\beanauctions"
   ```
   If the game is already running, rescan mods from the Lua console with `core_modmanager.initDB()`.
2. Hot-reload after editing, from the in-game Lua console (`~`):
   ```lua
   extensions.reload("career_modules_beanScanTool") extensions.reload("career_modules_beanAuctions")
   ```
   Reloading a module unloads the modules that depend on it (beanValue → beanScanTool → beanAuctions), so reload
   them all, dependency first. Batch-load them like the career loader does to check for warnings:
   ```lua
   extensions.load({"career_modules_beanAuctions", "career_modules_beanChopShop", "career_modules_beanScanTool", "career_modules_beanValue"})
   ```
   UI changes take effect the next time the site is opened.
3. Self-tests (bid math, fault classification):
   ```lua
   career_modules_beanAuctions.selfTest()  -- "ok"
   career_modules_beanScanTool.selfTest()  -- "ok"
   career_modules_beanValue.selfTest()     -- "ok"
   ```
4. Useful debug calls:
   ```lua
   career_modules_beanAuctions.openWindow()        -- open the site
   career_modules_beanAuctions.debugEndLot(lotId)  -- send a lot to its live round now
   dump(career_modules_beanAuctions.getLots())
   ```

Tuning values (lot count, timers, fees, labor rate, fault odds and repair recipes) are local constants at the top of each Lua file.

## Packaging and uploading

### 1. Build the zip
The zip must have `lua/`, `ui/` and `settings/` **at its root**, not inside a `beanauctions/` folder. From the repo root:

```bash
tar -a -cf beanauctions.zip lua ui settings
```

Use Windows' built-in `tar`, not PowerShell's `Compress-Archive`. Windows PowerShell 5.1 writes zip paths with backslashes, which other zip readers may not handle.

Only `lua/`, `ui/` and `settings/` belong in the zip. Leave out `README.md`, `LICENSE`, `docs/`, `.git` and any screenshots.

### 2. Test the zip before publishing
1. Remove or rename the unpacked/junction copy in `mods\unpacked\` so the two don't conflict.
2. Put `beanauctions.zip` in `mods\`, start BeamNG and load a career save.
3. Press **B**, check the tablet opens, then run the three `selfTest()` calls above.
4. Check the console (`~`) and `beamng.log` for errors or warnings. The repository reviewers do.

### 3. Upload to the BeamNG.com repository
1. Sign in at beamng.com, open **Resources → Mods & Resources → Upload a Mod**, and pick the category that fits (for example *Mods of Mods* or *User Interface Apps*).
2. Upload `beanauctions.zip`. Never rename it: updates must use the same zip name.
3. **Title:** `BeanAuctions: Salvage Auctions, Scan Tool & Tablet for Career`. **Tagline:** one sentence.
4. Paste `docs/repository-overview.txt` into the overview. It's already in the site's BBCode.
5. Upload at least two images with the site's **Upload Images** button. `docs/` has four: the tablet, the live floor, a lot page, Bean Diag.
6. Submit. The BeamNG moderators review every mod before it goes public.

The repository adds its own `mod_info/` folder to approved mods, so don't create one yourself.

### 4. Releasing an update
1. Bump the version in your release notes and in the repository's *Update* form.
2. Rebuild the zip with the same file name.
3. Upload it through **Post Update** on the existing resource rather than creating a new resource, so subscribers get the update automatically.
4. Publish the code to the public repo (next section).

## Repositories and branches
- **Private dev repo** (`origin`, `beanwrench/beanauctions-dev`): all work happens here. `dev` is the working branch; merge into `main` when a build is ready to test as staging.
- **Public repo** (`public`, `beanwrench/beanauctions`): release snapshots only, one commit per release, authored with the GitHub no-reply address so no private email or dev history goes public. The local `release` branch tracks it.

Publish `main` as a new public release (Git Bash, from the repo root):

```bash
export GIT_AUTHOR_NAME=beanwrench GIT_AUTHOR_EMAIL=70417648+beanwrench@users.noreply.github.com GIT_COMMITTER_NAME=beanwrench GIT_COMMITTER_EMAIL=70417648+beanwrench@users.noreply.github.com
git branch -f release "$(git commit-tree "main^{tree}" -p release -m "BeanAuctions v1.1")"
git push public release:main
git tag v1.1 release && git push public v1.1
```

## Known limitations
- Physical crash damage on salvage cars is applied once, at spawn. Like any career car, a damaged car loses its dents when respawned from storage, but broken parts stay tracked.
- Shocks and suspension wear aren't simulated, because the game's part-condition system doesn't cover them.
- The scan tool is only opened from the garage computer. There's no hotkey yet.
- The car pool comes from the stock config list, so police, race and offroad configs can show up (real salvage auctions sell those too).
