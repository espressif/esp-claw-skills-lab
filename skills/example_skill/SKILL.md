---
{
  "name": "example_skill",
  "description": "A clear description of what this skill does and when to use it. This example is not intended to be downloaded.",
  "author": "Espressif <test@espressif.com>",
  "metadata":
    {
      "cap_groups": [],
      "category": ["utility"],
      "peripherals": [],
      "tags": ["example", "demo"]
    }
}
---

# Skill 编写模板

此包只用于编写参考，没有可执行脚本，不要作为设备功能安装或调用。

## 包结构与元数据

- 使用 JSON frontmatter；`name` 必须与包目录同名，长度 1–63，仅包含 ASCII 字母、数字、下划线或连字符。
- `description` 简要说明用户意图与使用前提，正文只保留一个一级标题。
- `author` 和 `metadata` 可选；`cap_groups` 只声明工作流需要的能力组，不允许空字符串或重复项。
- 分类和外设使用本站允许的值，标签不要重复分类或外设。

## 路径与执行约定

- 所有包内文件引用以 `{CUR_SKILL_DIR}/` 开头，运行时只展开正文中的占位符。
- Skill 独立提供自己的资源，不引用其他 Skill 或 App 的文件。
- Lua 可写数据通过 `storage.get_root_dir()` 和 `storage.join_path(...)` 放入 DATA；包内资源按只读处理。
- 仅使用当前固件已提供的 Lua 模块和 native capability。
- 短任务使用 `lua_run_script`，长驻任务使用 `lua_run_script_async` 并指定稳定名称及硬件互斥组。
- 只有用户明确要求替换冲突任务时才使用 `replace: true`；失败后报告实际错误。
