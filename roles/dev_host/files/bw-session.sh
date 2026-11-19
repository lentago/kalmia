# shellcheck shell=bash
# Shared by the bw wrapper, bw-unlock and bw-lock (kalmia#343, installed by the
# dev_host role). Resolves where the per-task Bitwarden session key lives.
#
# The key is on tmpfs, so a reboot clears it: $XDG_RUNTIME_DIR, else
# /run/user/<uid> (tmux-hosted sessions can lack the variable, the directory is
# there for any logged-in user). Never falls back to a disk path: with no tmpfs
# directory there is simply no key file and bw behaves as it does today.

bw_session_file() {
    local dir=${XDG_RUNTIME_DIR:-}
    [[ -n $dir && -d $dir && -O $dir ]] || dir=/run/user/$(id -u)
    [[ -d $dir && -O $dir ]] || return 1
    printf '%s/bw-session\n' "$dir"
}
