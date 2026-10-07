#!/usr/bin/env bash
set -e

echo "=========================================================="
echo "  Configuration de Wisper Local (Apple Silicon M4)        "
echo "=========================================================="

# 1. Vérifier Homebrew
if ! command -v brew &>/dev/null; then
    echo "❌ Homebrew n'est pas installé. Veuillez installer Homebrew : https://brew.sh"
    exit 1
fi

echo "📦 Vérification et installation des dépendances locales..."
if ! command -v whisper-cli &>/dev/null; then
    echo "Installation de whisper.cpp..."
    brew install whisper-cpp
fi

if ! command -v ollama &>/dev/null; then
    echo "Installation de Ollama..."
    brew install ollama
fi

# 2. Démarrage de Ollama
echo "🚀 Démarrage du service Ollama..."
brew services start ollama || true

# 3. Téléchargement des modèles Whisper
MODELS_DIR="$HOME/Library/Application Support/WisprFlow/models"
mkdir -p "$MODELS_DIR"

if [ ! -f "$MODELS_DIR/ggml-base.bin" ]; then
    echo "📥 Téléchargement du modèle Whisper Base..."
    curl -L --progress-bar "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin" -o "$MODELS_DIR/ggml-base.bin"
fi

if [ ! -f "$MODELS_DIR/ggml-large-v3-turbo.bin" ]; then
    echo "📥 Téléchargement du modèle Whisper Large v3 Turbo (haute fidélité multilingue)..."
    curl -L --progress-bar "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin" -o "$MODELS_DIR/ggml-large-v3-turbo.bin"
fi

# 4. Modèle LLM 3B (Llama 3.2 3B)
echo "🧠 Téléchargement du modèle Llama 3.2 3B dans Ollama..."
ollama pull llama3.2:3b

# 5. Compilation de l'application macOS
echo "🔨 Compilation de l'application native..."
make clean
make

echo "=========================================================="
echo "  ✅ Installation et configuration réussies !            "
echo "  L'application est prête dans : build/Wisper Dev.app    "
echo "  Pour lancer l'application : make run                   "
echo "=========================================================="
