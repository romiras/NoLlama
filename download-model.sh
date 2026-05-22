#!/usr/bin/env bash
# download-model.sh — Download or convert any HuggingFace model for NoLlama
#
# Usage:
#     ./download-model.sh OpenVINO/Qwen3-8B-int4-cw-ov          # pre-exported, just download
#     ./download-model.sh Qwen/Qwen2.5-VL-3B-Instruct --convert --weight int8
#     ./download-model.sh Qwen/Qwen2.5-VL-3B-Instruct --convert --weight int4 --trust
#
# Downloads to ~/models/<repo-name>/ by default.
# Use --output to override the target directory.

set -euo pipefail

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Defaults
HF_ID=""
CONVERT=false
WEIGHT="int4"
TRUST=false
OUTPUT=""

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --convert)
            CONVERT=true
            shift
            ;;
        --weight)
            WEIGHT="$2"
            shift 2
            ;;
        --trust)
            TRUST=true
            shift
            ;;
        --output)
            OUTPUT="$2"
            shift 2
            ;;
        -*)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
        *)
            if [[ -z "$HF_ID" ]]; then
                HF_ID="$1"
            else
                echo -e "${RED}Unknown argument: $1${NC}"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$HF_ID" ]]; then
    echo -e "${RED}Error: HuggingFace ID is required.${NC}"
    echo "Usage: $0 <HfId> [--convert] [--weight <weight>] [--trust] [--output <output>]"
    exit 1
fi

# Activate venv if it exists
if [[ -f "$SCRIPT_DIR/venv/bin/activate" ]]; then
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/venv/bin/activate"
elif [[ -f "$SCRIPT_DIR/venv/Scripts/activate" ]]; then
    # In case someone runs this on Git Bash/WSL with a Windows venv
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/venv/Scripts/activate"
else
    echo -e "${YELLOW}WARNING: No venv found. Using system Python.${NC}"
fi

# Determine target directory
REPO_NAME="${HF_ID##*/}"
if [[ -z "$OUTPUT" ]]; then
    OUTPUT="$HOME/models/$REPO_NAME"
fi

echo ""
echo -e "${CYAN}=== NoLlama Model Download ===${NC}"
echo ""
echo "  Model:  $HF_ID"
echo "  Target: $OUTPUT"
if [[ "$CONVERT" == true ]]; then
    echo "  Mode:   Convert (optimum-cli, $WEIGHT)"
else
    echo "  Mode:   Download (pre-exported)"
fi
echo ""

if [[ -d "$OUTPUT" ]]; then
    echo -e "${YELLOW}Target directory already exists: $OUTPUT${NC}"
    read -rn 1 -p "Overwrite? [y/N] " reply
    echo ""
    if [[ ! "$reply" =~ ^[yY]$ ]]; then
        echo "Aborted."
        exit 0
    fi
    rm -rf "$OUTPUT"
fi

if [[ "$CONVERT" == true ]]; then
    echo -e "${CYAN}Converting $HF_ID to OpenVINO ($WEIGHT)...${NC}"
    echo "  This may take 5-30 minutes depending on model size."
    echo ""

    ARGS=("export" "openvino" "--model" "$HF_ID" "--weight-format" "$WEIGHT")
    if [[ "$TRUST" == true ]]; then
        ARGS+=("--trust-remote-code")
    fi
    ARGS+=("$OUTPUT")

    echo -e "\033[0;90mRunning: optimum-cli ${ARGS[*]}${NC}"
    echo ""
    
    if ! optimum-cli "${ARGS[@]}"; then
        echo ""
        echo -e "${RED}ERROR: Conversion failed.${NC}"
        echo -e "${YELLOW}  Common fixes:${NC}"
        echo -e "${YELLOW}    - Add --trust if the model needs trust-remote-code${NC}"
        echo -e "${YELLOW}    - Check that optimum-intel is installed: pip install optimum[openvino]${NC}"
        echo -e "${YELLOW}    - Some architectures aren't supported yet by optimum-intel${NC}"
        exit 1
    fi
else
    echo -e "${CYAN}Downloading $HF_ID...${NC}"
    echo ""

    export PYTHONIOENCODING="utf-8"
    if ! hf download "$HF_ID" --local-dir "$OUTPUT"; then
        echo ""
        echo -e "${RED}ERROR: Download failed.${NC}"
        echo -e "${YELLOW}  If 401/403: run './venv/bin/huggingface-cli login' first${NC}"
        exit 1
    fi
fi

echo ""
echo -e "${GREEN}[OK] Model ready at: $OUTPUT${NC}"
echo ""
echo "To use with NoLlama:"
echo "  python3 nollama.py --model-dir \"$OUTPUT\" --device GPU"
echo "  python3 nollama.py --gpu-model-dir \"$OUTPUT\""
echo ""
