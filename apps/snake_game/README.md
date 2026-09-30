# Snake

滑动开始并控制方向；PAUSE / RESUME 暂停或继续，失败后滑动重开。

从设备 Launcher 启动。触摸屏；扬声器可选。退出可使用设备 Launcher 的返回操作。

配置写在 `launcher.json.args`，默认无需修改。`grid_size` 调整网格，`target_size` 调整舞台大小，`run_time_ms` 控制运行时长（毫秒，`0` 持续运行）。

已开放浏览器模拟入口；音频和传感器效果以真机为准，本次 API 迁移尚未运行验证。
