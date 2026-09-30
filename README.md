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
pnpm build
```
