#!/usr/bin/env bash
# start-template.sh — NoLlama launcher
# Starts the server, waits for models to load, then opens the browser.
# Args are set by install.sh in the generated start.sh

set -euo pipefail

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

SERVER_ARGS=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-args)
            SERVER_ARGS="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PORT=8000
URL="http://localhost:$PORT"

# Activate venv
if [[ -f "$SCRIPT_DIR/venv/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/venv/bin/activate"
else
    echo -e "${RED}ERROR: venv not found. Run ./install.sh first.${NC}"
    exit 1
fi

# Start server in background
echo ""
echo -e "  ${CYAN}NoLlama starting...${NC}"
echo ""

# shellcheck disable=SC2086
python3 "$SCRIPT_DIR/nollama.py" $SERVER_ARGS > nollama.log 2>&1 &
SERVER_PID=$!

# Trap to kill server on exit
trap 'kill $SERVER_PID 2>/dev/null || true' EXIT

# Poll /health until ready (or error/timeout)
SPINNER=("|" "/" "-" "\\")
MAX_WAIT=120
ELAPSED=0
LAST_STATUS=""
SPIN_IDX=0

while (( ELAPSED < MAX_WAIT )); do
    sleep 0.5
    ELAPSED=$((ELAPSED + 1)) # This is actually half-seconds if we sleep 0.5

    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo ""
        echo -e "  ${RED}ERROR: Server process exited unexpectedly.${NC}"
        echo "  Check nollama.log for details."
        exit 1
    fi

    # Use curl to check health
    HEALTH_JSON=$(curl -s --max-time 2 "$URL/health" || true)
    
    if [[ -n "$HEALTH_JSON" ]]; then
        STATUS=$(echo "$HEALTH_JSON" | jq -r '.status // ""')

        if [[ "$STATUS" != "$LAST_STATUS" ]]; then
            LAST_STATUS="$STATUS"
            DEVICE_INFO=$(echo "$HEALTH_JSON" | jq -r '.devices | to_entries | .[] | select(.value.status != "not_configured") | "\(.key | ascii_upcase): \(.value.model) (\(.value.status))"' | paste -sd "  |  " -)
            if [[ -n "$DEVICE_INFO" ]]; then
                echo ""
                echo -e "  ${GRAY}$DEVICE_INFO${NC}"
            fi
        fi

        if [[ "$STATUS" == "ready" ]]; then
            echo ""
            echo -e "  ${GREEN}Ready! Opening browser...${NC}"
            echo ""
            
            # Open browser
            if command -v xdg-open > /dev/null; then
                xdg-open "$URL"
            elif command -v open > /dev/null; then
                open "$URL"
            else
                echo "  Please open $URL in your browser."
            fi
            break
        fi

        SPIN="${SPINNER[SPIN_IDX % 4]}"
        SPIN_IDX=$((SPIN_IDX + 1))
        # Simple progress bar
        BAR_LEN=$((ELAPSED / 4))
        if (( BAR_LEN > 40 )); then BAR_LEN=40; fi
        BAR=$(printf "%${BAR_LEN}s" | tr ' ' '#')
        printf "\r  [%s] Loading models... %s" "$SPIN" "$BAR"
    else
        SPIN="${SPINNER[SPIN_IDX % 4]}"
        SPIN_IDX=$((SPIN_IDX + 1))
        printf "\r  [%s] Waiting for server..." "$SPIN"
    fi
done

if (( ELAPSED >= MAX_WAIT )); then
    echo ""
    echo -e "  ${YELLOW}WARNING: Server did not become ready within ${MAX_WAIT}s${NC}"
    echo "  Opening browser anyway..."
    if command -v xdg-open > /dev/null; then
        xdg-open "$URL"
    elif command -v open > /dev/null; then
        open "$URL"
    fi
fi

echo ""
echo "  Server running at $URL"
echo "  Press Ctrl+C to stop."
echo ""

# Wait for server to exit
wait "$SERVER_PID"
