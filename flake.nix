{
  description = "Tweet Filter with Gemini Nano - Chrome Extension Development Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Node.js runtime and package manager
            nodejs_20

            # Git for version control
            git

            # Optional: Browser automation and testing tools
            # chromium  # Uncomment if you want Chromium in the dev environment
          ];

          shellHook = ''
            echo "🚀 Tweet Filter with Gemini Nano Development Environment"
            echo ""
            echo "Node.js version: $(node --version)"
            echo "npm version: $(npm --version)"
            echo ""
            echo "Available commands:"
            echo "  npm install       - Install dependencies"
            echo "  npm run build     - Build the extension"
            echo ""
            echo "Chrome Extension Setup:"
            echo "  1. Build: npm run build"
            echo "  2. Load: chrome://extensions/ → Developer mode → Load unpacked → dist/"
            echo "  3. After changes: rebuild and reload extension in Chrome"
            echo ""
          '';
        };
      }
    );
}
