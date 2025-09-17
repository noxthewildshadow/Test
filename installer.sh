#!/usr/bin/env bash

# =============================================================================
# THE BLOCKHEADS SERVER INSTALLER
# =============================================================================

# Color configuration
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
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

# Function to display step messages
step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

# Function to check for required dependencies
check_dependencies() {
    step "Checking required dependencies..."
    
    local missing_deps=()
    
    if ! command -v curl &> /dev/null; then
        missing_deps+=("curl")
    fi
    
    if ! command -v tar &> /dev/null; then
        missing_deps+=("tar")
    fi
    
    if ! command -v patchelf &> /dev/null; then
        missing_deps+=("patchelf")
    fi
    
    if ! command -v screen &> /dev/null; then
        missing_deps+=("screen")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        warning "Missing dependencies: ${missing_deps[*]}"
        info "Please install them with: sudo apt-get install ${missing_deps[*]}"
        return 1
    fi
    
    success "All dependencies are installed"
    return 0
}

# Function to download and extract the server binary
download_server() {
    step "Downloading server binary..."
    
    if curl -sL https://web.archive.org/web/20240309015235if_/https://majicdave.com/share/blockheads_server171.tar.gz | tar xvz; then
        success "Server binary downloaded and extracted"
    else
        critical_error "Failed to download server binary"
    fi
}

# Function to patch the server binary
patch_server() {
    step "Patching server binary..."
    
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
    
    local errors=0
    for original in "${!patches[@]}"; do
        if patchelf --replace-needed "$original" "${patches[$original]}" blockheads_server171; then
            info "Patched $original → ${patches[$original]}"
        else
            warning "Failed to patch $original"
            ((errors++))
        fi
    done
    
    if [ $errors -eq 0 ]; then
        success "All patches applied successfully"
    else
        warning "$errors patches failed (this might be OK if libraries are already available)"
    fi
}

# Function to download additional scripts from GitHub
download_scripts() {
    step "Downloading additional scripts..."
    
    local scripts=(
        "server_manager.sh"
        "server_patcher.sh"
        "common_functions.sh"
        "server_commands.sh"
    )
    
    local errors=0
    for script in "${scripts[@]}"; do
        info "Downloading $script..."
        if curl -sSL -o "$script" "https://raw.githubusercontent.com/noxthewildshadow/Test/main/$script"; then
            success "Downloaded $script"
        else
            warning "Failed to download $script"
            ((errors++))
        fi
    done
    
    if [ $errors -eq 0 ]; then
        success "All scripts downloaded successfully"
    else
        warning "Some scripts failed to download (you may need to download them manually)"
    fi
}

# Function to set execute permissions
set_permissions() {
    step "Setting execute permissions..."
    
    chmod +x blockheads_server171 server_manager.sh server_patcher.sh server_commands.sh
    
    success "Execute permissions set"
}

# Function to create default directory structure
create_directories() {
    step "Creating directory structure..."
    
    local saves_dir="$HOME/GNUstep/Library/ApplicationSupport/TheBlockheads/saves"
    mkdir -p "$saves_dir"
    
    success "Directory structure created at $saves_dir"
}

# Function to display completion message
show_completion() {
    echo ""
    success "INSTALLATION COMPLETED SUCCESSFULLY!"
    echo ""
    info "Next steps:"
    info "1. Create a world with: ${GREEN}./blockheads_server171 -n${NC}"
    info "2. After creating the world, press ${YELLOW}CTRL+C${NC} to exit"
    info "3. Start your server with: ${GREEN}./server_manager.sh start [WORLD_NAME]${NC}"
    echo ""
    info "Available commands:"
    info "  ${GREEN}./server_manager.sh start [WORLD_NAME] [PORT]${NC} - Start server"
    info "  ${RED}./server_manager.sh stop [PORT]${NC}              - Stop server"
    info "  ${CYAN}./server_manager.sh status [PORT]${NC}           - Show server status"
    info "  ${YELLOW}./server_manager.sh list${NC}                  - List running servers"
    info "  ${YELLOW}./server_manager.sh help${NC}                  - Show help"
    echo ""
    warning "Note: If you encounter library errors, run: ${ORANGE}./server_patcher.sh${NC}"
    echo ""
}

# Main installation process
main() {
    echo -e "${CYAN}"
    echo "================================================"
    echo "    THE BLOCKHEADS SERVER INSTALLATION"
    echo "================================================"
    echo -e "${NC}"
    
    # Check dependencies
    if ! check_dependencies; then
        warning "Some dependencies are missing, but we'll continue anyway"
    fi
    
    # Download server binary
    download_server
    
    # Patch server binary
    patch_server
    
    # Download additional scripts
    download_scripts
    
    # Set execute permissions
    set_permissions
    
    # Create directory structure
    create_directories
    
    # Display completion message
    show_completion
}

# Run main function
main "$@"
