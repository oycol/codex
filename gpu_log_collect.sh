#!/bin/bash

readonly SCRIPT_VERSION="2.0"
readonly SCRIPT_UPDATE_DATE="2025-09-24 10:00:00"

readonly DEFAULT_MAX_LOG_LINES=20000
MAX_LOG_LINES=$DEFAULT_MAX_LOG_LINES

show_help() {
    cat << EOF
GPU Log Collection Tool - Optimized Version v${SCRIPT_VERSION}

Usage: $0 [options]

Options:
    --json              Output results in JSON format (for automated scripts)
    --max-lines <num>   Cap collected log output to <num> lines (default: ${DEFAULT_MAX_LOG_LINES})
    --help, -h          Show this help information

Function Description:
    Collect comprehensive system logs required for GPU diagnostics, including:
    - System information and hardware configuration
    - GPU driver and runtime status
    - Network configuration and connection status
    - Error logs and diagnostic information

Output Modes:
    Normal Mode: Color-formatted text output, suitable for human reading
    JSON Mode: Structured JSON output, suitable for program parsing

Examples:
    $0              # Run in normal mode
    $0 --json       # Output in JSON mode
    $0 --help       # Show help information

Author: Kingsoft Cloud Delivery Team
Version: ${SCRIPT_VERSION}
Updated: ${SCRIPT_UPDATE_DATE}

EOF
    exit 0
}
json_output=false

is_positive_integer() {
    [[ $1 =~ ^[1-9][0-9]*$ ]]
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --json)
            json_output=true
            shift
            ;;
        --max-lines)
            if [[ -z $2 ]]; then
                echo "Error: --max-lines requires a numeric argument" >&2
                exit 1
            fi
            if ! is_positive_integer "$2"; then
                echo "Error: --max-lines expects a positive integer" >&2
                exit 1
            fi
            MAX_LOG_LINES=$2
            shift 2
            ;;
        --help|-h)
            show_help
            ;;
        *)
            echo "Unknown parameter: $1"
            echo "Use '$0 --help' to view help information"
            exit 1
            ;;
    esac
done

strip_colors() {
    sed -r 's/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g'
}

readonly DEFAULT_COMMAND_TIMEOUT=30
readonly NVIDIA_SMI_COMMAND_TIMEOUT=240

readonly LOG_RETENTION_DAYS=15

LOG_DIRECTORY=""
LOG_ARCHIVE_FILENAME=""
SYSTEM_SERIAL_NUMBER=""
OPERATING_SYSTEM_FAMILY=""

declare -A PROCESS_EXISTENCE_CACHE
declare -A COMMAND_ERROR_COUNTER

readonly SINGLE_LINE_SEPARATOR="--------------------------------------------------------------------------------"
readonly DOUBLE_LINE_SEPARATOR="================================================================================"

readonly COLOR_GREEN='\e[32m'
readonly COLOR_RED='\e[31m'
readonly COLOR_BLUE='\e[34m'
readonly COLOR_YELLOW='\e[33m'
readonly COLOR_RESET='\e[0m'

readonly EXIT_CODE_SUCCESS=0
readonly EXIT_CODE_TIMEOUT=1
readonly EXIT_CODE_COMMAND_FAILURE=2

init() {
    if [[ $EUID -ne 0 ]]; then
        echo "Error: This script requires root privileges to run" >&2
        exit 1
    fi

    SYSTEM_SERIAL_NUMBER=$(dmidecode -s system-serial-number 2>/dev/null || echo "unknown")
    OPERATING_SYSTEM_FAMILY=$(detect_distro)

    LOG_DIRECTORY=$(mktemp -d -t ksyun_logs_XXXXXX)
    if [[ -z "$LOG_DIRECTORY" || ! -d "$LOG_DIRECTORY" ]]; then
        echo "Error: Unable to create temporary log directory" >&2
        exit 1
    fi

    LOG_ARCHIVE_FILENAME="Ksyun_log_${SYSTEM_SERIAL_NUMBER}_$(date +%Y%m%d_%H%M%S).tar.gz"

    setup_output_redirect

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Log collection started" >> "$LOG_DIRECTORY/error.log"
}

detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID_LIKE" in
            *rhel*|*fedora*|*centos*) echo "redhat" ;;
            *debian*|*ubuntu*) echo "debian" ;;
            *) echo "unknown" ;;
        esac
    else
        [[ -f /etc/redhat-release ]] && echo "redhat" && return
        [[ -f /etc/debian_version ]] && echo "debian" && return
        echo "unknown"
    fi
}

setup_output_redirect() {
    local error_log="$LOG_DIRECTORY/error.log"

    exec 4>&1
    exec 5>&2

    exec >"$error_log" 2>&1

    if [ "$json_output" = true ]; then
        exec 3>"$error_log"
    else
        exec 3> >(tee -a "$error_log" >&4)
    fi
}

restore_output_redirect() {
    exec 1>&4
    exec 2>&5

    exec 4>&-
    exec 5>&-
    exec 3>&-
}

cleanup() {
    restore_output_redirect

    if [ "$json_output" = true ]; then
        cat << EOF
{
    "status": "interrupted",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
    "message": "Log collection interrupted",
    "temp_directory": "$LOG_DIRECTORY"
}
EOF
    else
        echo -e "\n${COLOR_RED}Log collection interrupted, please manually clean up log directory: $LOG_DIRECTORY${COLOR_RESET}"
    fi
    exit 0
}

trap cleanup SIGINT SIGTERM

print_centered() {
    local text="$1"
    local fill_char="${2:- }"
    local term_width=$(tput cols 2>/dev/null || echo 80)
    local text_len=${#text}

    if [ "$json_output" = true ]; then
        return
    fi

    if (( text_len >= term_width )); then
        echo "$text"
        return
    fi

    local padding_len=$(( (term_width - text_len) / 2 ))
    local padding=$(printf '%*s' "$padding_len" '' | tr ' ' "$fill_char")
    echo -e "${padding}${text}${padding}"
}

show_version() {
    print_centered "${COLOR_GREEN}Version: $SCRIPT_VERSION${COLOR_RESET}" >&4
    print_centered "${COLOR_BLUE}Updated: $SCRIPT_UPDATE_DATE${COLOR_RESET}  Current Time: $(date '+%Y-%m-%d %H:%M:%S')" >&4
    print_centered "-------------------------------------" "-" >&4
}

show_progress_with_timeout() {
    local pid=$1
    local timeout=$2
    local msg=$3
    local start_time=$(date +%s)
    local spinstr='|/-\'
    local i=0

    if [ "$json_output" = true ]; then
        while check_process_exists "$pid"; do
            local now=$(date +%s)
            local elapsed=$((now - start_time))

            if (( elapsed >= timeout )); then
                echo "Warning: Process $pid timed out, but was not terminated (for safety)" >> "$LOG_DIRECTORY/error.log"
                return $EXIT_CODE_TIMEOUT
            fi
            sleep 1
        done
        return $EXIT_CODE_SUCCESS
    fi

    while check_process_exists "$pid"; do
        local now=$(date +%s)
        local elapsed=$((now - start_time))

        if (( elapsed >= timeout )); then
            printf "\r${COLOR_RED}[✗] %s  %ds - Timeout!${COLOR_RESET}\n" "$msg" "$elapsed" >&3
            echo "Warning: Process $pid timed out, but was not terminated (for safety)" >> "$LOG_DIRECTORY/error.log"
            return $EXIT_CODE_TIMEOUT
        fi

        printf "\r[%c] %s  %ds" "${spinstr:i%${#spinstr}:1}" "$msg" "$elapsed" >&3
        ((i++))
        sleep 0.1
    done

    local elapsed=$(($(date +%s) - start_time))
    printf "\r${COLOR_GREEN}[✓] %s  %ds - Completed!${COLOR_RESET}\n" "$msg" "$elapsed" >&3
    return $EXIT_CODE_SUCCESS
}

check_process_exists() {
    local pid=$1
    if [[ -n "$pid" ]] && [[ -d "/proc/$pid" ]]; then
        return 0
    else
        return 1
    fi
}

log_message() {
    local level="$1"
    local message="$2"
    local log_file="$3"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local clean_message=$(echo "$message" | strip_colors)

    echo "[$timestamp] [$level] $clean_message" >> "$LOG_DIRECTORY/error.log"

    if [[ -n "$log_file" ]]; then
        echo "[$timestamp] [$level] $clean_message" >> "$log_file"
    fi
}

log_info() {
    log_message "INFO" "$1"
}

log_error() {
    local error_code=$1
    local error_msg=$2
    local log_file=$3
    log_message "ERROR" "[$error_code] $error_msg" "$log_file"
}

collect_system() {
    log_info "Starting system log collection..."

    local boot_count=$(journalctl --list-boots 2>/dev/null | wc -l)
    local have_last_boot=$([[ "$boot_count" -gt 1 ]] && echo true || echo false)

    collect_xid_logs "$have_last_boot" &
    local xid_pid=$!

    collect_journal_logs "$have_last_boot" &
    local journal_pid=$!

    collect_system_deep_info "$have_last_boot" &
    local deep_pid=$!

    wait $xid_pid $journal_pid $deep_pid

    log_info "System log collection completed"
}

collect_xid_logs() {
    local have_last_boot=$1
    local xid_current_log="$LOG_DIRECTORY/xid_current.log"
    local xid_last_log="$LOG_DIRECTORY/xid_last.log"

    echo "Current boot information:" >> "$xid_current_log"
    journalctl --list-boots 2>/dev/null | awk '$1==0{print $0}' >> "$xid_current_log" || echo "Unable to get current boot information" >> "$xid_current_log"
    echo "$SINGLE_LINE_SEPARATOR" >> "$xid_current_log"
    echo "Current boot XID logs:" >> "$xid_current_log"
    journalctl -k -b --no-pager 2>/dev/null | grep -iE 'NVRM: Xid|Sxid' | tail -n "$MAX_LOG_LINES" >> "$xid_current_log" || true

    if $have_last_boot; then
        echo "Last boot information:" >> "$xid_last_log"
        journalctl --list-boots | awk '$1==-1{print $0}' >> "$xid_last_log"
        echo "$SINGLE_LINE_SEPARATOR" >> "$xid_last_log"
        echo "Last boot XID logs:" >> "$xid_last_log"
        journalctl -k -b -1 --no-pager 2>/dev/null | grep -iE 'NVRM: Xid|Sxid' | tail -n "$MAX_LOG_LINES" >> "$xid_last_log" || true
    else
        echo "Last boot XID logs (from traditional log files):" >> "$xid_last_log"
        collect_xid_from_files | tail -n "$MAX_LOG_LINES" >> "$xid_last_log"
    fi
}

collect_xid_from_files() {
    local boot_time=$(who -b 2>/dev/null | awk '{print $3, $4}' || echo "")
    [[ -z "$boot_time" ]] && return

    local syslog_files=("/var/log/syslog" "/var/log/messages")

    for file in "${syslog_files[@]}"; do
        if [[ -f "$file" && -r "$file" ]]; then
            echo "$SINGLE_LINE_SEPARATOR Logs before current boot ($file)"
            awk -v boot_time="$boot_time" '
                BEGIN {
                    cmd="date -d \"" boot_time "\" +%s 2>/dev/null"
                    cmd | getline boot_epoch
                    close(cmd)
                    if (boot_epoch == "") exit 1
                }
                /NVRM: Xid| Sxid/ {
                    log_line=$0
                    cmd="date -d \"" $1 " " $2 " " $3 "\" +%s 2>/dev/null"
                    cmd | getline log_epoch
                    close(cmd)
                    if (log_epoch != "" && log_epoch < boot_epoch) print log_line
                }
            ' "$file" 2>/dev/null || true
            return
        fi
    done

    echo "No available system log files found"
}

collect_journal_logs() {
    local have_last_boot=$1
    local journal_log="$LOG_DIRECTORY/journalctl.log"

    if $have_last_boot; then
        local since_date=$(date -d "${LOG_RETENTION_DAYS} days ago" '+%Y-%m-%d')
        journalctl --since "$since_date" --no-pager --lines="$MAX_LOG_LINES" > "$journal_log" 2>>"$LOG_DIRECTORY/error.log" || {
            log_error $? "journalctl command failed" "$journal_log"
            echo "journalctl command execution failed" > "$journal_log"
        }
    else
        collect_journal_from_files | tail -n "$MAX_LOG_LINES" > "$journal_log"
    fi
}

collect_journal_from_files() {
    local since_date=$(date -d "${LOG_RETENTION_DAYS} days ago" '+%b %e')
    local syslog_files=("/var/log/syslog" "/var/log/messages")

    for file in "${syslog_files[@]}"; do
        if [[ -f "$file" && -r "$file" ]]; then
            awk -v d="$since_date" '
                BEGIN {
                    mon=substr(d,1,3)
                    day=substr(d,5,2)+0
                }
                {
                    log_mon=substr($0,1,3)
                    log_day=substr($0,5,2)+0
                    if (log_mon == mon && log_day >= day) print $0
                }
            ' "$file" | tail -n "$MAX_LOG_LINES"
            return
        fi
    done

    echo "No system log files found"
}

collect_system_deep_info() {
    local have_last_boot=$1
    local sys_log="$LOG_DIRECTORY/sys"

    mkdir -p "$sys_log"

    journalctl -k -b --no-pager --lines="$MAX_LOG_LINES" > "$sys_log/dmesg.log" 2>>"$LOG_DIRECTORY/error.log" || \
        dmesg | tail -n "$MAX_LOG_LINES" > "$sys_log/dmesg.log" 2>>"$LOG_DIRECTORY/error.log"

    if $have_last_boot; then
        journalctl -k -b -1 --no-pager --lines="$MAX_LOG_LINES" > "$sys_log/dmesg_last.log" 2>>"$LOG_DIRECTORY/error.log" || true
    fi

    collect_pstore_logs "$sys_log"

    if $have_last_boot; then
        journalctl --list-boots > "$sys_log/boot.log" 2>>"$LOG_DIRECTORY/error.log" || true
    else
        last | grep reboot > "$sys_log/boot.log" 2>>"$LOG_DIRECTORY/error.log" || true
    fi

    cat /proc/cmdline > "$sys_log/cmdline" 2>>"$LOG_DIRECTORY/error.log" || \
        echo "Unable to read boot parameters" > "$sys_log/cmdline"
}

collect_pstore_logs() {
    local sys_log="$1"
    local pstore_dirs=("/sys/fs/pstore" "/var/lib/pstore")

    for dir in "${pstore_dirs[@]}"; do
        if [[ -d "$dir" && -r "$dir" && "$(ls -A "$dir" 2>/dev/null)" ]]; then
            mkdir -p "$sys_log/pstore"
            cp -r "$dir"/* "$sys_log/pstore/" 2>>"$LOG_DIRECTORY/error.log" || true
            break
        fi
    done
}

collect_pci() {
    echo "Starting PCI log collection..." >> "$LOG_DIRECTORY/error.log"

    local pci_log="$LOG_DIRECTORY/pci.log"

    local pci_devices=$(lspci -PPnn 2>/dev/null)
    local nvidia_dev=$(echo "$pci_devices" | grep -i 'nvidia')
    if [[ -n "$nvidia_dev" ]]; then
        echo "$SINGLE_LINE_SEPARATOR $(echo "$nvidia_dev" | wc -l) Nvidia Device" > "$pci_log"
        echo "$nvidia_dev" >> "$pci_log"
    fi

    echo "$SINGLE_LINE_SEPARATOR Nvidia PCIe Link Status" >> "$pci_log"
    echo "$pci_devices" | grep -i 10de | while read -r line; do
        local full_path=$(echo "$line" | awk '{print $1}')

        if [[ "$full_path" == */* ]]; then
            local device_bus=$(echo "$full_path" | awk -F'/' '{print $NF}')
            printf "Device: %s " "$device_bus" >> "$pci_log"
            lspci -vvv -s "$device_bus" 2>>"$LOG_DIRECTORY/error.log" | grep "LnkSta:" >> "$pci_log" || echo "  No link status found" >> "$pci_log"
        else
            printf "Device: %s " "$full_path"  >> "$pci_log"
            lspci -vvv -s "$full_path" 2>>"$LOG_DIRECTORY/error.log" | grep "LnkSta:" >> "$pci_log" || echo "  No link status found" >> "$pci_log"
        fi
    done

    local network_dev=$(echo "$pci_devices" | grep -iE 'Ethernet controller|InfiniBand controller')
    if [[ -n "$network_dev" ]]; then
        echo "$SINGLE_LINE_SEPARATOR $(echo "$network_dev" | wc -l) Network Device" >> "$pci_log"
        echo "$network_dev" >> "$pci_log"
    fi

    echo "$SINGLE_LINE_SEPARATOR Network PCIe Link Status" >> "$pci_log"
    echo "$pci_devices" | grep -iE 'Ethernet controller|InfiniBand controller' | awk '{print $1}' | while read -r device_bus; do
        local iface=$(basename $(readlink -f "/sys/bus/pci/devices/0000:${device_bus}/net/*" 2>>"$LOG_DIRECTORY/error.log" ) 2>/dev/null || echo "unknown")
        printf "Device: %s" "$iface" >> "$pci_log"
        lspci -vvv -s "$device_bus" 2>>"$LOG_DIRECTORY/error.log" | grep "LnkSta:" >> "$pci_log" || true
    done

    collect_pci_deep_info "$pci_log"

    echo "PCI log collection completed" >> "$LOG_DIRECTORY/error.log"
}

collect_pci_deep_info() {
    local pci_dir="$LOG_DIRECTORY/pci"

    mkdir -p "$pci_dir"
    lspci -vt > "$pci_dir/lspci.log" 2>>"$LOG_DIRECTORY/error.log" || true
    lspci -vt > "$pci_dir/lspci_vt.log" 2>>"$LOG_DIRECTORY/error.log" || true
    lspci -nnvv > "$pci_dir/lspci_nnvv.log" 2>>"$LOG_DIRECTORY/error.log" || true
}

collect_network() {
    echo "Starting network log collection..." >> "$LOG_DIRECTORY/error.log"

    local network_log="$LOG_DIRECTORY/network.log"

    {
        echo "$SINGLE_LINE_SEPARATOR"
        ip -br link show 2>>"$LOG_DIRECTORY/error.log" || echo "Unable to get network interface information"

        echo "$SINGLE_LINE_SEPARATOR"
        ip -br addr show 2>>"$LOG_DIRECTORY/error.log" || echo "Unable to get IP address information"

        echo "$SINGLE_LINE_SEPARATOR"
        collect_network_config

        echo "$SINGLE_LINE_SEPARATOR"
        ip -s addr show 2>>"$LOG_DIRECTORY/error.log" || echo "Unable to get detailed network statistics"
    } > "$network_log"

    echo "Network log collection completed" >> "$LOG_DIRECTORY/error.log"
}

collect_network_config() {
    case $OPERATING_SYSTEM_FAMILY in
        redhat)
            local config_files=(/etc/sysconfig/network-scripts/ifcfg-*)
            for file in "${config_files[@]}"; do
                [[ -f "$file" && -r "$file" ]] && echo "=== $file ===" && cat "$file"
            done
            ;;
        debian)
            [[ -f /etc/network/interfaces ]] && cat /etc/network/interfaces
            ;;
        *)
            echo "Unsupported OS type: $OPERATING_SYSTEM_FAMILY"
            ;;
    esac
}

check_gpu() {
    if lspci -PPnn 2>/dev/null | grep -q -iE '10de:1af1|10de:22a3'; then
        echo "nvlink"
    else
        echo "pcie"
    fi
}

collect_gpu() {
    echo "Starting NVIDIA log collection..." >> "$LOG_DIRECTORY/error.log"
    if ! command -v nvidia-smi &> /dev/null; then
        log_error $EXIT_CODE_COMMAND_FAILURE "nvidia-smi command not available" "$LOG_DIRECTORY/error.log"
        return $EXIT_CODE_COMMAND_FAILURE
    fi

    echo "$SINGLE_LINE_SEPARATOR Nvidia PM Running" >> "$LOG_DIRECTORY/error.log"
    nvidia-smi -pm 1 2>>"$LOG_DIRECTORY/error.log" || log_error $? "Unable to enable persistence mode" "$LOG_DIRECTORY/error.log"

    echo "$SINGLE_LINE_SEPARATOR Start SMI Collecting" >> "$LOG_DIRECTORY/error.log"

    nvidia-smi > "$LOG_DIRECTORY/nvidia-smi.log" 2>>"$LOG_DIRECTORY/error.log" || \
        log_error $? "nvidia-smi basic information collection failed" "$LOG_DIRECTORY/error.log"

    nvidia-smi -q > "$LOG_DIRECTORY/nvidia-smi-q.log" 2>>"$LOG_DIRECTORY/error.log" || \
        log_error $? "nvidia-smi detailed information collection failed" "$LOG_DIRECTORY/error.log"

    if [[ "$(check_gpu)" == "nvlink" ]]; then
        nvidia-smi topo -m 2>>"$LOG_DIRECTORY/error.log" | \
            sed -r "s/\x1B\[[0-9;]*[mGK]//g" | \
            expand -t 8 > "$LOG_DIRECTORY/nvidia-smi-topo.log" || \
            log_error $? "Topology information collection failed" "$LOG_DIRECTORY/error.log"
    fi

    if command -v nvidia-bug-report.sh &> /dev/null; then
        nvidia-bug-report.sh --safe-mode --output-file "$LOG_DIRECTORY/nvidia-bug-report.log" 2>>"$LOG_DIRECTORY/error.log" || \
            log_error $? "Bug report collection failed" "$LOG_DIRECTORY/error.log"
    else
        echo "nvidia-bug-report.sh not available" >> "$LOG_DIRECTORY/error.log"
    fi

    echo "NVIDIA log collection completed" >> "$LOG_DIRECTORY/error.log"
}


run_and_monitor_function() {
    local func_name=$1
    local timeout_sec=$2
    local msg=$3

    export OPERATING_SYSTEM_FAMILY LOG_DIRECTORY

    $func_name &
    local func_pid=$!

    show_progress_with_timeout $func_pid $timeout_sec "$msg"
    return $?
}

output_json_result() {
    local status="$1"
    local log_archive="$2"
    local error_count=$(wc -l < "$LOG_DIRECTORY/error.log" 2>/dev/null || echo "0")

    json_escape() {
        printf '%s' "$1" | sed 's/["\\]/\\&/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g'
    }

    local escaped_serial=$(json_escape "$SYSTEM_SERIAL_NUMBER")
    local escaped_os=$(json_escape "$OPERATING_SYSTEM_FAMILY")
    local escaped_gpu=$(json_escape "$(check_gpu)")
    local escaped_archive=$(json_escape "$log_archive")
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [ "$json_output" = true ]; then
        printf '{
    "status": "%s",
    "timestamp": "%s",
    "system_serial": "%s",
    "os_family": "%s",
    "gpu_type": "%s",
    "log_archive": "%s",
    "max_log_lines": %s
}\n' "$status" "$timestamp" "$escaped_serial" "$escaped_os" "$escaped_gpu" "$escaped_archive" "$MAX_LOG_LINES"

    fi
}

finish_collect() {
    restore_output_redirect

    print_centered "-------------------------------------" "-"
    generate_collection_summary

    if tar -czf "$LOG_ARCHIVE_FILENAME" -C "$LOG_DIRECTORY" . 2>>"$LOG_DIRECTORY/error.log"; then
        if [ "$json_output" = true ]; then
            output_json_result "success" "$(pwd)/$LOG_ARCHIVE_FILENAME"
        else
            print_centered "Log packaged to: $(pwd)/$LOG_ARCHIVE_FILENAME"
        fi
    else
        local exit_code=$?
        if [ "$json_output" = true ]; then
            output_json_result "failed" ""
        else
            print_centered "Log packaging failed! Please check $LOG_DIRECTORY directory"
        fi
        log_error $exit_code "Log packaging failed" "$LOG_DIRECTORY/error.log"
        return 1
    fi
}

generate_collection_summary() {
    {
        echo "$DOUBLE_LINE_SEPARATOR"
        echo "Log Collection Summary"
        echo "Version: ${SCRIPT_VERSION}"
        echo "Updated: ${SCRIPT_UPDATE_DATE}"
        echo "================"
        echo "Collection Time: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "System Serial Number: $SYSTEM_SERIAL_NUMBER"
        echo "Operating System: $OPERATING_SYSTEM_FAMILY"
        echo "GPU Type: $(check_gpu)"
        echo "Log Line Cap: $MAX_LOG_LINES"
        echo ""
        echo "Collected Files:"
        find "$LOG_DIRECTORY" -type f -name "*.log" -o -name "*.txt" | sort
        echo ""
        echo "$DOUBLE_LINE_SEPARATOR"
    } >> "$LOG_DIRECTORY/error.log"
}

readonly TASK_EXECUTION_ORDER=(system pci network gpu)

declare -A COLLECTION_TASKS=(
    ["system"]="Collect system logs"
    ["pci"]="Collect hardware logs"
    ["network"]="Collect network logs"
    ["gpu"]="Collect GPU logs"
)

declare -A TASK_TIMEOUT_VALUES=(
    ["system"]=$DEFAULT_COMMAND_TIMEOUT
    ["pci"]=$DEFAULT_COMMAND_TIMEOUT
    ["network"]=$DEFAULT_COMMAND_TIMEOUT
    ["gpu"]=$NVIDIA_SMI_COMMAND_TIMEOUT
)

main() {
    init

    show_version

    local failed_tasks=()

    for task in "${TASK_EXECUTION_ORDER[@]}"; do
        if ! run_and_monitor_function "collect_${task}" "${TASK_TIMEOUT_VALUES[$task]}" "${COLLECTION_TASKS[$task]}..."; then
            failed_tasks+=("$task")
            if [ "$json_output" == false ]; then
                echo "${COLOR_RED}Task failed: ${COLLECTION_TASKS[$task]}${COLOR_RESET}" >&3
            fi
        fi
    done

    if [[ ${#failed_tasks[@]} -gt 0 ]] && [ "$json_output" == false ]; then
        echo "${COLOR_RED}The following tasks failed: ${failed_tasks[*]}${COLOR_RESET}" >&3
    fi

    finish_collect

    [[ ${#failed_tasks[@]} -eq 0 ]] && exit 0 || exit 1
}

main "$@"
