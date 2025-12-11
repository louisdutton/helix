{
  description = "A modal text editor for unix-based systems";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
    ...
  }: let
    inherit (nixpkgs) lib;
    eachSystem = lib.genAttrs lib.systems.flakeExposed;
    pkgsFor = eachSystem (system:
      import nixpkgs {
        localSystem.system = system;
        overlays = [
          (import rust-overlay)
          self.overlays.fugue
          self.overlays.tree-sitter
        ];
      });
    gitRev = self.rev or self.dirtyRev or null;
  in {
    packages = eachSystem (system: {
      inherit (pkgsFor.${system}) fugue;
      /*
      The default Fugue build. Uses the latest stable Rust toolchain, and unstable
      nixpkgs.

      The build inputs can be overridden with the following:

      packages.${system}.default.override { rustPlatform = newPlatform; };

      Overriding a derivation attribute can be done as well:

      packages.${system}.default.overrideAttrs { buildType = "debug"; };
      */
      default = self.packages.${system}.fugue;
    });
    checks =
      lib.mapAttrs (system: pkgs: let
        # Get Fugue's MSRV toolchain to build with by default.
        msrvToolchain = pkgs.pkgsBuildHost.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;
        msrvPlatform = pkgs.makeRustPlatform {
          cargo = msrvToolchain;
          rustc = msrvToolchain;
        };
      in {
        fugue = self.packages.${system}.fugue.override {
          rustPlatform = msrvPlatform;
        };
      })
      pkgsFor;

    # Devshell behavior is preserved.
    devShells =
      lib.mapAttrs (system: pkgs: {
        default = let
          commonRustFlagsEnv = "-C link-arg=-fuse-ld=lld -C target-cpu=native --cfg tokio_unstable";
          platformRustFlagsEnv = lib.optionalString pkgs.stdenv.isLinux "-Clink-arg=-Wl,--no-rosegment";
          grammars = with pkgs.tree-sitter; mkGrammars allGrammars;
        in
          pkgs.mkShell {
            inputsFrom = [self.checks.${system}.fugue];
            nativeBuildInputs = with pkgs;
              [
                lld
                cargo-flamegraph
                rust-bin.nightly.latest.rust-analyzer
              ]
              ++ (lib.optional (stdenv.isx86_64 && stdenv.isLinux) cargo-tarpaulin)
              ++ (lib.optional stdenv.isLinux lldb);

            packages = with pkgs; [
              alejandra
              nixd
            ];

            FUGUE_RUNTIME = "${grammars}";

            shellHook = ''
              export RUST_BACKTRACE="1"
              export RUSTFLAGS="''${RUSTFLAGS:-""} ${commonRustFlagsEnv} ${platformRustFlagsEnv}"
            '';
          };
      })
      pkgsFor;

    overlays = {
      fugue = final: prev: {
        fugue = final.callPackage ./default.nix {inherit gitRev;};
      };

      tree-sitter = final: prev: {
        tree-sitter =
          prev.tree-sitter
          // {
            mkGrammars = grammarPackages: let
              mkGrammarInstall = drv: let
                name = with lib.strings;
                  drv.name
                  |> getName
                  |> removePrefix "tree-sitter-"
                  |> removeSuffix "-grammar"
                  |> replaceStrings ["-"] ["_"];
              in ''
                mkdir $out/queries/${name}
                ln -s ${drv}/parser $out/grammars/${name}.so
                ln -s ${drv}/queries/* $out/queries/${name}/
              '';

              grammarInstalls = builtins.concatStringsSep "\n" (map mkGrammarInstall grammarPackages);
            in
              final.runCommand "tree-sitter-grammars" {} ''
                mkdir -p $out/grammars
                mkdir -p $out/queries
                ${grammarInstalls}
              '';
          };
      };

      default = self.overlays.fugue;
    };
  };
  # nixConfig = {
  #   extra-substituters = ["https://fugue.cachix.org"];
  #   extra-trusted-public-keys = ["fugue.cachix.org-1:ejp9KQpR1FBI2onstMQ34yogDm4OgU2ru6lIwPvuCVs="];
  # };
}
