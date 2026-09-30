# Game of Life

点击放置种子，拖动绘制或擦除细胞，长按重置；有 IMU 时可摇动打散。

从设备 Launcher 启动。显示屏，触摸优先；无触摸时使用 GPIO0 按钮，IMU 可选。退出可使用设备 Launcher 的返回操作。

配置写在 `launcher.json.args`，默认无需修改。`cell_px` 调整格子大小，`display_ms` 和 `step_ms` 调整刷新与演化间隔，`imu_device` 选择板载 IMU。

已开放浏览器模拟入口；音频和传感器效果以真机为准，本次 API 迁移尚未运行验证。
