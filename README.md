# web-stats

macOS menu bar Swift app that tracks which websites you spend time on in Brave.

It polls Brave's active tab URL every 5 seconds, only counts time while Brave is the frontmost app, and aggregates by domain. The app keeps a rolling 60 days of local history at:

```text
~/Library/Application Support/web-stats/stats-history.json
```

The menu panel includes 7-day, 30-day, and 60-day chart tabs, plus a CSV export button for the selected range.
The chart only shows the top 6 domains per range, the top websites list caps at 20, and recent visits caps at 6.

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

Tracking runs inside the menu bar app. If the menu bar app is closed, tracking stops until the app starts again.

For the most reliable login behavior, move `.build/web-stats.app` to `~/Applications`, then open it once. The menu bar app installs the login job automatically.

macOS may ask for Automation permission so the app can read Brave's active tab URL. Grant it for tracking to work.

Only `http` and `https` tabs are counted. Brave internal pages such as new tabs and settings are ignored.

## Notes

- No network calls.
- No browser history scraping.
- Local history is limited to 60 days.
- Only active foreground Brave tab time is counted.
