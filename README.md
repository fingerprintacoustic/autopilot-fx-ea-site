# autopilot-fx-ea-site

Landing page for **AutoPilot FX EA** — a downloadable MQL5 Expert Advisor for MetaTrader 5.

Part of [Fingerprint Acoustic Trade](https://trade.fingerprintacoustic.com) (AutoPilot FX).

## What's here

- `index.html` — single-file landing page, vanilla HTML/CSS/JS, no build step
- `AutoPilotFX_EA.mq5` — the EA itself, served directly as the download
- `CNAME` — custom domain for GitHub Pages (`ea.fingerprintacoustic.com`)

## Deploy

Served by GitHub Pages from the `main` branch, root folder. Any push to `main` redeploys.

To preview locally, just open `index.html` in a browser (or `python -m http.server`).

## Updating the EA download

Replace `AutoPilotFX_EA.mq5` with the new version (keep the filename) and update the
version string in `index.html`, then commit and push.
