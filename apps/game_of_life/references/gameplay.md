# Game of Life 操作

- 点击：放置种子图案。
- 拖动：绘制细胞；从活细胞起笔时擦除。
- 长按：重置。
- 摇动：检测到可用 IMU 后打散细胞。

规则为 Conway B3/S23。通过 `cell_px`、`display_ms` 和 `step_ms` 调整格子大小、绘制间隔和演化间隔。每帧使用 `screen:begin()` / `screen:present()`，由当前 display 服务处理脏区提交。
