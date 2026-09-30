# 触摸绘画

选择颜色与笔刷后拖动绘画；CLEAR 清空画布，× 返回 Launcher。

## 运行要求

需要屏幕和触摸输入。

## 操作

选择颜色和笔刷后在画布拖动；CLEAR 清空画布，右上角 × 返回 Launcher。清空与退出在松手时生效，拖离按钮取消。小屏将色盘和笔刷分行排列，避免重叠。需要至少 160×160 的触摸屏。

## 安装与启动

将完整的 `lcd_touch_paint/` 包安装到设备 DATA 根目录下的 `apps/`，再通过 `publish_app` 发布。DATA 根目录应通过设备存储接口解析，不要固定为 `/fatfs`。安装时先写脚本与资源，最后写 `launcher.json`。从设备 Launcher 点击应用启动。

`launcher.json` 保存启动配置，内嵌 `catalog` 保存本站目录信息；本文件是使用说明。App 不需要 `SKILL.md`。

## 实现说明

复制上游 system/apps/lcd_touch_paint，保留原始 launcher.json 和图标。脚本将首次绘制纳入异常保护，确保初始绘制失败时也释放屏幕。
