# Vendored renderers

Third-party JavaScript bundled with Cheese for the offline Files tools. Every file is pinned to an
exact version, copied unmodified from the published package, and loaded only from the app bundle:
the web views that run them block every non-local load. The whole `Renderers/` folder must stay
under 3 MB (`RendererBudgetTests` enforces it). Each license is in `licenses/` and shown in
Settings → About.

| File | Library | Version | License | Source |
|---|---|---|---|---|
| `marked.umd.js` | marked | 18.1.1 | MIT | https://www.npmjs.com/package/marked/v/18.1.1 (`lib/marked.umd.js`) |

## Updating

1. Download the package (`npm pack <name>@<version>`) into a scratch folder, never into the repo.
2. Copy the file listed above, unmodified, and replace its license in `licenses/`.
3. Update the version here, then run `make test-integration`.

Only MIT-compatible licenses (MIT, BSD, ISC, Apache-2.0). Ask before adding anything copyleft.
