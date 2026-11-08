# Frontend

Angular 22 PWA (standalone components, signals, Signal Forms, Tailwind), split into
npm workspace packages under `packages/`.

Everything you need is in the repo root. [README.md](../README.md) covers what the app
does and how to run it, [AGENTS.md](../AGENTS.md) has the architecture rules and the
gotchas, and [CONTRIBUTING.md](../CONTRIBUTING.md) explains how to send a change.

```bash
npm start      # ng serve app , dev server on :4200, proxies /api to :5000
npm run build  # ng build app , production bundle
npm test       # vitest, workspace-wide (every package's specs in one run)
npm run lint
npm run e2e    # Playwright; needs the API on :5000 against an EMPTY database
npm run gen:api  # regenerate the typed client from openapi.json
```

Development happens in the dev container, the host isn't expected to carry Node.
