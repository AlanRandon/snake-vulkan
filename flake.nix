{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    zig-overlay = {
      url = "github:mitchellh/zig-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
    zls-overlay = {
      url = "github:zigtools/zls";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        zig-overlay.follows = "zig-overlay";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = { self, nixpkgs, flake-utils, zig-overlay, zls-overlay }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        zig = zig-overlay.packages.${system}.master;
        overlays = [
          (final: prev: {
            inherit zig;
          })
        ];
        pkgs = import nixpkgs { inherit system overlays; };
        zls = zls-overlay.packages.${system}.zls.overrideAttrs (old: {
          nativeBuildInputs = [ zig ];
        });
        nativeBuildInputs = with pkgs; [ shaderc zig ];
        buildInputs =
          with pkgs; [
            vulkan-tools
            vulkan-headers
            vulkan-loader
            vulkan-validation-layers
            spirv-tools
            stb
            glfw
            libsoundio
          ];
      in
      {
        devShell = pkgs.mkShell {
          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          VULKAN_SDK = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          packages = [ zls ];
          inherit buildInputs nativeBuildInputs;
        };
      }
    );
}
