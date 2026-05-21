# web-stats

macOS menu bar Swift app that tracks which websites you spend time on in Brave.

It polls Brave's active tab URL every 5 seconds, only counts time while Brave is the frontmost app, aggregates by domain, and stores totals locally at:

```text
~/Library/Application Support/web-stats/site-totals.json
```

## Run during development

```bash
swift run web-stats
```

This runs from Terminal, so packaging is better for normal use.

## Package as `.app`

```bash
./scripts/package-app.sh
open .build/web-stats.app
```

The packaged app installs two user `launchd` jobs:

- `dev.local.webstats.menubar` starts the menu bar UI at login, without `KeepAlive`.
- `dev.local.webstats.agent` runs the tracker helper with `KeepAlive`.

Tracking continues if the menu bar app is closed because the helper writes stats to the local JSON file. If macOS Settings disables the background helper, macOS can stop tracking until permission is restored.

For the most reliable login behavior, move `.build/web-stats.app` to `~/Applications`, then open it once. The menu bar app installs both jobs automatically.

macOS may ask for Automation permission so the app can read Brave's active tab URL. Grant it for tracking to work.

Only `http` and `https` tabs are counted. Brave internal pages such as new tabs and settings are ignored.

## Notes

- No network calls.
- No browser history scraping.
- Only active foreground Brave tab time is counted.
