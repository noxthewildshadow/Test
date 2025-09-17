#!/bin/bash
# =============================================================================
# THE BLOCKHEADS ANTICHEAT SECURITY SYSTEM WITH IP VERIFICATION
# =============================================================================

# Load common functions
source blockheads_common.sh

# Validate jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required but not installed. Please install jq first.${NC}"
    exit 1
fi

# Initialize variables
LOG_FILE="$1"
PORT="$2"
LOG_DIR=$(dirname "$LOG_FILE")
DATA_FILE="$LOG_DIR/data.json"
SCREEN_SERVER="blockheads_server_$PORT"

# Track player messages for spam detection
declare -A player_message_times
declare -A player_message_counts

# Track admin commands for spam detection
declare -A admin_last_command_time
declare -A admin_command_count

# Track IP change grace periods
declare -A ip_change_grace_periods
declare -A ip_change_pending_players

# Track IP mismatch announcements to prevent duplicates
declare -A ip_mismatch_announced

# Track grace period timer PIDs to cancel them on verification
declare -A grace_period_pids

# Function to initialize data.json
initialize_data() {
    initialize_data_json "$DATA_FILE"
    if ! validate_data_json "$DATA_FILE"; then
        print_error "data.json is invalid, restoring from backup"
        restore_from_backup "$DATA_FILE"
    fi
    sync_server_files "$DATA_FILE"
}

# Function to check if a player name is valid (only letters, numbers, and underscores)
is_valid_player_name() {
    local name="$1"
    # Check for empty name
    if [[ -z "$name" ]]; then
        return 1
    fi
    
    # Check for spaces at beginning or end
    if [[ "$name" =~ ^[[:space:]]+ ]] || [[ "$name" =~ [[:space:]]+$ ]]; then
        return 1
    fi
    
    # Check for invalid characters (only allow letters, numbers, and underscores)
    if [[ "$name" =~ [^a-zA-Z0-9_] ]]; then
        return 1
    fi
    
    return 0
}

# Function to schedule clear and multiple messages
schedule_clear_and_messages() {
    local messages=("$@")
    # Clear chat immediately
    screen -S "$SCREEN_SERVER" -p 0 -X stuff "/clear$(printf \\r)" 2>/dev/null
    # Send messages after 2 seconds
    (
        sleep 2
        for msg in "${messages[@]}"; do
            send_server_command "$SCREEN_SERVER" "$msg"
        done
    ) &
}

# Function to get player info from data.json
get_player_info() {
    local player_name="$1"
    get_user_data "$DATA_FILE" "$player_name"
}

# Function to update player info in data.json
update_player_info() {
    local player_name="$1" player_ip="$2" player_rank="$3" player_password="$4"
    
    local updates=$(jq -n \
        --arg ip "$player_ip" \
        --arg rank "$player_rank" \
        --arg password "$player_password" \
        '{
            ip_first: (if .ip_first == "" or .ip_first == "unknown" then $ip else .ip_first end),
            rank: $rank,
            password: $password
        }')
    
    update_user_data "$DATA_FILE" "$player_name" "$updates"
    print_success "Updated player info in registry: $player_name -> IP: $player_ip, Rank: $player_rank"
}

# Function to update player rank in data.json
update_player_rank() {
    local player_name="$1" new_rank="$2"
    
    local updates=$(jq -n --arg rank "$new_rank" '{rank: $rank}')
    update_user_data "$DATA_FILE" "$player_name" "$updates"
    print_success "Updated player rank in registry: $player_name -> $new_rank"
}

# Function to send delayed uncommands
send_delayed_uncommands() {
    local target_player="$1" command_type="$2"
    (
        sleep 2; screen -S "$SCREEN_SERVER" -p 0 -X stuff "/un${command_type} $target_player$(printf \\r)" 2>/dev/null
        sleep 2; screen -S "$SCREEN_SERVER" -p 0 -X stuff "/un${command_type} $target_player$(printf \\r)" 2>/dev/null
        sleep 1; screen -S "$SCREEN_SERVER" -p 0 -X stuff "/un${command_type} $target_player$(printf \\r)" 2>/dev/null
    ) &
}

# Function to check if player is in list
is_player_in_list() {
    local player_name="$1" list_type="$2"
    local player_data=$(get_player_info "$player_name")
    
    case "$list_type" in
        "admin")
            [ "$(echo "$player_data" | jq -r '.rank')" = "admin" ] && return 0
            ;;
        "mod")
            [ "$(echo "$player_data" | jq -r '.rank')" = "mod" ] && return 0
            ;;
        "blacklisted")
            [ "$(echo "$player_data" | jq -r '.blacklisted')" = "true" ] && return 0
            ;;
        "whitelisted")
            [ "$(echo "$player_data" | jq -r '.whitelisted')" = "true" ] && return 0
            ;;
    esac
    
    return 1
}

# Function to get player rank
get_player_rank() {
    local player_name="$1"
    local player_data=$(get_player_info "$player_name")
    if [ -z "$player_data" ] || [ "$player_data" = "{}" ]; then
        echo "NONE"
    else
        echo "$player_data" | jq -r '.rank // "NONE"'
    fi
}

# Function to get IP by name
get_ip_by_name() {
    local name="$1"
    if [ -z "$LOG_FILE" ] || [ ! -f "$LOG_FILE" ]; then
        echo "unknown"
        return 1
    fi
    awk -F'|' -v pname="$name" '
    /Player Connected/ {
        part=$1
        sub(/.*Player Connected[[:space:]]*/, "", part)
        gsub(/^[ \t]+|[ \t]+$/, "", part)
        ip=$2
        gsub(/^[ \t]+|[ \pt]+$/, "", ip)
        if (part == pname) { last_ip=ip }
    }
    END { if (last_ip) print last_ip; else print "unknown" }
    ' "$LOG_FILE"
}

# Function to start IP change grace period
start_ip_change_grace_period() {
    local player_name="$1" player_ip="$2"
    local grace_end=$(( $(date +%s) + 30 ))
    ip_change_grace_periods["$player_name"]=$grace_end
    ip_change_pending_players["$player_name"]="$player_ip"
    print_warning "Started IP change grace period for $player_name (30 seconds)"
    
    # Start grace period countdown and store PID
    (
        sleep 30
        if [ -n "${ip_change_grace_periods[$player_name]}" ]; then
            print_warning "IP change grace period expired for $player_name - kicking player"
            send_server_command "$SCREEN_SERVER" "/kick $player_name"
            unset ip_change_grace_periods["$player_name"]
            unset ip_change_pending_players["$player_name"]
            unset grace_period_pids["$player_name"]
        fi
    ) &
    grace_period_pids["$player_name"]=$!
    
    # Send warning message to player after 5 seconds
    (
        sleep 5
        if is_player_connected "$player_name" && is_in_grace_period "$player_name"; then
            send_server_command "$SCREEN_SERVER" "WARNING: $player_name, your IP has changed from the registered one!"
            send_server_command "$SCREEN_SERVER" "You have 30 seconds to verify your identity with: !ip_change YOUR_CURRENT_PASSWORD"
            send_server_command "$SCREEN_SERVER" "If you don't verify, you will be kicked from the server."
        fi
    ) &
}

# Function to check if player is in IP change grace period
is_in_grace_period() {
    local player_name="$1"
    local current_time=$(date +%s)
    if [ -n "${ip_change_grace_periods[$player_name]}" ] && [ ${ip_change_grace_periods["$player_name"]} -gt $current_time ]; then
        return 0
    else
        # Clean up if grace period has expired
        unset ip_change_grace_periods["$player_name"]
        unset ip_change_pending_players["$player_name"]
        unset grace_period_pids["$player_name"]
        return 1
    fi
}

# Function to validate IP change
validate_ip_change() {
    local player_name="$1" password="$2" current_ip="$3"
    local player_data=$(get_player_info "$player_name")
    
    if [ -z "$player_data" ] || [ "$player_data" = "{}" ]; then
        print_error "Player $player_name not found in registry"
        schedule_clear_and_messages "ERROR: $player_name, you are not registered in the system." "Use !ip_psw to set a password first." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi
    
    local registered_password=$(echo "$player_data" | jq -r '.password // "NONE"')
    
    if [ "$registered_password" != "$password" ]; then
        print_error "Invalid password for IP change: $player_name"
        schedule_clear_and_messages "ERROR: $player_name, the password is incorrect." "Usage: !ip_change YOUR_CURRENT_PASSWORD"
        return 1
    fi
    
    # Update IP in data.json
    local updates=$(jq -n --arg ip "$current_ip" '{ip_first: $ip}')
    update_user_data "$DATA_FILE" "$player_name" "$updates"
    print_success "IP updated for $player_name: $current_ip"
    
    # End grace period and cancel kick by killing the timer process
    if [ -n "${grace_period_pids[$player_name]}" ]; then
        kill "${grace_period_pids[$player_name]}" 2>/dev/null
        unset grace_period_pids["$player_name"]
    fi
    unset ip_change_grace_periods["$player_name"]
    unset ip_change_pending_players["$player_name"]
    
    # Send success message
    schedule_clear_and_messages "SUCCESS: $player_name, your IP has been verified and updated!" "Your new IP address is: $current_ip"
    
    return 0
}

# Function to handle password creation
handle_password_creation() {
    local player_name="$1" password="$2" confirm_password="$3" player_ip="$4"
    local player_data=$(get_player_info "$player_name")

    # Si el jugador ya existe en el registro, verificar si ya tiene contraseña
    if [ -n "$player_data" ] && [ "$player_data" != "{}" ]; then
        local registered_password=$(echo "$player_data" | jq -r '.password // "NONE"')
        if [ "$registered_password" != "NONE" ]; then
            print_warning "Player $player_name already has a password set."
            schedule_clear_and_messages "ERROR: $player_name, you already have a password set." "If you want to change it, use: !ip_psw_change OLD_PASSWORD NEW_PASSWORD"
            return 1
        fi
    fi

    # Validar contraseña
    if [ ${#password} -lt 6 ]; then
        schedule_clear_and_messages "ERROR: $player_name, password must be at least 6 characters." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi

    if [ "$password" != "$confirm_password" ]; then
        schedule_clear_and_messages "ERROR: $player_name, passwords do not match." "You must enter the same password twice to confirm it." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi

    # Actualizar contraseña
    if [ -n "$player_data" ] && [ "$player_data" != "{}" ]; then
        local registered_ip=$(echo "$player_data" | jq -r '.ip_first // "unknown"')
        local registered_rank=$(echo "$player_data" | jq -r '.rank // "NONE"')
        update_player_info "$player_name" "$registered_ip" "$registered_rank" "$password"
    else
        local rank=$(get_player_rank "$player_name")
        local updates=$(jq -n \
            --arg ip "$player_ip" \
            --arg rank "$rank" \
            --arg password "$password" \
            '{
                ip_first: $ip,
                rank: $rank,
                password: $password
            }')
        
        update_user_data "$DATA_FILE" "$player_name" "$updates"
    fi

    schedule_clear_and_messages "SUCCESS: $player_name, your IP password has been set successfully." "You can now use !ip_change YOUR_PASSWORD if your IP changes."
    return 0
}

# Function to handle password change
handle_password_change() {
    local player_name="$1" old_password="$2" new_password="$3"
    local player_data=$(get_player_info "$player_name")
    
    if [ -z "$player_data" ] || [ "$player_data" = "{}" ]; then
        print_error "Player $player_name not found in registry"
        schedule_clear_and_messages "ERROR: $player_name, you don't have a password set." "Use !ip_psw to generate one first." "Example: !ip_psw mypassword123 mypassword123"
        return 1
    fi
    
    local registered_password=$(echo "$player_data" | jq -r '.password // "NONE"')
    
    # Verificar que la contraseña anterior coincida
    if [ "$registered_password" != "$old_password" ]; then
        print_error "Invalid old password for $player_name"
        schedule_clear_and_messages "ERROR: $player_name, the old password is incorrect." "Usage: !ip_psw_change OLD_PASSWORD NEW_PASSWORD"
        return 1
    fi
    
    # Verificar intentos de cambio de contraseña
    local current_time=$(date +%s)
    local current_attempts=$(echo "$player_data" | jq -r '.password_change_attempts // 0')
    local last_attempt_time=$(echo "$player_data" | jq -r '.last_password_change_attempt // 0')
    
    # Reiniciar contador si ha pasado más de 1 hora
    [ $((current_time - last_attempt_time)) -gt 3600 ] && current_attempts=0
    
    current_attempts=$((current_attempts + 1))
    
    local updates=$(jq -n \
        --argjson attempts "$current_attempts" \
        --argjson time "$current_time" \
        '{password_change_attempts: $attempts, last_password_change_attempt: $time}')
    
    update_user_data "$DATA_FILE" "$player_name" "$updates"
    
    if [ $current_attempts -gt 3 ]; then
        print_error "Password change limit exceeded for $player_name"
        schedule_clear_and_messages "ERROR: $player_name, you've exceeded the password change limit (3 times per hour)." "Please wait before trying again."
        return 1
    fi
    
    # Validar nueva contraseña
    if [ ${#new_password} -lt 6 ]; then
        schedule_clear_and_messages "ERROR: $player_name, new password must be at least 6 characters." "Example: !ip_psw_change oldpass newpassword123"
        return 1
    fi
    
    # Actualizar contraseña
    local updates=$(jq -n --arg password "$new_password" '{password: $password}')
    update_user_data "$DATA_FILE" "$player_name" "$updates"
    
    schedule_clear_and_messages "SUCCESS: $player_name, your password has been changed successfully." "You can now use !ip_change NEW_PASSWORD if your IP changes."
    
    return 0
}

# Function to check for username theft with IP verification
check_username_theft() {
    local player_name="$1" player_ip="$2"
    
    # Skip if player name is invalid
    ! is_valid_player_name "$player_name" && return 0
    
    # Check if player exists in data.json
    local player_data=$(get_player_info "$player_name")
    
    if [ -n "$player_data" ] && [ "$player_data" != "{}" ]; then
        # Player exists, check if IP matches
        local registered_ip=$(echo "$player_data" | jq -r '.ip_first // "unknown"')
        local registered_rank=$(echo "$player_data" | jq -r '.rank // "NONE"')
        local registered_password=$(echo "$player_data" | jq -r '.password // "NONE"')
        
        if [ "$registered_ip" != "$player_ip" ] && [ "$registered_ip" != "unknown" ]; then
            # IP doesn't match - check if player has password
            if [ "$registered_password" = "NONE" ]; then
                # No password set - remind player to set one after 5 seconds (only once)
                print_warning "IP changed for $player_name but no password set (old IP: $registered_ip, new IP: $player_ip)"
                # Only show announcement once per player connection
                if [[ -z "${ip_mismatch_announced[$player_name]}" ]]; then
                    ip_mismatch_announced["$player_name"]=1
                    (
                        sleep 5
                        # Check if player is still connected before sending message
                        if is_player_connected "$player_name"; then
                            send_server_command "$SCREEN_SERVER" "WARNING: $player_name, your IP has changed but you don't have a password set."
                            send_server_command "$SCREEN_SERVER" "Use !ip_psw PASSWORD CONFIRM_PASSWORD to set your password, or you may lose access to your account."
                            send_server_command "$SCREEN_SERVER" "Example: !ip_psw mypassword123 mypassword123"
                        fi
                    ) &
                fi
                # Update IP in registry
                local updates=$(jq -n --arg ip "$player_ip" '{ip_first: $ip}')
                update_user_data "$DATA_FILE" "$player_name" "$updates"
            else
                # Password set - start grace period (only if not already started)
                if [[ -z "${ip_change_grace_periods[$player_name]}" ]]; then
                    print_warning "IP changed for $player_name (old IP: $registered_ip, new IP: $player_ip)"
                    # Start grace period immediately
                    start_ip_change_grace_period "$player_name" "$player_ip"
                fi
            fi
        else
            # IP matches - update rank if needed
            local current_rank=$(get_player_rank "$player_name")
            if [ "$current_rank" != "$registered_rank" ]; then
                local updates=$(jq -n --arg rank "$current_rank" '{rank: $rank}')
                update_user_data "$DATA_FILE" "$player_name" "$updates"
            fi
        fi
    else
        # New player - add to data.json with no password
        local rank=$(get_player_rank "$player_name")
        local current_time=$(date +%s)
        local updates=$(jq -n \
            --arg ip "$player_ip" \
            --arg rank "$rank" \
            --arg password "NONE" \
            --argjson created "$current_time" \
            '{
                ip_first: $ip,
                password: $password,
                rank: $rank,
                created: $created
            }')
        
        update_user_data "$DATA_FILE" "$player_name" "$updates"
        print_success "Added new player to registry: $player_name ($player_ip) with rank: $rank"
        
        # Remind player to set password after 5 seconds (only once)
        if [[ -z "${ip_mismatch_announced[$player_name]}" ]]; then
            ip_mismatch_announced["$player_name"]=1
            (
                sleep 5
                # Check if player is still connected before sending message
                if is_player_connected "$player_name"; then
                    send_server_command "$SCREEN_SERVER" "WARNING: $player_name, you don't have a password set for IP verification."
                    send_server_command "$SCREEN_SERVER" "Use !ip_psw PASSWORD CONFIRM_PASSWORD to set your password, or you may lose access to your account if your IP changes."
                    send_server_command "$SCREEN_SERVER" "Example: !ip_psw mypassword123 mypassword123"
                fi
            ) &
        fi
    fi
    
    return 0
}

# Function to check if a player is currently connected
is_player_connected() {
    local player_name="$1"
    # Check if player is in the current player list
    if screen -S "$SCREEN_SERVER" -p 0 -X stuff "/list$(printf \\r)" 2>/dev/null; then
        # Give the server a moment to process the command
        sleep 0.5
        # Check the log for the player name in the list
        if tail -n 10 "$LOG_FILE" | grep -q "$player_name"; then
            return 0
        fi
    fi
    return 1
}

# Function to detect spam and dangerous commands
check_dangerous_activity() {
    local player_name="$1" message="$2" current_time=$(date +%s)
    
    # Skip if player name is invalid or is server
    ! is_valid_player_name "$player_name" || [ "$player_name" = "SERVER" ] && return 0
    
    # Check if player is in grace period - restrict sensitive commands
    if is_in_grace_period "$player_name"; then
        # List of restricted commands during grace period
        local restricted_commands="!give_admin !give_mod !buy_admin !buy_mod /stop /admin /mod /clear /clear-blacklist /clear-adminlist /clear-modlist /clear-whitelist"
        
        for cmd in $restricted_commands; do
            if [[ "$message" == "$cmd"* ]]; then
                print_error "RESTRICTED COMMAND: $player_name attempted to use $cmd during IP change grace period"
                send_server_command "$SCREEN_SERVER" "WARNING: $player_name, sensitive commands are restricted during IP verification."
                return 1
            fi
        done
    fi
    
    # Get player IP for banning
    local player_ip=$(get_ip_by_name "$player_name")
    
    # Check for spam (more than 2 messages in 1 second)
    if [ -n "${player_message_times[$player_name]}" ]; then
        local last_time=${player_message_times[$player_name]}
        local count=${player_message_counts[$player_name]}
        
        if [ $((current_time - last_time)) -le 1 ]; then
            count=$((count + 1))
            player_message_counts[$player_name]=$count
            
            if [ $count -gt 2 ]; then
                print_error "SPAM DETECTED: $player_name sent $count messages in 1 second"
                send_server_command "$SCREEN_SERVER" "/ban $player_ip"
                send_server_command "$SCREEN_SERVER" "WARNING: $player_name (IP: $player_ip) was banned for spamming"
                return 1
            fi
        else
            # Reset counter if more than 1 second has passed
            player_message_counts[$player_name]=1
            player_message_times[$player_name]=$current_time
        fi
    else
        # First message from this player
        player_message_times[$player_name]=$current_time
        player_message_counts[$player_name]=1
    fi
    
    # Check for dangerous commands from ranked players
    local rank=$(get_player_rank "$player_name")
    if [ "$rank" != "NONE" ]; then
        # List of dangerous commands
        local dangerous_commands="/stop /shutdown /restart /banall /kickall /op /deop /save-off"
        
        for cmd in $dangerous_commands; do
            if [[ "$message" == "$cmd"* ]]; then
                print_error "DANGEROUS COMMAND: $player_name ($rank) attempted to use: $message"
                record_admin_offense "$player_name"
                local offense_count=$?
                
                if [ $offense_count -ge 2 ]; then
                    send_server_command "$SCREEN_SERVER" "/ban $player_ip"
                    send_server_command "$SCREEN_SERVER" "WARNING: $player_name (IP: $player_ip) was banned for attempting dangerous commands"
                    return 1
                else
                    send_server_command "$SCREEN_SERVER" "WARNING: $player_name, dangerous commands are restricted!"
                    return 0
                fi
            fi
        done
    fi
    
    return 0
}
