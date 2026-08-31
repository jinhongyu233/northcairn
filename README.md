# GoFlow2 + Vector + VictoriaLogs + Grafana 一键部署

## 简介

本脚本用于在 **CentOS / AlmaLinux / Rocky Linux / RHEL** 系统上一键部署一套完整的 NetFlow/sFlow 流量采集与分析平台，数据流如下：

```
网络设备 (NetFlow v5/v9/IPFIX / sFlow)
        │
        ▼  UDP 2055 / 6343
   GoFlow2  (采集器)
        │
        ▼  JSON 文件
   /data/goflow2/flow.log
        │
        ▼  file source
    Vector  (清洗/转换)
        │
        ▼  HTTP jsonline
 VictoriaLogs  (日志存储/LogsQL查询)
        │
        ▼  LogsQL
    Grafana  (可视化看板)
```

## 组件版本

| 组件 | 版本 | 说明 |
|------|------|------|
| GoFlow2 | 2.2.6 | NetFlow/IPFIX/sFlow 采集器，输出 JSON 到文件 |
| Vector | 0.57.0 | 日志采集与转换，读取文件并写入 VictoriaLogs |
| VictoriaLogs | v1.51.1 | 日志存储与 LogsQL 查询引擎 |
| Grafana Enterprise | 13.2.0 | 可视化看板 |
| VictoriaLogs Grafana 插件 | 0.31.0 | Grafana 数据源插件 |

## 目录结构要求

执行脚本前，请检查安装包和 `config/` 目录与脚本放在**同一目录**下：

```
xflow
├── deploy_goflow2_stack.sh          # 本部署脚本
├── goflow2-2.2.6-1.x86_64.rpm      # GoFlow2 RPM 包
├── vector-0.57.0-1.x86_64.rpm      # Vector RPM 包
├── grafana-enterprise_13.2.0_*.rpm # Grafana RPM 包
├── victoria-logs-linux-amd64-v1.51.1-enterprise.tar.gz  # VictoriaLogs 压缩包
├── victoriametrics-logs-datasource-0.31.0.zip             # Grafana 插件
└── config/
    ├── goflow2                     # logrotate 配置
    ├── vector.yaml                 # Vector 配置文件
    ├── victorialogs.service        # VictoriaLogs systemd 服务文件
    └── dashboard-goflow2-1.json    # Grafana Dashboard
```

### config 文件说明

| 文件 | 作用 |
|------|------|
| `goflow2` | logrotate 配置，按大小 2G 滚动，保留 3 份，使用 copytruncate |
| `vector.yaml` | Vector 主配置，file source 读取 `/data/goflow2/*.log`，转换后写入 VictoriaLogs |
| `victorialogs.service` | systemd 服务文件，数据目录 `/data/victorialogs`，保留 180 天，监听 9428 |
| `dashboard-goflow2-1.json` | Grafana 流量分析看板，通过 provisioning 自动导入 |

## 前置条件

- 操作系统：CentOS 7/8/9、AlmaLinux、Rocky Linux、RHEL、Oracle Linux
- 以 **root** 用户执行
- 服务器可访问外网（用于安装依赖，如已配置本地 yum 源则无需外网）
- 最低资源建议：2 CPU / 4GB 内存 / 50GB 磁盘（流量大时按需增加）

## 快速开始

```bash
# 1. 赋予执行权限
chmod +x deploy_goflow2_stack.sh

# 2. 执行部署
./deploy_goflow2_stack.sh
```

脚本会按以下顺序执行：
1. 系统初始化（安装依赖、配置防火墙、处理 SELinux）
2. 部署 GoFlow2
3. 部署 VictoriaLogs
4. 部署 Vector
5. 部署 Grafana（含插件、数据源、Dashboard）
6. 输出部署汇总信息

### 测试工具

```
# 1. 赋予执行权限
chmod +x xflow-tool

# 2. 执行部署案例
sudo xflow-tool -i ens33 -t 192.168.88.98 -p 6343 -c 4 -f in,out 
```

该脚本使用go语言编写，linux amd64环境使用，用于模拟sflow流量发送。

​	-i 指定采样的网卡接口，

​    -t 指定采集服务器地址

​    -p 指定采集服务器端口

​    -c 采样比，需要为2的指数

​    -f 采样流量方向



## 部署后验证

### 1. 检查服务状态

```bash
systemctl status goflow2.service
systemctl status victorialogs.service
systemctl status vector.service
systemctl status grafana-server.service
```

### 2. 检查端口监听

```bash
ss -lntup | grep -E '2055|6343|9428|3000'
```

预期输出：
- `2055/udp` — GoFlow2 NetFlow 监听
- `6343/udp` — GoFlow2 sFlow 监听
- `9428/tcp` — VictoriaLogs HTTP API
- `3000/tcp` — Grafana Web

### 3. 验证 VictoriaLogs

```bash
curl -s http://127.0.0.1:9428/health
# 预期返回: healthy
```

### 4. 验证 Grafana

浏览器访问 `http://<服务器IP>:3000`
- 默认账号：`admin` / `admin`（首次登录强制修改密码）
- 数据源：`victorialogs`（已自动配置，指向 `http://127.0.0.1:9428`）
- Dashboard：`GoFlow2 流量分析`（已自动导入）

### 5. 验证数据流

```bash
# 查看 GoFlow2 是否产生日志
tail -f /data/goflow2/flow.log

# 查看 Vector 是否正常消费
journalctl -u vector.service -f

# 在 VictoriaLogs 中查询是否有数据
curl -s 'http://127.0.0.1:9428/select/logsql/query?query=vendor:goflow2+%7C+stats+count()'
```

## 端口清单

| 端口 | 协议 | 组件 | 说明 |
|------|------|------|------|
| 2055 | UDP | GoFlow2 | NetFlow v5/v9/IPFIX 接收 |
| 6343 | UDP | GoFlow2 | sFlow 接收 |
| 9428 | TCP | VictoriaLogs | HTTP UI/HTTP API / LogsQL 查询 |
| 3000 | TCP | Grafana | Web 界面 |

脚本会自动通过 firewalld 开放以上端口（如果 firewalld 处于运行状态）。

## 服务管理

```bash
# 启动/停止/重启
systemctl start|stop|restart goflow2
systemctl start|stop|restart victorialogs
systemctl start|stop|restart vector
systemctl start|stop|restart grafana-server

# 查看日志
journalctl -u goflow2.service -f
journalctl -u victorialogs.service -f
journalctl -u vector.service -f
journalctl -u grafana-server.service -f

# 开机自启
systemctl enable goflow2 victorialogs vector grafana-server
```

## 关键路径

| 路径 | 说明 |
|------|------|
| `/data/goflow2/flow.log` | GoFlow2 输出的 JSON 流量日志 |
| `/data/victorialogs/` | VictoriaLogs 数据存储目录 |
| `/usr/local/victorialogs/` | VictoriaLogs 安装目录 |
| `/etc/vector/vector.yaml` | Vector 配置文件 |
| `/etc/default/goflow2` | GoFlow2 启动参数配置 |
| `/etc/systemd/system/victorialogs.service` | VictoriaLogs systemd 服务 |
| `/etc/logrotate.d/goflow2` | GoFlow2 日志滚动配置 |
| `/var/lib/grafana/dashboards/` | Grafana Dashboard 文件目录 |

## 常见问题

### Q1: Grafana 中看不到 VictoriaLogs 数据源或插件未加载

**原因**：Grafana 13.x 默认禁止加载未签名插件。

**解决**：脚本已自动配置 `allow_loading_unsigned_plugins = victorialogs-datasource`。如仍有问题，检查 `/etc/grafana/grafana.ini` 中该配置是否生效，然后重启 Grafana。

### Q2: VictoriaLogs 中查不到数据

**排查步骤**：
1. 确认 GoFlow2 有流量输入：`tail -f /data/goflow2/flow.log`
2. 确认 Vector 正常运行：`journalctl -u vector -f`
3. 确认 Vector 配置中 sink 地址正确：`http://localhost:9428/insert/jsonline`
4. 确认 VictoriaLogs 健康：`curl http://127.0.0.1:9428/health`

### Q4: GoFlow2 的 flow.log 文件不存在

**原因**：没有 NetFlow/sFlow 设备向该服务器发送流量，GoFlow2 不会创建日志文件。

**解决**：配置网络设备将 NetFlow/sFlow 导出到该服务器的 2055/6343 端口，有流量后文件自动生成。

### Q5: 脚本支持重复执行吗？

**支持**。脚本设计为幂等，重复执行不会报错，会覆盖配置并重启服务。

### 

## 网络设备配置参考

以华为设备为例，配置 NetStream 导出到本服务器：

```
ip netstream export version 9
ip netstream export host <服务器IP> 2055
interface <接口>
 ip netstream inbound
 ip netstream outbound
 ip netstream sampler fix-packets 1000 inbound
 ip netstream sampler fix-packets 1000 outbound
```

> 建议使用 NetFlow v9 或 IPFIX，确保采样率通过 Option Template 传递，便于后续带宽计算时做采样率补偿。

## 卸载

如需完全卸载：

```bash
systemctl stop goflow2 victorialogs vector grafana-server
systemctl disable goflow2 victorialogs vector grafana-server
yum remove -y goflow2 vector grafana-enterprise
rm -rf /usr/local/victorialogs /data/victorialogs /data/goflow2
rm -f /etc/systemd/system/victorialogs.service /etc/logrotate.d/goflow2 /etc/default/goflow2
rm -rf /var/lib/grafana /etc/grafana
systemctl daemon-reload
```

## License

本脚本仅供学习和生产部署参考，使用前请根据实际环境调整配置。各软件组件遵循其各自的开源协议。
