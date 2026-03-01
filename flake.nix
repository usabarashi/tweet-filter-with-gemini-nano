{
  description = "Tweet Filter with Gemini Nano - Chrome Extension Development Environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # Node.js LTS (>=22.5 required for spago 1.x)
            nodejs

            # PureScript compiler (spago is installed via npm)
            purescript

            # TLA+ model checker
            tlaplus
          ];

          shellHook = ''
            echo "Tweet Filter with Gemini Nano Development Environment"
            echo ""
            echo "Node.js version: $(node --version)"
            echo "PureScript version: $(purs --version)"
            echo ""
            echo "Available commands:"
            echo "  npm install       - Install dependencies (includes spago)"
            echo "  npm run build     - Build the extension (spago build + Vite bundle)"
            echo "  npm test          - Run PureScript tests"
            echo "  tlc modeling/TweetFilter.tla  - Run TLA+ model checker"
            echo ""
            echo "Chrome Extension Setup:"
            echo "  1. Build: npm run build"
            echo "  2. Load: chrome://extensions/ -> Developer mode -> Load unpacked -> dist/"
            echo "  3. After changes: rebuild and reload extension in Chrome"
            echo ""
          '';
        };
      }
    );
}
