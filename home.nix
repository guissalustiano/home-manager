{ config, pkgs, lib, ... }:

let
  isGui = builtins.pathExists /run/opengl-driver;
  sessionVars = {
    EDITOR = "hx";
  };
  pkgs-unstable = import <nixpkgs-unstable> {
    system = builtins.currentSystem;
    config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
      "claude-code"
      "obsidian"
      "slack"
      "spotify"
      "vscode"
    ];
  };
in
{
  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [
    "claude-code"
    "obsidian"
    "slack"
    "spotify"
    "vscode"
  ];

  nixpkgs.overlays = [
    (final: prev: {
      claude-code = pkgs-unstable.claude-code;
    })
  ];

  home.username = "salust";
  home.homeDirectory = "/home/salust";

  home.stateVersion = "25.11";

  home.packages = [
    pkgs.eza
    pkgs.htop
    pkgs.ripgrep
    pkgs.awscli2
    pkgs.gh
    (pkgs.writeShellScriptBin "nix-init" ''
      echo "use nix" > .envrc
      direnv allow
    '')
  ] ++ lib.optionals isGui [
    pkgs.evince
    pkgs.obsidian
    pkgs.slack
    pkgs.spotify
    pkgs.sweethome3d.application
    pkgs.telegram-desktop
  ];

  programs.vscode = lib.mkIf isGui {
    enable = true;
    package = pkgs.vscode;
    profiles.default.userSettings = {
      "claudeCode.preferredLocation" = "panel";
      "claudeCode.claudeProcessWrapper" = "${config.home.homeDirectory}/.nix-profile/bin/claude";
    };
  };

  home.file.".terminfo/x/xterm-ghostty".source = "${pkgs.ghostty}/share/terminfo/x/xterm-ghostty";

  home.file.".claude/CLAUDE.md".text = ''
    # Global Claude Code Instructions

    ## System configuration

    This machine runs **NixOS** and is primarily managed with **Home Manager**. The main configuration file is:

    ```
    ~/.config/home-manager/home.nix
    ```

    When asked to install packages, change shell settings, configure tools, or adjust the environment, prefer editing `home.nix` and applying with `home-manager switch` (aliased as `hms`).

    For system-level concerns (services, kernel modules, hardware), the NixOS entrypoint is `/etc/nixos/configuration.nix` (applied with `sudo nixos-rebuild switch`), but this should rarely be needed.

    ## Project-specific dependencies

    Projects use a `default.nix` (or `shell.nix`) in the project root for per-project dependencies, managed via **direnv** (`use nix` in `.envrc`). When a project needs a tool or library, add it to that project's `default.nix` rather than to `home.nix`.
  '';

  home.sessionVariables = sessionVars;

  programs.git = {
    enable = true;
    settings.user = {
      name = "Guilherme Stabach Salustiano";
      email = "guissalustiano@gmail.com";
      signingkey = "D2CF0041485B408D";
    };
    settings.commit.gpgsign = true;
    settings.tag.gpgsign = true;
    settings.gpg.format = "openpgp";
  };

  programs.jujutsu = {
    enable = true;
    settings = {
      user = {
        name = "Guilherme Stabach Salustiano";
        email = "guissalustiano@gmail.com";
      };
      signing = {
        backend = "gpg";
        key = "D2CF0041485B408D";
        behavior = "own";
      };
    };
  };

  programs.helix = {
    enable = true;
    settings = {
      theme = "base16_transparent";
      editor.line-number = "relative";
    };
  };

  programs.starship = {
    enable = true;
    enableFishIntegration = true;
    settings = {
      jujutsu_status = {
        disabled = false;
      };
    };
  };

  programs.zoxide = {
    enable = true;
    enableFishIntegration = true;
  };

  programs.ghostty = lib.mkIf isGui {
    enable = true;
    settings = {
      command = "${pkgs.fish}/bin/fish";
      background-opacity = 0.9;
    };
  };

  programs.zellij = {
    enable = true;
    settings = {
      default_shell = "${pkgs.fish}/bin/fish";
      default_layout = "compact";
      show_startup_tips = false;
    };
  };

  programs.fish = {
    enable = true;
    shellAliases = {
      hms = "home-manager switch";
    };
  };

  programs.direnv = {
    enable = true;
    enableFishIntegration = true;
    nix-direnv.enable = true;
  };

  programs.claude-code = {
    enable = true;
    settings = {
      theme = "dark";
      enabledPlugins."github@claude-plugins-official" = false;
      enabledPlugins."mattpocock-skills@mattpocock" = true;
      enabledPlugins."slack@claude-plugins-official" = true;
      env.BASH_ENV = "${config.home.homeDirectory}/.config/bash_env.sh";
      permissions.allow = [ "Read" "WebSearch" "WebFetch" ];
      enabledMcpjsonServers = [ "github" "linear-server" ];
    };
    mcpServers = {
      github = {
        type = "http";
        url = "https://api.githubcopilot.com/mcp";
      };
      linear-server = {
        type = "http";
        url = "https://mcp.linear.app/mcp";
      };
    };
    marketplaces.mattpocock = pkgs.fetchFromGitHub {
      owner = "mattpocock";
      repo = "skills";
      rev = "2ab958093e83e0ec752e6c1c5932da465bf23e0c";
      sha256 = "1w18xwkni55qh2n6bxw755vr5hdkvjw8xnm42qzmhnh9xgm4c2vm";
    };
    marketplaces.claude-plugins-official = pkgs.fetchFromGitHub {
      owner = "anthropics";
      repo = "claude-plugins-official";
      rev = "10dee3b37671692f9c2437988b68faa5e1256b38";
      sha256 = "1lpdvwpg7lyijk27ljhmrxgc5mxn7hz8q3ypw2gpnslwppra02br";
    };
  };

  home.enableNixpkgsReleaseCheck = false;

  nix.package = pkgs.nix;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
