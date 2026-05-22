#!/usr/bin/env bash
# install.sh — NoLlama setup: venv, dependencies, model selection
#
# Usage:
#     ./install.sh              # interactive setup
#     ./install.sh --skip-model   # venv + deps only

set -euo pipefail

# Colors
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

SKIP_MODEL=false
if [[ "${1:-}" == "--skip-model" ]]; then
    SKIP_MODEL=true
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_ROOT="$HOME/models"
VENV_DIR="$SCRIPT_DIR/venv"

echo ""
echo -e "${CYAN}=== NoLlama Install ===${NC}"
echo ""

# 1. Create venv
if [[ -d "$VENV_DIR" ]]; then
    echo "[OK] venv already exists"
else
    echo "Creating Python venv..."
    if ! python3 -m venv "$VENV_DIR"; then
        echo -e "${RED}ERROR: Failed to create venv. Is python3-venv installed?${NC}"
        exit 1
    fi
    echo "[OK] venv created"
fi

# Activate venv
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"

echo "Installing dependencies..."
python3 -m pip install --upgrade pip wheel setuptools > /dev/null 2>&1
if ! python3 -m pip install -r "$SCRIPT_DIR/requirements.txt"; then
    echo -e "${RED}ERROR: pip install failed${NC}"
    exit 1
fi
echo "[OK] Dependencies installed"
echo ""

# 2. Detect devices
echo -e "${CYAN}Detecting devices...${NC}"
DEVICE_INFO=$(python3 -c "
import openvino as ov, json
try:
    core = ov.Core()
    d = {}
    for dev in core.get_available_devices():
        try: d[dev] = core.get_property(dev, 'FULL_DEVICE_NAME')
        except: d[dev] = dev
    print(json.dumps(d))
except Exception as e:
    print(json.dumps({'error': str(e)}))
")

HAS_NPU=$(echo "$DEVICE_INFO" | jq -r 'has("NPU")')
HAS_GPU=$(echo "$DEVICE_INFO" | jq -r 'has("GPU")')

echo ""
if [[ "$HAS_NPU" == "true" ]]; then
    NPU_NAME=$(echo "$DEVICE_INFO" | jq -r '.NPU')
    echo -e "  ${GREEN}[+] NPU: $NPU_NAME${NC}"
else
    echo -e "  ${GRAY}[- ] NPU: not found${NC}"
fi

if [[ "$HAS_GPU" == "true" ]]; then
    GPU_NAME=$(echo "$DEVICE_INFO" | jq -r '.GPU')
    echo -e "  ${GREEN}[+] GPU: $GPU_NAME${NC}"
else
    echo -e "  ${GRAY}[- ] GPU: not found${NC}"
fi

CPU_NAME=$(echo "$DEVICE_INFO" | jq -r '.CPU // "CPU"')
echo -e "  ${GRAY}[+] CPU: $CPU_NAME${NC}"
echo ""

# 3. Scan local models
declare -a LOCAL_MODELS_NAMES
declare -a LOCAL_MODELS_PATHS
declare -a LOCAL_MODELS_TYPES
declare -a LOCAL_MODELS_SIZES
declare -a LOCAL_MODELS_NPU_OK

if [[ -d "$MODELS_ROOT" ]]; then
    echo -e "  ${GRAY}Local models ($MODELS_ROOT):${NC}"
    while IFS= read -r dir; do
        if [[ -f "$dir/openvino_language_model.bin" ]] || [[ -f "$dir/openvino_model.bin" ]]; then
            NAME=$(basename "$dir")
            BIN_PATH=""
            if [[ -f "$dir/openvino_language_model.bin" ]]; then
                BIN_PATH="$dir/openvino_language_model.bin"
            else
                BIN_PATH="$dir/openvino_model.bin"
            fi
            
            BIN_SIZE=$(stat -c%s "$BIN_PATH")
            SIZE_GB=$(echo "scale=1; $BIN_SIZE / 1073741824" | bc)
            
            TYPE="llm"
            if [[ -f "$dir/config.json" ]]; then
                # Simple check for VLM in config.json using jq
                ARCH=$(jq -r '.architectures[0] // ""' "$dir/config.json" | tr '[:upper:]' '[:lower:]')
                MT=$(jq -r '.model_type // ""' "$dir/config.json" | tr '[:upper:]' '[:lower:]')
                if [[ "$ARCH" =~ vl|vision|llava|qwen2vl|internvl|minicpm ]] || [[ "$MT" =~ vl|vision ]]; then
                    TYPE="vlm"
                fi
            fi
            
            NPU_OK=false
            if { [[ "$NAME" =~ int4-cw ]] || [[ "$NAME" =~ cw-ov ]]; } && (( $(echo "$SIZE_GB < 10" | bc -l) )); then
                NPU_OK=true
            fi
            
            LOCAL_MODELS_NAMES+=("$NAME")
            LOCAL_MODELS_PATHS+=("$dir")
            LOCAL_MODELS_TYPES+=("$TYPE")
            LOCAL_MODELS_SIZES+=("$SIZE_GB")
            LOCAL_MODELS_NPU_OK+=("$NPU_OK")
            
            echo -e "    ${GRAY}$NAME ($SIZE_GB GB, ${TYPE^^})${NC}"
        fi
    done < <(find "$MODELS_ROOT" -maxdepth 1 -type d)
    echo ""
fi

if [[ "$SKIP_MODEL" == "true" ]]; then
    echo "Skipping model selection (--skip-model)"
    echo ""
    echo -e "${YELLOW}=== Install complete (no model) ===${NC}"
    exit 0
fi

REGISTRY_JSON=$(cat "$SCRIPT_DIR/models.json")

# Helper: show a model menu and return the selection
show_model_menu() {
    local title="$1"
    local registry_key="$2"
    local filter_type="${3:-}" # optional: llm, vlm
    local filter_npu_ok="${4:-}" # optional: true, false
    local allow_skip="${5:-false}"

    echo -e "${CYAN}=== $title ===${NC}"
    echo ""

    local items_name=()
    local items_action=()
    local items_path=()
    local items_hfid=()
    local items_source=()
    local items_weight=()
    local items_trust=()
    local items_size=()
    local items_notes=()

    # Local models first
    local has_local=false
    for i in "${!LOCAL_MODELS_NAMES[@]}"; do
        if [[ -n "$filter_type" && "${LOCAL_MODELS_TYPES[$i]}" != "$filter_type" ]]; then continue; fi
        if [[ -n "$filter_npu_ok" && "${LOCAL_MODELS_NPU_OK[$i]}" != "$filter_npu_ok" ]]; then continue; fi
        
        if [[ "$has_local" == "false" ]]; then
            echo -e "  ${YELLOW}Already on disk (instant)${NC}"
            has_local=true
        fi
        
        idx=${#items_name[@]}
        items_name+=("${LOCAL_MODELS_NAMES[i]}")
        items_action+=("local")
        items_path+=("${LOCAL_MODELS_PATHS[i]}")
        items_hfid+=("")
        items_source+=("")
        items_weight+=("")
        items_trust+=("false")
        items_size+=("${LOCAL_MODELS_SIZES[i]}")
        items_notes+=("Already on disk")
        
        printf "    %d. %s  (${GRAY}%s GB${NC})  ${GRAY}Already on disk${NC}\n" "$((idx + 1))" "${LOCAL_MODELS_NAMES[i]}" "${LOCAL_MODELS_SIZES[i]}"
    done
    if [[ "$has_local" == "true" ]]; then echo ""; fi

    # Registry models
    echo -e "  ${YELLOW}Download from HuggingFace:${NC}"
    local reg_count
    reg_count=$(echo "$REGISTRY_JSON" | jq -r ".${registry_key} | length")
    for ((i=0; i<reg_count; i++)); do
        local name hfid rsource rweight rtrust rsize rnotes
        name=$(echo "$REGISTRY_JSON" | jq -r ".${registry_key}[$i].name")
        hfid=$(echo "$REGISTRY_JSON" | jq -r ".${registry_key}[$i].hf_id")
        
        # Skip if already in local models
        local already_local=false
        for ln in "${LOCAL_MODELS_NAMES[@]}"; do
            if [[ "$(echo "$ln" | tr '[:upper:]' '[:lower:]')" == "$(echo "${hfid##*/}" | tr '[:upper:]' '[:lower:]')" ]]; then
                already_local=true
                break
            fi
        done
        if [[ "$already_local" == "true" ]]; then continue; fi

        rsource=$(echo "$REGISTRY_JSON" | jq -r ".${registry_key}[$i].source")
        rweight=$(echo "$REGISTRY_JSON" | jq -r ".${registry_key}[$i].weight_format // \"int4\"")
        rtrust=$(echo "$REGISTRY_JSON" | jq -r ".${registry_key}[$i].trust_remote_code // false")
        rsize=$(echo "$REGISTRY_JSON" | jq -r ".${registry_key}[$i].est_size_gb")
        rnotes=$(echo "$REGISTRY_JSON" | jq -r ".${registry_key}[$i].notes // \"\"")

        local dl_tag="download"
        if [[ "$rsource" == "convert" ]]; then dl_tag="convert"; fi

        idx=${#items_name[@]}
        items_name+=("$name")
        items_action+=("$rsource")
        items_path+=("")
        items_hfid+=("$hfid")
        items_source+=("$rsource")
        items_weight+=("$rweight")
        items_trust+=("$rtrust")
        items_size+=("$rsize")
        items_notes+=("$rnotes")

        printf "    %d. %s  (${GRAY}~%s GB, %s${NC})  ${GRAY} %s${NC}\n" "$((idx + 1))" "$name" "$rsize" "$dl_tag" "$rnotes"
    done
    echo ""

    local prompt="Pick a model [1-${#items_name[@]}]"
    if [[ "$allow_skip" == "true" ]]; then
        prompt+=" or press Enter to skip"
    fi
    prompt+=": "

    while true; do
        read -rp "$prompt" choice
        if [[ "$allow_skip" == "true" && -z "$choice" ]]; then
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items_name[@]} )); then
            local selected_idx=$((choice - 1))
            SELECTED_ACTION="${items_action[$selected_idx]}"
            SELECTED_NAME="${items_name[$selected_idx]}"
            SELECTED_PATH="${items_path[$selected_idx]}"
            SELECTED_HFID="${items_hfid[$selected_idx]}"
            SELECTED_WEIGHT="${items_weight[$selected_idx]}"
            SELECTED_TRUST="${items_trust[$selected_idx]}"
            return 0
        fi
        echo -e "${RED}Enter a number between 1 and ${#items_name[@]}${NC}"
    done
}

install_model() {
    local target_dir="$1"
    
    if [[ "$SELECTED_ACTION" == "local" ]]; then
        echo -e "Linking to: ${GREEN}$SELECTED_PATH${NC}"
        if [[ -e "$target_dir" ]]; then
            rm -rf "$target_dir"
        fi
        ln -s "$SELECTED_PATH" "$target_dir"
        echo -e "${GREEN}[OK] $SELECTED_NAME${NC}"
        return 0
    fi

    # For pre-exported or convert, use download-model.sh
    local args=("$SELECTED_HFID" "--output" "$target_dir")
    if [[ "$SELECTED_ACTION" == "convert" ]]; then
        args+=("--convert" "--weight" "$SELECTED_WEIGHT")
    fi
    if [[ "$SELECTED_TRUST" == "true" ]]; then
        args+=("--trust")
    fi

    if ! bash "$SCRIPT_DIR/download-model.sh" "${args[@]}"; then
        echo -e "${RED}ERROR: Model installation failed.${NC}"
        return 1
    fi
    return 0
}

MODEL_DIR="$SCRIPT_DIR/model"
GPU_MODEL_DIR="$SCRIPT_DIR/gpu-model"
START_ARGS=()

if [[ "$HAS_NPU" == "true" ]]; then
    # Step 1: NPU chat model
    show_model_menu "Step 1: Chat Model (NPU)" "npu" "llm" "true" "false"
    # NPU_SELECTED_NAME is just for bookkeeping, can be used for filtering Step 2
    NPU_SELECTED_NAME="$SELECTED_NAME"
    export NPU_SELECTED_NAME
    if ! install_model "$MODEL_DIR"; then
        echo -e "${YELLOW}Model installation failed. You can re-run install.sh to try again.${NC}"
        exit 1
    fi
    START_ARGS+=("--device" "NPU")
    echo ""

    # Step 2: GPU model (optional)
    if [[ "$HAS_GPU" == "true" ]]; then
        echo -e "${CYAN}=== Step 2: GPU Model (optional) ===${NC}"
        echo ""
        echo "  You also have an Intel GPU. What do you want to use it for?"
        echo ""
        echo "    A. Vision model  — image understanding alongside NPU chat"
        echo "    B. Bigger LLM    — much smarter chat than the NPU model"
        echo "    C. Skip          — NPU chat only"
        echo ""
        while true; do
            read -rp "  [A/B/C]: " gpu_choice
            gpu_choice=$(echo "$gpu_choice" | tr '[:lower:]' '[:upper:]')
            if [[ "$gpu_choice" =~ ^[ABC]$ ]] || [[ -z "$gpu_choice" ]]; then break; fi
            echo -e "${RED}  Enter A, B, or C${NC}"
        done

        if [[ "$gpu_choice" == "A" ]]; then
            show_model_menu "GPU Vision Model" "gpu_vlm" "vlm" "" "true"
            if [[ -n "${SELECTED_NAME:-}" ]]; then
                if install_model "$GPU_MODEL_DIR"; then
                    START_ARGS+=("--gpu-model-dir" "gpu-model")
                fi
            fi
        elif [[ "$gpu_choice" == "B" ]]; then
            show_model_menu "GPU LLM (bigger chat model)" "gpu_llm" "llm" "" "true"
            if [[ -n "${SELECTED_NAME:-}" ]]; then
                if install_model "$GPU_MODEL_DIR"; then
                    START_ARGS+=("--gpu-model-dir" "gpu-model")
                fi
            fi
        fi
    fi
elif [[ "$HAS_GPU" == "true" ]]; then
    echo -e "${YELLOW}No NPU detected. Selecting a GPU model.${NC}"
    echo ""
    # Merge GPU VLM and LLM for the menu
    # In Bash we can't easily merge JSON but we can just ask show_model_menu to handle a combined view
    # For simplicity, let's just show gpu_llm and gpu_vlm sequentially in the menu? 
    # Or just use jq to merge them.
    REGISTRY_JSON=$(echo "$REGISTRY_JSON" | jq '.gpu_combined = (.gpu_vlm + .gpu_llm)')
    show_model_menu "GPU Model" "gpu_combined" "" "" "false"
    if install_model "$MODEL_DIR"; then
        START_ARGS+=("--device" "GPU")
    fi
else
    echo -e "${YELLOW}No NPU or GPU detected. Models will run on CPU (slower).${NC}"
    echo ""
    show_model_menu "CPU Model" "npu" "llm" "" "false"
    if install_model "$MODEL_DIR"; then
        START_ARGS+=("--device" "CPU")
    fi
fi

# 5. Generate start.sh
START_SCRIPT="$SCRIPT_DIR/start.sh"
ARGS_STR="${START_ARGS[*]}"

cat > "$START_SCRIPT" <<EOF
#!/usr/bin/env bash
# Auto-generated by install.sh
./start-template.sh --server-args "$ARGS_STR"
EOF

chmod +x "$START_SCRIPT"
echo -e "${GREEN}[OK] Generated start.sh${NC}"

# 6. Convert start-template.ps1 to start-template.sh (if not done yet)
# I'll do this in the next turn to keep this tool call manageable.

echo ""
echo -e "${GREEN}=== NoLlama install complete ===${NC}"
echo ""
echo "To start the server:"
echo "  ./start.sh"
echo ""
