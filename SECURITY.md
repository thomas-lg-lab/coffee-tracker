# Security policy

Coffee Tracker is designed to be internet-exposed and self-hosted by people who are not
me, so a vulnerability here can affect someone else's home network. Reports are welcome.

## Reporting a vulnerability

**Please don't open a public issue.** Use GitHub's private vulnerability reporting:

→ **[Report a vulnerability](https://github.com/thomas-lg-lab/coffee-tracker/security/advisories/new)**

That opens a private advisory only you and I can see, so a fix can ship before the
details are public.

Useful things to include, in rough order of value:

- what an attacker gets (read another user's data, forge a token, run code in the
  container, escape to the host)
- the smallest sequence of requests that shows it
- the version, the image tag, or the commit `main` was on
- whether it needs an account, an admin account, or nothing at all

## What to expect

One person maintains this, around a job and a life. So:

- an acknowledgement within about a week
- an assessment, including "this is working as intended, and here's why", once I've
  reproduced it
- a fix on `main` and a new image for anything that lets someone read or write data
  they shouldn't, or escape the container

There is no bounty. I'm happy to credit you in the advisory and the release notes
unless you'd rather I didn't.

## Supported versions

The latest `:latest` image, built from `main`. There are no maintained release
branches, so "upgrade to the current image" is the fix for everything.

## Things that are already known, and deliberate

Not vulnerabilities, please don't report these:

- The first account to register becomes an administrator. A fresh instance accepts
  exactly one registration and then closes itself. That window is the documented
  bootstrap, and closing it promptly is the operator's job.
- **Session tokens live in `localStorage`**, so any XSS is an account compromise. What
  stands between the two is a content security policy with no inline script, Angular's
  default escaping, and no `innerHTML` or `bypassSecurityTrust` anywhere in the
  codebase. An actual XSS *is* worth reporting; the storage choice by itself isn't.
- TLS is the reverse proxy's job. The container speaks plain HTTP by design and is not
  meant to be published straight to the internet.
- Anyone signed in can see the whole catalog. The shelf is shared on purpose; only the
  ratings are per-user.

## Hardening your own instance

See the [deployment guide](deploy/README.md) and the Security section of
[the design notes](docs/design-notes.md).
