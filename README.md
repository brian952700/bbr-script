# Brian BBR 一键加速脚本

[![Version](https://img.shields.io/badge/version-1.0.5-blue)](https://github.com/brian952700/bbr-script)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

由 **brian952700** 维护的 Linux BBR 管理脚本，提供 BBR 启用、内核升级、状态查看和旧内核清理菜单。

项目主页：[brian952700/bbr-script](https://github.com/brian952700/bbr-script) · [问题反馈](https://github.com/brian952700/bbr-script/issues) · [下载 ZIP](https://github.com/brian952700/bbr-script/archive/refs/heads/main.zip)

## 一键下载安装

以 **root** 用户在 Linux 的 Bash 终端执行：

```bash
curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o install.sh https://raw.githubusercontent.com/brian952700/bbr-script/main/install.sh && bash install.sh
```

使用 wget：

```bash
wget --tries=3 --timeout=30 -O install.sh https://raw.githubusercontent.com/brian952700/bbr-script/main/install.sh && bash install.sh
```

入口脚本从本仓库下载最新版 `newbbr.sh`，下载失败会停止，语法检查通过后启动管理脚本。管理脚本会执行依赖检查等初始化操作，再显示交互菜单；不会自动选择升级内核。

直接下载管理脚本后运行：

```bash
curl -fL --retry 3 --connect-timeout 15 --max-time 180 -o newbbr.sh https://raw.githubusercontent.com/brian952700/bbr-script/main/newbbr.sh && bash newbbr.sh
```

[下载 install.sh](https://raw.githubusercontent.com/brian952700/bbr-script/main/install.sh) · [下载 newbbr.sh](https://raw.githubusercontent.com/brian952700/bbr-script/main/newbbr.sh)

非 root 用户可下载后使用 `sudo bash install.sh`。如果系统没有 curl 或 wget，请先通过系统包管理器安装其中一个。

## 使用方法

| 菜单 | 功能 |
| --- | --- |
| 1 | 安装/启用 BBR，建议先选择此项 |
| 2 | 升级 Ubuntu / Debian 内核 |
| 3 | 升级 CentOS 内核（仅现有 CentOS 7 分支提供安装逻辑） |
| 4 | 清理旧内核 |
| 5 | 查看当前状态 |
| 0 | 退出 |

先选择 `1`；若提示内核不支持，再考虑升级内核。升级成功并重启后，重新执行安装命令，选择 `1` 启用 BBR。检测到 BBR 已启用且内核满足脚本条件时，脚本会显示状态后退出。

验证当前拥塞控制算法：

```bash
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.default_qdisc
```

拥塞控制算法输出 `bbr` 表示当前已启用。BBR 可能编译进内核，不能只凭 `lsmod` 是否显示模块判断。

## 系统与操作说明

- 脚本面向 Ubuntu、Debian 和 CentOS；具体可用性取决于内核配置、系统权限、架构和软件源，未对所有发行版逐一验证。
- CentOS 8 及以上的内核升级被脚本禁止；CentOS 6 没有自动内核升级分支。
- OpenVZ 等共享宿主内核的容器无法自行更换内核，BBR 是否可用取决于宿主机。
- 首次运行会尝试安装缺少的依赖；CentOS 6/7/8 会尝试切换 Vault 软件源。
- Ubuntu / Debian 内核升级流程可能修改 `/etc/apt/sources.list` 中的软件源地址。
- BBR 启用会写入 `/etc/sysctl.d/99-bbr.conf` 并应用网络参数；效果取决于实际网络环境。
- 升级内核、修改软件源或清理旧内核前，请备份数据与配置，保留可用的控制台和恢复方式。

## 更新日志

### v1.0.5（2026-10-31）

- 将项目展示、维护者、安装下载及反馈入口统一到 `brian952700/bbr-script`。
- 新增 `install.sh` 下载运行入口，支持 curl / wget、失败停止、临时文件清理和 Bash 语法检查。
- 更新使用说明，移除旧联系方式和未经本仓库验证的性能承诺。
- 保留原版 BBR 管理逻辑及 MIT 版权声明。

## 来源与许可

本仓库 fork 自 [adsorgcn/bbr-script](https://github.com/adsorgcn/bbr-script)，原维护者为 **静水流深**；该项目基于 [ylx2016/Linux-NetSpeed](https://github.com/ylx2016/Linux-NetSpeed) 改进。

本分支由 [brian952700](https://github.com/brian952700) 维护。使用 [MIT License](LICENSE)，保留原作者版权声明。GitHub 上仍保留 fork 来源关系。

