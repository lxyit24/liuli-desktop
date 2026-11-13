# 琉璃桌面客户端 · 来源与许可

本项目是 **FlClash** 的修改版（fork），仅将界面名称、图标与配色替换为「琉璃」，
并移除了首次启动的免责声明确认页；核心功能与实现均来自上游。

- 上游仓库：https://github.com/chen08209/FlClash
- 上游作者：chen08209 及 FlClash 贡献者
- 上游协议：**GNU General Public License v3.0**（见 `LICENSE`）

## 许可

依据 GPL-3.0，本仓库同样以 GPL-3.0 发布：

- 你可以自由使用、修改、分发本软件；
- 分发二进制时必须同时提供完整源代码（即本仓库）；
- 必须保留原作者版权声明与许可声明。

## 与上游的差异

1. `lib/common/constant.dart`：`appName` → `琉璃`，主色 → `#3B74F2`
2. `lib/bootstrap.dart`：跳过首次启动的免责声明确认
3. `windows/runner/main.cpp`、`Runner.rc`：窗口标题 / 文件描述 → `Liuli 琉璃`
4. `assets/images/**`、`windows/runner/resources/app_icon.ico`：替换为琉璃图标
5. `.github/workflows/liuli-windows.yml`：Windows 云构建（Flutter + Go + Rust）

## 构建

```bash
git config -f .gitmodules submodule.core/Clash.Meta.url https://github.com/chen08209/Clash.Meta.git
git config -f .gitmodules submodule.plugins/prism_ui.url https://github.com/chen08209/prism_ui.git
git submodule update --init --recursive

flutter pub get
flutter build windows --release
```

产物：`build/windows/x64/runner/Release/`
