# Contributing

This is a personal, for-fun project: a no-pressure space to learn modern C#/.NET. That
shapes what's welcome here: there's no roadmap to serve and no deadline to hit, so a
change is judged on whether it makes the app better for people self-hosting it and
whether it's something I'd enjoy maintaining.

**Bug reports and questions are always welcome**, including "how is this supposed to
work?" If you had to ask, the docs are wrong.

For a **security** issue, don't open an issue: see [SECURITY.md](SECURITY.md).

## Before writing a feature

Open an issue first. I'd rather say "not for me, sorry" to a paragraph than to a
weekend of your work. Small fixes (a broken link, a wrong command, an obvious bug)
don't need that; just send them.

## Working on the code

**Read [AGENTS.md](AGENTS.md) first.** It's the real contributor guide: the
architecture rules, the comment style this codebase is deliberate about, and the
hard-won gotchas, including the NuGet lock-file trap that bites every backend
dependency bump.

Development happens **inside the dev container**; the host isn't expected to carry
.NET, Node or Tesseract. Open the repo in VS Code and run *Dev Containers: Reopen in
Container*.

Three test suites, all of which CI runs on every PR:

```bash
dotnet test CoffeeTracker.sln     # backend: unit + HTTP integration
cd frontend && npm test           # frontend: unit (Vitest)
cd frontend && npm run e2e        # frontend: end-to-end (Playwright, Chromium)
```

The e2e suite needs the API running on `:5000` against an **empty** database.

## Sending a change

- Branch off `main`; `main` itself takes no direct pushes.
- **PR titles follow [Conventional Commits](https://www.conventionalcommits.org/)**;
  `.github/workflows/pr-title-check.yml` enforces the type against
  `.github/conventional-commit-types.json`, so `fix(web): …` passes and `Fixed the
  thing` doesn't.
- Say *why* in the description, not just what. The diff already says what. The PR template
  (the organisation's default) asks for it, and for how you tested.
- If dependencies changed, commit the regenerated lockfiles (`package-lock.json`, NuGet
  `packages.lock.json`).
- Get CI green. It runs backend, frontend, e2e, the production Docker build, CodeQL and
  a Trivy image scan.
- Changes are **squash-merged**, so don't worry about tidying your commit history.

## Behaviour specs

Non-trivial behaviour changes go through [OpenSpec](openspec/): one change per feature,
merged, then archived into `openspec/specs/` in a follow-up PR. If that sounds like
overhead for what you're doing, it probably is. Ask in the issue and I'll tell you.

## Code of conduct

Be decent. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
