#!/usr/bin/env bash

# Color configuration
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display critical errors
critical_error() {
    echo -e "${RED}[CRITICAL ERROR]${NC} $1"
    exit 1
}

# Function to display warnings
warning() {
    echo -e "${ORANGE}[WARNING]${NC} $1"
}

# Function to display success messages
success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Function to display information
info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Function to download files from GitHub
download_github() {
    local file=$1
    info "Downloading $file..."
    curl -sSL -o "$file" "https://raw.githubusercontent.com/noxthewildshadow/Test/main/$file"
    
    if [ $? -ne 0 ]; then
        warning "Failed to download $file"
        return 1
    else
        success "$file downloaded successfully"
        return 0
    fi
}

# Step 1: Check for required dependencies
info "Checking required dependencies..."
command -v curl >/dev/null 2>&1 || critical_error "curl is required but not installed"
command -v patchelf >/dev/null 2>&1 || critical_error "patchelf is required but not installed"

# Step 2: Download and extract the binary
info "Downloading main binary..."
curl -sL https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz | tar xvz

if [ $? -ne 0 ]; then
    critical_error "Failed to download the main binary"
fi

# Step 3: Apply patches to the binary
info "Applying patches to executable..."
declare -A patches=(
    ["libgnustep-base.so.1.24"]="libgnustep-base.so.1.28"
    ["libobjc.so.4.6"]="libobjc.so.4"
    ["libgnutls.so.26"]="libgnutls.so.30"
    ["libgcrypt.so.11"]="libgcrypt.so.20"
    ["libffi.so.6"]="libffi.so.8"
    ["libicui18n.so.48"]="libicui18n.so.70"
    ["libicuuc.so.48"]="libicuuc.so.70"
    ["libicudata.so.48"]="libicudata.so.70"
    ["libdispatch.so"]="libdispatch.so.0"
)

for original in "${!patches[@]}"; do
    patchelf --replace-needed "$original" "${patches[$original]}" blockheads_server171
    if [ $? -ne 0 ]; then
        warning "Failed to apply patch for $original"
    fi
done

success "Patches applied to executable"

# Step 4: Download additional scripts
github_files=("installer.sh" "server_manager.sh" "server_patcher.sh" "common_functions.sh" "server_commands.sh")

for file in "${github_files[@]}"; do
    download_github "$file"
done

# Step 5: Set execute permissions
info "Setting execute permissions..."
chmod +x installer.sh server_manager.sh server_patcher.sh server_commands.sh

if [ $? -ne 0 ]; then
    warning "Failed to set execute permissions on all files"
fi

# Step 6: Execute installer
info "Executing installer..."
curl -sSL https://raw.githubusercontent.com/noxthewildshadow/Test/main/installer.sh | sudo bash

if [ $? -ne 0 ]; then
    critical_error "Failed to execute installer"
else
    success "Installation completed successfully"
fi
