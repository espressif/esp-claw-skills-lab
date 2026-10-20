# ESP-Claw Skills Lab

Visit the [Skills Lab](https://skills-lab.esp-claw.com) site or the [ESP-Claw GitHub repository](https://github.com/espressif/esp-claw) to learn more.

To contribute, see the documentation: [EN](https://esp-claw.com/en/tutorial/skills-lab) / [中文](https://esp-claw.com/zh-cn/tutorial/skills-lab).

## Packages

- `skills/`: Skills invoked by the agent, each described by `SKILL.md`.
- `apps/`: Lua apps launched from the device Launcher, each defined by `launcher.json`.

## Local Development

```sh
pnpm install --frozen-lockfile
pnpm dev
```

To check packages and build the site:

```sh
pnpm validate-packages
pnpm test
pnpm test-apps # Requires Lua 5.4 or later as `lua`.
pnpm build
```

`pnpm build` validates packages before building the site. The pre-commit hook checks formatting and packages without rewriting files; use `pnpm format` to apply formatting fixes. Pull requests also run the TypeScript and Lua regression tests.
