# web-stats

macOS menu bar Swift app that tracks which websites you spend time on in Brave.

It polls Brave's active tab URL every 5 seconds, only counts time while Brave is the frontmost app, and aggregates by domain in memory. History is not written to disk and resets when the app quits.

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

The packaged app installs one user `launchd` job:

- `dev.local.webstats.menubar` starts the menu bar UI at login, without `KeepAlive`.

Tracking runs inside the menu bar app. If the menu bar app is closed, tracking stops and session totals are discarded.

For the most reliable login behavior, move `.build/web-stats.app` to `~/Applications`, then open it once. The menu bar app installs the login job automatically.

macOS may ask for Automation permission so the app can read Brave's active tab URL. Grant it for tracking to work.

Only `http` and `https` tabs are counted. Brave internal pages such as new tabs and settings are ignored.

## Notes

- No network calls.
- No browser history scraping.
- No local history file.
- Only active foreground Brave tab time is counted.
