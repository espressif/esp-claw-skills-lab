# 重力滚球

倾斜开发板使球进入目标圈，停留后得分。触摸右上角 × 返回 Launcher。

## 运行要求

需要屏幕及板级 imu_sensor。无触摸设备可通过运行时取消 App。

## 操作

倾斜设备使球进入目标环，底部进度条显示停留进度。右上角 × 返回 Launcher，旁边按钮暂停/继续；暂停时保留球的位置、速度与得分。控制按钮松手生效，拖离取消。无触摸设备可通过运行时取消 App。

## 安装与启动

将完整的 `balance_ball/` 包安装到设备 DATA 根目录下的 `apps/`，再通过 `publish_app` 发布。DATA 根目录应通过设备存储接口解析，不要固定为 `/fatfs`。安装时先写脚本与资源，最后写 `launcher.json`。从设备 Launcher 点击应用启动。

`launcher.json` 保存启动配置，内嵌 `catalog` 保存本站目录信息；本文件是使用说明。App 不需要 `SKILL.md`。

## 实现说明

使用 display.open()、screen:begin()/present() 和 imu.new()/read()/close()。默认持续运行，退出或异常时释放屏幕与 IMU。

## 启动参数

可在 `launcher.json` 的 `args` 中配置 `run_ms`（默认 0，持续运行）、`frame_ms`、`lsb_per_g`（默认 2048，需符合所用 IMU 的量程）、`invert_x`、`invert_y`、`swap_xy`、`ball_r`、`target_r`、`accel_k`、`friction`、`bounce`、`max_speed` 和 `hold_frames`。数值参数必须在脚本声明的范围内。
