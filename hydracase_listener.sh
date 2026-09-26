#!/usr/bin/env bash

# ==============================================================================
#
# hydracase_listener.sh Ver2.22 by rbruzzon@redhat.com
#
# ==============================================================================

# ==============================================================================
# CONFIGURATION & CONSTANTS
# ==============================================================================
SLACK_TEAM_ID="E030G10V24F"           # Slack Enterprise Team ID
TARGET_CHANNEL_ID="D04NRQ0PNJV"       # Direct Message channel with HydraCaseBot
BOT_USER_ID="U04JNCVBVNU"             # HydraCaseBot User ID
CURRENT_USER="${USER:-$(whoami)}"
TARGET_EMAIL="${CURRENT_USER}@redhat.com" # Auto-resolves current Linux user email
SMTP_SERVER="smtp.corp.redhat.com:25" # Internal SMTP Relay Server
POLL_INTERVAL=15                      # Polling Interval (in seconds)
LAST_SEEN_FILE="/tmp/hydracase_last_seen_${CURRENT_USER}.txt"

# SAML SSO Direct URLs
SLACK_SAML_URL="https://redhat.enterprise.slack.com/sso/saml/start?redir=%2Fclient%2F${SLACK_TEAM_ID}%2F${TARGET_CHANNEL_ID}"
SLACK_HEADLESS_URL="https://app.slack.com/client/${SLACK_TEAM_ID}/${TARGET_CHANNEL_ID}"

# ------------------------------------------------------------------------------
# LOGGING & DEBUG CONFIGURATION
# ------------------------------------------------------------------------------
DEBUG_MODE=true                       # Set to 'true' for verbose execution logs
SHOW_CREDENTIALS_DUMP=false           # Set to 'false' to hide raw TOKEN & COOKIE strings
DUMP_RAW_MESSAGES=true                # Set to 'true' to dump raw Slack JSON messages
# ------------------------------------------------------------------------------

# Automatic Profile Directory Resolver
FF_BASE_DIR="/home/${CURRENT_USER}/.mozilla/firefox"
FF_PROFILE_DIR=$(find "$FF_BASE_DIR" -maxdepth 1 -type d \( -name "*default-redhat*" -o -name "*RedHat*" -o -name "*.default-release*" -o -name "*.default*" \) 2>/dev/null | head -n 1)
FF_USER_JS="${FF_PROFILE_DIR}/user.js"

# Logging Helpers
log_debug() { [ "$DEBUG_MODE" = true ] && echo -e "[\e[34mDEBUG\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_success() { echo -e "[\e[32mOK\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo -e "[\e[33mWARN\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "[\e[31mERROR\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# ==============================================================================
# HELP & SETUP GUIDE
# ==============================================================================
show_help() {
    cat << EOF
HydraCaseBot Slack-to-Email Listener Service (Ver2.22)

Usage:
  ./hydracase_listener.sh [OPTION]

Options:
  -h, --help        Show this help menu and setup instructions

--------------------------------------------------------------------------------
CONFIGURATION & SETUP GUIDE
--------------------------------------------------------------------------------
1. Prerequisites & Dependencies:
   - Ensure 'jq', 'curl', 'sqlite3', 's-nail' (mailx), and Python packages are installed:
       $ sudo dnf install -y jq curl sqlite coreutils s-nail xdotool python3-pip
       $ pip install browser-cookie3 --user

2. DEBUG & CREDENTIAL LOGGING CONTROL:
   - DEBUG_MODE=true|false            : Enables or disables general execution logging.
   - SHOW_CREDENTIALS_DUMP=true|false : Set to 'false' to hide raw TOKEN and COOKIE strings.
   - DUMP_RAW_MESSAGES=true|false     : Set to 'true' to dump raw Slack JSON messages for debugging.

3. FIREFOX AUTOMATIC PROFILE LOCATION:
   - Automatically binds directly to profile path: ${FF_PROFILE_DIR:-"NOT FOUND"}

4. AUTOMATED SAML SSO BOOTSTRAP & HEADLESS REFRESH:
   - Enforces Kerberos SPNEGO preferences directly into Firefox's user.js.
   - Dynamic Auto-Bootstrap: If 'data.sqlite' or token xoxc- is missing, launches GUI Firefox,
     monitors 'data.sqlite' creation dynamically every second, kills Firefox upon generation,
     and seamlessly transitions to headless background execution.
   - Headless Renewal: Background polling pings Slack headlessly without opening any GUI window.

5. Running the Service:
   - Standard foreground execution:
       $ ./hydracase_listener.sh
   - Running in background:
       $ nohup ./hydracase_listener.sh > /tmp/hydracase.log 2>&1 &
--------------------------------------------------------------------------------
EOF
}

# Handle Help menu before enabling process traps
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# ==============================================================================
# CLEANUP & TRAP MANAGEMENT
# ==============================================================================
kill_target_firefox() {
    log_debug "Killing any background Firefox instances and cleaning lock files..."
    pkill -9 -f "firefox.*${SLACK_TEAM_ID}" 2>/dev/null || true
    pkill -9 -f "firefox.*--headless" 2>/dev/null || true
    pkill -9 -f "firefox.*sso/saml" 2>/dev/null || true
    
    if [ -d "$FF_PROFILE_DIR" ]; then
        rm -f "${FF_PROFILE_DIR}/.parentlock" "${FF_PROFILE_DIR}/parent.lock" "${FF_PROFILE_DIR}/lock" 2>/dev/null || true
    fi
}

cleanup_on_exit() {
    trap - SIGINT SIGTERM EXIT
    echo ""
    log_warn "Stopping HydraCaseBot Listener Service..."
    kill_target_firefox
    log_success "Cleanup complete. Exiting."
    exit 0
}

trap cleanup_on_exit SIGINT SIGTERM EXIT

# ==============================================================================
# CREDENTIAL EXTRACTION & SELF-HEALING
# ==============================================================================
enforce_firefox_kerberos_prefs() {
    [ -d "$FF_PROFILE_DIR" ] || return
    log_debug "Enforcing Kerberos SPNEGO settings in ${FF_USER_JS}..."
    cat << 'EOF_PREFS' > "$FF_USER_JS"
user_pref("network.negotiate-auth.trusted-uris", ".redhat.com,.fedoraproject.org,.slack.com");
user_pref("network.negotiate-auth.delegation-uris", ".redhat.com,.fedoraproject.org,.slack.com");
EOF_PREFS
}

sync_firefox_wal() {
    local target_db
    target_db=$(find "$FF_BASE_DIR" -name "data.sqlite" 2>/dev/null | grep -i "slack.com" | head -n 1)
    if command -v sqlite3 &>/dev/null && [ -f "$target_db" ]; then
        sqlite3 "$target_db" "PRAGMA wal_checkpoint(FULL);" &>/dev/null || true
    fi
}

get_slack_token() {
    local target_dbs
    mapfile -t target_dbs < <(find "$FF_BASE_DIR" -name "data.sqlite" 2>/dev/null | grep -i "slack")

    if [ ${#target_dbs[@]} -eq 0 ]; then
        return 1
    fi

    local extracted_token=""
    for db in "${target_dbs[@]}"; do
        if [ -f "$db" ]; then
            # Copia passiva non bloccante per evitare file lock mentre Firefox scrive
            cp "${db}"* /tmp/ 2>/dev/null
            sleep 0.1
            extracted_token=$(strings /tmp/data.sqlite* 2>/dev/null | grep -oE 'xoxc-[0-9a-zA-Z-]{80,}' | tail -n 1)
            rm -f /tmp/data.sqlite* 2>/dev/null
            
            if [ -n "$extracted_token" ]; then
                echo "$extracted_token"
                return 0
            fi
        fi
    done

    return 1
}

get_slack_cookie() {
    python3 -c "
import browser_cookie3
try:
    cj = browser_cookie3.firefox(domain_name='.slack.com')
    print([c.value for c in cj if c.name == 'd'][0])
except Exception:
    pass
" 2>/dev/null
}

refresh_firefox_session() {
    local force_saml_bootstrap="$1"
    
    kill_target_firefox

    if command -v klist &>/dev/null && ! klist -s; then
        log_warn "Kerberos ticket missing or expired! Run 'kinit' to restore SSO authentication."
    fi

    enforce_firefox_kerberos_prefs

    if command -v firefox &>/dev/null; then
        if [ "$force_saml_bootstrap" = "true" ]; then
            log_warn "=================================================================="
            log_warn "[!] INITIAL AUTHENTICATION REQUIRED (Token/data.sqlite missing)"
            log_warn "[!] Launching GUI Firefox on Path: ${FF_PROFILE_DIR}"
            log_warn "=================================================================="
            
            firefox --profile "${FF_PROFILE_DIR}" --no-remote "${SLACK_SAML_URL}" >/dev/null 2>&1 &
            
            log_debug "Monitoring data.sqlite and token creation dynamically (max 45s)..."
            local token_found=false
            for i in {1..45}; do
                sleep 1
                if get_slack_token &>/dev/null; then
                    log_success "data.sqlite and token successfully generated in ${i} seconds!"
                    token_found=true
                    break
                fi
            done
            
            if [ "$token_found" = false ]; then
                log_warn "Timeout reached while waiting for data.sqlite creation."
            fi
        else
            log_warn "Triggering Automated Headless Kerberos Self-Healing Mechanism..."
            log_debug "Pinging Slack headlessly at: ${SLACK_HEADLESS_URL}"
            firefox --profile "${FF_PROFILE_DIR}" --no-remote --headless "${SLACK_HEADLESS_URL}" >/dev/null 2>&1 &
            log_debug "Waiting 15 seconds for Kerberos SSO negotiation and SQLite cookie sync..."
            sleep 15
        fi
        
        sync_firefox_wal
        kill_target_firefox
        log_success "Session refresh cycle complete."
    fi
}

verify_slack_token() {
    local token="$1"
    local cookie="$2"
    
    log_debug "Executing auth.test verification against Slack API..."
    local auth_response
    auth_response=$(curl -s -X POST "https://slack.com/api/auth.test" \
        -H "Authorization: Bearer ${token}" \
        -H "Cookie: d=${cookie}" \
        -H "Content-Type: application/x-www-form-urlencoded")

    local is_ok
    is_ok=$(echo "$auth_response" | jq -r '.ok // false')

    if [ "$is_ok" == "true" ]; then
        log_success "Authentication valid for active user!"
        return 0
    else
        log_error "Auth failed: $(echo "$auth_response" | jq -r '.error // "invalid_auth"')"
        log_debug "FULL Auth Response: $auth_response"
        return 1
    fi
}

# ==============================================================================
# MAIN LOOP
# ==============================================================================
echo "=================================================="
echo "[+] Starting HydraCaseBot Dynamic Listener"
echo "[+] Active User   : ${CURRENT_USER}"
echo "[+] Target Email  : ${TARGET_EMAIL}"
echo "[+] Target Channel: ${TARGET_CHANNEL_ID}"
echo "[+] Firefox Profile Path: ${FF_PROFILE_DIR}"
echo "[+] Debug Mode    : ${DEBUG_MODE} (Dump Credentials: ${SHOW_CREDENTIALS_DUMP} | Dump Raw MSG: ${DUMP_RAW_MESSAGES})"
echo "=================================================="

[ -f "$LAST_SEEN_FILE" ] || echo "0" > "$LAST_SEEN_FILE"

while true; do
    log_debug "--------------------------------------------------"
    log_debug "Starting polling loop..."

    SLACK_USER_TOKEN=$(get_slack_token)
    SLACK_COOKIE_D=$(get_slack_cookie)

    if [ "$DEBUG_MODE" = true ] && [ "$SHOW_CREDENTIALS_DUMP" = true ]; then
        log_debug "=== FULL CREDENTIALS DUMP ==="
        log_debug "TOKEN (Len ${#SLACK_USER_TOKEN})  : ${SLACK_USER_TOKEN:-"NOT FOUND"}"
        log_debug "COOKIE (Len ${#SLACK_COOKIE_D}) : ${SLACK_COOKIE_D:-"NOT FOUND"}"
        log_debug "============================="
    fi

    if [ -z "$SLACK_USER_TOKEN" ]; then
        log_error "Missing token/database. Triggering Automated SAML SSO Bootstrap..."
        refresh_firefox_session "true"
        sleep "$POLL_INTERVAL"
        continue
    elif [ -z "$SLACK_COOKIE_D" ]; then
        log_error "Missing cookie. Triggering Headless Refresh..."
        refresh_firefox_session "false"
        sleep "$POLL_INTERVAL"
        continue
    fi

    verify_slack_token "$SLACK_USER_TOKEN" "$SLACK_COOKIE_D" || {
        log_error "Session validation rejected by Slack."
        refresh_firefox_session "false"
        sleep "$POLL_INTERVAL"
        continue
    }

    LAST_SEEN=$(cat "$LAST_SEEN_FILE")

    RESPONSE=$(curl -s -X GET "https://slack.com/api/conversations.history?channel=${TARGET_CHANNEL_ID}&limit=10" \
        -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
        -H "Cookie: d=${SLACK_COOKIE_D}" \
        -H "Content-Type: application/x-www-form-urlencoded")

    OK_STATUS=$(echo "$RESPONSE" | jq -r '.ok // false')
    if [ "$OK_STATUS" != "true" ]; then
        log_error "Slack API Error: $(echo "$RESPONSE" | jq -r '.error // "Unknown"')"
        refresh_firefox_session "false"
        sleep "$POLL_INTERVAL"
        continue
    fi

    MESSAGES=$(echo "$RESPONSE" | jq -c --arg bot_id "$BOT_USER_ID" --arg last_ts "$LAST_SEEN" \
        '[.messages[]? | select((.user == $bot_id or .bot_id != null) and (.ts > $last_ts))] | reverse | .[]')

    if [ -n "$MESSAGES" ]; then
        while IFS= read -r msg; do
            [ -z "$msg" ] && continue
            
            TS=$(echo "$msg" | jq -r '.ts')
            EPOCH_SEC=$(echo "$TS" | cut -d'.' -f1)
            HUMAN_TS=$(date -d "@${EPOCH_SEC}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$TS")

            SENDER=$(echo "$msg" | jq -r '.user // "bot"')
            log_debug "Processing message TS: $TS ($HUMAN_TS) [Sender: $SENDER]"

            ATTACH_COUNT=$(echo "$msg" | jq '.attachments | length // 0')

            if [ "$ATTACH_COUNT" -gt 0 ]; then
                for (( idx=0; idx<ATTACH_COUNT; idx++ )); do
                    ATT=$(echo "$msg" | jq -c ".attachments[$idx]")

                    EVAL_OUT=$(python3 -c "
import json, html, re, sys

try:
    att = json.loads(sys.argv[1])
    
    title = ''
    for block in att.get('blocks', []):
        if block.get('type') == 'context':
            for elem in block.get('elements', []):
                txt = elem.get('text', '')
                if not txt.startswith('id:'):
                    title = txt
                    break

    if not title and 'fallback' in att:
        fb_match = re.search(r'Subject:\s*(.*?)(?=\n|$)', att['fallback'])
        if fb_match:
            title = fb_match.group(1).strip()

    full_text = ''
    for block in att.get('blocks', []):
        if 'text' in block and isinstance(block['text'], dict):
            full_text += block['text'].get('text', '') + '\n'
        if 'fields' in block:
            for f in block['fields']:
                full_text += f.get('text', '') + '\n'

    decoded = html.unescape(html.unescape(full_text))

    num_m = re.search(r':case_number:\s*([0-9]{7,8})', decoded)
    case_num = num_m.group(1).strip() if num_m else 'UnknownCase'

    cust_m = re.search(r':account:\s*(.*?)\s*(?=:case_owner:|:product:|:package:|:bust_in_silhouette:|\t|\n|$)', decoded)
    customer = cust_m.group(1).strip() if cust_m else 'Red Hat Account'

    owner_m = re.search(r':case_owner:\s*(.*?)\s*(?=:product:|:package:|\t|\n|$)', decoded)
    case_owner = owner_m.group(1).strip() if owner_m else 'Unassigned'

    if case_owner.startswith('<@') and 'fallback' in att:
        owner_fb = re.search(r'Owner:\s*(.*?)(?=\n|$)', att['fallback'])
        if owner_fb:
            case_owner = owner_fb.group(1).strip()

    prod_m = re.search(r':product:\s*(.*?)\s*(?=\t|\n|$)', decoded)
    platform = prod_m.group(1).strip() if prod_m else 'Red Hat Enterprise Software'

    print(f'CASE_NUM=\"{case_num}\"')
    print(f'CUSTOMER=\"{customer}\"')
    print(f'CASE_OWNER=\"{case_owner}\"')
    print(f'PLATFORM=\"{platform}\"')
    print(f'TITLE_CASE=\"{title}\"')

except Exception:
    print('CASE_NUM=\"UnknownCase\"')
    print('CUSTOMER=\"Red Hat Account\"')
    print('CASE_OWNER=\"Unassigned\"')
    print('PLATFORM=\"Red Hat Enterprise Software\"')
    print('TITLE_CASE=\"N/A\"')
" "$ATT")

                    eval "$EVAL_OUT"

                    BODY_TEXT=$(python3 -c "
import json, html, re, sys

try:
    att = json.loads(sys.argv[1])
    
    extra_lines = []
    for block in att.get('blocks', []):
        btype = block.get('type')
        if btype == 'section' and 'text' in block:
            t = block['text'].get('text', '')
            if 'Status:' in t:
                extra_lines.append(t)
        elif 'fields' in block:
            for f in block['fields']:
                extra_lines.append(f.get('text', ''))

    extra_text = '\n'.join(extra_lines)
    extra_text = html.unescape(html.unescape(extra_text))
    extra_text = re.sub(r'[*~]', '', extra_text)

    body = f'''Case Number: ${CASE_NUM}
Title: ${TITLE_CASE}
Customer Name: ${CUSTOMER}
Case Owner: ${CASE_OWNER}
Platform: ${PLATFORM}
{extra_text}'''
    print(body.strip())
except Exception:
    print('Details Unavailable')
" "$ATT")

                    SEVERITY=$(echo "$BODY_TEXT" | grep -i 'Severity:' | sed 's/.*Severity:[[:space:]]*//I' | awk -F' ' '{print $1,$2}' | tr -d '\r')
                    [ -z "$SEVERITY" ] && SEVERITY="3 (Medium)"

                    STATUS=$(echo "$BODY_TEXT" | grep -i 'Status:' | head -n 1 | sed 's/.*Status:[[:space:]]*//I' | cut -d'*' -f1 | tr -d '\r')
                    [ -z "$STATUS" ] && STATUS="In Progress"

                    SBT=$(echo "$BODY_TEXT" | grep -i 'SBT:' | sed 's/.*SBT:[[:space:]]*//I' | tr -d '\r')
                    [ -z "$SBT" ] && SBT="N/A"

                    PORTAL_URL="https://access.redhat.com/support/cases/#/case/${CASE_NUM}"
                    SFDC_URL="https://redhat.lightning.force.com"

                    EMAIL_TITLE="Severity: ${SEVERITY} - Status: ${STATUS} - SBT: ${SBT} - Case Number: ${CASE_NUM} - Platform: ${PLATFORM} - Customer: ${CUSTOMER}"

                    log_debug "Dispatching card $((idx+1))/$ATTACH_COUNT to $TARGET_EMAIL with Title: $EMAIL_TITLE"

                    echo -e "HydraCaseBot Notification\n\nFull Details:\n----------------------------------------\n${BODY_TEXT}\n----------------------------------------\nDirect Links:\n🔴 Red Hat Portal: ${PORTAL_URL}\n☁️ Salesforce (SFDC): ${SFDC_URL}\n----------------------------------------\nDate/Time: ${HUMAN_TS}\nChannel: ${TARGET_CHANNEL_ID}" | \
                    mailx -S v15-compat=yes \
                          -S smtp-auth=none \
                          -S smtp-use-starttls=no \
                          -r "$TARGET_EMAIL" \
                          -s "$EMAIL_TITLE" \
                          -S mta="smtp://${SMTP_SERVER}" \
                          "$TARGET_EMAIL"

                    [ $? -eq 0 ] && log_success "Card $((idx+1)) dispatched!" || log_error "Failed to send card $((idx+1))"
                done
            fi

            echo "$TS" > "$LAST_SEEN_FILE"
            log_debug "Updated $LAST_SEEN_FILE with timestamp $TS"

        done < <(echo "$MESSAGES")
    fi

    log_debug "Sleeping for $POLL_INTERVAL seconds..."
    sleep "$POLL_INTERVAL"
done
rbruzzon@rbruzzon-thinkpadt14gen5:~$ cat hydracase_listener.sh
#!/usr/bin/env bash

# ==============================================================================
#
# hydracase_listener.sh Ver2.22 by rbruzzon@redhat.com
#
# ==============================================================================

# ==============================================================================
# CONFIGURATION & CONSTANTS
# ==============================================================================
SLACK_TEAM_ID="E030G10V24F"           # Slack Enterprise Team ID
TARGET_CHANNEL_ID="D04NRQ0PNJV"       # Direct Message channel with HydraCaseBot
BOT_USER_ID="U04JNCVBVNU"             # HydraCaseBot User ID
CURRENT_USER="${USER:-$(whoami)}"
TARGET_EMAIL="${CURRENT_USER}@redhat.com" # Auto-resolves current Linux user email
SMTP_SERVER="smtp.corp.redhat.com:25" # Internal SMTP Relay Server
POLL_INTERVAL=15                      # Polling Interval (in seconds)
LAST_SEEN_FILE="/tmp/hydracase_last_seen_${CURRENT_USER}.txt"

# SAML SSO Direct URLs
SLACK_SAML_URL="https://redhat.enterprise.slack.com/sso/saml/start?redir=%2Fclient%2F${SLACK_TEAM_ID}%2F${TARGET_CHANNEL_ID}"
SLACK_HEADLESS_URL="https://app.slack.com/client/${SLACK_TEAM_ID}/${TARGET_CHANNEL_ID}"

# ------------------------------------------------------------------------------
# LOGGING & DEBUG CONFIGURATION
# ------------------------------------------------------------------------------
DEBUG_MODE=true                       # Set to 'true' for verbose execution logs
SHOW_CREDENTIALS_DUMP=false           # Set to 'false' to hide raw TOKEN & COOKIE strings
DUMP_RAW_MESSAGES=true                # Set to 'true' to dump raw Slack JSON messages
# ------------------------------------------------------------------------------

# Automatic Profile Directory Resolver
FF_BASE_DIR="/home/${CURRENT_USER}/.mozilla/firefox"
FF_PROFILE_DIR=$(find "$FF_BASE_DIR" -maxdepth 1 -type d \( -name "*default-redhat*" -o -name "*RedHat*" -o -name "*.default-release*" -o -name "*.default*" \) 2>/dev/null | head -n 1)
FF_USER_JS="${FF_PROFILE_DIR}/user.js"

# Logging Helpers
log_debug() { [ "$DEBUG_MODE" = true ] && echo -e "[\e[34mDEBUG\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_success() { echo -e "[\e[32mOK\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_warn() { echo -e "[\e[33mWARN\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }
log_error() { echo -e "[\e[31mERROR\e[0m] $(date '+%Y-%m-%d %H:%M:%S') - $1"; }

# ==============================================================================
# HELP & SETUP GUIDE
# ==============================================================================
show_help() {
    cat << EOF
HydraCaseBot Slack-to-Email Listener Service (Ver2.22)

Usage:
  ./hydracase_listener.sh [OPTION]

Options:
  -h, --help        Show this help menu and setup instructions

--------------------------------------------------------------------------------
CONFIGURATION & SETUP GUIDE
--------------------------------------------------------------------------------
1. Prerequisites & Dependencies:
   - Ensure 'jq', 'curl', 'sqlite3', 's-nail' (mailx), and Python packages are installed:
       $ sudo dnf install -y jq curl sqlite coreutils s-nail xdotool python3-pip
       $ pip install browser-cookie3 --user

2. DEBUG & CREDENTIAL LOGGING CONTROL:
   - DEBUG_MODE=true|false            : Enables or disables general execution logging.
   - SHOW_CREDENTIALS_DUMP=true|false : Set to 'false' to hide raw TOKEN and COOKIE strings.
   - DUMP_RAW_MESSAGES=true|false     : Set to 'true' to dump raw Slack JSON messages for debugging.

3. FIREFOX AUTOMATIC PROFILE LOCATION:
   - Automatically binds directly to profile path: ${FF_PROFILE_DIR:-"NOT FOUND"}

4. AUTOMATED SAML SSO BOOTSTRAP & HEADLESS REFRESH:
   - Enforces Kerberos SPNEGO preferences directly into Firefox's user.js.
   - Dynamic Auto-Bootstrap: If 'data.sqlite' or token xoxc- is missing, launches GUI Firefox,
     monitors 'data.sqlite' creation dynamically every second, kills Firefox upon generation,
     and seamlessly transitions to headless background execution.
   - Headless Renewal: Background polling pings Slack headlessly without opening any GUI window.

5. Running the Service:
   - Standard foreground execution:
       $ ./hydracase_listener.sh
   - Running in background:
       $ nohup ./hydracase_listener.sh > /tmp/hydracase.log 2>&1 &
--------------------------------------------------------------------------------
EOF
}

# Handle Help menu before enabling process traps
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    show_help
    exit 0
fi

# ==============================================================================
# CLEANUP & TRAP MANAGEMENT
# ==============================================================================
kill_target_firefox() {
    log_debug "Killing any background Firefox instances and cleaning lock files..."
    pkill -9 -f "firefox.*${SLACK_TEAM_ID}" 2>/dev/null || true
    pkill -9 -f "firefox.*--headless" 2>/dev/null || true
    pkill -9 -f "firefox.*sso/saml" 2>/dev/null || true
    
    if [ -d "$FF_PROFILE_DIR" ]; then
        rm -f "${FF_PROFILE_DIR}/.parentlock" "${FF_PROFILE_DIR}/parent.lock" "${FF_PROFILE_DIR}/lock" 2>/dev/null || true
    fi
}

cleanup_on_exit() {
    trap - SIGINT SIGTERM EXIT
    echo ""
    log_warn "Stopping HydraCaseBot Listener Service..."
    kill_target_firefox
    log_success "Cleanup complete. Exiting."
    exit 0
}

trap cleanup_on_exit SIGINT SIGTERM EXIT

# ==============================================================================
# CREDENTIAL EXTRACTION & SELF-HEALING
# ==============================================================================
enforce_firefox_kerberos_prefs() {
    [ -d "$FF_PROFILE_DIR" ] || return
    log_debug "Enforcing Kerberos SPNEGO settings in ${FF_USER_JS}..."
    cat << 'EOF_PREFS' > "$FF_USER_JS"
user_pref("network.negotiate-auth.trusted-uris", ".redhat.com,.fedoraproject.org,.slack.com");
user_pref("network.negotiate-auth.delegation-uris", ".redhat.com,.fedoraproject.org,.slack.com");
EOF_PREFS
}

sync_firefox_wal() {
    local target_db
    target_db=$(find "$FF_BASE_DIR" -name "data.sqlite" 2>/dev/null | grep -i "slack.com" | head -n 1)
    if command -v sqlite3 &>/dev/null && [ -f "$target_db" ]; then
        sqlite3 "$target_db" "PRAGMA wal_checkpoint(FULL);" &>/dev/null || true
    fi
}

get_slack_token() {
    local target_dbs
    mapfile -t target_dbs < <(find "$FF_BASE_DIR" -name "data.sqlite" 2>/dev/null | grep -i "slack")

    if [ ${#target_dbs[@]} -eq 0 ]; then
        return 1
    fi

    local extracted_token=""
    for db in "${target_dbs[@]}"; do
        if [ -f "$db" ]; then
            # Copia passiva non bloccante per evitare file lock mentre Firefox scrive
            cp "${db}"* /tmp/ 2>/dev/null
            sleep 0.1
            extracted_token=$(strings /tmp/data.sqlite* 2>/dev/null | grep -oE 'xoxc-[0-9a-zA-Z-]{80,}' | tail -n 1)
            rm -f /tmp/data.sqlite* 2>/dev/null
            
            if [ -n "$extracted_token" ]; then
                echo "$extracted_token"
                return 0
            fi
        fi
    done

    return 1
}

get_slack_cookie() {
    python3 -c "
import browser_cookie3
try:
    cj = browser_cookie3.firefox(domain_name='.slack.com')
    print([c.value for c in cj if c.name == 'd'][0])
except Exception:
    pass
" 2>/dev/null
}

refresh_firefox_session() {
    local force_saml_bootstrap="$1"
    
    kill_target_firefox

    if command -v klist &>/dev/null && ! klist -s; then
        log_warn "Kerberos ticket missing or expired! Run 'kinit' to restore SSO authentication."
    fi

    enforce_firefox_kerberos_prefs

    if command -v firefox &>/dev/null; then
        if [ "$force_saml_bootstrap" = "true" ]; then
            log_warn "=================================================================="
            log_warn "[!] INITIAL AUTHENTICATION REQUIRED (Token/data.sqlite missing)"
            log_warn "[!] Launching GUI Firefox on Path: ${FF_PROFILE_DIR}"
            log_warn "=================================================================="
            
            firefox --profile "${FF_PROFILE_DIR}" --no-remote "${SLACK_SAML_URL}" >/dev/null 2>&1 &
            
            log_debug "Monitoring data.sqlite and token creation dynamically (max 45s)..."
            local token_found=false
            for i in {1..45}; do
                sleep 1
                if get_slack_token &>/dev/null; then
                    log_success "data.sqlite and token successfully generated in ${i} seconds!"
                    token_found=true
                    break
                fi
            done
            
            if [ "$token_found" = false ]; then
                log_warn "Timeout reached while waiting for data.sqlite creation."
            fi
        else
            log_warn "Triggering Automated Headless Kerberos Self-Healing Mechanism..."
            log_debug "Pinging Slack headlessly at: ${SLACK_HEADLESS_URL}"
            firefox --profile "${FF_PROFILE_DIR}" --no-remote --headless "${SLACK_HEADLESS_URL}" >/dev/null 2>&1 &
            log_debug "Waiting 15 seconds for Kerberos SSO negotiation and SQLite cookie sync..."
            sleep 15
        fi
        
        sync_firefox_wal
        kill_target_firefox
        log_success "Session refresh cycle complete."
    fi
}

verify_slack_token() {
    local token="$1"
    local cookie="$2"
    
    log_debug "Executing auth.test verification against Slack API..."
    local auth_response
    auth_response=$(curl -s -X POST "https://slack.com/api/auth.test" \
        -H "Authorization: Bearer ${token}" \
        -H "Cookie: d=${cookie}" \
        -H "Content-Type: application/x-www-form-urlencoded")

    local is_ok
    is_ok=$(echo "$auth_response" | jq -r '.ok // false')

    if [ "$is_ok" == "true" ]; then
        log_success "Authentication valid for active user!"
        return 0
    else
        log_error "Auth failed: $(echo "$auth_response" | jq -r '.error // "invalid_auth"')"
        log_debug "FULL Auth Response: $auth_response"
        return 1
    fi
}

# ==============================================================================
# MAIN LOOP
# ==============================================================================
echo "=================================================="
echo "[+] Starting HydraCaseBot Dynamic Listener"
echo "[+] Active User   : ${CURRENT_USER}"
echo "[+] Target Email  : ${TARGET_EMAIL}"
echo "[+] Target Channel: ${TARGET_CHANNEL_ID}"
echo "[+] Firefox Profile Path: ${FF_PROFILE_DIR}"
echo "[+] Debug Mode    : ${DEBUG_MODE} (Dump Credentials: ${SHOW_CREDENTIALS_DUMP} | Dump Raw MSG: ${DUMP_RAW_MESSAGES})"
echo "=================================================="

[ -f "$LAST_SEEN_FILE" ] || echo "0" > "$LAST_SEEN_FILE"

while true; do
    log_debug "--------------------------------------------------"
    log_debug "Starting polling loop..."

    SLACK_USER_TOKEN=$(get_slack_token)
    SLACK_COOKIE_D=$(get_slack_cookie)

    if [ "$DEBUG_MODE" = true ] && [ "$SHOW_CREDENTIALS_DUMP" = true ]; then
        log_debug "=== FULL CREDENTIALS DUMP ==="
        log_debug "TOKEN (Len ${#SLACK_USER_TOKEN})  : ${SLACK_USER_TOKEN:-"NOT FOUND"}"
        log_debug "COOKIE (Len ${#SLACK_COOKIE_D}) : ${SLACK_COOKIE_D:-"NOT FOUND"}"
        log_debug "============================="
    fi

    if [ -z "$SLACK_USER_TOKEN" ]; then
        log_error "Missing token/database. Triggering Automated SAML SSO Bootstrap..."
        refresh_firefox_session "true"
        sleep "$POLL_INTERVAL"
        continue
    elif [ -z "$SLACK_COOKIE_D" ]; then
        log_error "Missing cookie. Triggering Headless Refresh..."
        refresh_firefox_session "false"
        sleep "$POLL_INTERVAL"
        continue
    fi

    verify_slack_token "$SLACK_USER_TOKEN" "$SLACK_COOKIE_D" || {
        log_error "Session validation rejected by Slack."
        refresh_firefox_session "false"
        sleep "$POLL_INTERVAL"
        continue
    }

    LAST_SEEN=$(cat "$LAST_SEEN_FILE")

    RESPONSE=$(curl -s -X GET "https://slack.com/api/conversations.history?channel=${TARGET_CHANNEL_ID}&limit=10" \
        -H "Authorization: Bearer ${SLACK_USER_TOKEN}" \
        -H "Cookie: d=${SLACK_COOKIE_D}" \
        -H "Content-Type: application/x-www-form-urlencoded")

    OK_STATUS=$(echo "$RESPONSE" | jq -r '.ok // false')
    if [ "$OK_STATUS" != "true" ]; then
        log_error "Slack API Error: $(echo "$RESPONSE" | jq -r '.error // "Unknown"')"
        refresh_firefox_session "false"
        sleep "$POLL_INTERVAL"
        continue
    fi

    MESSAGES=$(echo "$RESPONSE" | jq -c --arg bot_id "$BOT_USER_ID" --arg last_ts "$LAST_SEEN" \
        '[.messages[]? | select((.user == $bot_id or .bot_id != null) and (.ts > $last_ts))] | reverse | .[]')

    if [ -n "$MESSAGES" ]; then
        while IFS= read -r msg; do
            [ -z "$msg" ] && continue
            
            TS=$(echo "$msg" | jq -r '.ts')
            EPOCH_SEC=$(echo "$TS" | cut -d'.' -f1)
            HUMAN_TS=$(date -d "@${EPOCH_SEC}" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || echo "$TS")

            SENDER=$(echo "$msg" | jq -r '.user // "bot"')
            log_debug "Processing message TS: $TS ($HUMAN_TS) [Sender: $SENDER]"

            ATTACH_COUNT=$(echo "$msg" | jq '.attachments | length // 0')

            if [ "$ATTACH_COUNT" -gt 0 ]; then
                for (( idx=0; idx<ATTACH_COUNT; idx++ )); do
                    ATT=$(echo "$msg" | jq -c ".attachments[$idx]")

                    EVAL_OUT=$(python3 -c "
import json, html, re, sys

try:
    att = json.loads(sys.argv[1])
    
    title = ''
    for block in att.get('blocks', []):
        if block.get('type') == 'context':
            for elem in block.get('elements', []):
                txt = elem.get('text', '')
                if not txt.startswith('id:'):
                    title = txt
                    break

    if not title and 'fallback' in att:
        fb_match = re.search(r'Subject:\s*(.*?)(?=\n|$)', att['fallback'])
        if fb_match:
            title = fb_match.group(1).strip()

    full_text = ''
    for block in att.get('blocks', []):
        if 'text' in block and isinstance(block['text'], dict):
            full_text += block['text'].get('text', '') + '\n'
        if 'fields' in block:
            for f in block['fields']:
                full_text += f.get('text', '') + '\n'

    decoded = html.unescape(html.unescape(full_text))

    num_m = re.search(r':case_number:\s*([0-9]{7,8})', decoded)
    case_num = num_m.group(1).strip() if num_m else 'UnknownCase'

    cust_m = re.search(r':account:\s*(.*?)\s*(?=:case_owner:|:product:|:package:|:bust_in_silhouette:|\t|\n|$)', decoded)
    customer = cust_m.group(1).strip() if cust_m else 'Red Hat Account'

    owner_m = re.search(r':case_owner:\s*(.*?)\s*(?=:product:|:package:|\t|\n|$)', decoded)
    case_owner = owner_m.group(1).strip() if owner_m else 'Unassigned'

    if case_owner.startswith('<@') and 'fallback' in att:
        owner_fb = re.search(r'Owner:\s*(.*?)(?=\n|$)', att['fallback'])
        if owner_fb:
            case_owner = owner_fb.group(1).strip()

    prod_m = re.search(r':product:\s*(.*?)\s*(?=\t|\n|$)', decoded)
    platform = prod_m.group(1).strip() if prod_m else 'Red Hat Enterprise Software'

    print(f'CASE_NUM=\"{case_num}\"')
    print(f'CUSTOMER=\"{customer}\"')
    print(f'CASE_OWNER=\"{case_owner}\"')
    print(f'PLATFORM=\"{platform}\"')
    print(f'TITLE_CASE=\"{title}\"')

except Exception:
    print('CASE_NUM=\"UnknownCase\"')
    print('CUSTOMER=\"Red Hat Account\"')
    print('CASE_OWNER=\"Unassigned\"')
    print('PLATFORM=\"Red Hat Enterprise Software\"')
    print('TITLE_CASE=\"N/A\"')
" "$ATT")

                    eval "$EVAL_OUT"

                    BODY_TEXT=$(python3 -c "
import json, html, re, sys

try:
    att = json.loads(sys.argv[1])
    
    extra_lines = []
    for block in att.get('blocks', []):
        btype = block.get('type')
        if btype == 'section' and 'text' in block:
            t = block['text'].get('text', '')
            if 'Status:' in t:
                extra_lines.append(t)
        elif 'fields' in block:
            for f in block['fields']:
                extra_lines.append(f.get('text', ''))

    extra_text = '\n'.join(extra_lines)
    extra_text = html.unescape(html.unescape(extra_text))
    extra_text = re.sub(r'[*~]', '', extra_text)

    body = f'''Case Number: ${CASE_NUM}
Title: ${TITLE_CASE}
Customer Name: ${CUSTOMER}
Case Owner: ${CASE_OWNER}
Platform: ${PLATFORM}
{extra_text}'''
    print(body.strip())
except Exception:
    print('Details Unavailable')
" "$ATT")

                    SEVERITY=$(echo "$BODY_TEXT" | grep -i 'Severity:' | sed 's/.*Severity:[[:space:]]*//I' | awk -F' ' '{print $1,$2}' | tr -d '\r')
                    [ -z "$SEVERITY" ] && SEVERITY="3 (Medium)"

                    STATUS=$(echo "$BODY_TEXT" | grep -i 'Status:' | head -n 1 | sed 's/.*Status:[[:space:]]*//I' | cut -d'*' -f1 | tr -d '\r')
                    [ -z "$STATUS" ] && STATUS="In Progress"

                    SBT=$(echo "$BODY_TEXT" | grep -i 'SBT:' | sed 's/.*SBT:[[:space:]]*//I' | tr -d '\r')
                    [ -z "$SBT" ] && SBT="N/A"

                    PORTAL_URL="https://access.redhat.com/support/cases/#/case/${CASE_NUM}"
                    SFDC_URL="https://redhat.lightning.force.com"

                    EMAIL_TITLE="Severity: ${SEVERITY} - Status: ${STATUS} - SBT: ${SBT} - Case Number: ${CASE_NUM} - Platform: ${PLATFORM} - Customer: ${CUSTOMER}"

                    log_debug "Dispatching card $((idx+1))/$ATTACH_COUNT to $TARGET_EMAIL with Title: $EMAIL_TITLE"

                    echo -e "HydraCaseBot Notification\n\nFull Details:\n----------------------------------------\n${BODY_TEXT}\n----------------------------------------\nDirect Links:\n🔴 Red Hat Portal: ${PORTAL_URL}\n☁️ Salesforce (SFDC): ${SFDC_URL}\n----------------------------------------\nDate/Time: ${HUMAN_TS}\nChannel: ${TARGET_CHANNEL_ID}" | \
                    mailx -S v15-compat=yes \
                          -S smtp-auth=none \
                          -S smtp-use-starttls=no \
                          -r "$TARGET_EMAIL" \
                          -s "$EMAIL_TITLE" \
                          -S mta="smtp://${SMTP_SERVER}" \
                          "$TARGET_EMAIL"

                    [ $? -eq 0 ] && log_success "Card $((idx+1)) dispatched!" || log_error "Failed to send card $((idx+1))"
                done
            fi

            echo "$TS" > "$LAST_SEEN_FILE"
            log_debug "Updated $LAST_SEEN_FILE with timestamp $TS"

        done < <(echo "$MESSAGES")
    fi

    log_debug "Sleeping for $POLL_INTERVAL seconds..."
    sleep "$POLL_INTERVAL"
done
