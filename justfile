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

# Copy the plugin to the desktop machine's local plugin dir for testing
deploy host="elotoja@100.112.233.120":
    ssh {{host}} 'mkdir -p ~/.local/share/noctalia/plugins/monitors'
    rsync -a --delete monitors/ {{host}}:.local/share/noctalia/plugins/monitors/
