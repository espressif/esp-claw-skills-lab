# Flappy Bird

触摸屏幕或使用配置的 GPIO 按键控制小鸟。音效为可选功能。

## 运行要求

需要至少 160×160 的屏幕，以及触摸输入或 GPIO 按键；音频输出可选。

## 操作

- 进入后等待点击或按键开始，游戏中点击或按键跳跃/拍翅，结束后再次操作重试。
- 触摸右上角 × 返回 Launcher；旁边的暂停按钮可暂停/继续，暂停面板也可点击继续。
- 控制按钮松手生效，拖离按钮取消；点击退出或暂停不会触发游戏动作。
- 默认持续运行。`args.run_ms` 大于 0 时限制运行时长；Flappy Bird 兼容 `run_time_ms`。无触摸设备可通过运行时取消 App。

## 安装与启动

将完整的 `flappybird/` 包安装到设备 DATA 根目录下的 `apps/`，再通过 `publish_app` 发布。DATA 根目录应通过设备存储接口解析，不要固定为 `/fatfs`。安装时先写脚本与资源，最后写 `launcher.json`。从设备 Launcher 点击应用启动。

`launcher.json` 保存启动配置，内嵌 `catalog` 保存本站目录信息；本文件是使用说明。App 不需要 `SKILL.md`。

## 实现说明

基于上游 Flappy Bird，增加暂停/继续、右上角退出和小屏适配，保留小鸟绘制与原有图标。脚本按当前音频 API 修正：通过 output:info() 获取实际采样率、声道数和位深，使用 output:set_volume() 设置音量，生成匹配的 16/32 位 PCM；其他位深跳过可选音效。sample_rate_hz 不再作为输出格式配置。

## 启动参数

默认优先使用触摸。GPIO 按键场景在 `launcher.json` 的 `args` 中配置 `input_mode: "button"` 和 `button_gpio`；其他可选参数以随包脚本顶部的参数定义为准。
