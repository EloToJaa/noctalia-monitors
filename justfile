default:
    @just --list

# Unit tests for the pure logic (monitors/model.luau, monitors/backend.luau).
# The plugin runtime wants `require("./x.luau")`, stock luau wants no extension,
# so the tests run on a copy with the extension stripped.
test:
    rm -rf .test-tmp && mkdir -p .test-tmp/monitors .test-tmp/tests
    cp monitors/model.luau monitors/backend.luau .test-tmp/monitors/
    sed -i 's|\.luau")|")|' .test-tmp/monitors/*.luau
    cp tests/*.luau .test-tmp/tests/
    luau .test-tmp/tests/model_test.luau
    luau .test-tmp/tests/backend_test.luau
    rm -rf .test-tmp

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
