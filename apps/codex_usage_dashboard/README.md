# Codex 用量看板

显示 5 小时与每周剩余额度，每分钟刷新；Refresh 手动刷新，右上角 × 返回 Launcher。

## 运行要求

需要至少 160×240 的屏幕、display、delay、capability、json、system，以及允许访问数据源的 http_request 能力。按钮操作需要触摸屏；否则可通过运行时取消 App。

## 操作与状态

底部 REFRESH 手动刷新，右上角 × 返回 Launcher。显示 5 小时与每周的剩余额度；横屏双列，窄屏上下排列。失败时保留上次数据并显示 STALE / RETRY；尚无成功数据时显示 FAILED / RETRY。未配置数据源时提示 SET URL IN ARGS。

模拟器使用随包示例数据，标记 DEMO；设备上的 HTTP 请求最长等待 5 秒，请求期间触摸处理会暂缓。

## 安装与启动

将完整的 `codex_usage_dashboard/` 包安装到设备 DATA 根目录下的 `apps/`，再通过 `publish_app` 发布。DATA 根目录应通过设备存储接口解析，不要固定为 `/fatfs`。安装时先写脚本与资源，最后写 `launcher.json`。从设备 Launcher 点击应用启动。

`launcher.json` 保存启动配置，内嵌 `catalog` 保存本站目录信息；本文件是使用说明。App 不需要 `SKILL.md`。

## 实现说明

使用 `display.open()` 和基础图元绘制响应式卡片，从屏幕对象读取尺寸。HTTP 状态、JSON 和百分比字段校验失败时显示更新失败并记录日志，保留上次有效数据。

## 数据源配置

在 `launcher.json` 的 `args` 中设置 PC 数据服务的实际地址，例如：

```json
{ "url": "http://192.168.1.10:8000/data.json" }
```

没有设置地址时，仅提示 `SET URL IN ARGS`，不会请求示例地址。该数据服务需要自行在 PC 上运行，设备的 `search_http_allowlist` 必须允许对应主机。数据源接口保持原看板约定，不直接调用 Codex 或 OpenAI API。

接口应返回 HTTP 2xx 和如下 JSON（也支持外包一层 `usage` 对象）：

```json
{
  "five_h_pct": 72,
  "five_h_reset": "2h 30m",
  "weekly_pct": 85,
  "weekly_reset": "3d 4h"
}
```

百分比字段表示剩余额度，必须是 0–100 的数字；缺失或无效数据不会被当作 0%。每周重置时间也兼容旧数据源的 `HH:MM on DD Month` 格式，按设备本地时间解释。
