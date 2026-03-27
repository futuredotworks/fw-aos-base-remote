#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LOG_DIR="$PROJECT_DIR/logs"
VENV_PYTHON="$PROJECT_DIR/.venv/bin/python3"

mkdir -p "$LOG_DIR"

# Determine bind address: Tailscale IP if available, otherwise localhost
# Use --local flag to force localhost (for Cloudflare Tunnel / ngrok)
if [ "${1:-}" = "--local" ]; then
    BIND_IP="127.0.0.1"
    echo "Mode: localhost (use Cloudflare Tunnel or ngrok to expose)"
else
    BIND_IP=$(tailscale ip -4 2>/dev/null || echo "")
    if [ -z "$BIND_IP" ]; then
        BIND_IP="127.0.0.1"
        echo "Tailscale not available, falling back to localhost"
        echo "Tip: use Cloudflare Tunnel to expose from your phone"
    else
        echo "Tailscale IP: $BIND_IP"
    fi
fi

# Kill any existing ttyd processes
pkill -f "ttyd" 2>/dev/null || true
sleep 1

# Keep Mac awake (kill any existing caffeinate first)
pkill -f "caffeinate" 2>/dev/null || true
caffeinate -d -i -s &
CAFFEINATE_PID=$!
echo "caffeinate running (PID: $CAFFEINATE_PID)"

# Start ttyd bound to chosen interface
# Uses tmux-attach.sh wrapper for clean argument handling
ttyd \
    --port 7681 \
    --interface "$BIND_IP" \
    --writable \
    -t fontSize=14 \
    -t lineHeight=1.2 \
    -t cursorBlink=true \
    -t cursorStyle=block \
    -t scrollback=10000 \
    -t 'fontFamily="Menlo, Monaco, Consolas, monospace, Apple Color Emoji, Segoe UI Emoji"' \
    "$SCRIPT_DIR/tmux-attach.sh" \
    >> "$LOG_DIR/ttyd.log" 2>&1 &

TTYD_PID=$!
echo "ttyd running (PID: $TTYD_PID) on http://$BIND_IP:7681"

# Start voice dictation wrapper (use venv Python)
pkill -f "voice-wrapper" 2>/dev/null || true
BIND_IP="$BIND_IP" "$VENV_PYTHON" "$SCRIPT_DIR/voice-wrapper.py" >> "$LOG_DIR/voice-wrapper.log" 2>&1 &
WRAPPER_PID=$!
echo "voice wrapper running (PID: $WRAPPER_PID) on http://$BIND_IP:8080"

echo ""
echo "=== Remote CLI Ready ==="
echo "Terminal:  http://$BIND_IP:7681"
echo "Voice UI:  http://$BIND_IP:8080"
echo ""
echo "Open the Voice UI URL on your phone."
echo "To stop: $SCRIPT_DIR/stop-remote-cli.sh"

# Save PIDs for stop script
echo "$TTYD_PID" > "$LOG_DIR/ttyd.pid"
echo "$CAFFEINATE_PID" > "$LOG_DIR/caffeinate.pid"
echo "$WRAPPER_PID" > "$LOG_DIR/voice-wrapper.pid"

# Watchdog: restart ttyd if it crashes, exit cleanly on SIGTERM
KEEP_RUNNING=true
trap 'KEEP_RUNNING=false; kill $TTYD_PID 2>/dev/null' TERM INT

while $KEEP_RUNNING; do
    wait $TTYD_PID 2>/dev/null || true
    if ! $KEEP_RUNNING; then
        break
    fi
    echo "[$(date)] ttyd exited, restarting in 5s..." >> "$LOG_DIR/ttyd.log"
    sleep 5
    ttyd \
        --port 7681 \
        --interface "$BIND_IP" \
        --writable \
        -t fontSize=14 \
        -t lineHeight=1.2 \
        -t cursorBlink=true \
        -t cursorStyle=block \
        -t scrollback=10000 \
        "$SCRIPT_DIR/tmux-attach.sh" \
        >> "$LOG_DIR/ttyd.log" 2>&1 &
    TTYD_PID=$!
    echo "$TTYD_PID" > "$LOG_DIR/ttyd.pid"
    echo "[$(date)] ttyd restarted (PID: $TTYD_PID)" >> "$LOG_DIR/ttyd.log"
done
