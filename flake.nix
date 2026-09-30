{
  description = "Headroom — the context optimization layer for LLM applications";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # The package definition lives here rather than in a separate file so the
      # flake stays a single reviewable unit. It is written as a callPackage-able
      # function so the overlay below can splice in nixpkgs' own dependencies.
      headroomPackage =
        {
          lib,
          # Supplied as python313Packages at every call site below. headroom supports
          # 3.10–3.14, but nixpkgs' default python3 is 3.14 and only the 3.13 package
          # set is known to build the full dependency list here, so 3.13 is requested
          # explicitly. (The original reason for the pin — litellm carrying a
          # `python_version < '3.14'` marker, which left the dashboard's "Proxy $
          # Saved" tile at $0.00 on 3.14 — is gone: litellm is unconditional again.)
          python3Packages,
          rustPlatform,
          cargo,
          rustc,
          cmake,
          perl,
          pkg-config,
          sqlite,
          ast-grep,
          difftastic,
          scc,
          # The `[proxy]` extra is upstream's documented "most common install":
          # it is what `headroom proxy` needs. Turn it off for a lean CLI that
          # only does local compression.
          withProxy ? true,
        }:
        python3Packages.buildPythonApplication rec {
          pname = "headroom-ai";
          version = (lib.importTOML (src + "/pyproject.toml")).project.version;
          pyproject = true;

          src = self;

          # No git dependencies in Cargo.lock, so the vendored tree is fully
          # described by the lockfile — nothing to re-hash on a dep bump.
          cargoDeps = rustPlatform.importCargoLock { lockFile = src + "/Cargo.lock"; };

          nativeBuildInputs = [
            rustPlatform.cargoSetupHook
            rustPlatform.maturinBuildHook
            rustPlatform.bindgenHook # aws-lc-sys, onig_sys need libclang
            cargo
            rustc
            cmake # aws-lc-sys builds its C core with cmake
            perl
            pkg-config
          ];

          # cmake is present only for the aws-lc-sys build script; without this
          # nixpkgs' cmake hook would try to configure the repo root itself.
          dontUseCmakeConfigure = true;

          buildInputs = [ sqlite ];

          # `ast-grep-cli` is the upstream PyPI wrapper around the ast-grep
          # binary and is not packaged in nixpkgs. headroom resolves the tool
          # from PATH (headroom/binaries.py) and degrades gracefully when it is
          # missing, so drop the Python dep and wrap the real binary in instead.
          pythonRemoveDeps = [ "ast-grep-cli" ];

          # Every version floor in pyproject.toml is satisfied by the locked
          # nixpkgs, so no `pythonRelaxDeps` is needed. If a `nix flake update`
          # lands a nixpkgs whose package sits below a floor, the runtime-deps
          # check fails loudly at build time — add the offending name to a
          # `pythonRelaxDeps` list here after confirming it is safe.

          dependencies =
            with python3Packages;
            [
              tiktoken
              pydantic
              litellm
              click
              rich
              opentelemetry-api
              pyyaml
              tomlkit
              # A core (not `[proxy]`) dependency since 0.39.1 / GH #3831:
              # headroom/proxy/ssl_context.py verifies upstream TLS through the OS
              # trust store by default, so TLS-inspecting corporate roots (Zscaler
              # et al) are honoured — hence it is needed even with withProxy = false.
              truststore
            ]
            ++ lib.optionals withProxy (
              [
                fastapi
                uvicorn
                orjson
                httpx
                openai
                mcp
                magika
                zstandard
                websockets
                onnxruntime
                transformers
                watchdog
                sqlite-vec
              ]
              ++ httpx.optional-dependencies.http2
            );

          # `headroom tools` otherwise fetches prebuilt difft/scc/ast-grep
          # binaries into a per-user cache, which will not run unpatched on
          # NixOS. Splicing nixpkgs' builds into the wrapper's PATH makes
          # `headroom diff`, `headroom loc` and `headroom sg` resolve them as
          # already-installed ("on-path") tools and skips the download entirely.
          # nixpkgs tracks these ahead of the versions in headroom's registry
          # (difft 0.64, scc 3.5); both are backwards compatible for the flags
          # headroom passes.
          makeWrapperArgs = [
            "--prefix"
            "PATH"
            ":"
            (lib.makeBinPath [
              ast-grep
              difftastic
              scc
            ])
          ];

          # The upstream suite pulls models and hits the network; the import
          # check below is what actually proves the maturin build produced a
          # loadable `headroom._core`.
          doCheck = false;
          pythonImportsCheck = [
            "headroom"
            "headroom._core"
          ];

          meta = {
            description = "The context optimization layer for LLM applications";
            homepage = "https://github.com/chopratejas/headroom";
            changelog = "https://github.com/chopratejas/headroom/blob/main/CHANGELOG.md";
            license = lib.licenses.asl20;
            mainProgram = "headroom";
            platforms = lib.platforms.unix;
          };
        };
    in
    {
      overlays.default = final: prev: {
        headroom = final.callPackage headroomPackage { python3Packages = final.python313Packages; };
      };

      packages = forAllSystems (pkgs: rec {
        headroom = pkgs.callPackage headroomPackage { python3Packages = pkgs.python313Packages; };
        headroom-minimal = headroom.override { withProxy = false; };
        default = headroom;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          inputsFrom = [ self.packages.${pkgs.system}.headroom ];
          packages = with pkgs; [
            uv
            maturin
            rustc
            cargo
            clippy
            rustfmt
            ruff
            nodejs # commitlint hooks
            ast-grep
            difftastic
            scc
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
