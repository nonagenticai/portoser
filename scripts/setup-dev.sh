#!/usr/bin/env bash
# Setup development environment for Portoser with uv

set -euo pipefail

echo "🚀 Setting up Portoser development environment..."
echo ""

# Check if uv is installed
if ! command -v uv &> /dev/null; then
    echo "❌ uv is not installed!"
    echo ""
    read -p "Do you want to install uv now? (Y/n) " -n 1 -r
    echo
    if [[ ! "$REPLY" =~ ^[Nn]$ ]]; then
        ./scripts/install-uv.sh
    else
        echo "Please install uv manually: https://github.com/astral-sh/uv"
        exit 1
    fi
fi

echo "✅ uv is installed ($(uv --version))"
echo ""

# Navigate to backend directory
cd "$(dirname "$0")/../web/backend"

echo "📦 Installing Python dependencies with uv..."
uv sync

echo ""
echo "✅ Development environment setup complete!"
echo ""
echo "Available commands:"
echo "  uv run uvicorn main:app --reload       # Start development server"
echo "  uv run pytest                          # Run tests"
echo "  uv run ruff check .                    # Lint code"
echo "  uv run ruff format .                   # Format code"
echo "  uv pip list                            # List installed packages"
echo "  uv pip install <package>               # Install a new package"
echo ""
echo "To activate the virtual environment:"
echo "  source .venv/bin/activate              # Unix/macOS"
printf '%s\n' '  .venv\Scripts\activate                # Windows'
echo ""
