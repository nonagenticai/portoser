#!/usr/bin/env bash
# Install uv (Astral's fast Python package manager)
# https://github.com/astral-sh/uv

set -euo pipefail

echo "🚀 Installing uv (Astral's Python package manager)..."

# Bail out early on unsupported platforms; the upstream installer also
# bails, but a clear error here is friendlier.
OS="$(uname -s)"
case "${OS}" in
    Linux*|Darwin*) ;;
    *) echo "Unsupported OS: ${OS}"; exit 1 ;;
esac

# Install uv
if command -v uv &> /dev/null; then
    echo "✅ uv is already installed ($(uv --version))"
    read -p "Do you want to upgrade? (y/N) " -n 1 -r
    echo
    if [[ "$REPLY" =~ ^[Yy]$ ]]; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
else
    echo "📦 Installing uv..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# Add to PATH if needed
if [[ ":$PATH:" != *":$HOME/.cargo/bin:"* ]]; then
    echo ""
    echo "⚠️  Please add uv to your PATH by adding this to your shell profile:"
    echo "    export PATH=\"\$HOME/.cargo/bin:\$PATH\""
    echo ""
fi

echo "✅ uv installation complete!"
echo ""
echo "Next steps:"
echo "  1. cd web/backend"
echo "  2. uv sync           # Install dependencies"
echo "  3. uv run pytest     # Run tests"
echo ""
