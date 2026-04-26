# Pointless Homebrew Cask

This directory contains the [Homebrew Cask](https://docs.brew.sh/Cask-Cookbook) for Pointless.
It is intended to be distributed via a personal tap: `AR-1106/homebrew-pointless`.

## How it works

1. When you run `../release.sh`, it builds and notarizes `Pointless-x.y.z.dmg`.
2. `release.sh` automatically computes the SHA-256 checksum of the DMG.
3. It updates `pointless.rb` in this directory with the new `version` and `sha256`.
4. You upload the DMG to GitHub Releases for `AR-1106/Pointless`.
5. You copy/symlink `pointless.rb` to your tap repository (`AR-1106/homebrew-pointless`) and commit it.

## Testing locally

To test the cask locally without publishing to the tap:

```bash
# Ensure no cached versions interfere
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_FROM_API=1

# Install from the local file
brew install --cask ./pointless.rb

# Audit for style and correctness
brew audit --new --cask ./pointless.rb
brew style --fix ./pointless.rb

# Test uninstall and zap
brew uninstall --cask pointless
brew zap --cask pointless
```
