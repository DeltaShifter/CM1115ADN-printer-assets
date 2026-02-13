#!/bin/bash

# 功能说明:
# 1. 智能检测活跃用户 - 单用户时直接使用，多用户时通过进程分析选择最活跃用户
#    增强检测逻辑：优先查找正在运行安装程序的用户（包含-installer、.deb、.rpm的进程）
# 2. 自动补全DISPLAY环境变量 - 通过who命令或X11套接字检测
# 3. 自动补全XDG_RUNTIME_DIR环境变量 - 基于检测到的用户UID设置
# 4. 支持日志记录和调试 - 详细记录检测过程和结果
# 5. 优化执行效率 - 根据环境变量状态决定是否进行检测

# 动态设置日志文件路径和配置
if [ $# -gt 0 ]; then
    # 提取程序名（去掉路径和扩展名）
    PROGRAM_NAME=$(basename "$1" | sed 's/\.[^.]*$//')
    LOG_FILE="/tmp/display-env-wrapper_${PROGRAM_NAME}.log"
else
    LOG_FILE="/tmp/display-env-wrapper.log"
fi
LOG_MAX_SIZE=1048576  # 1MB in bytes
LOG_ENABLED=false     # 日志开关

# 日志函数 - 带开关、大小限制和轮转功能
log_message() {
    # 检查日志开关
    if [ "$LOG_ENABLED" != "true" ]; then
        return 0
    fi
    
    # 检查日志文件大小
    if [ -f "$LOG_FILE" ]; then
        local log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$log_size" -gt "$LOG_MAX_SIZE" ]; then
            # 轮转日志文件
            mv "$LOG_FILE" "${LOG_FILE}.old" 2>/dev/null || true
            echo "$(date '+%Y-%m-%d %H:%M:%S') - 日志文件达到1MB限制，已轮转" > "$LOG_FILE"
        fi
    fi
    
    # 写入日志
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# 增强的活跃用户检测函数
detect_active_user() {
    # 获取/home目录下的真实用户列表
    local home_users=""
    if [ -d "/home" ]; then
        home_users=$(ls -1 /home 2>/dev/null | tr '\n' '|' | sed 's/|$//')
    fi
    
    # 优先级1: 查找正在运行安装程序的用户（优先真实用户）
    local installer_user=""
    if [ -n "$home_users" ]; then
        installer_user=$(ps -ef | tail -n +2 | awk -v home_users="$home_users" '
            $1 != "root" && match($1, "^(" home_users ")$") && (/-installer/ || /\.deb/ || /\.rpm/) {
                print $1; exit
            }')
    fi
    # 如果真实用户中没找到，再从所有非root用户中找
    if [ -z "$installer_user" ]; then
        installer_user=$(ps -ef | tail -n +2 | awk '
            $1 != "root" && (/-installer/ || /\.deb/ || /\.rpm/) {
                print $1; exit
            }')
    fi
    if [ -n "$installer_user" ]; then
        echo "$installer_user"
        return 0
    fi
    
    # 优先级2: 从真实用户中查找最近的进程
    local recent_user=""
    if [ -n "$home_users" ]; then
        recent_user=$(ps -ef | tail -n +2 | tac | awk -v home_users="$home_users" '
            $1 != "root" && match($1, "^(" home_users ")$") {print $1; exit}')
    fi
    # 如果真实用户中没找到，再从所有非root用户中找
    if [ -z "$recent_user" ]; then
        recent_user=$(ps -ef | tail -n +2 | tac | awk '$1 != "root" {print $1; exit}')
    fi
    if [ -n "$recent_user" ]; then
        echo "$recent_user"
        return 0
    fi
    
    # 保底方案: 从who命令中获取第一个非root用户
    local fallback_user=$(who | grep -v "^root" | head -1 | awk '{print $1}')
    if [ -n "$fallback_user" ]; then
        echo "$fallback_user"
        return 0
    fi
    
    # 如果都失败，返回空
    echo ""
    return 1
}

log_message "=================== 脚本启动 ==================="
log_message "日志文件: $LOG_FILE"
log_message "当前用户: $(whoami), 进程ID: $$"

# 记录初始环境变量
log_message "初始环境: DISPLAY=${DISPLAY:-'未设置'}, WAYLAND=${WAYLAND_DISPLAY:-'未设置'}, XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-'未设置'}"
log_message "登录用户: $(who 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ')"

# 获取当前用户信息
CURRENT_USER=$(whoami)
CURRENT_UID=$(id -u)

# 如果是root用户，检测活跃的图形用户
ACTUAL_DISPLAY_USER="$CURRENT_USER"
ACTUAL_USER_UID="$CURRENT_UID"

if [ "$CURRENT_USER" = "root" ]; then
    log_message "检测root用户，查找活跃的非root用户..."
    
    # 多种方式检查系统中的非root用户，增强健壮性
    NON_ROOT_USERS=""
    
    # 通过who命令检查当前登录用户
    WHO_USERS=$(who 2>/dev/null | grep -v "^root" | awk '{print $1}' | sort -u)
    if [ -n "$WHO_USERS" ]; then
        NON_ROOT_USERS="$WHO_USERS"
        log_message "通过who命令找到用户: $(echo "$WHO_USERS" | tr '\n' ' ')"
    fi
    
    USER_COUNT=$(echo "$NON_ROOT_USERS" | grep -c '^' 2>/dev/null || echo 0)
    
    # 修正计数逻辑：空字符串也会被grep -c计为1，需要特殊处理
    if [ -z "$NON_ROOT_USERS" ]; then
        USER_COUNT=0
    fi
    
    log_message "发现 $USER_COUNT 个非root用户: [$(echo "$NON_ROOT_USERS" | tr '\n' ' ')]"
    
    if [ "$USER_COUNT" -eq 1 ] && [ -n "$NON_ROOT_USERS" ]; then
        # 只有一个用户且不为空，直接使用，无需检测
        SINGLE_USER=$(echo "$NON_ROOT_USERS" | head -1)
        ACTUAL_DISPLAY_USER="$SINGLE_USER"
        ACTUAL_USER_UID=$(id -u "$ACTUAL_DISPLAY_USER" 2>/dev/null || echo "$CURRENT_UID")
        log_message "系统中只有一个有效非root用户，直接使用: $ACTUAL_DISPLAY_USER"
    else
        # 多个用户或无有效用户，需要通过进程检测最活跃的用户
        if [ "$USER_COUNT" -gt 1 ]; then
            log_message "多个用户登录，开始检测最活跃用户..."
        elif [ "$USER_COUNT" -eq 1 ] && [ -z "$NON_ROOT_USERS" ]; then
            log_message "用户计数异常（发现1个但为空），开始检测最活跃用户..."
        else
            log_message "未发现登录的非root用户，开始通过进程检测活跃用户..."
        fi
        
        # 记录进程信息（仅用于日志调试，不影响用户检测逻辑）
        log_message "检查安装程序进程:"
        ps -ef | tail -n +2 | awk '$1 != "root" && (/-installer/ || /\.deb/ || /\.rpm/)' | while IFS= read -r line; do
            log_message "  [安装程序] $line"
        done
        
        log_message "检查最新bash进程:"
        ps -ef | tail -n +2 | tac | awk '$1 != "root" && $8 == "/bin/bash"' | head -5 | while IFS= read -r line; do
            log_message "  [bash进程] $line"
        done
        
        log_message "最近非root进程:"
        ps -ef | tail -n +2 | awk '$1 != "root"' | tail -20 | while IFS= read -r line; do
            log_message "  $line"
        done
        
        # 使用增强检测函数查找活跃用户
        ACTIVE_USER=$(detect_active_user)
        if [ -n "$ACTIVE_USER" ]; then
            ACTUAL_DISPLAY_USER="$ACTIVE_USER"
            ACTUAL_USER_UID=$(id -u "$ACTUAL_DISPLAY_USER" 2>/dev/null || echo "$CURRENT_UID")
            log_message "通过增强检测到最活跃用户: $ACTUAL_DISPLAY_USER"
        else
            # 最后的备用方案：如果有登录用户就用第一个，否则用当前用户
            if [ -n "$NON_ROOT_USERS" ]; then
                ACTUAL_DISPLAY_USER=$(echo "$NON_ROOT_USERS" | head -1)
                ACTUAL_USER_UID=$(id -u "$ACTUAL_DISPLAY_USER" 2>/dev/null || echo "$CURRENT_UID")
                log_message "警告: 未能检测到活跃用户，使用第一个登录用户: $ACTUAL_DISPLAY_USER"
            else
                log_message "警告: 未发现任何非root用户，使用当前用户: $CURRENT_USER"
            fi
        fi
    fi
fi

# 检查并补全DISPLAY环境变量
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
    log_message "DISPLAY未设置，开始检测..."
    
    if [ "$ACTUAL_DISPLAY_USER" != "root" ]; then
        log_message "为用户 $ACTUAL_DISPLAY_USER 进行多方法DISPLAY检测..."
        
        DETECTED_DISPLAY=""
        DETECTION_METHOD=""
        
        # 方法1: 使用 loginctl (systemd) 检测
        log_message "方法1: 尝试使用 loginctl 检测DISPLAY..."
        if command -v loginctl >/dev/null 2>&1; then
            SESSION_ID=$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$ACTUAL_DISPLAY_USER" '$3==u {print $1}' | head -n1)
            if [ -n "$SESSION_ID" ]; then
                LOGINCTL_DISPLAY=$(loginctl show-session "$SESSION_ID" -p Display 2>/dev/null | cut -d= -f2)
                if [ -n "$LOGINCTL_DISPLAY" ]; then
                    DETECTED_DISPLAY="$LOGINCTL_DISPLAY"
                    DETECTION_METHOD="loginctl"
                    log_message "✓ loginctl 检测成功: 会话ID=$SESSION_ID, DISPLAY=$DETECTED_DISPLAY"
                else
                    log_message "✗ loginctl 找到会话但无DISPLAY信息"
                fi
            else
                log_message "✗ loginctl 未找到用户会话"
            fi
        else
            log_message "✗ loginctl 命令不可用"
        fi
        
        # 方法2: 读取桌面会话进程环境变量
        if [ -z "$DETECTED_DISPLAY" ]; then
            log_message "方法2: 尝试从桌面会话进程环境变量检测DISPLAY..."
            DESKTOP_PID=""
            
            # 按优先级检查不同桌面环境的进程
            for desktop_proc in gnome-session plasmashell xfce4-session lxqt-session cinnamon-session mate-session unity-panel-service; do
                DESKTOP_PID=$(pgrep -u "$ACTUAL_DISPLAY_USER" "$desktop_proc" 2>/dev/null | head -n1)
                if [ -n "$DESKTOP_PID" ]; then
                    log_message "  找到桌面进程: $desktop_proc (PID: $DESKTOP_PID)"
                    break
                fi
            done
            
            if [ -n "$DESKTOP_PID" ]; then
                if [ -r "/proc/$DESKTOP_PID/environ" ]; then
                    PROC_DISPLAY=$(tr '\0' '\n' < "/proc/$DESKTOP_PID/environ" 2>/dev/null | grep "^DISPLAY=" | cut -d= -f2)
                    if [ -n "$PROC_DISPLAY" ]; then
                        DETECTED_DISPLAY="$PROC_DISPLAY"
                        DETECTION_METHOD="desktop-process"
                        log_message "✓ 桌面进程环境变量检测成功: PID=$DESKTOP_PID, DISPLAY=$DETECTED_DISPLAY"
                    else
                        log_message "✗ 桌面进程环境变量中无DISPLAY"
                    fi
                else
                    log_message "✗ 无法读取桌面进程环境变量文件"
                fi
            else
                log_message "✗ 未找到桌面会话进程"
            fi
        fi
        
        # 方法3: 通过X11套接字检测（原有方法）
        if [ -z "$DETECTED_DISPLAY" ]; then
            log_message "方法3: 尝试通过X11套接字检测DISPLAY..."
            SOCKET_DISPLAY=""
            log_message "  扫描X11套接字..."
            for socket in /tmp/.X11-unix/X*; do
                if [ -S "$socket" ]; then
                    socket_num=$(basename "$socket" | sed 's/X//')
                    socket_owner=$(stat -c%U "$socket" 2>/dev/null || echo "unknown")
                    log_message "    发现套接字 X$socket_num (所有者: $socket_owner)"
                    
                    # 优先匹配用户所有者的套接字
                    if [ "$socket_owner" = "$ACTUAL_DISPLAY_USER" ]; then
                        SOCKET_DISPLAY=":$socket_num"
                        DETECTED_DISPLAY="$SOCKET_DISPLAY"
                        DETECTION_METHOD="x11-socket-owner"
                        log_message "✓ X11套接字所有者匹配检测成功: DISPLAY=$DETECTED_DISPLAY"
                        break
                    fi
                fi
            done
            
            if [ -z "$DETECTED_DISPLAY" ]; then
                log_message "✗ X11套接字所有者匹配失败"
            fi
        fi
        
        # 方法4: 通过who命令检测（原有备用方法）
        if [ -z "$DETECTED_DISPLAY" ]; then
            log_message "方法4: 尝试通过who命令检测DISPLAY..."
            USER_DISPLAY=$(who | grep "^$ACTUAL_DISPLAY_USER " | grep -o '(:[0-9]*)' | sed 's/[():]//g' | head -1)
            if [ -n "$USER_DISPLAY" ]; then
                DETECTED_DISPLAY=":$USER_DISPLAY"
                DETECTION_METHOD="who-command"
                log_message "✓ who命令检测成功: DISPLAY=$DETECTED_DISPLAY"
            else
                log_message "✗ who命令检测失败"
            fi
        fi
        
        # 设置检测到的DISPLAY
        if [ -n "$DETECTED_DISPLAY" ]; then
            export DISPLAY="$DETECTED_DISPLAY"
            log_message "🎯 DISPLAY检测成功! 方法: $DETECTION_METHOD, 值: $DISPLAY"
        else
            log_message "❌ 所有检测方法均失败"
        fi
    fi
    
    # 如果仍未设置DISPLAY，使用默认值
    if [ -z "$DISPLAY" ]; then
        export DISPLAY=":0"
        DETECTION_METHOD="default-fallback"
        log_message "🔄 使用默认DISPLAY: :0 (所有检测方法失败)"
    fi
else
    log_message "DISPLAY已设置，无需检测"
fi

# 检查并补全XDG_RUNTIME_DIR环境变量
if [ -z "$XDG_RUNTIME_DIR" ]; then
    log_message "XDG_RUNTIME_DIR未设置，开始设置..."
    
    if [ -n "$ACTUAL_USER_UID" ] && [ "$ACTUAL_USER_UID" != "0" ]; then
        export XDG_RUNTIME_DIR="/run/user/$ACTUAL_USER_UID"
        log_message "设置XDG_RUNTIME_DIR: $XDG_RUNTIME_DIR"
    else
        log_message "无法设置XDG_RUNTIME_DIR，用户UID无效"
    fi
else
    log_message "XDG_RUNTIME_DIR已设置，无需修改"
fi

# 记录最终环境变量和执行目标程序
log_message "最终环境: DISPLAY=${DISPLAY:-'未设置'}, XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-'未设置'}, 活跃用户=${ACTUAL_DISPLAY_USER:-'当前用户'}"

# 检查目标程序
if [ $# -eq 0 ]; then
    log_message "未提供目标程序，返回活跃用户: $ACTUAL_DISPLAY_USER"
    echo "ACTUAL_DISPLAY_USER=$ACTUAL_DISPLAY_USER"
    exit 0
fi

TARGET_PROGRAM="$1"
shift

if [ -f "$TARGET_PROGRAM" ] || command -v "$TARGET_PROGRAM" >/dev/null 2>&1; then
    log_message "执行: $TARGET_PROGRAM $*"
else
    log_message "错误: 未找到程序: $TARGET_PROGRAM"
    exit 1
fi

log_message "=================== 脚本结束 ==================="
exec "$TARGET_PROGRAM" "$@"
