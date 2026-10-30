---
name: wherekey
description: Use the local WhereKey catalog when a coding or testing task needs an API key, authenticated API service, saved curl request, or locally stored credential. Trigger when the user asks to find a service in WhereKey, run code with a saved key, validate a configured API, or call a saved curl service without exposing its secret.
---

# WhereKey

Use WhereKey as a local service broker. Work only with service names, Key aliases, environment-variable names, redacted request shapes, statuses, and command results.

## Workflow

1. Run `wherekey catalog --json` to find candidate services. Do not guess a service when multiple entries plausibly match the request.
2. When request shape or project usage is relevant, run `wherekey describe --service "NAME" --json`.
3. For an API Key service, run the required test or program through:

   ```bash
   wherekey run --service "NAME" -- command arg...
   ```

   Add `--key "ALIAS"` only when the user names a non-default Key or the task requires it.
4. For a saved curl service, use `wherekey call --service "NAME"` to call it, or `wherekey check --service "NAME" --json` when only validity is needed.
5. Treat a nonzero exit status or an `invalid` result as a real failure. Report the error without asking for or printing the Key.

## Safety

- Never try to read, print, echo, transform, encode, inspect, or persist injected environment values.
- Never run `env`, `printenv`, shell tracing, or diagnostic commands intended to reveal the credential.
- Never add a WhereKey value to `.env`, source files, fixtures, logs, Git, or tool configuration.
- Do not bypass WhereKey by asking the user to paste a Key.
- Allow WhereKey to record the current working directory as the project using the service.
