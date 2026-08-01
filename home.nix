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
    pkgs.starship-jj
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

    ## Version control: prefer jj over git

    I use **Jujutsu (`jj`)**. Prefer it to `git` for version-control work.

    Before running any VCS command, check whether the repo is jj-backed (`jj root`, or look for `.jj/`). If it is, use jj — including in **colocated** repos that have both `.jj/` and `.git/`, where jj is the source of truth and mutating git commands (`git add`, `git commit`, `git checkout`, `git rebase`, `git reset`, `git stash`) desynchronize jj's state. Read-only git (`git log`, `git show`, `git diff`) is fine anywhere.

    The `jj` skill has the mental model, the git-to-jj translation table, and the recipes — consult it rather than translating git habits command by command.

    Two boundaries:

    - In a repo that is **only** git, use git. Don't run `jj git init --colocate` to convert it without asking, since that changes the repo for anyone else working in it.
    - For **new** repos, prefer starting them with `jj git init --colocate`, which keeps git interop for tooling and remotes.

    ## Project-specific dependencies

    Projects use a `default.nix` (or `shell.nix`) in the project root for per-project dependencies, managed via **direnv** (`use nix` in `.envrc`). When a project needs a tool or library, add it to that project's `default.nix` rather than to `home.nix`.

    Exception: for a genuinely one-off need (a script I'll run once), use ad-hoc `nix-shell -p <pkg> --run '...'` rather than adding a permanent entry anywhere.
  '';

  home.sessionVariables = sessionVars;

  programs.gh = {
    enable = true;
    extensions = [ pkgs.gh-stack ];
    settings.aliases.co = "pr checkout";
  };

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

      # `jj stack-pr [REVSET] [gh-stack flags...]` — push one bookmark per change
      # in REVSET (default `trunk()..@`), then wire the branches into a GitHub
      # stack. `gh stack link` is the only gh-stack subcommand that keeps its
      # hands off local git state, so jj stays the source of truth.
      aliases.stack-pr = [
        "util"
        "exec"
        "--"
        "bash"
        "-c"
        ''
          set -euo pipefail

          range='trunk()..@'
          case "''${1-}" in
            "" | -*) ;;
            *)
              range=$1
              shift
              ;;
          esac

          # `jj git push` refuses undescribed commits, so drop them from the range
          # (this is usually just an empty `@`).
          pushable="($range) & description(regex:'.')"
          if [ "$(jj log --no-graph --no-pager -r "$pushable" -T '"x\n"' | wc -l)" -lt 2 ]; then
            echo "stack-pr: need at least 2 described changes in $range" >&2
            exit 1
          fi

          base=$(jj log --no-graph --no-pager -r 'trunk()' \
            -T 'local_bookmarks.map(|b| b.name()).join("")')
          jj git push -c "$pushable"

          # Bookmark names come from templates.git_push_bookmark, so they are
          # derived from change IDs and survive amends: PRs update in place.
          layers=($(jj log --no-graph --no-pager --reversed -r "($pushable) & bookmarks()" \
            -T 'local_bookmarks.map(|b| b.name()).join(" ") ++ " "'))

          echo "stacking onto $base (bottom to top): ''${layers[*]}"
          gh stack link "''${layers[@]}" --base "$base" "$@"
        ''
        "jj-stack-pr"
      ];
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
      # jj status via starship-jj. `shell` is the binary itself, so no shell is
      # spawned; outside a jj repo it exits non-zero and starship hides the module.
      custom.jj = {
        command = "prompt";
        shell = [ "${pkgs.starship-jj}/bin/starship-jj" "--ignore-working-copy" "starship" ];
        format = "$output";
        ignore_timeout = true;
        use_stdin = false;
        when = true;
      };

      # starship-jj covers VCS status; the git modules would only duplicate it
      # in colocated repos.
      git_branch.disabled = true;
      git_commit.disabled = true;
      git_metrics.disabled = true;
      git_state.disabled = true;
      git_status.disabled = true;
    };
  };

  # starship-jj's own config; `starship-jj starship config default` prints this.
  xdg.configFile."starship-jj/starship-jj.toml".source =
    (pkgs.formats.toml { }).generate "starship-jj.toml" {
      module_separator = " ";
      reset_color = false;

      bookmarks = {
        search_depth = 100;
        exclude = [ ];
      };

      module = [
        {
          type = "Symbol";
          symbol = "󱗆 ";
          color = "Blue";
        }
        {
          type = "Bookmarks";
          separator = " ";
          color = "Magenta";
          behind_symbol = "⇡";
          surround_with_quotes = true;
          ignore_empty_commits = "None";
        }
        {
          type = "Commit";
          previous_message_symbol = "⇣";
          max_length = 24;
          show_previous_if_empty = false;
          empty_text = "(no description set)";
          surround_with_quotes = true;
          non_unique.color = "Black";
        }
        {
          type = "State";
          separator = " ";
          conflict = { disabled = false; text = "(CONFLICT)"; color = "Red"; };
          divergent = { disabled = false; text = "(DIVERGENT)"; color = "Cyan"; };
          empty = { disabled = false; text = "(EMPTY)"; color = "Yellow"; };
          immutable = { disabled = false; text = "(IMMUTABLE)"; color = "Yellow"; };
          hidden = { disabled = false; text = "(HIDDEN)"; color = "Yellow"; };
        }
        {
          type = "Metrics";
          template = "[{changed} {added}{removed}]";
          hide_if_empty = false;
          color = "Magenta";
          changed_files = { prefix = ""; suffix = ""; color = "Cyan"; };
          added_lines = { prefix = "+"; suffix = ""; color = "Green"; };
          removed_lines = { prefix = "-"; suffix = ""; color = "Red"; };
        }
      ];
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
      enabledPlugins."mattpocock-skills@mattpocock" = true;
      enabledPlugins."slack@claude-plugins-official" = true;
      enabledPlugins."skill-creator@claude-plugins-official" = true;
      env.BASH_ENV = "${config.home.homeDirectory}/.config/bash_env.sh";
      permissions.allow = [ "Read" "WebSearch" "WebFetch" ];
    };
    marketplaces = {
      mattpocock = pkgs.fetchFromGitHub {
        owner = "mattpocock";
        repo = "skills";
        rev = "2ab958093e83e0ec752e6c1c5932da465bf23e0c";
        sha256 = "1w18xwkni55qh2n6bxw755vr5hdkvjw8xnm42qzmhnh9xgm4c2vm";
      };
    };
  };

  home.enableNixpkgsReleaseCheck = false;

  nix.package = pkgs.nix;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}
