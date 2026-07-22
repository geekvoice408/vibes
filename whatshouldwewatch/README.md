# What Should We Watch? (Episode Roulette)

A mobile-friendly synthwave web app that picks a random episode of Family Guy,
The Simpsons, Seinfeld, South Park, Futurama, King of the Hill, or Law & Order.

Hosted on GitHub Pages — no server, no API key.

## How it works

- 100% static: one HTML file plus PWA icons/manifest.
- Episode data comes from the free, keyless [TVMaze API](https://www.tvmaze.com/api).
  One request per show fetches the full episode catalogue (title, plot,
  rating, runtime, airdate), cached in `localStorage` for 24 hours.
- Watch history and season filters live in `localStorage` per browser.
  History is keyed by season/episode number (older installs keyed by OMDb
  imdbID are migrated automatically on first load).

## Development

Open `index.html` in a browser, or serve the directory with any static file
server:

```bash
python3 -m http.server 8080
```

## Deployment

Pushed to `main` → the `pages.yml` workflow publishes this directory to
GitHub Pages.

## History

Previously ran as a Go container (`ghcr.io/geekvoice408/episode-picker`) on
the k8s cluster behind a NodePort, using the OMDb API with an embedded key.
Moved to GitHub Pages + TVMaze in July 2026; the ArgoCD app was retired.
