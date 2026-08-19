{ config, pkgs, lib, ... }:

let
  isGui = builtins.pathExists /run/opengl-driver;
  sessionVars = {
    EDITOR = "hx";

    HOME_MANAGER_BACKUP_OVERWRITE = "1";

    # context-mode's start.mjs re-execs itself under bun on Linux, to take the
    # bun:sqlite path in its bundle instead of the better-sqlite3 native module
    # it would otherwise `npm install` into its own (store, read-only) plugin
    # directory. It finds bun by probing $BUN_INSTALL/bin/bun and a few fixed
    # paths, never PATH. Side effect: this is also where `bun add -g` would
    # install, so global bun installs will fail — use home.packages instead.
    BUN_INSTALL = "${pkgs.bun}";
  };

  chromePwas = {
    google-meet = {
      name = "Google Meet";
      id = "kjgfgldnnfoeklkmfkjfagphfepbbdan";
      profile = "Profile 1";
      categories = [ "Network" "VideoConference" ];
    };
    whatsapp-web = {
      name = "WhatsApp Web";
      id = "hnpfjngllnobngcgfapefoaidbinmjnm";
      profile = "Default";
      categories = [ "Network" "InstantMessaging" ];
    };
  };
  iconSizes = [ "32x32" "48x48" "128x128" "256x256" "512x512" ];

  # The launcher and icon set one PWA needs, as paths relative to ~/.local/share.
  pwaFiles = slug: pwa:
    let
      entry = "chrome-${pwa.id}-${lib.replaceStrings [ " " ] [ "_" ] pwa.profile}";
      item = pkgs.makeDesktopItem {
        name = entry;
        desktopName = pwa.name;
        exec = ''google-chrome-stable "--profile-directory=${pwa.profile}" --app-id=${pwa.id}'';
        icon = slug;
        type = "Application";
        terminal = false;
        inherit (pwa) categories;
        # Ties the window to this launcher so it does not appear as a stray Chrome
        # window in the dock. Chrome uses crx_<app-id> for PWA windows.
        extraConfig.StartupWMClass = "crx_${pwa.id}";
      };
    in
    {
      "applications/${entry}.desktop".source = "${item}/share/applications/${entry}.desktop";
    }
    // builtins.listToAttrs (map
      (size: {
        name = "icons/hicolor/${size}/apps/${slug}.png";
        value.source = ./icons + "/${slug}/${size}.png";
      })
      iconSizes);

  jj-stack-pr = pkgs.writers.writeFishBin "jj-stack-pr"
    {
      makeWrapperArgs = [
        "--prefix"
        "PATH"
        ":"
        (lib.makeBinPath [ config.programs.jujutsu.package pkgs.gh ])
      ];
    }
    (builtins.readFile ./stack-pr.fish);

  kotlin-lsp = pkgs.callPackage ./kotlin-lsp.nix { };

  # context-mode keeps bulky tool output out of the context window by running
  # the work in a sandbox and returning only what the code derived. Upstream
  # ships its esbuild bundles committed, so the checkout is the plugin.
  #
  # Loaded through programs.claude-code.plugins, which links it under
  # ~/.claude/skills as a personal plugin. The alternative, registering it as
  # its own single-plugin marketplace, would make home-manager own
  # ~/.claude/plugins/known_marketplaces.json and drop whatever Claude Code has
  # added there itself on every switch.
  context-mode = pkgs.fetchFromGitHub {
    owner = "mksglu";
    repo = "context-mode";
    rev = "v1.0.169";
    hash = "sha256-1pV56ZB2aqod+C0kb5myuiWLAJ7+opiaurwZZ3BGKYk=";
  };

  # ponytail is a skill plus three SessionStart/UserPromptSubmit hooks that
  # inject its ruleset; the hooks are plain node scripts and keep their state in
  # ~/.claude, so the checkout needs nothing beyond the nodejs added above.
  ponytail = pkgs.fetchFromGitHub {
    owner = "DietrichGebert";
    repo = "ponytail";
    rev = "v4.9.0";
    hash = "sha256-8cYggVltBAlZ/Zj4pl1bOu7mQdZFXCmDGW4RSpvRA+w=";
  };
in
{
  nixpkgs.config.allowUnfree = true;

  home.username = "salust";
  home.homeDirectory = "/home/salust";

  home.stateVersion = "25.11";

  home.packages = [
    pkgs.eza
    pkgs.fd
    pkgs.htop
    pkgs.ripgrep
    pkgs.awscli2
    pkgs.starship-jj
    kotlin-lsp
    # Runtimes for the context-mode plugin. Its plugin.json and every hook
    # command invoke a bare `node`, so nodejs has to be on PATH; bun is what
    # node re-execs into (see BUN_INSTALL above) and its sandbox probes PATH
    # for runtimes, only offering TypeScript when bun is there.
    pkgs.nodejs
    pkgs.bun
    (pkgs.writeShellScriptBin "nix-init" ''
      echo "use nix" > .envrc
      direnv allow
    '')
  ] ++ lib.optionals isGui [
    pkgs.evince
    pkgs.gimp
    pkgs.google-chrome
    pkgs.obs-studio
    pkgs.obsidian
    pkgs.slack
    pkgs.spotify
    pkgs.telegram-desktop
    pkgs.vlc
  ];

  xdg.mimeApps = lib.mkIf isGui {
    enable = true;
    defaultApplications = {
      "application/pdf" = [ "org.gnome.Evince.desktop" ];
      "x-scheme-handler/claude-cli" = [ "claude-code-url-handler.desktop" ];
      "x-scheme-handler/slack" = [ "slack.desktop" ];
      "x-scheme-handler/tg" = [ "org.telegram.desktop.desktop" ];
      "x-scheme-handler/tonsite" = [ "org.telegram.desktop.desktop" ];
    };
  };

  # Chorme PWA
  xdg.dataFile = lib.mkIf isGui (
    lib.foldl' lib.mergeAttrs { } (lib.mapAttrsToList pwaFiles chromePwas)
  );

  programs.zed-editor = lib.mkIf isGui {
    enable = true;
    extensions = [ "kotlin" ];
    userSettings = {
      helix_mode = true;
      # The Kotlin extension registers two servers and runs both by default; keep
      # only JetBrains' kotlin-lsp.
      languages.Kotlin.language_servers = [ "kotlin-lsp" "!kotlin-language-server" ];

      # Use the kotlin-lsp from home.packages rather than the unpatched build the
      # extension downloads. --stdio is required: the server otherwise listens on
      # a socket (127.0.0.1:9999) and Zed never connects.
      lsp.kotlin-lsp.binary = {
        path = "${kotlin-lsp}/bin/kotlin-lsp";
        arguments = [ "--stdio" ];
      };

      # Zed builds the project environment by spawning $SHELL, which is bash here,
      # and direnv's hook is only installed for fish (see programs.direnv below).
      # "direct" skips the hook entirely: Zed runs `direnv export json` itself, so
      # language servers and tasks get the project's nix env.
      load_direnv = "direct";

      # The integrated terminal is a separate path — it execs a shell rather than
      # importing the project environment, so it needs a shell that has the hook.
      terminal.shell.program = "${pkgs.fish}/bin/fish";
    };
  };

  # kotlin-lsp is an IntelliJ server, and it runs the Gradle import with a JDK it
  # discovers by scanning the conventional locations (~/.jdks among them) rather
  # than from PATH. NixOS has no /usr/lib/jvm, so put one where it will look —
  # otherwise the import dies with "no compatible JDKs found on the machine".
  #
  # Still needed even though ./kotlin-lsp.nix hardcodes jdk21 into the launcher:
  # that only picks the JVM the server process itself runs on. The project JDK
  # handed to Gradle goes through IntelliJ's own discovery, which is why
  # intellij.platform.lang.impl.jar has ~/.jdks and /usr/lib/jvm baked in.
  home.file.".jdks/openjdk-21" = lib.mkIf isGui { source = pkgs.jdk21.home; };

  programs.vscode = lib.mkIf isGui {
    enable = true;
    package = pkgs.vscode;
    profiles.default.userSettings = {
      "claudeCode.preferredLocation" = "panel";
      "claudeCode.claudeProcessWrapper" = "${config.home.homeDirectory}/.nix-profile/bin/claude";
      "intellij.region" = "americas";
      "intellij.dataSharing" = "full";
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

      aliases.stack-pr = [ "util" "exec" "--" "${jj-stack-pr}/bin/jj-stack-pr" ];
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

  # Ghostty launches fish directly, but $SHELL is still bash, so anything that
  # honors $SHELL (Zed, VS Code, ssh) gets bash. Let home-manager own .bashrc so
  # the direnv hook below actually reaches it. initExtra reproduces the PATH line
  # from the hand-written .bashrc this replaces; it is deliberately not
  # home.sessionPath, which would also add ~/.local/bin to fish.
  programs.bash = {
    enable = true;
    initExtra = ''
      export PATH="$HOME/.local/bin:$PATH"
    '';
  };

  programs.direnv = {
    enable = true;
    enableBashIntegration = true;
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
      enabledPlugins."github@claude-plugins-official" = true;
      # This plugin is only an lspServers entry that runs bare `kotlin-lsp`
      # (upstream's README says to get it from brew); it resolves off PATH, which
      # the kotlin-lsp in home.packages above satisfies.
      enabledPlugins."kotlin-lsp@claude-plugins-official" = true;
      env.BASH_ENV = "${config.home.homeDirectory}/.config/bash_env.sh";
      permissions.allow = [ "Read" "WebSearch" "WebFetch" ];
    };
    plugins.context-mode = context-mode;
    plugins.ponytail = ponytail;
    # The playwright@claude-plugins-official plugin is only this MCP server, but
    # it runs `npx @playwright/mcp@latest` and then downloads browsers that are
    # not patched for NixOS. Point the nix build at the Chrome we already have.
    # The module ships this as the personal plugin ~/.claude/skills/claude-code-home-manager.
    mcpServers = lib.optionalAttrs isGui {
      playwright = {
        type = "stdio";
        command = "${pkgs.playwright-mcp}/bin/playwright-mcp";
        args = [ "--executable-path" "${pkgs.google-chrome}/bin/google-chrome-stable" ];
      };
    };
  };

  home.enableNixpkgsReleaseCheck = false;

  nix.package = pkgs.nix;
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  programs.home-manager.enable = true;
}
