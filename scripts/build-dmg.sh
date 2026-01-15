#!/bin/bash
#
# build-dmg.sh - Build and package Fluent into a distributable DMG
#
# Usage: ./scripts/build-dmg.sh
#

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="Fluent"
SCHEME="Fluent"
PROJECT="$PROJECT_DIR/Fluent.xcodeproj"

# Print step with color
step() {
    echo -e "${BLUE}==>${NC} $1"
}

success() {
    echo -e "${GREEN}✓${NC} $1"
}

warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

error() {
    echo -e "${RED}✗${NC} $1"
}

# Check dependencies
check_dependencies() {
    step "Checking dependencies..."

    if ! command -v xcodebuild &> /dev/null; then
        error "xcodebuild not found. Please install Xcode."
        exit 1
    fi

    if ! command -v create-dmg &> /dev/null; then
        error "create-dmg not found."
        echo "  Install with: brew install create-dmg"
        exit 1
    fi

    success "All dependencies found"
}

# Clean previous builds
clean() {
    step "Cleaning previous builds..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    success "Build directory cleaned"
}

# Archive the app
archive() {
    step "Archiving $APP_NAME (this may take a minute)..."

    xcodebuild archive \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
        -quiet

    success "Archive created"
}

# Export the app
export_app() {
    step "Exporting $APP_NAME..."

    xcodebuild -exportArchive \
        -archivePath "$BUILD_DIR/$APP_NAME.xcarchive" \
        -exportPath "$BUILD_DIR" \
        -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist" \
        -quiet

    success "App exported to $BUILD_DIR/$APP_NAME.app"
}

# Create DMG
create_dmg() {
    step "Creating DMG..."

    # Remove existing DMG if present (create-dmg won't overwrite)
    rm -f "$BUILD_DIR/$APP_NAME.dmg"

    create-dmg \
        --volname "$APP_NAME" \
        --volicon "$BUILD_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "$APP_NAME.app" 150 190 \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link 450 190 \
        "$BUILD_DIR/$APP_NAME.dmg" \
        "$BUILD_DIR/$APP_NAME.app"

    success "DMG created"
}

# Main
main() {
    echo ""
    echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║${NC}     Building $APP_NAME DMG Installer     ${BLUE}║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════╝${NC}"
    echo ""

    check_dependencies
    clean
    archive
    export_app
    create_dmg

    echo ""
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  Build complete!${NC}"
    echo -e "${GREEN}════════════════════════════════════════════${NC}"
    echo ""
    echo "  DMG location: $BUILD_DIR/$APP_NAME.dmg"
    echo "  Size: $(du -h "$BUILD_DIR/$APP_NAME.dmg" | cut -f1)"
    echo ""
    warning "Note: Without notarization, users will need to"
    echo "       right-click > Open on first launch."
    echo ""
}

main "$@"
