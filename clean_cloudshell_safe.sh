#!/bin/bash

echo "🚀 Nettoyage des SDKs et gros outils inutilés (Docker/k3d intacts)..."
echo "-------------------------------------------------------------------"

# 1. Nettoyage des paquets système et caches d'installation
echo "📦 Purge des caches APT..."
sudo apt-get clean
sudo apt-get autoclean
sudo apt-get autoremove -y

# 2. Suppression des gros SDKs préinstallés inutiles
echo "🔥 Suppression de .NET, Rust, Go, Android SDK et paquets lourds..."
sudo rm -rf /usr/share/dotnet
sudo rm -rf /usr/local/go
sudo rm -rf /root/.rustup /root/.cargo
sudo rm -rf /usr/local/android-sdk

# 3. Nettoyage des dossiers temporaires système
echo "🧹 Purge des fichiers temporaires /tmp..."
sudo rm -rf /tmp/* /var/tmp/*
sudo rm -rf /var/cache/*

# 4. Réduction des logs du système
echo "📰 Purge des logs journald..."
sudo journalctl --vacuum-size=10M

echo "-------------------------------------------------------------------"
echo "✅ Nettoyage ciblé terminé !"
echo "📊 Espace disponible sur la racine (/):"
df -h /
