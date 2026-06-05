#!/bin/bash
# SGM Bypasser Instant Temp IPv4 - Final Production Version
# (No Discord debug webhook, all logging local)

set -o pipefail

# ---------- Colors ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'
PURPLE='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'

# ---------- Paths & Config ----------
DB_FILE="$HOME/.sgm_bypasser_db.json"
LOG_DIR="/tmp/.sgm_tunnels"
SCRIPT_DIR="$HOME/.sgm_scripts"
API_URL="http://quaxly001.hatenna.com:25452/send"
BOT_INVITE="https://discord.com/oauth2/authorize?client_id=1502918807105175732&permissions=8&integration_type=0&scope=bot+applications.commands"
CF_API_BASE="https://api.cloudflare.com/client/v4"
DEBUG_LOG="$LOG_DIR/debug.log"

mkdir -p "$LOG_DIR" "$SCRIPT_DIR"

# ---------- Local Debug Logger ----------
debug_log() {
    local msg="$1"
    echo "[$(date '+%H:%M:%S')] $msg" >> "$DEBUG_LOG"
}

# ---------- Auto-install dependencies ----------
for cmd in tmux dig jq python3; do
    command -v "$cmd" &> /dev/null && continue
    echo -e "${YELLOW}Installing $cmd...${NC}"
    case "$cmd" in
        tmux) sudo apt-get install -y -qq tmux 2>/dev/null || sudo yum install -y -q tmux 2>/dev/null ;;
        dig)  sudo apt-get install -y -qq dnsutils 2>/dev/null || sudo yum install -y -q bind-utils 2>/dev/null ;;
        jq)   sudo apt-get install -y -qq jq 2>/dev/null || sudo yum install -y -q jq 2>/dev/null ;;
        python3) sudo apt-get install -y -qq python3 2>/dev/null || sudo yum install -y -q python3 2>/dev/null ;;
    esac
done

# ---------- Database ----------
init_db() { [ ! -f "$DB_FILE" ] && echo '{"cf_api_token":null,"zone_ids":{},"profiles":{}}' > "$DB_FILE"; }
load_db() { cat "$DB_FILE"; }
save_db() { echo "$1" > "$DB_FILE"; }

# ---------- Banner ----------
banner() {
    clear
    echo -e "${CYAN}╔════════════════════════════════════════╗"
    echo -e "║    SGM Bypasser Instant Temp IPv4      ║"
    echo -e "╚════════════════════════════════════════╝${NC}"
}

# ---------- Cloudflare API ----------
cf_api_call() {
    local method="$1" endpoint="$2" data="$3"
    local token=$(load_db | jq -r '.cf_api_token // ""')
    [ -z "$token" ] || [ "$token" = "null" ] && { echo '{"success":false}'; return; }
    if [ -n "$data" ]; then
        curl -s -X "$method" "${CF_API_BASE}${endpoint}" \
            -H "Authorization: Bearer ${token}" -H "Content-Type: application/json" --data "$data"
    else
        curl -s -X "$method" "${CF_API_BASE}${endpoint}" -H "Authorization: Bearer ${token}"
    fi
}

get_zone_id() {
    local domain="$1"
    local db=$(load_db)
    local cached=$(echo "$db" | jq -r ".zone_ids.\"$domain\" // \"\"")
    [ -n "$cached" ] && [ "$cached" != "null" ] && { echo "$cached"; return; }
    local resp=$(cf_api_call "GET" "/zones?name=${domain}")
    local zid=$(echo "$resp" | jq -r '.result[0].id // ""')
    if [ -n "$zid" ]; then
        db=$(echo "$db" | jq ".zone_ids.\"$domain\" = \"$zid\"")
        save_db "$db"
        echo "$zid"
    fi
}

# ---------- Setup API Token ----------
setup_api_token() {
    banner
    echo -e "${YELLOW}🔑 Setup Cloudflare API Token${NC}\n"
    local token=$(load_db | jq -r '.cf_api_token // ""')
    if [ -n "$token" ] && [ "$token" != "null" ]; then
        echo -e "${GREEN}✅ Token already set.${NC}"
        echo -ne "${PURPLE}Change? (y/n): ${NC}"; read -r ch; [ "$ch" != "y" ] && return
    fi
    echo -ne "${PURPLE}Paste token: ${NC}"; read -r newtoken
    [ -z "$newtoken" ] && { echo -e "${RED}Empty.${NC}"; sleep 2; return; }
    echo -e "\n${YELLOW}Verifying...${NC}"
    local test=$(curl -s "${CF_API_BASE}/zones" -H "Authorization: Bearer ${newtoken}")
    local cnt=$(echo "$test" | jq '.result | length' 2>/dev/null)
    if [ -n "$cnt" ] && [ "$cnt" != "null" ] && [ "$cnt" != "0" ]; then
        local db=$(load_db); db=$(echo "$db" | jq ".cf_api_token = \"$newtoken\""); save_db "$db"
        echo -e "${GREEN}✅ Token verified & saved.${NC}"; debug_log "API Token saved"
    elif echo "$test" | jq -e '.success == false' >/dev/null 2>&1; then
        echo -e "${RED}❌ Invalid token: $(echo "$test" | jq -r '.errors[0].message')${NC}"
    else
        local db=$(load_db); db=$(echo "$db" | jq ".cf_api_token = \"$newtoken\""); save_db "$db"
        echo -e "${GREEN}✅ Token saved (no zones found).${NC}"; debug_log "API Token saved (no zones)"
    fi
    sleep 2
}

# ---------- List DNS Records (option 9) ----------
list_dns_records() {
    banner
    echo -e "${YELLOW}🌐 Cloudflare DNS Records${NC}\n"
    local token=$(load_db | jq -r '.cf_api_token // ""')
    [ -z "$token" ] || [ "$token" = "null" ] && { echo -e "${RED}Setup API Token first!${NC}"; read -r; return; }
    echo -e "${YELLOW}Fetching zones...${NC}"
    local zones=$(cf_api_call "GET" "/zones")
    local zcount=$(echo "$zones" | jq '.result | length' 2>/dev/null)
    if [ -z "$zcount" ] || [ "$zcount" = "0" ]; then
        echo -e "${RED}No zones found.${NC}"; read -r; return
    fi
    for i in $(seq 0 $((zcount - 1))); do
        local zname=$(echo "$zones" | jq -r ".result[$i].name")
        local zid=$(echo "$zones" | jq -r ".result[$i].id")
        local db=$(load_db); db=$(echo "$db" | jq ".zone_ids.\"$zname\" = \"$zid\""); save_db "$db"
        echo -e "\n${PURPLE}━━━ ${CYAN}$zname${NC} ${PURPLE}━━━${NC}"
        local recs=$(cf_api_call "GET" "/zones/${zid}/dns_records")
        local rcount=$(echo "$recs" | jq '.result | length' 2>/dev/null)
        if [ -n "$rcount" ] && [ "$rcount" != "0" ]; then
            printf "${BLUE}%-5s %-45s %-6s %-20s %-10s${NC}\n" "#" "Name" "Type" "Content" "Proxy"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
            for j in $(seq 0 $((rcount - 1))); do
                local name=$(echo "$recs" | jq -r ".result[$j].name")
                local type=$(echo "$recs" | jq -r ".result[$j].type")
                local content=$(echo "$recs" | jq -r ".result[$j].content")
                local proxied=$(echo "$recs" | jq -r ".result[$j].proxied")
                local pdisp="Gray ☁️"; [ "$proxied" = "true" ] && pdisp="🟠 Orange"
                printf "%-5s ${CYAN}%-45s${NC} %-6s %-20s %-10s\n" "$((j+1))" "$name" "$type" "$content" "$pdisp"
            done
        else
            echo -e "${YELLOW}No records${NC}"
        fi
    done
    echo -ne "\n${PURPLE}Press Enter...${NC}"; read -r
}

# ---------- DNS record create/update ----------
create_or_update_dns() {
    local domain="$1" subdomain="$2" ip="$3"
    local zid=$(get_zone_id "$domain"); [ -z "$zid" ] && return 1
    local fqdn="${subdomain}.${domain}"
    local tok=$(load_db | jq -r '.cf_api_token')
    local ex=$(curl -s "${CF_API_BASE}/zones/${zid}/dns_records?name=${fqdn}" -H "Authorization: Bearer ${tok}")
    local rid=$(echo "$ex" | jq -r '.result[0].id // ""')
    if [ -n "$rid" ] && [ "$rid" != "null" ]; then
        curl -s -X PUT "${CF_API_BASE}/zones/${zid}/dns_records/${rid}" \
            -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}" > /dev/null
        debug_log "DNS updated: $fqdn → $ip"
        return 0
    else
        local resp=$(curl -s -X POST "${CF_API_BASE}/zones/${zid}/dns_records" \
            -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}")
        [ "$(echo "$resp" | jq -r '.success')" = "true" ] && { debug_log "DNS created: $fqdn → $ip"; return 0; }
        # Handle "already exists" by refetching and updating
        if echo "$resp" | jq -r '.errors[0].message' | grep -qi "already exist"; then
            local r2=$(curl -s "${CF_API_BASE}/zones/${zid}/dns_records?name=${fqdn}" -H "Authorization: Bearer ${tok}")
            local r2id=$(echo "$r2" | jq -r '.result[0].id // ""')
            [ -n "$r2id" ] && [ "$r2id" != "null" ] && curl -s -X PUT "${CF_API_BASE}/zones/${zid}/dns_records/${r2id}" \
                -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" \
                --data "{\"type\":\"A\",\"name\":\"${fqdn}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}" > /dev/null
        fi
    fi
}

# ---------- Delete DNS record ----------
delete_dns_record() {
    local domain="$1" subdomain="$2"
    local zid=$(get_zone_id "$domain"); [ -z "$zid" ] && return 1
    local fqdn="${subdomain}.${domain}"
    local tok=$(load_db | jq -r '.cf_api_token')
    local ex=$(curl -s "${CF_API_BASE}/zones/${zid}/dns_records?name=${fqdn}" -H "Authorization: Bearer ${tok}")
    local rid=$(echo "$ex" | jq -r '.result[0].id // ""')
    [ -n "$rid" ] && [ "$rid" != "null" ] && curl -s -X DELETE "${CF_API_BASE}/zones/${zid}/dns_records/${rid}" \
        -H "Authorization: Bearer ${tok}" > /dev/null && debug_log "DNS deleted: $fqdn"
}

# ---------- Get Pinggy IP ----------
get_pinggy_ip() {
    local host=$(echo "$1" | sed -E 's|tcp://([^:]+):[0-9]+|\1|')
    local ip=""
    for i in 1 2 3; do
        ip=$(dig +short "$host" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        [ -z "$ip" ] && ip=$(dig +short "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
        [ -z "$ip" ] && ip=$(host "$host" 2>/dev/null | grep "has address" | awk '{print $NF}' | head -1)
        [ -n "$ip" ] && break
        sleep 2
    done
    echo "$ip"
}

# ---------- Clear Cloudflare Data (option 10) ----------
clear_cf_data() {
    banner
    echo -e "${RED}🗑️  Clear Cloudflare Data${NC}\n"
    echo -ne "${RED}Remove API token, zone cache and ALL profile DNS records? (y/n): ${NC}"; read -r c
    [ "$c" != "y" ] && return
    local db=$(load_db)
    # Delete all profile DNS records
    local profs=$(echo "$db" | jq -r '.profiles | keys[]' 2>/dev/null)
    if [ -n "$profs" ]; then
        while IFS= read -r p; do
            for m in bot webhook; do
                local d=$(echo "$db" | jq -r ".profiles.\"$p\".cf_domain_${m} // \"\"")
                local s=$(echo "$db" | jq -r ".profiles.\"$p\".cf_subdomain_${m} // \"\"")
                [ -n "$d" ] && [ "$d" != "null" ] && [ -n "$s" ] && [ "$s" != "null" ] && delete_dns_record "$d" "$s"
            done
        done <<< "$profs"
    fi
    db=$(echo "$db" | jq '.cf_api_token = null | .zone_ids = {}')
    db=$(echo "$db" | jq '.profiles = (.profiles | map_values(.cf_subdomain_bot = null | .cf_domain_bot = null | .cf_full_domain_bot = null | .cf_subdomain_webhook = null | .cf_domain_webhook = null | .cf_full_domain_webhook = null))')
    save_db "$db"
    debug_log "Cloudflare data cleared"
    echo -e "${GREEN}✅ Cloudflare data cleared.${NC}"; sleep 2
}

# ---------- Tunnel Script Generator ----------
create_tunnel_script() {
    local pname="$1" port="$2" method="$3" uid="$4" wh="$5"
    local spath="$LOG_DIR/${pname}_${method}_tunnel.sh"
    cat > "$spath" << 'EOF'
#!/bin/bash
PROFILE_NAME="$1"; PORT="$2"; METHOD="$3"; USER_ID="$4"; WEBHOOK="$5"
DB_FILE="$HOME/.sgm_bypasser_db.json"; LOG_FILE="/tmp/.sgm_tunnels/${PROFILE_NAME}_${METHOD}.log"
API_URL="http://quaxly001.hatenna.com:25452/send"; CF_API_BASE="https://api.cloudflare.com/client/v4"
DEBUG_LOG="/tmp/.sgm_tunnels/debug.log"

log_msg() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"; }
td() { echo "[$(date '+%H:%M:%S')] [${PROFILE_NAME}:${METHOD}] $1" >> "$DEBUG_LOG"; }
get_token() { python3 -c "import json;f=open('$DB_FILE');db=json.load(f);print(db.get('cf_api_token',''))" 2>/dev/null; }
get_zone_id() { python3 -c "import json;f=open('$DB_FILE');db=json.load(f);print(db.get('zone_ids',{}).get('$1',''))" 2>/dev/null; }
get_pinggy_ip() {
    local h=$(echo "$1" | sed -E 's|tcp://([^:]+):[0-9]+|\1|'); local ip=""
    for a in 1 2 3; do ip=$(dig +short "$h" @8.8.8.8 2>/dev/null|grep -E '^[0-9.]+$'|head -1); [ -z "$ip" ] && ip=$(dig +short "$h" 2>/dev/null|grep -E '^[0-9.]+$'|head -1); [ -z "$ip" ] && ip=$(host "$h" 2>/dev/null|grep "has address"|awk '{print $NF}'|head -1); [ -n "$ip" ] && break; sleep 2; done; echo "$ip"
}

update_cf_dns() {
    local url="$1"; local pp=$(echo "$url"|grep -oE '[0-9]+$')
    local cf_field="cf_full_domain_${METHOD}"
    local cfd=$(python3 -c "import json;f=open('$DB_FILE');db=json.load(f);print(db['profiles']['$PROFILE_NAME'].get('${cf_field}',''))" 2>/dev/null)
    [ -z "$cfd" ] || [ "$cfd" = "null" ] && { td "No CF domain for $METHOD"; return; }
    td "Updating DNS: $cfd"; sleep 3
    local ip=$(get_pinggy_ip "$url"); [ -z "$ip" ] && { td "Failed to resolve IP"; return; }
    td "IP: $ip (Port: $pp)"
    local dom=$(echo "$cfd"|sed 's/^[^.]*\.//'); local sub=$(echo "$cfd"|sed "s/\.${dom}$//")
    local zid=$(get_zone_id "$dom"); [ -z "$zid" ] && { td "Zone not found: $dom"; return; }
    local tok=$(get_token)
    local ex=$(curl -s "${CF_API_BASE}/zones/${zid}/dns_records?name=${cfd}" -H "Authorization: Bearer ${tok}")
    local rid=$(echo "$ex"|jq -r '.result[0].id//""')
    if [ -n "$rid" ] && [ "$rid" != "null" ]; then
        curl -s -X PUT "${CF_API_BASE}/zones/${zid}/dns_records/${rid}" -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"${cfd}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}" > /dev/null
        td "DNS updated: $cfd → $ip"
    else
        local r=$(curl -s -X POST "${CF_API_BASE}/zones/${zid}/dns_records" -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"${cfd}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}")
        if [ "$(echo "$r"|jq -r '.success')" = "true" ]; then td "DNS created: $cfd → $ip"
        elif echo "$r"|jq -r '.errors[0].message'|grep -qi "already exist"; then
            local r2=$(curl -s "${CF_API_BASE}/zones/${zid}/dns_records?name=${cfd}" -H "Authorization: Bearer ${tok}"); local r2id=$(echo "$r2"|jq -r '.result[0].id//""')
            [ -n "$r2id" ] && [ "$r2id" != "null" ] && curl -s -X PUT "${CF_API_BASE}/zones/${zid}/dns_records/${r2id}" -H "Authorization: Bearer ${tok}" -H "Content-Type: application/json" --data "{\"type\":\"A\",\"name\":\"${cfd}\",\"content\":\"${ip}\",\"ttl\":1,\"proxied\":false}" > /dev/null && td "DNS updated: $cfd → $ip"
        fi
    fi
}

send_notification() {
    local url="$1"; local host=$(echo "$url"|sed -E 's|tcp://([^:]+):[0-9]+|\1|')
    local tp=$(echo "$url"|grep -oE '[0-9]+$'); local ts=$(date '+%Y-%m-%d %H:%M:%S'); local lp="$PORT"
EOF

    if [ "$method" = "bot" ]; then
        cat >> "$spath" << 'BOT'
    local cff=$(python3 -c "import json;f=open('$DB_FILE');db=json.load(f);print(db['profiles']['$PROFILE_NAME'].get('cf_full_domain_bot',''))" 2>/dev/null)
    FIELDS=''; [ "$lp" = "22" ] && FIELDS+=",{\"name\":\"➡️ SSH Command\",\"value\":\"\`\`\`ssh -p $tp root@$host\`\`\`\"}"
    FIELDS+=",{\"name\":\"➡️ Pinggy Host\",\"value\":\"$host\",\"inline\":true}"
    FIELDS+=",{\"name\":\"➡️ Tunnel Port\",\"value\":\"$tp\",\"inline\":true}"
    FIELDS+=",{\"name\":\"➡️ Local Port\",\"value\":\"$lp\",\"inline\":true}"
    [ -n "$cff" ] && [ "$cff" != "null" ] && FIELDS+=",{\"name\":\"🌐 Cloudflare URL\",\"value\":\"$cff\",\"inline\":false}" && FIELDS+=",{\"name\":\"🔗 Connect With\",\"value\":\"\`\`\`${cff}:${tp}\`\`\`\",\"inline\":false}"
    curl -s -X POST "$API_URL" -H "Content-Type: application/json" -d "{\"user_id\":\"$USER_ID\",\"profile_name\":\"$PROFILE_NAME\",\"tunnel_url\":\"$url\",\"port\":\"$lp\",\"action\":\"new\",\"embed\":{\"title\":\"🌐 IPv4 Tunnel Active\",\"description\":\"Your tunnel for **$PROFILE_NAME** is ready!\",\"color\":3066993,\"fields\":[${FIELDS:1}],\"footer\":{\"text\":\"SGM Bypasser | 24/7 | $ts\"}}}" > /dev/null 2>&1
    log_msg "Sent to Bot"
BOT
    else
        cat >> "$spath" << 'WEB'
    local cff=$(python3 -c "import json;f=open('$DB_FILE');db=json.load(f);print(db['profiles']['$PROFILE_NAME'].get('cf_full_domain_webhook',''))" 2>/dev/null)
    FIELDS=''; [ "$lp" = "22" ] && FIELDS+=",{\"name\":\"➡️ SSH Command\",\"value\":\"\`\`\`ssh -p $tp root@$host\`\`\`\"}"
    FIELDS+=",{\"name\":\"➡️ Pinggy Host\",\"value\":\"$host\",\"inline\":true}"
    FIELDS+=",{\"name\":\"➡️ Tunnel Port\",\"value\":\"$tp\",\"inline\":true}"
    FIELDS+=",{\"name\":\"➡️ Local Port\",\"value\":\"$lp\",\"inline\":true}"
    [ -n "$cff" ] && [ "$cff" != "null" ] && FIELDS+=",{\"name\":\"🌐 Cloudflare URL\",\"value\":\"$cff\",\"inline\":false}" && FIELDS+=",{\"name\":\"🔗 Connect With\",\"value\":\"\`\`\`${cff}:${tp}\`\`\`\",\"inline\":false}"
    curl -s -X POST "$WEBHOOK" -H "Content-Type: application/json" -d "{\"embeds\":[{\"title\":\"🌐 IPv4 Tunnel Active\",\"description\":\"Your tunnel for **$PROFILE_NAME** is ready!\",\"color\":3066993,\"fields\":[${FIELDS:1}],\"footer\":{\"text\":\"SGM Bypasser | 24/7 | $ts\"}}]}" > /dev/null 2>&1
    log_msg "Sent to Webhook"
WEB
    fi

    cat >> "$spath" << 'EOF'
}
update_db() { python3 -c "import json;f=open('$DB_FILE');db=json.load(f);db['profiles']['$PROFILE_NAME']['tunnel_url_$METHOD']='$1';db['profiles']['$PROFILE_NAME']['tunnel_running_$METHOD']=True;f=open('$DB_FILE','w');json.dump(db,f,indent=2)" 2>/dev/null; }
log_msg "Monitor started: $PROFILE_NAME | Port: $PORT | Method: $METHOD"
td "Monitor started (Port: $PORT)"

while true; do
    log_msg "Starting Pinggy..."
    ssh -p 443 -R0:localhost:$PORT tcp@a.pinggy.io -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR >> "$LOG_FILE" 2>&1 &
    SSH_PID=$!
    URL=""
    for i in $(seq 1 30); do sleep 2; URL=$(grep -oE 'tcp://[a-zA-Z0-9.-]+\.pinggy(-free)?\.(link|io):[0-9]+' "$LOG_FILE" | tail -1); [ -n "$URL" ] && break; kill -0 $SSH_PID 2>/dev/null || { sleep 1; URL=$(grep -oE 'tcp://[a-zA-Z0-9.-]+\.pinggy(-free)?\.(link|io):[0-9]+' "$LOG_FILE" | tail -1); break; }; done
    [ -n "$URL" ] && { log_msg "✅ $URL"; td "Got URL: $URL"; update_db "$URL"; update_cf_dns "$URL"; send_notification "$URL"; }
    wait $SSH_PID 2>/dev/null
    log_msg "❌ Disconnected. Restarting..."; td "Restarting..."; sleep 3
done
EOF
    chmod +x "$spath"
    echo "$spath"
}

# ---------- Tmux helpers ----------
start_tunnel_tmux() {
    local p="$1" port="$2" meth="$3" uid="$4" wh="$5"
    local sn="sgm_${p}_${meth}"
    tmux kill-session -t "$sn" 2>/dev/null; sleep 0.5
    local ts=$(create_tunnel_script "$p" "$port" "$meth" "$uid" "$wh")
    tmux new-session -d -s "$sn" "bash '$ts' '$p' '$port' '$meth' '$uid' '$wh'"
    sleep 2
    if tmux has-session -t "$sn" 2>/dev/null; then
        echo -e "\n${GREEN}✅ Tunnel started (${meth})!${NC}"
        local cf=$(load_db | jq -r ".profiles.\"$p\".cf_full_domain_${meth} // \"\"")
        [ -n "$cf" ] && [ "$cf" != "null" ] && echo -e "${CYAN}🌐 ${cf}${NC}"
        debug_log "Tunnel started: $sn"
        return 0
    else
        echo -e "\n${RED}❌ Failed to start.${NC}"; return 1
    fi
}

stop_tunnel_tmux() {
    local sn="sgm_${1}_${2}"
    tmux has-session -t "$sn" 2>/dev/null && { tmux kill-session -t "$sn"; rm -f "$LOG_DIR/${1}_${2}.log" "$LOG_DIR/${1}_${2}_tunnel.sh"; return 0; }
    return 1
}

is_tunnel_running() { tmux has-session -t "sgm_${1}_${2}" 2>/dev/null; }

# ---------- Setup DNS for a method ----------
setup_dns() {
    local p="$1" meth="$2"
    banner; echo -e "${YELLOW}🌐 Setup DNS for ${meth^}: ${CYAN}$p${NC}\n"
    [ -z "$(load_db | jq -r '.cf_api_token // ""')" ] && { echo -e "${RED}❌ Set API Token first!${NC}"; sleep 2; return; }
    echo -ne "${PURPLE}Subdomain (e.g. dpi): ${NC}"; read -r sub
    [ -z "$sub" ] && { echo -e "${RED}Empty.${NC}"; sleep 2; return; }
    echo -ne "${PURPLE}Domain (e.g. example.com): ${NC}"; read -r dom
    [ -z "$dom" ] && { echo -e "${RED}Empty.${NC}"; sleep 2; return; }
    local fd="${sub}.${dom}"
    echo -ne "${YELLOW}Use ${CYAN}$fd${YELLOW}? (y/n): ${NC}"; read -r c; [ "$c" != "y" ] && return
    echo -e "\n${YELLOW}Fetching zone...${NC}"
    local zid=$(get_zone_id "$dom"); [ -z "$zid" ] && { echo -e "${RED}Zone not found.${NC}"; sleep 2; return; }
    echo -e "${GREEN}✅ Zone found.${NC}"
    local db=$(load_db)
    db=$(echo "$db" | jq ".profiles.\"$p\".cf_full_domain_${meth} = \"$fd\"")
    db=$(echo "$db" | jq ".profiles.\"$p\".cf_domain_${meth} = \"$dom\" | .profiles.\"$p\".cf_subdomain_${meth} = \"$sub\"")
    save_db "$db"
    echo -e "${GREEN}✅ DNS configured. Start tunnel to create record.${NC}"
    debug_log "DNS setup ($meth): $fd"
    sleep 3
}

# ---------- Show method data ----------
show_method_data() {
    local p="$1" meth="$2"
    banner; echo -e "${YELLOW}${meth^} Method Data: ${CYAN}$p${NC}\n"
    local data=$(load_db | jq ".profiles.\"$p\"")
    if [ "$meth" = "bot" ]; then
        echo -e "${BLUE}Discord ID:${NC} $(echo "$data"|jq -r '.user_id//"Not set"')"
        echo -e "${BLUE}Port:${NC} $(echo "$data"|jq -r '.port_bot//"Not set"')"
        local cf=$(echo "$data"|jq -r '.cf_full_domain_bot//""')
    else
        echo -e "${BLUE}Webhook:${NC} $(echo "$data"|jq -r '.webhook//"Not set"')"
        echo -e "${BLUE}Port:${NC} $(echo "$data"|jq -r '.port_webhook//"Not set"')"
        local cf=$(echo "$data"|jq -r '.cf_full_domain_webhook//""')
    fi
    [ -n "$cf" ] && [ "$cf" != "null" ] && echo -e "${BLUE}🌐 Cloudflare:${NC} ${CYAN}$cf${NC}"
    if is_tunnel_running "$p" "$meth"; then
        echo -e "\n${GREEN}✅ Running${NC}"
        local u=$(echo "$data"|jq -r ".tunnel_url_${meth}//\"\"")
        [ "$u" != "null" ] && [ -n "$u" ] && echo -e "${BLUE}Pinggy:${NC} ${CYAN}$u${NC}"
    else
        echo -e "\n${RED}❌ Stopped${NC}"
    fi
    echo -ne "\n${PURPLE}Press Enter...${NC}"; read -r
}

# ---------- Status All ----------
status_all() {
    banner; echo -e "${YELLOW}📊 Status All Profiles${NC}\n"
    local db=$(load_db); local pr=$(echo "$db"|jq -r '.profiles|keys[]' 2>/dev/null)
    [ -z "$pr" ] && { echo -e "${RED}No profiles.${NC}"; read -r; return; }
    printf "${PURPLE}%-15s %-10s %-10s %-12s %-12s %-25s %-25s %-10s${NC}\n" "Profile" "Bot Port" "Web Port" "Bot" "Webhook" "CF Bot" "CF Webhook" "Status"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    while IFS= read -r p; do
        local pb=$(echo "$db"|jq -r ".profiles.\"$p\".port_bot//\"-\""); local pw=$(echo "$db"|jq -r ".profiles.\"$p\".port_webhook//\"-\"")
        local hb=$(echo "$db"|jq -r ".profiles.\"$p\".user_id//\"null\""); local hw=$(echo "$db"|jq -r ".profiles.\"$p\".webhook//\"null\"")
        local cfb=$(echo "$db"|jq -r ".profiles.\"$p\".cf_full_domain_bot//\"-\""); local cfw=$(echo "$db"|jq -r ".profiles.\"$p\".cf_full_domain_webhook//\"-\"")
        local bs="❌"; local ws="❌"; local bc=""; local wc=""
        [ "$hb" != "null" ] && bc="✅"; [ "$hw" != "null" ] && wc="✅"
        is_tunnel_running "$p" "bot" && bs="🟢"; is_tunnel_running "$p" "webhook" && ws="🟢"
        local bd="${bs}"; [ -n "$bc" ] && bd="${bs}(${bc})"; local wd="${ws}"; [ -n "$wc" ] && wd="${ws}(${wc})"
        local ov="Idle"; is_tunnel_running "$p" "bot" || is_tunnel_running "$p" "webhook" && ov="🟢 Active"
        echo -ne "${CYAN}$(printf '%-15s' "$p")${NC} "
        echo -ne "$(printf '%-10s' "$pb") "; echo -ne "$(printf '%-10s' "$pw") "
        echo -ne "$(printf '%-12s' "$bd") "; echo -ne "$(printf '%-12s' "$wd") "
        echo -ne "$(printf '%-25s' "${cfb:0:25}") "; echo -ne "$(printf '%-25s' "${cfw:0:25}") "
        echo -e "$ov"
    done <<< "$pr"
    echo -ne "\n${PURPLE}Press Enter...${NC}"; read -r
}

# ---------- Restart/Stop All ----------
restart_all() {
    banner; echo -e "${YELLOW}🔄 Restart All Tunnels${NC}\n"
    echo -ne "${RED}Continue? (y/n): ${NC}"; read -r c; [ "$c" != "y" ] && return
    local db=$(load_db); local pr=$(echo "$db"|jq -r '.profiles|keys[]' 2>/dev/null)
    [ -z "$pr" ] && { echo -e "${RED}No profiles.${NC}"; sleep 2; return; }
    while IFS= read -r p; do
        local pb=$(echo "$db"|jq -r ".profiles.\"$p\".port_bot"); local pw=$(echo "$db"|jq -r ".profiles.\"$p\".port_webhook")
        local ui=$(echo "$db"|jq -r ".profiles.\"$p\".user_id"); local wh=$(echo "$db"|jq -r ".profiles.\"$p\".webhook")
        is_tunnel_running "$p" "bot" && stop_tunnel_tmux "$p" "bot"
        is_tunnel_running "$p" "webhook" && stop_tunnel_tmux "$p" "webhook"
        sleep 1
        [ "$ui" != "null" ] && [ "$pb" != "null" ] && [ -n "$pb" ] && echo -e "${GREEN}🔄 Bot: ${CYAN}$p${NC}" && start_tunnel_tmux "$p" "$pb" "bot" "$ui" "" > /dev/null 2>&1
        [ "$wh" != "null" ] && [ "$pw" != "null" ] && [ -n "$pw" ] && echo -e "${GREEN}🔄 Webhook: ${CYAN}$p${NC}" && start_tunnel_tmux "$p" "$pw" "webhook" "" "$wh" > /dev/null 2>&1
    done <<< "$pr"
    echo -e "\n${GREEN}✅ Done.${NC}"; sleep 2
}

stop_all() {
    banner; echo -e "${YELLOW}🛑 Stop All Tunnels${NC}\n"
    echo -ne "${RED}Continue? (y/n): ${NC}"; read -r c; [ "$c" != "y" ] && return
    local pr=$(load_db|jq -r '.profiles|keys[]' 2>/dev/null)
    [ -z "$pr" ] && { echo -e "${RED}No profiles.${NC}"; sleep 2; return; }
    while IFS= read -r p; do
        echo -e "${YELLOW}Stopping: ${CYAN}$p${NC}"
        is_tunnel_running "$p" "bot" && stop_tunnel_tmux "$p" "bot" && echo -e "  ${GREEN}✅ Bot${NC}"
        is_tunnel_running "$p" "webhook" && stop_tunnel_tmux "$p" "webhook" && echo -e "  ${GREEN}✅ Webhook${NC}"
    done <<< "$pr"
    echo -e "\n${GREEN}✅ Done.${NC}"; sleep 2
}

# ---------- Main Menu ----------
main_menu() {
    while true; do
        banner
        local token=$(load_db | jq -r '.cf_api_token // ""')
        echo -e "${YELLOW}Welcome to SGM Bypasser Instant Temp IPv4${NC}"
        [ -n "$token" ] && [ "$token" != "null" ] && echo -e "${GREEN}☁️  Cloudflare API: Configured${NC}" || echo -e "${RED}☁️  Cloudflare API: Not Configured${NC}"
        echo -e "\n${BLUE}Choose your options below:${NC}\n"
        echo -e "${GREEN}[1]${NC} Create Profile"; echo -e "${GREEN}[2]${NC} List Profiles"
        echo -e "${GREEN}[3]${NC} Delete Profile"; echo -e "${GREEN}[4]${NC} Open Profile"
        echo -e "${GREEN}[5]${NC} Status All"; echo -e "${GREEN}[6]${NC} Restart All"
        echo -e "${GREEN}[7]${NC} Stop All"; echo -e "${YELLOW}[8]${NC} Setup Cloudflare API Token"
        echo -e "${YELLOW}[9]${NC} Show Cloudflare DNS Records"
        echo -e "${RED}[10]${NC} Clear Cloudflare Data"; echo -e "${RED}[11]${NC} Exit\n"
        echo -ne "${PURPLE}Enter your choice: ${NC}"; read -r ch
        case $ch in
            1) create_profile ;; 2) list_profiles ;; 3) delete_profile ;; 4) open_profile ;;
            5) status_all ;; 6) restart_all ;; 7) stop_all ;; 8) setup_api_token ;;
            9) list_dns_records ;; 10) clear_cf_data ;; 11) cleanup_and_exit ;;
            *) echo -e "\n${RED}Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

# ---------- Profile management ----------
create_profile() {
    banner; echo -e "${YELLOW}Create New Profile${NC}\n"
    echo -ne "${BLUE}Profile name: ${NC}"; read -r n; [ -z "$n" ] && { echo -e "${RED}Empty.${NC}"; sleep 2; return; }
    local db=$(load_db)
    echo "$db" | jq -e ".profiles.\"$n\"" > /dev/null 2>&1 && { echo -e "${RED}Already exists.${NC}"; sleep 2; return; }
    db=$(echo "$db" | jq ".profiles.\"$n\" = {\"user_id\":null,\"webhook\":null,\"port_bot\":null,\"port_webhook\":null,\"cf_subdomain_bot\":null,\"cf_domain_bot\":null,\"cf_full_domain_bot\":null,\"cf_subdomain_webhook\":null,\"cf_domain_webhook\":null,\"cf_full_domain_webhook\":null}")
    save_db "$db"; echo -e "\n${GREEN}✅ Created.${NC}"; sleep 1; profile_menu "$n"
}

list_profiles() {
    banner; echo -e "${YELLOW}Available Profiles${NC}\n"
    local db=$(load_db); local pr=$(echo "$db"|jq -r '.profiles|keys[]' 2>/dev/null)
    [ -z "$pr" ] && { echo -e "${RED}None.${NC}"; read -r; return; }
    local cnt=1
    while IFS= read -r p; do
        local b="❌"; local w="❌"; local cb=""; local cw=""
        is_tunnel_running "$p" "bot" && b="✅"; is_tunnel_running "$p" "webhook" && w="✅"
        local cfb=$(echo "$db"|jq -r ".profiles.\"$p\".cf_full_domain_bot//\"\"")
        local cfw=$(echo "$db"|jq -r ".profiles.\"$p\".cf_full_domain_webhook//\"\"")
        [ -n "$cfb" ] && [ "$cfb" != "null" ] && cb=" | 🌐 $cfb"
        [ -n "$cfw" ] && [ "$cfw" != "null" ] && cw=" | 🌐 $cfw"
        echo -e "${GREEN}[$cnt]${NC} ${CYAN}$p${NC} - Bot: $b$cb | Web: $w$cw"; cnt=$((cnt+1))
    done <<< "$pr"
    echo -ne "\n${PURPLE}Press Enter...${NC}"; read -r
}

delete_profile() {
    banner; echo -e "${YELLOW}Delete Profile${NC}\n"
    local db=$(load_db); local pr=$(echo "$db"|jq -r '.profiles|keys[]' 2>/dev/null)
    [ -z "$pr" ] && { echo -e "${RED}None.${NC}"; sleep 2; return; }
    while IFS= read -r p; do echo -e "  ${CYAN}• $p${NC}"; done <<< "$pr"
    echo -ne "\n${RED}Name: ${NC}"; read -r pn
    echo "$db" | jq -e ".profiles.\"$pn\"" > /dev/null 2>&1 || { echo -e "${RED}Not found.${NC}"; sleep 2; return; }
    is_tunnel_running "$pn" "bot" && stop_tunnel_tmux "$pn" "bot"
    is_tunnel_running "$pn" "webhook" && stop_tunnel_tmux "$pn" "webhook"
    for m in bot webhook; do
        local d=$(echo "$db"|jq -r ".profiles.\"$pn\".cf_domain_${m}//\"\"")
        local s=$(echo "$db"|jq -r ".profiles.\"$pn\".cf_subdomain_${m}//\"\"")
        [ -n "$d" ] && [ "$d" != "null" ] && [ -n "$s" ] && [ "$s" != "null" ] && delete_dns_record "$d" "$s"
    done
    echo -ne "${RED}Confirm? (y/n): ${NC}"; read -r c
    [ "$c" = "y" ] && { db=$(echo "$db"|jq "del(.profiles.\"$pn\")"); save_db "$db"; echo -e "\n${GREEN}✅ Deleted.${NC}"; }
    sleep 2
}

open_profile() {
    banner; echo -e "${YELLOW}Open Profile${NC}\n"
    local pr=$(load_db|jq -r '.profiles|keys[]' 2>/dev/null)
    [ -z "$pr" ] && { echo -e "${RED}None.${NC}"; sleep 2; return; }
    while IFS= read -r p; do echo -e "  ${CYAN}• $p${NC}"; done <<< "$pr"
    echo -ne "\n${PURPLE}Name: ${NC}"; read -r pn
    load_db | jq -e ".profiles.\"$pn\"" > /dev/null 2>&1 && profile_menu "$pn" || { echo -e "${RED}Not found.${NC}"; sleep 2; }
}

profile_menu() {
    local p="$1"
    while true; do
        banner; echo -e "${YELLOW}Profile: ${CYAN}$p${NC}"
        local b="❌"; local w="❌"
        is_tunnel_running "$p" "bot" && b="✅"; is_tunnel_running "$p" "webhook" && w="✅"
        echo -e "Bot: $b | Webhook: $w"
        local db=$(load_db)
        local cfb=$(echo "$db"|jq -r ".profiles.\"$p\".cf_full_domain_bot//\"\"")
        local cfw=$(echo "$db"|jq -r ".profiles.\"$p\".cf_full_domain_webhook//\"\"")
        [ -n "$cfb" ] && [ "$cfb" != "null" ] && echo -e "🌐 Bot DNS: ${CYAN}$cfb${NC}"
        [ -n "$cfw" ] && [ "$cfw" != "null" ] && echo -e "🌐 Web DNS: ${CYAN}$cfw${NC}"
        echo -e "\n${BLUE}Options:${NC}\n"
        echo -e "${GREEN}[1]${NC} Discord Bot"; echo -e "${GREEN}[2]${NC} Webhook"; echo -e "${RED}[3]${NC} Back\n"
        echo -ne "${PURPLE}Choice: ${NC}"; read -r c
        case $c in 1) bot_method "$p" ;; 2) webhook_method "$p" ;; 3) return ;; *) echo -e "${RED}Invalid.${NC}"; sleep 1 ;; esac
    done
}

# ---------- Bot / Webhook submenus ----------
bot_method() {
    local p="$1"
    while true; do
        banner; echo -e "${YELLOW}Bot Method - ${CYAN}$p${NC}"
        is_tunnel_running "$p" "bot" && echo -e "${GREEN}Status: ✅ Running${NC}" || echo -e "${RED}Status: ❌ Stopped${NC}"
        local cf=$(load_db|jq -r ".profiles.\"$p\".cf_full_domain_bot//\"\""); [ -n "$cf" ] && [ "$cf" != "null" ] && echo -e "🌐 ${CYAN}$cf${NC}"
        echo -e "\n${BLUE}Options:${NC}\n"
        echo -e "${GREEN}[1]${NC} Set Discord ID"; echo -e "${GREEN}[2]${NC} Change Discord ID"
        echo -e "${GREEN}[3]${NC} Set Port"; echo -e "${GREEN}[4]${NC} Change Port"
        echo -e "${GREEN}[5]${NC} Setup DNS"; echo -e "${GREEN}[6]${NC} Show Data"
        echo -e "${GREEN}[7]${NC} Start Tunnel"; echo -e "${GREEN}[8]${NC} Stop Tunnel"
        echo -e "${GREEN}[9]${NC} Clear Bot Data"; echo -e "${RED}[10]${NC} Back\n"
        echo -ne "${PURPLE}Choice: ${NC}"; read -r c
        case $c in
            1|2) set_discord_id "$p" ;;
            3|4) set_port "$p" "bot" ;;
            5) setup_dns "$p" "bot" ;;
            6) show_method_data "$p" "bot" ;;
            7) is_tunnel_running "$p" "bot" && { echo -e "\n${YELLOW}⚠️ Already running.${NC}"; sleep 2; } || start_bot_tunnel "$p" ;;
            8) stop_tunnel_tmux "$p" "bot" ;;
            9) echo -ne "\n${RED}Clear? (y/n): ${NC}"; read -r cc
               if [ "$cc" = "y" ]; then
                   local db=$(load_db)
                   local d=$(echo "$db"|jq -r ".profiles.\"$p\".cf_domain_bot//\"\""); local s=$(echo "$db"|jq -r ".profiles.\"$p\".cf_subdomain_bot//\"\"")
                   [ -n "$d" ] && [ "$d" != "null" ] && [ -n "$s" ] && [ "$s" != "null" ] && delete_dns_record "$d" "$s"
                   db=$(echo "$db"|jq ".profiles.\"$p\".user_id = null | .profiles.\"$p\".port_bot = null | .profiles.\"$p\".cf_subdomain_bot = null | .profiles.\"$p\".cf_domain_bot = null | .profiles.\"$p\".cf_full_domain_bot = null")
                   save_db "$db"; echo -e "\n${GREEN}✅ Cleared.${NC}"
               fi; sleep 1 ;;
            10) return ;;
            *) echo -e "${RED}Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

webhook_method() {
    local p="$1"
    while true; do
        banner; echo -e "${YELLOW}Webhook Method - ${CYAN}$p${NC}"
        is_tunnel_running "$p" "webhook" && echo -e "${GREEN}Status: ✅ Running${NC}" || echo -e "${RED}Status: ❌ Stopped${NC}"
        local cf=$(load_db|jq -r ".profiles.\"$p\".cf_full_domain_webhook//\"\""); [ -n "$cf" ] && [ "$cf" != "null" ] && echo -e "🌐 ${CYAN}$cf${NC}"
        echo -e "\n${BLUE}Options:${NC}\n"
        echo -e "${GREEN}[1]${NC} Set Webhook"; echo -e "${GREEN}[2]${NC} Change Webhook"
        echo -e "${GREEN}[3]${NC} Set Port"; echo -e "${GREEN}[4]${NC} Change Port"
        echo -e "${GREEN}[5]${NC} Setup DNS"; echo -e "${GREEN}[6]${NC} Show Data"
        echo -e "${GREEN}[7]${NC} Start Tunnel"; echo -e "${GREEN}[8]${NC} Stop Tunnel"
        echo -e "${GREEN}[9]${NC} Clear Webhook Data"; echo -e "${RED}[10]${NC} Back\n"
        echo -ne "${PURPLE}Choice: ${NC}"; read -r c
        case $c in
            1|2) set_webhook "$p" ;;
            3|4) set_port "$p" "webhook" ;;
            5) setup_dns "$p" "webhook" ;;
            6) show_method_data "$p" "webhook" ;;
            7) is_tunnel_running "$p" "webhook" && { echo -e "\n${YELLOW}⚠️ Already running.${NC}"; sleep 2; } || start_webhook_tunnel "$p" ;;
            8) stop_tunnel_tmux "$p" "webhook" ;;
            9) echo -ne "\n${RED}Clear? (y/n): ${NC}"; read -r cc
               if [ "$cc" = "y" ]; then
                   local db=$(load_db)
                   local d=$(echo "$db"|jq -r ".profiles.\"$p\".cf_domain_webhook//\"\""); local s=$(echo "$db"|jq -r ".profiles.\"$p\".cf_subdomain_webhook//\"\"")
                   [ -n "$d" ] && [ "$d" != "null" ] && [ -n "$s" ] && [ "$s" != "null" ] && delete_dns_record "$d" "$s"
                   db=$(echo "$db"|jq ".profiles.\"$p\".webhook = null | .profiles.\"$p\".port_webhook = null | .profiles.\"$p\".cf_subdomain_webhook = null | .profiles.\"$p\".cf_domain_webhook = null | .profiles.\"$p\".cf_full_domain_webhook = null")
                   save_db "$db"; echo -e "\n${GREEN}✅ Cleared.${NC}"
               fi; sleep 1 ;;
            10) return ;;
            *) echo -e "${RED}Invalid.${NC}"; sleep 1 ;;
        esac
    done
}

start_bot_tunnel() {
    local p="$1"; local db=$(load_db)
    local uid=$(echo "$db"|jq -r ".profiles.\"$p\".user_id"); local port=$(echo "$db"|jq -r ".profiles.\"$p\".port_bot")
    [ "$uid" = "null" ] || [ "$port" = "null" ] && { echo -e "\n${RED}❌ Set ID and Port first.${NC}"; sleep 2; return; }
    start_tunnel_tmux "$p" "$port" "bot" "$uid" ""
}

start_webhook_tunnel() {
    local p="$1"; local db=$(load_db)
    local wh=$(echo "$db"|jq -r ".profiles.\"$p\".webhook"); local port=$(echo "$db"|jq -r ".profiles.\"$p\".port_webhook")
    [ "$wh" = "null" ] || [ "$port" = "null" ] && { echo -e "\n${RED}❌ Set Webhook and Port first.${NC}"; sleep 2; return; }
    start_tunnel_tmux "$p" "$port" "webhook" "" "$wh"
}

set_discord_id() {
    banner; echo -e "${YELLOW}Set Discord ID${NC}\n"
    echo -ne "${BLUE}Paste ID: ${NC}"; read -r id; [ -z "$id" ] && { echo -e "${RED}Empty.${NC}"; sleep 2; return; }
    echo -ne "${YELLOW}Confirm ${CYAN}$id${YELLOW}? (y/n): ${NC}"; read -r c
    [ "$c" = "y" ] && { local db=$(load_db); db=$(echo "$db"|jq ".profiles.\"$1\".user_id = \"$id\""); save_db "$db"; echo -e "\n${GREEN}✅ Saved.${NC}"; }
    sleep 1
}

set_port() {
    local p="$1" m="$2"
    banner; echo -e "${YELLOW}Set ${m^} Port${NC}\n"
    echo -ne "${BLUE}Port: ${NC}"; read -r port; [[ ! "$port" =~ ^[0-9]+$ ]] && { echo -e "${RED}Invalid.${NC}"; sleep 2; return; }
    echo -ne "${YELLOW}Port ${CYAN}$port${YELLOW}? (y/n): ${NC}"; read -r c
    [ "$c" = "y" ] && { local db=$(load_db); db=$(echo "$db"|jq ".profiles.\"$p\".port_${m} = \"$port\""); save_db "$db"; echo -e "\n${GREEN}✅ Saved.${NC}"; }
    sleep 1
}

set_webhook() {
    banner; echo -e "${YELLOW}Set Webhook${NC}\n"
    echo -ne "${BLUE}URL: ${NC}"; read -r wh; [ -z "$wh" ] && { echo -e "${RED}Empty.${NC}"; sleep 2; return; }
    echo -e "\n${YELLOW}Testing...${NC}"; curl -s -X POST "$wh" -H "Content-Type: application/json" -d '{"content":"✅ Test!"}' > /dev/null 2>&1
    echo -ne "${YELLOW}Received? (y/n): ${NC}"; read -r c
    [ "$c" = "y" ] && { local db=$(load_db); db=$(echo "$db"|jq ".profiles.\"$1\".webhook = \"$wh\""); save_db "$db"; echo -e "\n${GREEN}✅ Saved.${NC}"; }
    sleep 2
}

cleanup_and_exit() {
    echo -e "\n${YELLOW}Stopping all...${NC}"
    tmux ls 2>/dev/null | grep '^sgm_' | cut -d: -f1 | while read -r s; do tmux kill-session -t "$s" 2>/dev/null; done
    rm -f "$LOG_DIR"/*.log "$LOG_DIR"/*_tunnel.sh
    echo -e "${GREEN}Goodbye!${NC}"; exit 0
}
trap cleanup_and_exit SIGINT SIGTERM

# ---------- Start ----------
init_db
debug_log "🚀 SGM Bypasser started"
main_menu
