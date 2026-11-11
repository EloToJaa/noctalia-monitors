default:
    @just --list

# Unit tests for the pure logic (monitors/model.luau)
test:
    luau tests/model_test.luau

# Type/syntax check every entry script
check:
    luau-analyze monitors/*.luau tests/*.luau

# Format Nix files
fmt:
    alejandra .

# Build the plugin source package
build:
    nix build

# Copy the plugin into Noctalia's local plugin dir (hot-reloads in the running shell)
deploy:
    mkdir -p ~/.local/share/noctalia/plugins/monitors
    rsync -a --delete monitors/ ~/.local/share/noctalia/plugins/monitors/
