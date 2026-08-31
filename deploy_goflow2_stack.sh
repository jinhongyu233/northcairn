#!/bin/bash
#==============================================================================
# GoFlow2 + Vector + VictoriaLogs + Grafana 一键部署脚本
# 适配系统: CentOS 7/8/9 / AlmaLinux / Rocky Linux / RHEL
# 数据流: 网络设备 -> GoFlow2(2055/6343) -> file -> Vector -> VictoriaLogs -> Grafana
#==============================================================================
set -euo pipefail

#----------------------------- 颜色与日志函数 -----------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC}  $1"; }

#----------------------------- 前置检查 -----------------------------
if [ "$EUID" -ne 0 ]; then
    log_error "请使用 root 用户执行此脚本"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-unknown}"
else
    log_error "无法识别操作系统 (/etc/os-release 不存在)"
    exit 1
fi

case "$OS_ID" in
    centos|almalinux|rocky|rhel|ol)
        log_info "检测到系统: $OS_PRETTY"
        ;;
    *)
        log_error "不支持的系统: $OS_ID，仅支持 CentOS / AlmaLinux / Rocky Linux / RHEL / OracleLinux"
        exit 1
        ;;
esac

#----------------------------- 变量定义 -----------------------------
GOFLOW2_RPM="goflow2-2.2.6-1.x86_64.rpm"
VECTOR_RPM="vector-0.57.0-1.x86_64.rpm"
GRAFANA_RPM="grafana-enterprise_13.2.0_32077357341_linux_amd64.rpm"
VL_TAR="victoria-logs-linux-amd64-v1.51.1.tar.gz"
VL_PLUGIN_ZIP="victoriametrics-logs-datasource-0.31.0.zip"
CONFIG_DIR="config"

GOFLOW2_LOG_DIR="/data/goflow2"
GOFLOW2_LOG_FILE="${GOFLOW2_LOG_DIR}/flow.log"
VL_INSTALL_DIR="/usr/local/victorialogs"
VL_DATA_DIR="/data/victorialogs"
VL_PORT="9428"
GRAFANA_PORT="3000"
VL_DATASOURCE_NAME="victoriametrics-logs-datasource"
VL_PLUGIN_ID="victoriametrics-logs-datasource"

#----------------------------- 工具函数 -----------------------------
check_file() {
    if [ ! -f "$1" ]; then
        log_error "文件不存在: $1"
        exit 1
    fi
}

check_service() {
    local svc="$1"
    if systemctl is-active --quiet "$svc"; then
        log_info "$svc 运行正常"
        return 0
    else
        log_error "$svc 未运行，请检查: journalctl -u $svc -n 50 --no-pager"
        return 1
    fi
}

#----------------------------- 1. 系统初始化 -----------------------------
init_system() {
    log_step "系统初始化: 安装基础依赖 / 防火墙 / SELinux"

    yum install -y epel-release 2>/dev/null || true
    yum install -y curl wget tar gzip unzip firewalld policycoreutils-python-utils 2>/dev/null || true

    # 防火墙
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        log_info "配置 firewalld 开放端口"
        firewall-cmd --permanent --add-port=2055/udp  >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=6343/udp  >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=${VL_PORT}/tcp  >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-port=${GRAFANA_PORT}/tcp >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        log_info "已开放: 2055/udp(NetFlow) 6343/udp(sFlow) ${VL_PORT}/tcp(VL) ${GRAFANA_PORT}/tcp(Grafana)"
    else
        log_warn "firewalld 未运行，跳过防火墙配置（请自行确保端口可达）"
    fi

    # SELinux
    if [ -x /usr/sbin/getenforce ]; then
        local se_state
        se_state="$(getenforce 2>/dev/null || echo Disabled)"
        if [ "$se_state" = "Enforcing" ]; then
            log_warn "SELinux=Enforcing，临时设置为 Permissive 以避免部署权限问题，并写入配置永久生效"
            setenforce 0 || true
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
        fi
    fi
}

#----------------------------- 2. 部署 GoFlow2 -----------------------------
deploy_goflow2() {
    log_step "部署 GoFlow2"
    check_file "$GOFLOW2_RPM"

    log_info "安装 rpm: $GOFLOW2_RPM"
    yum localinstall -y "$GOFLOW2_RPM"

    log_info "创建目录"
    mkdir -p /usr/share/goflow2
    mkdir -p "$GOFLOW2_LOG_DIR"

    log_info "写入 /etc/default/goflow2"
    cat > /etc/default/goflow2 << 'EOF'
GOFLOW2_ARGS=-listen "sflow://:6343,netflow://:2055" -format "json" -transport file -transport.file /data/goflow2/flow.log
EOF

    # logrotate
    if [ -f "$CONFIG_DIR/goflow2" ]; then
        log_info "安装 logrotate 配置 (来自 config/goflow2)"
        cp "$CONFIG_DIR/goflow2" /etc/logrotate.d/goflow2
        chmod 644 /etc/logrotate.d/goflow2
    else
        log_warn "config/goflow2 不存在，生成默认 logrotate 配置"
        cat > /etc/logrotate.d/goflow2 << 'EOF'
/data/goflow2/flow.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
    dateext
    create 0644 root root
}
EOF
    fi

    log_info "启动 goflow2.service"
    systemctl daemon-reload
    systemctl enable goflow2.service >/dev/null 2>&1 || true
    systemctl restart goflow2.service
    sleep 2
    check_service goflow2.service

    # 等待日志文件生成
    for i in $(seq 1 10); do
        [ -f "$GOFLOW2_LOG_FILE" ] && break
        sleep 1
    done
    [ -f "$GOFLOW2_LOG_FILE" ] && log_info "flow.log 已生成: $GOFLOW2_LOG_FILE" || log_warn "flow.log 尚未生成（无流量时正常）"
    chmod 644 "$GOFLOW2_LOG_FILE" 2>/dev/null || true
}

#----------------------------- 3. 部署 VictoriaLogs -----------------------------
deploy_victorialogs() {
    log_step "部署 VictoriaLogs"
    check_file "$VL_TAR"

    log_info "创建系统用户 victorialogs"
    id victorialogs &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin victorialogs

    log_info "创建目录"
    mkdir -p "$VL_INSTALL_DIR"
    mkdir -p "$VL_DATA_DIR"

    log_info "解压 $VL_TAR -> $VL_INSTALL_DIR"
    # 先清空旧解压内容（保留目录）
    find "$VL_INSTALL_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
    # 解压到临时目录，再把内容平铺到目标目录
    # 兼容 tar 包内含顶层目录 / 直接是文件 两种结构，确保二进制落在 $VL_INSTALL_DIR/ 下
    VL_TMP="$(mktemp -d)"
    tar xf "$VL_TAR" -C "$VL_TMP"
    if [ "$(find "$VL_TMP" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ] && \
       [ -d "$(find "$VL_TMP" -mindepth 1 -maxdepth 1 -type d | head -1)" ]; then
        INNER_DIR="$(find "$VL_TMP" -mindepth 1 -maxdepth 1 -type d | head -1)"
        mv "$INNER_DIR"/* "$VL_INSTALL_DIR"/ 2>/dev/null || true
        mv "$INNER_DIR"/.[!.]* "$VL_INSTALL_DIR"/ 2>/dev/null || true
    else
        mv "$VL_TMP"/* "$VL_INSTALL_DIR"/ 2>/dev/null || true
        mv "$VL_TMP"/.[!.]* "$VL_INSTALL_DIR"/ 2>/dev/null || true
    fi
    rm -rf "$VL_TMP"

    # 校验二进制（victorialogs.service 中写死 ExecStart=/usr/local/victorialogs/victoria-logs-prod）
    VL_BIN="${VL_INSTALL_DIR}/victoria-logs-prod"
    if [ -f "$VL_BIN" ]; then
        chmod +x "$VL_BIN"
        log_info "VictoriaLogs 二进制: $VL_BIN"
    else
        log_error "未找到 $VL_BIN，解压结果如下："
        ls -la "$VL_INSTALL_DIR"
        exit 1
    fi

    log_info "安装 systemd service"
    if [ -f "$CONFIG_DIR/victorialogs.service" ]; then
        cp "$CONFIG_DIR/victorialogs.service" /etc/systemd/system/victorialogs.service
        chmod 644 /etc/systemd/system/victorialogs.service
    else
        log_error "config/victorialogs.service 不存在，无法部署服务"
        exit 1
    fi

    chown -R victorialogs:victorialogs "$VL_DATA_DIR"
    chown -R victorialogs:victorialogs "$VL_INSTALL_DIR"

    log_info "启动 victorialogs.service"
    systemctl daemon-reload
    systemctl enable victorialogs.service >/dev/null 2>&1 || true
    systemctl restart victorialogs.service
    sleep 3
    check_service victorialogs.service

    # 健康检查
    local ok=0
    for i in $(seq 1 15); do
        if curl -sf "http://127.0.0.1:${VL_PORT}/health" >/dev/null 2>&1; then
            ok=1
            break
        fi
        sleep 1
    done
    if [ "$ok" -eq 1 ]; then
        log_info "VictoriaLogs 健康检查通过: http://127.0.0.1:${VL_PORT}"
    else
        log_warn "VictoriaLogs 端口 ${VL_PORT} 暂未响应，请稍后检查 journalctl -u victorialogs"
    fi
}

#----------------------------- 4. 部署 Vector -----------------------------
deploy_vector() {
    log_step "部署 Vector"
    check_file "$VECTOR_RPM"

    log_info "安装 rpm: $VECTOR_RPM"
    yum localinstall -y "$VECTOR_RPM"

    log_info "配置 /etc/vector/vector.yaml"
    if [ -f "$CONFIG_DIR/vector.yaml" ]; then
        log_info "使用 config/vector.yaml"
        cp "$CONFIG_DIR/vector.yaml" /etc/vector/vector.yaml
    else
        log_warn "config/vector.yaml 不存在，生成默认配置 (goflow2 file -> victorialogs)"
        cat > /etc/vector/vector.yaml << 'YAMLEOF'
data_dir: /var/lib/vector

sources:
  goflow:
    type: file
    include:
      - /data/goflow2/*.log

    ignore_older_secs: 600
    read_from: end

transforms:
  goflow_flow_file_tran:
    type: remap
    inputs:
      - goflow

    source: |
      . = parse_json!(.message)
      .vendor = "goflow2"

sinks:
  victorialogs:
    type: http
    inputs:
      - goflow_flow_file_tran
    uri:
      http://localhost:9428/insert/jsonline
    method: post
    encoding:
      codec: json
    framing:
      method: newline_delimited
    request:
      concurrency: adaptive
    healthcheck:
      enabled: false
    batch:
      max_events: 500
      timeout_secs: 2
YAMLEOF
    fi
    chmod 644 /etc/vector/vector.yaml
    chown vector:vector /etc/vector/vector.yaml 2>/dev/null || true

    # 确保 vector 用户可读 goflow2 日志
    chmod 644 "$GOFLOW2_LOG_FILE" 2>/dev/null || true
    chmod 755 "$GOFLOW2_LOG_DIR" 2>/dev/null || true

    # 配置校验
    if command -v vector >/dev/null 2>&1; then
        if vector validate --no-environment /etc/vector/vector.yaml >/dev/null 2>&1; then
            log_info "vector.yaml 配置校验通过"
        else
            log_warn "vector.yaml 校验未通过，请人工检查配置（不影响启动）"
        fi
    fi

    log_info "启动 vector.service"
    systemctl daemon-reload
    systemctl enable vector.service >/dev/null 2>&1 || true
    systemctl restart vector.service
    sleep 2
    check_service vector.service
}

#----------------------------- 5. 部署 Grafana -----------------------------
deploy_grafana() {
    log_step "部署 Grafana + VictoriaLogs 数据源插件"
    check_file "$GRAFANA_RPM"
    check_file "$VL_PLUGIN_ZIP"

    log_info "安装 rpm: $GRAFANA_RPM"
    yum localinstall -y "$GRAFANA_RPM"

    # 安装插件
    log_info "安装 VictoriaLogs datasource 插件: $VL_PLUGIN_ZIP"
    mkdir -p /var/lib/grafana/plugins
    rm -rf /var/lib/grafana/plugins/${VL_PLUGIN_ID}* 2>/dev/null || true
    unzip -o -q "$VL_PLUGIN_ZIP" -d /var/lib/grafana/plugins/
    chown -R grafana:grafana /var/lib/grafana/plugins

    # 允许加载未签名插件 (VictoriaLogs 企业版插件可能未签名)
    log_info "配置 grafana.ini 允许未签名插件: $VL_PLUGIN_ID"
    if grep -q '^allow_loading_unsigned_plugins' /etc/grafana/grafana.ini; then
        sed -i "s/^allow_loading_unsigned_plugins.*/allow_loading_unsigned_plugins = ${VL_PLUGIN_ID}/" /etc/grafana/grafana.ini
    elif grep -q '^;allow_loading_unsigned_plugins' /etc/grafana/grafana.ini; then
        sed -i "s/^;allow_loading_unsigned_plugins.*/allow_loading_unsigned_plugins = ${VL_PLUGIN_ID}/" /etc/grafana/grafana.ini
    else
        echo "allow_loading_unsigned_plugins = ${VL_PLUGIN_ID}" >> /etc/grafana/grafana.ini
    fi

    # 数据源 provisioning
    log_info "配置数据源 provisioning: name=${VL_DATASOURCE_NAME}, url=http://127.0.0.1:${VL_PORT}"
    mkdir -p /etc/grafana/provisioning/datasources
    cat > /etc/grafana/provisioning/datasources/victorialogs.yaml << EOF
apiVersion: 1

datasources:
  - name: ${VL_DATASOURCE_NAME}
    type: ${VL_PLUGIN_ID}
    access: proxy
    url: http://127.0.0.1:${VL_PORT}
    isDefault: true
    editable: true
EOF
    chown grafana:grafana /etc/grafana/provisioning/datasources/victorialogs.yaml

    # Dashboard provisioning
    log_info "配置 Dashboard provisioning"
    mkdir -p /etc/grafana/provisioning/dashboards
    mkdir -p /var/lib/grafana/dashboards
    cat > /etc/grafana/provisioning/dashboards/default.yaml << 'EOF'
apiVersion: 1

providers:
  - name: 'default'
    orgId: 1
    folder: ''
    type: file
    disableDeletion: false
    updateIntervalSeconds: 10
    allowUiUpdates: true
    options:
      path: /var/lib/grafana/dashboards
EOF
    chown grafana:grafana /etc/grafana/provisioning/dashboards/default.yaml

    if [ -f "$CONFIG_DIR/dashboard-goflow2-1.json" ]; then
        cp "$CONFIG_DIR/dashboard-goflow2-1.json" /var/lib/grafana/dashboards/
        chown grafana:grafana /var/lib/grafana/dashboards/dashboard-goflow2-1.json
        log_info "已导入 Dashboard: dashboard-goflow2-1.json"
    else
        log_warn "config/dashboard-goflow2-1.json 不存在，跳过 Dashboard 导入"
    fi

    log_info "启动 grafana-server.service"
    systemctl daemon-reload
    systemctl enable grafana-server.service >/dev/null 2>&1 || true
    systemctl restart grafana-server.service
    sleep 5
    check_service grafana-server.service

    # 等待 grafana 端口
    local ok=0
    for i in $(seq 1 20); do
        if curl -sf "http://127.0.0.1:${GRAFANA_PORT}/api/health" >/dev/null 2>&1; then
            ok=1
            break
        fi
        sleep 1
    done
    if [ "$ok" -eq 1 ]; then
        log_info "Grafana 健康检查通过: http://127.0.0.1:${GRAFANA_PORT}"
    else
        log_warn "Grafana 端口 ${GRAFANA_PORT} 暂未响应，可能仍在启动"
    fi
}

#----------------------------- 6. 最终校验与汇总 -----------------------------
final_summary() {
    echo ""
    echo "============================================================"
    echo -e "${GREEN}  部署完成!${NC}"
    echo "============================================================"
    echo ""
    echo "【服务状态】"
    printf "  %-18s %s\n" "GoFlow2:"       "$(systemctl is-active goflow2.service 2>/dev/null || echo unknown)"
    printf "  %-18s %s\n" "VictoriaLogs:"  "$(systemctl is-active victorialogs.service 2>/dev/null || echo unknown)"
    printf "  %-18s %s\n" "Vector:"        "$(systemctl is-active vector.service 2>/dev/null || echo unknown)"
    printf "  %-18s %s\n" "Grafana:"       "$(systemctl is-active grafana-server.service 2>/dev/null || echo unknown)"
    echo ""
    echo "【监听端口】"
    echo "  GoFlow2     : 2055/udp (NetFlow v5/v9/IPFIX), 6343/udp (sFlow)"
    echo "  VictoriaLogs: ${VL_PORT}/tcp  (http://127.0.0.1:${VL_PORT})"
    echo "  Grafana     : ${GRAFANA_PORT}/tcp  (http://<服务器IP>:${GRAFANA_PORT})"
    echo ""
    echo "【关键路径】"
    echo "  GoFlow2 日志: ${GOFLOW2_LOG_FILE}"
    echo "  VL 数据目录 : ${VL_DATA_DIR}"
    echo "  VL 安装目录 : ${VL_INSTALL_DIR}"
    echo "  Vector 配置 : /etc/vector/vector.yaml"
    echo ""
    echo "【Grafana 访问】"
    echo "  URL      : http://<服务器IP>:${GRAFANA_PORT}"
    echo "  默认账号 : admin / admin (首次登录强制修改密码)"
    echo "  数据源   : ${VL_DATASOURCE_NAME} (已自动配置, 指向 http://127.0.0.1:${VL_PORT})"
    echo "  Dashboard: GoFlow2 流量分析 (已自动导入，如提供了 json)"
    echo ""
    echo "【数据流】"
    echo "  网络设备 --(NetFlow/sFlow)--> GoFlow2 --(JSON file)-->"
    echo "  Vector --(HTTP jsonline)--> VictoriaLogs <--(LogsQL)-- Grafana"
    echo ""
    echo "【常用排错命令】"
    echo "  journalctl -u goflow2.service -f"
    echo "  journalctl -u vector.service -f"
    echo "  journalctl -u victorialogs.service -f"
    echo "  journalctl -u grafana-server.service -f"
    echo "  curl http://127.0.0.1:${VL_PORT}/health"
    echo "  tail -f ${GOFLOW2_LOG_FILE}"
    echo "============================================================"
}

#----------------------------- 主流程 -----------------------------
main() {
    echo ""
    echo "============================================================"
    echo -e "${BLUE}  GoFlow2 + Vector + VictoriaLogs + Grafana 一键部署${NC}"
    echo "  系统  : $OS_PRETTY"
    echo "  目录  : $SCRIPT_DIR"
    echo "============================================================"
    echo ""

    # 检查必备文件
    log_info "检查安装包与配置文件..."
    check_file "$GOFLOW2_RPM"
    check_file "$VECTOR_RPM"
    check_file "$GRAFANA_RPM"
    check_file "$VL_TAR"
    check_file "$VL_PLUGIN_ZIP"
    [ -d "$CONFIG_DIR" ] || { log_error "config 目录不存在: $SCRIPT_DIR/$CONFIG_DIR"; exit 1; }
    log_info "所有安装包与 config 目录就绪"

    init_system
    deploy_goflow2
    deploy_victorialogs
    deploy_vector
    deploy_grafana
    final_summary
}

main "$@"
