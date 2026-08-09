# jj stack-pr — publish a jj stack as a chain of GitHub stacked PRs.
#
# Takes the bookmarks in a revset (default `trunk()..@`), checks they form a
# single linear chain that is already on the remote, then hands them to
# `gh stack link` bottom-to-top. `gh stack link` is the only gh-stack subcommand
# that needs no local git branch, which is what makes it usable from jj.
#
# This command never pushes. `jj git push` stays the only thing that writes to
# the remote; if a layer is not pushed yet, this aborts and tells you.
#
# The shebang is supplied by writers.writeFishBin in home.nix, which also puts
# the matching jj and gh on PATH.

function fail
    printf 'jj stack-pr: %s\n' $argv >&2
    exit 1
end

function usage
    echo 'jj stack-pr [-r REVSET] [--base BRANCH] [--remote NAME] [--open] [--dry-run] [-y]'
    echo
    echo 'Link the bookmarks in REVSET (default trunk()..@) into a GitHub stack,'
    echo 'bottom to top. Does not push; run `jj git push` first.'
    echo
    echo '  -r, --revisions REVSET  revset holding the stack (default trunk()..@)'
    echo '      --base BRANCH       base of the bottom PR (default: trunk()'"'"'s remote bookmark)'
    echo '      --remote NAME       remote to check against and link on (default: git.push)'
    echo '      --open              mark new and existing PRs ready for review'
    echo '      --dry-run           print the plan and stop'
    echo '  -y, --yes               skip the confirmation prompt'
end

argparse --name='jj stack-pr' h/help r/revisions= base= remote= open dry-run y/yes -- $argv
or exit 2

if set -q _flag_help
    usage
    exit 0
end

if test (count $argv) -gt 0
    # With no unknown-flag handling, a stray word is almost always a typo'd flag
    # or a revset that forgot its -r.
    fail "unexpected argument: $argv[1]" "did you mean -r '$argv[1]'?"
end

set -l revset 'trunk()..@'
set -q _flag_revisions
and set revset $_flag_revisions

# jj's own default push remote is origin, and gh takes the same git remote name.
set -l remote origin
if set -q _flag_remote
    set remote $_flag_remote
else
    set -l configured (jj config get git.push 2>/dev/null)
    test -n "$configured"
    and set remote $configured
end

# --- the stack must be a single linear chain ------------------------------------
#
# A merge inside the range, or more than one head, means "bottom to top" has no
# single answer — and gh stack link would silently get an arbitrary order.

set -l merges (jj log --no-graph --no-pager -r "($revset) & merges()" \
    -T 'change_id.shortest(8) ++ "  " ++ description.first_line() ++ "\n"')
or fail "could not evaluate revset: $revset"

if test (count $merges) -gt 0
    printf 'jj stack-pr: %s is not linear, it contains merges:\n' $revset >&2
    printf '  %s\n' $merges >&2
    exit 1
end

set -l heads (jj log --no-graph --no-pager -r "heads($revset)" \
    -T 'change_id.shortest(8) ++ "  " ++ description.first_line() ++ "\n"')
or fail "could not evaluate revset: $revset"

if test (count $heads) -ne 1
    printf 'jj stack-pr: %s has %d heads, expected 1:\n' $revset (count $heads) >&2
    printf '  %s\n' $heads >&2
    exit 1
end

# --- resolve the layers, bottom to top -----------------------------------------

set -l rows (jj log --no-graph --no-pager --reversed -r "($revset) & bookmarks()" \
    -T 'local_bookmarks.map(|b| b.name()).join(",") ++ "\t" ++ change_id.shortest(8) ++ "\t" ++ description.first_line() ++ "\n"')
or fail "could not evaluate revset: $revset"

set -l names
set -l descs
set -l ambiguous

for row in $rows
    set -l fields (string split \t -- $row)
    set -l bookmarks (string split , -- $fields[1])

    if test (count $bookmarks) -gt 1
        # Two bookmarks on one commit means two candidate PR heads for one diff.
        # Guessing would create a duplicate, empty PR.
        set -a ambiguous "$fields[2]  $fields[1]"
    end

    set -a names $bookmarks[1]
    set -a descs $fields[3]
end

if test (count $ambiguous) -gt 0
    echo 'jj stack-pr: these changes carry more than one bookmark, so the PR head is ambiguous:' >&2
    printf '  %s\n' $ambiguous >&2
    echo >&2
    echo 'Remove one with: jj bookmark forget <name>' >&2
    exit 1
end

if test (count $names) -lt 2
    fail "found "(count $names)" bookmarked change(s) in $revset; a stack needs at least 2"
end

# --- every layer must already be on the remote ---------------------------------
#
# Only the push remote matters. Colocated repos also carry an `@git` copy of
# every bookmark, which says nothing about GitHub.

set -l tracked_names
set -l tracked_state
set -l tracked_ahead

for row in (jj bookmark list --all-remotes --no-pager \
        -T 'if(remote, name ++ "\t" ++ remote ++ "\t" ++ if(tracked, "tracked", "untracked") ++ "\t" ++ tracking_ahead_count.lower() ++ "\n", "")')
    set -l fields (string split \t -- $row)
    test "$fields[2]" = "$remote"
    or continue
    set -a tracked_names $fields[1]
    set -a tracked_state $fields[3]
    set -a tracked_ahead $fields[4]
end

set -l unpushed
set -l stale

for name in $names
    set -l i (contains -i -- $name $tracked_names)

    if test -z "$i"; or test "$tracked_state[$i]" != tracked
        set -a unpushed $name
        continue
    end

    # Behind-only is fine: the remote just has commits we have not fetched.
    # Ahead means GitHub would show a PR that is missing our newest commits.
    if test "$tracked_ahead[$i]" -gt 0
        set -a stale "$name (ahead by $tracked_ahead[$i])"
    end
end

if test (count $unpushed) -gt 0 -o (count $stale) -gt 0
    printf 'jj stack-pr: these layers are not on %s as GitHub would see them:\n' $remote >&2
    for name in $unpushed
        printf '  %s — never pushed\n' $name >&2
    end
    for name in $stale
        printf '  %s\n' $name >&2
    end
    echo >&2
    printf 'Push them first: jj git push --remote %s --bookmark <name>\n' $remote >&2
    echo 'A bookmark that is both ahead and behind has diverged; fetch and rebase it first.' >&2
    exit 1
end

# --- base of the bottom PR -----------------------------------------------------

set -l base

if set -q _flag_base
    set base $_flag_base
else
    set -l suffix '@'(string escape --style=regex -- $remote)'$'
    set -l candidates

    for entry in (jj log --no-graph --no-pager -r 'trunk()' \
            -T 'remote_bookmarks.map(|b| b.name() ++ "@" ++ b.remote() ++ "\n").join("")')
        set -l name (string replace -r -- $suffix '' $entry)
        test "$name" != "$entry"
        or continue
        contains -- $name $candidates
        or set -a candidates $name
    end

    switch (count $candidates)
        case 0
            fail "trunk() has no bookmark on $remote; pass --base BRANCH"
        case 1
            set base $candidates[1]
        case '*'
            fail "trunk() has several bookmarks on $remote ($candidates); pass --base BRANCH"
    end
end

# --- plan ----------------------------------------------------------------------

set -l pr_heads
set -l pr_numbers

set -l pr_rows (gh pr list --state open --limit 200 --json number,headRefName \
    --jq '.[] | "\(.headRefName)\t\(.number)"')
if test $status -ne 0
    echo 'jj stack-pr: could not list open PRs; every layer will show as new' >&2
end

for row in $pr_rows
    set -l fields (string split \t -- $row)
    set -a pr_heads $fields[1]
    set -a pr_numbers $fields[2]
end

printf 'stack of %d PRs onto %s (bottom to top):\n' (count $names) $base

set -l i 0
for name in $names
    set i (math $i + 1)
    set -l j (contains -i -- $name $pr_heads)
    if test -n "$j"
        printf '  %2d. %-30s #%-6s %s\n' $i $name $pr_numbers[$j] $descs[$i]
    else
        printf '  %2d. %-30s %-7s %s\n' $i $name new $descs[$i]
    end
end

if set -q _flag_dry_run
    exit 0
end

if not set -q _flag_yes
    read --local --prompt-str 'link them into a stack? [y/N] ' reply
    or exit 130
    string match -qir '^y(es)?$' -- $reply
    or fail 'aborted'
end

# --- link ----------------------------------------------------------------------

set -l cmd gh stack link $names --base $base --remote $remote
set -q _flag_open
and set -a cmd --open

$cmd
