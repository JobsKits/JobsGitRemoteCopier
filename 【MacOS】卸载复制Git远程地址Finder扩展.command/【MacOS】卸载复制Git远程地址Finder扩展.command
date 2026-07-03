#!/bin/zsh
# 脚本自述：
# - 脚本名称：【MacOS】卸载复制Git远程地址Finder扩展.command
# - 核心用途：停止并注销 JobsGitRemoteCopier Finder Sync Extension，同时清理旧 Automator 服务版入口。
# - 影响范围：只处理固定扩展、Xcode / 本工作区构建产物和旧 Automator 服务。
# - 运行提示：运行后会先打印内置自述；按回车执行卸载并重启 Finder。按 Ctrl+C 可取消。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename -- "$0")"
WORKSPACE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT_BASENAME=$(basename "$0" | sed 's/\.[^.]*$//')
LOG_FILE="/tmp/${SCRIPT_BASENAME}.log"

EXTENSION_ID="com.jobs.JobsGitRemoteCopier.FinderSyncExtension"
APP_BUNDLE_ID="com.jobs.JobsGitRemoteCopier"
APP_REFRESH_MARKER="/tmp/JobsGitRemoteCopierNeedsFinderRestart"
APP_RUNTIME_LOG="/tmp/JobsGitRemoteCopier.log"
AUTOMATOR_SERVICE_DIR="${HOME}/Library/Services/复制Git远程地址.workflow"
AUTOMATOR_HELPER_SCRIPT="${HOME}/Library/Scripts/Jobs/CopyGitRemoteURL.zsh"
LOCAL_DERIVED_DATA_DIR="${WORKSPACE_DIR}/work/JobsGitRemoteCopierDerivedData"

log()            { echo -e "$1" | tee -a "$LOG_FILE"; }
color_echo()     { log "\033[1;32m$1\033[0m"; }
info_echo()      { log "\033[1;34mℹ $1\033[0m"; }
success_echo()   { log "\033[1;32m✔ $1\033[0m"; }
warn_echo()      { log "\033[1;33m⚠ $1\033[0m"; }
warm_echo()      { log "\033[1;33m$1\033[0m"; }
note_echo()      { log "\033[1;35m➤ $1\033[0m"; }
error_echo()     { log "\033[1;31m✖ $1\033[0m"; }
err_echo()       { log "\033[1;31m$1\033[0m"; }
debug_echo()     { log "\033[1;35m🐞 $1\033[0m"; }
highlight_echo() { log "\033[1;36m🔹 $1\033[0m"; }
gray_echo()      { log "\033[0;90m$1\033[0m"; }
bold_echo()      { log "\033[1m$1\033[0m"; }
underline_echo() { log "\033[4m$1\033[0m"; }

# 初始化 zsh 运行选项和日志文件。
init_runtime() {
  setopt NO_NOMATCH
  : > "$LOG_FILE"
}
# 打印脚本内置自述并等待用户确认阅读。
show_script_intro_and_wait() {
  clear
  highlight_echo "============================== 脚本自述 =============================="
  note_echo "当前脚本：${SCRIPT_PATH}"
  note_echo "核心用途：卸载 Finder 右键菜单里的“复制 Git 远程地址”。"
  warn_echo "影响范围：停止并注销 ${EXTENSION_ID}"
  warn_echo "影响范围：删除 Xcode DerivedData 下的 JobsGitRemoteCopier.app 构建产物。"
  warn_echo "影响范围：删除本工作区 ${LOCAL_DERIVED_DATA_DIR} 旧构建产物。"
  warn_echo "影响范围：删除 ${APP_REFRESH_MARKER} 运行时刷新标记。"
  warn_echo "影响范围：删除旧 Automator 服务 ${AUTOMATOR_SERVICE_DIR}"
  warn_echo "影响范围：自动重启 Finder，刷新 Finder Sync 扩展缓存。"
  warn_echo "执行策略：按回车后立即开始卸载并重启 Finder；按 Ctrl+C 才会取消。"
  gray_echo "不会删除 JobsGitRemoteCopier 工程源码。"
  gray_echo "取消方式：按 Ctrl+C 终止，不会继续执行卸载。"
  gray_echo "日志位置：${LOG_FILE}"
  highlight_echo "======================================================================="
  echo ""

  if [[ ! -t 0 ]]; then
    error_echo "当前没有可交互输入，无法确认卸载。请在终端里运行本脚本。"
    exit 1
  fi

  local _
  read -r "?👉 已了解脚本用途与影响，按回车继续；按 Ctrl+C 取消：" _
}
# 检查卸载流程依赖的系统命令。
check_environment() {
  local missing_commands=()
  local command_name=""

  for command_name in pluginkit pgrep pkill kill killall rm awk grep sed find xargs; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      missing_commands+=("$command_name")
    fi
  done

  if (( ${#missing_commands[@]} > 0 )); then
    error_echo "缺少必要命令：${(j:, :)missing_commands}"
    exit 1
  fi

  if [[ "$(uname -s)" != "Darwin" ]]; then
    error_echo "当前系统不是 MacOS，无法卸载 Finder 扩展。"
    exit 1
  fi
}
# 输出当前 Finder Sync 扩展注册状态，方便卸载前后对比。
print_current_extension_status() {
  note_echo "当前扩展注册状态："
  /usr/bin/pluginkit -m -i "$EXTENSION_ID" -A -D -vv 2>/dev/null | tee -a "$LOG_FILE" || true
}
# 临时禁用 Finder Sync 扩展，避免卸载过程中被 Finder 再次拉起。
disable_extension() {
  note_echo "禁用 Finder Sync 扩展：${EXTENSION_ID}"
  /usr/bin/pluginkit -e ignore -i "$EXTENSION_ID" 2>&1 | tee -a "$LOG_FILE" || true
}
# 停止仍在运行的宿主 App，避免已删除的构建产物继续驻留。
stop_host_application() {
  local pid=""

  note_echo "停止 JobsGitRemoteCopier 宿主 App。"
  /usr/bin/pkill -x 'JobsGitRemoteCopier' 2>/dev/null || true
  /usr/bin/pgrep -f '/JobsGitRemoteCopier.app/Contents/MacOS/JobsGitRemoteCopier' 2>/dev/null | while IFS= read -r pid; do
    if [[ -n "$pid" && "$pid" != "$$" ]]; then
      /bin/kill "$pid" 2>/dev/null || true
    fi
  done
}
# 停止已经被 Finder 拉起的扩展进程。
stop_extension_processes() {
  note_echo "停止 JobsGitRemoteCopyFinderSync 扩展进程。"
  /usr/bin/pkill -f 'JobsGitRemoteCopyFinderSync.appex/Contents/MacOS/JobsGitRemoteCopyFinderSync' 2>/dev/null || true
}
# 清除临时禁用选择并注销 Finder Sync 扩展。
reset_election_and_unregister_extension() {
  note_echo "清除扩展禁用选择，确保下次 Xcode 调试可以重新启用。"
  /usr/bin/pluginkit -e default -i "$EXTENSION_ID" 2>&1 | tee -a "$LOG_FILE" || true

  local extension_paths=()
  extension_paths=("${(@f)$(
    /usr/bin/pluginkit -m -i "$EXTENSION_ID" -A -D -vv 2>/dev/null \
      | /usr/bin/awk -F '= ' '/Path = / {print $2}'
  )}")

  local extension_path=""
  for extension_path in "${extension_paths[@]}"; do
    if [[ -n "$extension_path" && -e "$extension_path" ]]; then
      note_echo "注销扩展路径：${extension_path}"
      /usr/bin/pluginkit -r "$extension_path" 2>&1 | tee -a "$LOG_FILE" || true
    fi
  done
}
# 清理 App 和构建阶段留下的临时标记。
clear_runtime_markers() {
  note_echo "清理 JobsGitRemoteCopier 运行时标记。"
  /bin/rm -f "$APP_REFRESH_MARKER" "$APP_RUNTIME_LOG"
}
# 删除 Xcode DerivedData 下的宿主 App 构建产物。
remove_deriveddata_app_bundles() {
  local app_paths=()
  app_paths=("${(@f)$(
    /usr/bin/find "${HOME}/Library/Developer/Xcode/DerivedData" \
      -path '*JobsGitRemoteCopier*.app' \
      -type d \
      -print 2>/dev/null
  )}")

  local app_path=""
  for app_path in "${app_paths[@]}"; do
    if [[ -n "$app_path" && "$app_path" == "${HOME}/Library/Developer/Xcode/DerivedData/"* ]]; then
      note_echo "删除构建产物：${app_path}"
      /bin/rm -rf "$app_path"
    fi
  done

  if [[ -d "$LOCAL_DERIVED_DATA_DIR" && "$LOCAL_DERIVED_DATA_DIR" == "${WORKSPACE_DIR}/work/"* ]]; then
    note_echo "删除本工作区旧构建产物：${LOCAL_DERIVED_DATA_DIR}"
    /bin/rm -rf "$LOCAL_DERIVED_DATA_DIR"
  else
    gray_echo "未发现本工作区旧构建产物：${LOCAL_DERIVED_DATA_DIR}"
  fi
}
# 清理旧 Automator 服务版右键入口。
remove_legacy_automator_service() {
  if [[ -d "$AUTOMATOR_SERVICE_DIR" ]]; then
    note_echo "删除旧 Automator 服务：${AUTOMATOR_SERVICE_DIR}"
    /bin/rm -rf "$AUTOMATOR_SERVICE_DIR"
  else
    gray_echo "未发现旧 Automator 服务：${AUTOMATOR_SERVICE_DIR}"
  fi

  if [[ -f "$AUTOMATOR_HELPER_SCRIPT" ]]; then
    note_echo "删除旧 Automator 辅助脚本：${AUTOMATOR_HELPER_SCRIPT}"
    /bin/rm -f "$AUTOMATOR_HELPER_SCRIPT"
  else
    gray_echo "未发现旧 Automator 辅助脚本：${AUTOMATOR_HELPER_SCRIPT}"
  fi
}
# 刷新 MacOS Services 缓存，让“服务”子菜单尽快移除旧入口。
refresh_services_cache() {
  local pbs_path="/System/Library/CoreServices/pbs"

  if [[ -x "$pbs_path" ]]; then
    note_echo "刷新 MacOS Services 缓存。"
    "$pbs_path" -flush 2>&1 | tee -a "$LOG_FILE" || true
  else
    gray_echo "未找到 pbs，跳过 Services 缓存刷新。"
  fi
}
# 重启 Finder，强制清掉 Finder Sync 扩展缓存。
restart_finder_after_uninstall() {
  note_echo "重启 Finder，刷新 Finder Sync 扩展缓存。"
  /usr/bin/killall Finder 2>&1 | tee -a "$LOG_FILE" || true
}
# 打印卸载完成后的状态和提示。
print_done_tips() {
  echo ""
  success_echo "卸载流程已完成。"
  gray_echo "Finder 已重启；如果菜单仍短暂显示，请注销后重新登录。"
  gray_echo "工程源码仍保留在 JobsGitRemoteCopier。"
  gray_echo "以后重新运行 Xcode 工程时，App 会再次注册并启用 Finder 扩展。"
  gray_echo "日志位置：${LOG_FILE}"
}
# 编排脚本自述、卸载和刷新流程。
main() {
  show_script_intro_and_wait # 展示卸载影响范围，按回车后开始执行。
  init_runtime # 用户确认后初始化日志和 zsh 运行选项。
  check_environment # 检查卸载依赖的系统命令和 MacOS 环境。
  print_current_extension_status # 输出卸载前扩展注册状态，便于排查。
  disable_extension # 临时禁用 Finder Sync Extension，阻止卸载期间重新拉起。
  stop_host_application # 停止宿主 App，释放即将删除的构建产物。
  stop_extension_processes # 停止已运行的扩展进程。
  reset_election_and_unregister_extension # 清除禁用选择并注销 Finder Sync Extension。
  clear_runtime_markers # 清除 App 运行时刷新标记和旧日志。
  remove_deriveddata_app_bundles # 删除 Xcode DerivedData 里的构建产物。
  remove_legacy_automator_service # 清理旧 Automator 服务版入口。
  refresh_services_cache # 刷新 Services 缓存，移除“服务”子菜单旧入口。
  restart_finder_after_uninstall # 重启 Finder，清掉 Finder Sync 扩展缓存。
  print_done_tips # 输出卸载结果和后续提示。
}

main "$@"
