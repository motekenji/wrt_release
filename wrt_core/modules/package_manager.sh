#!/usr/bin/env bash
# 包管理器（apk / opkg）选择与构建配置修正。
#
# 选择规则：
#   PACKAGE_MANAGER=auto（默认）  上游源码树支持 apk 时用 apk，否则用 opkg
#   PACKAGE_MANAGER=apk          强制 apk，源码树不支持时报错退出
#   PACKAGE_MANAGER=opkg         强制 opkg

# 输出 Kconfig 中 USE_APK 的定义块（到下一个 config 条目为止）。
apk_kconfig_block() {
    local kconfig_file=$1

    awk '
        /^[[:space:]]*(menu)?config[[:space:]]/ {
            if (found)
                exit
            if ($0 ~ /USE_APK/)
                found = 1
        }
        found { print }
    ' "$kconfig_file"
}

# 上游源码树是否支持 apk 包管理器。
# 需要同时具备 Kconfig 开关与 package/system/apk 实现（25.12 起默认）。
# OpenWrt 24.10 中 USE_APK 依赖 BROKEN，视作不支持。
apk_supported_in_tree() {
    local build_dir=${1:?}
    local kconfig_file
    local block

    [ -f "$build_dir/package/system/apk/Makefile" ] || return 1

    for kconfig_file in "$build_dir/config/Config-build.in" "$build_dir/Config.in"; do
        [ -f "$kconfig_file" ] || continue

        block=$(apk_kconfig_block "$kconfig_file")
        [ -n "$block" ] || continue

        if printf '%s\n' "$block" | grep -q 'depends on BROKEN'; then
            return 1
        fi

        return 0
    done

    return 1
}

# 源码树的 Kconfig 是否定义了某个符号（用于按版本决定是否写入该选项）。
kconfig_symbol_exists() {
    local build_dir=${1:?}
    local symbol=${2:?}
    local kconfig_file

    for kconfig_file in "$build_dir"/config/*.in "$build_dir"/Config.in; do
        [ -f "$kconfig_file" ] || continue
        if grep -qE "^[[:space:]]*(menu)?config[[:space:]]+${symbol}[[:space:]]*$" "$kconfig_file"; then
            return 0
        fi
    done

    return 1
}

# 读取并校验 PACKAGE_MANAGER 环境变量，输出 auto / apk / opkg。
requested_package_manager() {
    local requested

    requested=$(printf '%s' "${PACKAGE_MANAGER:-auto}" | tr '[:upper:]' '[:lower:]')

    case "$requested" in
        ""|auto)
            printf 'auto\n'
            ;;
        apk|opkg)
            printf '%s\n' "$requested"
            ;;
        *)
            printf '错误：PACKAGE_MANAGER 只能为 auto、apk 或 opkg（当前为 "%s"）。\n' "${PACKAGE_MANAGER}" >&2
            return 1
            ;;
    esac
}

# 结合源码树能力与用户要求，输出最终使用的包管理器（apk / opkg）。
resolve_package_manager() {
    local build_dir=${1:?}
    local requested

    requested=$(requested_package_manager) || return 1

    case "$requested" in
        opkg)
            printf 'opkg\n'
            return 0
            ;;
        apk)
            if ! apk_supported_in_tree "$build_dir"; then
                printf '错误：上游源码树不支持 apk 包管理器（未找到可用的 CONFIG_USE_APK）。\n' >&2
                printf '      构建目录：%s\n' "$build_dir" >&2
                printf '      请改用 PACKAGE_MANAGER=opkg，或选择基于 OpenWrt 25.12 及更新版本的设备配置。\n' >&2
                return 1
            fi
            printf 'apk\n'
            return 0
            ;;
        auto)
            if apk_supported_in_tree "$build_dir"; then
                printf 'apk\n'
            else
                printf 'opkg\n'
            fi
            return 0
            ;;
    esac
}

# .config 是否已启用 apk。
config_uses_apk() {
    local config_file=${1:?}

    [ -f "$config_file" ] && grep -qE '^CONFIG_USE_APK=y' "$config_file"
}

# 在 .config 中写入单个 Kconfig 选项（覆盖已有赋值与 "# ... is not set" 行）。
set_config_symbol() {
    local config_file=$1
    local symbol=$2
    local value=$3

    if grep -qE "^${symbol}=" "$config_file"; then
        sed -i "s|^${symbol}=.*|${symbol}=${value}|" "$config_file"
    elif grep -qE "^# ${symbol} is not set" "$config_file"; then
        sed -i "s|^# ${symbol} is not set|${symbol}=${value}|" "$config_file"
    else
        printf '%s=%s\n' "$symbol" "$value" >>"$config_file"
    fi
}

# 必须在 make defconfig 之前调用：Kconfig 依据 USE_APK 重新计算默认包
# （apk-mbedtls 取代 opkg）以及依赖关系。
apply_package_manager_config() {
    local config_file=${1:?}
    local package_manager=${2:?}
    local build_dir=${3:?}

    case "$package_manager" in
        apk)
            set_config_symbol "$config_file" "CONFIG_USE_APK" "y"
            # 同一镜像内同时保留 apk 与 opkg 会互相破坏包数据库，显式关闭 opkg。
            set_config_symbol "$config_file" "CONFIG_PACKAGE_opkg" "n"

            # 每个 feed 单独成仓库时，base-files 才会把 base/luci/packages/... 的
            # packages.adb 一并写进 /etc/apk/repositories.d/distfeeds.list。
            if kconfig_symbol_exists "$build_dir" "PER_FEED_REPO"; then
                set_config_symbol "$config_file" "CONFIG_PER_FEED_REPO" "y"
            fi

            # iStore 系插件按 opkg 设计，apk 固件内无法正常装卸软件包；需要时
            # 可用 APK_KEEP_ISTORE=1 保留。
            if [ "${APK_KEEP_ISTORE:-0}" != "1" ]; then
                set_config_symbol "$config_file" "CONFIG_PACKAGE_luci-app-istorex" "n"
                set_config_symbol "$config_file" "CONFIG_PACKAGE_luci-app-store" "n"
            fi
            ;;
        opkg)
            set_config_symbol "$config_file" "CONFIG_USE_APK" "n"
            ;;
    esac
}

# make defconfig 之后校验结果，避免出现“要求 apk 却编出 opkg 固件”的静默错误。
verify_package_manager_config() {
    local config_file=${1:?}
    local package_manager=${2:?}

    if [ "$package_manager" = "apk" ]; then
        if ! config_uses_apk "$config_file"; then
            printf '错误：已选择 apk，但 make defconfig 后 .config 中 CONFIG_USE_APK 未生效。\n' >&2
            printf '      请检查上游 %s 中 USE_APK 是否被 BROKEN 条件或依赖遮蔽。\n' "$config_file" >&2
            return 1
        fi

        if grep -qE '^CONFIG_PACKAGE_opkg=y' "$config_file"; then
            if [ "${APK_ALLOW_OPKG:-0}" = "1" ]; then
                printf '警告：apk 模式下 .config 仍启用了 opkg（已设置 APK_ALLOW_OPKG=1，跳过检查）。\n' >&2
            else
                printf '错误：apk 模式下 .config 仍启用了 opkg，镜像内会同时存在两套包管理器。\n' >&2
                printf '      通常是某个已选包硬依赖 opkg 所致：请关闭该包，或设置 APK_ALLOW_OPKG=1 跳过检查。\n' >&2
                return 1
            fi
        fi

        if grep -qE '^CONFIG_PACKAGE_luci-app-(istorex|store)=y' "$config_file"; then
            printf '提示：iStore 系插件（luci-app-istorex / luci-app-store）按 opkg 设计，\n' >&2
            printf '      apk 固件中可能无法正常装卸软件；如必须使用请改回 PACKAGE_MANAGER=opkg。\n' >&2
        fi
    else
        if config_uses_apk "$config_file"; then
            printf '错误：已选择 opkg，但 .config 中 CONFIG_USE_APK=y。\n' >&2
            return 1
        fi
    fi
}

# 打印最终包管理器说明。
describe_package_manager() {
    case "$1" in
        apk)
            echo "包管理器：apk（命令 /usr/bin/apk，软件源 /etc/apk/repositories.d/distfeeds.list，软件包格式 .apk）"
            ;;
        opkg)
            echo "包管理器：opkg（命令 /bin/opkg，软件源 /etc/opkg/distfeeds.conf，软件包格式 .ipk）"
            ;;
        *)
            echo "包管理器：$1"
            ;;
    esac
}
