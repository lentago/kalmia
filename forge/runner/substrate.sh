#!/usr/bin/env bash
# substrate.sh — the kalmia-authored OS substrate for a claytonia (bullpen)
# runner image. Runs as root INSIDE a build container; idempotent.
#
# This is the image's CONTRACT: the one-time host setup that claytonia's gitops
# loop does NOT manage — packages, the `claude` service user, Claude Code, the
# gh CLI, secret PLACEHOLDERS, and first-boot de-templating. The runner
# software itself (bin/, systemd units, cron, runner.env) is claytonia's and is
# layered on top by its own gitops/install.sh — this script never copies it.
#
# Derived once from claytonia provision/01+03 (the substrate-bearing steps);
# kalmia owns it henceforth because it IS what the image guarantees. Anything
# gitops deploys, or that is secret / shared runtime state, is deliberately
# absent. See forge/runner/README.md § What the image guarantees.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Operator access key — a PUBLIC ssh key (safe to bake; no private material).
CLAUDE_SSH_PUBKEY="${CLAUDE_SSH_PUBKEY:-ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCbnPjDFmbYusUw13NsD5h+NMRA/l8JAjaSZF94ohUvMQvXTY5ozTnBl5fWtd9UHof9ftE4hLdih/sSdDxRJAtq9SSCSb4OuFsEy+CFJpM6/f6mtsCjrL3TE11f5M6hiGX7423gdW0FXBLgC6klTWK023lt21S9VU0um6XIPicdsMg8udOVKSYPquPSq6XhB7ngpPjN7XdELfzSJYAwlgTaoFjw1ZvdQfMRslCXdx/AhbKBSlQKBsf/LkLZJCZACvt1+Z1vZtJr7kq7WqANEzJqrTZWDTF5NnEPU6eHDVqCh8lZZkaBY6cTNIIugwW3UMSrbw3I40OD9/qGpleyLowmf8cxX1WHY/HbVAxpmxYbWO5f4N9l6lFe6tdVwaTGtlj3jEJFM/CPZP6ygp6m9OqgaXXwSG6vFuJKz4XQvtF3hBmRs+vlzgflkF+5h/qKh+e29g/bkj82zMA8cfIdwoT9n2DdP3LHIfSFo/l9l9AANPKHFtvZq6saHIx5Dp/Pd8M= cpitzi@penguin}"

echo ">>> [substrate] packages"
apt-get update -qq
# Runner deps (claytonia provision/01) + cron (02). gh is added from its own
# apt repo below. --no-install-recommends keeps an MTA (postfix, a cron
# recommend) out — a runner doesn't mail cron output, and postfix's chroot
# device nodes break unprivileged-container extraction of the captured template.
# openssh-client is listed explicitly so ssh-keygen is present for first-boot
# host-key regen even without recommends.
apt-get install -y -qq --no-install-recommends \
  curl ca-certificates git jq ripgrep inotify-tools sudo python3 less \
  openssh-server openssh-client tini cron >/dev/null
echo "PKGS_OK"

echo ">>> [substrate] claude service user + sudoers"
id claude >/dev/null 2>&1 || useradd -m -s /bin/bash claude
echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude
chmod 440 /etc/sudoers.d/claude

echo ">>> [substrate] operator ssh key (root + claude)"
for u in root claude; do
  [ "$u" = root ] && H=/root || H=/home/claude
  mkdir -p "$H/.ssh"; chmod 700 "$H/.ssh"
  touch "$H/.ssh/authorized_keys"
  grep -qF "$CLAUDE_SSH_PUBKEY" "$H/.ssh/authorized_keys" || echo "$CLAUDE_SSH_PUBKEY" >> "$H/.ssh/authorized_keys"
  chmod 600 "$H/.ssh/authorized_keys"
done
chown -R claude:claude /home/claude/.ssh
systemctl enable ssh >/dev/null 2>&1 || true
echo "SSH_OK"

echo ">>> [substrate] Claude Code (native installer, as claude)"
su - claude -c 'curl -fsSL https://claude.ai/install.sh | bash' 2>&1 | tail -4
su - claude -c 'grep -q ".local/bin" ~/.bashrc || echo "export PATH=\$HOME/.local/bin:\$PATH" >> ~/.bashrc'
su - claude -c 'export PATH=$HOME/.local/bin:$PATH; claude --version' && echo "CLAUDE_OK"

echo ">>> [substrate] gh CLI (apt repo)"
if ! command -v gh >/dev/null 2>&1; then
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq && apt-get install -y -qq gh >/dev/null
fi
gh --version | head -1

echo ">>> [substrate] runner dirs"
mkdir -p /opt/claude-runner/bin /opt/claude-runner/etc /etc/claude-runner
install -d -o claude -g claude /home/claude/work

echo ">>> [substrate] secret PLACEHOLDERS (real values injected at first boot, never baked)"
# Empty OAuth token — set later with claude-set-token.
if [ ! -f /etc/claude-runner/token.env ]; then
  echo 'CLAUDE_CODE_OAUTH_TOKEN=' > /etc/claude-runner/token.env
  chown root:claude /etc/claude-runner/token.env; chmod 640 /etc/claude-runner/token.env
fi
# Empty GitHub App config + key — filled in per fleet after App install.
if [ ! -f /etc/claude-runner/gh-app.env ]; then
  printf 'APP_ID=\nINSTALLATION_ID=\n' > /etc/claude-runner/gh-app.env
  chown root:claude /etc/claude-runner/gh-app.env; chmod 640 /etc/claude-runner/gh-app.env
fi
if [ ! -f /etc/claude-runner/gh-app.pem ]; then
  touch /etc/claude-runner/gh-app.pem
  chown root:claude /etc/claude-runner/gh-app.pem; chmod 640 /etc/claude-runner/gh-app.pem
fi

echo ">>> [substrate] git identity + App credential helper (claude user)"
su - claude -c '
  git config --global user.name  "claude-runner[bot]"
  git config --global user.email "claude-runner[bot]@users.noreply.github.com"
  git config --global credential.https://github.com.helper "/usr/local/bin/gh-credential-helper"
  git config --global init.defaultBranch main
'

echo ">>> [substrate] first-boot de-templating unit (unique host identity per clone)"
# A captured template must not ship shared ssh host keys or a shared machine-id.
# build.sh strips them at capture; this unit regenerates ssh host keys on the
# first boot of every clone, before sshd starts. (systemd already regenerates an
# empty /etc/machine-id on boot, so that needs no unit.)
cat > /usr/local/sbin/forge-firstboot <<'FB'
#!/usr/bin/env bash
# Regenerate ssh host keys if the template was captured without them.
set -eu
ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1 || ssh-keygen -A
FB
chmod 755 /usr/local/sbin/forge-firstboot
cat > /etc/systemd/system/forge-firstboot.service <<'UNIT'
[Unit]
Description=Forge first-boot de-templating (regenerate ssh host keys)
Before=ssh.service
ConditionPathExistsGlob=!/etc/ssh/ssh_host_*_key
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/forge-firstboot
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
UNIT
systemctl enable forge-firstboot.service >/dev/null 2>&1 || true
systemctl enable cron >/dev/null 2>&1 || true

echo "SUBSTRATE_DONE"
