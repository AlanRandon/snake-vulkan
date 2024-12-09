{
  description = "A flake for vulkan";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShell = pkgs.mkShell {
          shellHook = "exec zsh";

          VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          VULKAN_SDK = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";

          buildInputs =
            with pkgs; [
              vulkan-tools
              vulkan-headers
              vulkan-loader
              vulkan-validation-layers
              spirv-tools
              shaderc
              stb
              glfw
              libmpg123
              libao
            ];
        };
      }
    );
}
