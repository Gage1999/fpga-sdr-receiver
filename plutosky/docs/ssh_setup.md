# SSH Setup Guide: PlutoSky 7020

How to configure persistent SSH access on a fresh board. After following this
guide, you will be able to SSH into the board over USB with public-key auth,
and the board's host fingerprint will remain stable across cold boots.

---

## Prerequisites

- Board booted and reachable at `192.168.2.1` (USB gadget network)
- Initial password-based SSH access (tezuka default: `root` / `analog`, or
  check your firmware's default)
- Git Bash or any Unix shell on the host machine

---

## 1. Generate an SSH key pair on your host

Skip this step if you already have a key you want to use.

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_plutosky -C "plutosky"
```

This creates:
- `~/.ssh/id_plutosky`, private key (keep this safe, never share it)
- `~/.ssh/id_plutosky.pub`, public key (this goes on the board)

---

## 2. Add your SSH config entry

Add the following to `~/.ssh/config` (create the file if it doesn't exist):

```
Host pluto-usb
    HostName 192.168.2.1
    User root
    IdentityFile ~/.ssh/id_plutosky
```

---

## 3. Set up the jffs2 directory structure

SSH into the board with the default password (analog):

```bash
ssh root@192.168.2.1
```

On the board, create the persistent SSH directory:

```bash
mkdir -p /mnt/jffs2/ssh/host_keys
```

Exit back to your host:

```bash
exit
```

---

## 4. Copy your public key to the board

From your host machine:

```bash
scp -O ~/.ssh/id_plutosky.pub root@192.168.2.1:/mnt/jffs2/ssh/authorized_keys
```

SSH in and set permissions:

```bash
ssh root@192.168.2.1
chmod 600 /mnt/jffs2/ssh/authorized_keys
exit
```

> **Handing off to another user?** See [Adding keys for additional users](#adding-keys-for-additional-users) before continuing, append their key now rather than overwriting later.

---

## 5. Copy board scripts to the board

From your host, copy both scripts from the repo's `board/` directory:

```bash
scp -O board/install_key.sh root@192.168.2.1:/mnt/jffs2/ssh/install_key.sh
scp -O board/autorun.sh root@192.168.2.1:/mnt/jffs2/autorun.sh
```

SSH in and make them executable:

```bash
ssh root@192.168.2.1
chmod +x /mnt/jffs2/ssh/install_key.sh
chmod +x /mnt/jffs2/autorun.sh
exit
```

If you need to edit either script on the board directly:

```bash
ssh root@192.168.2.1
vi /mnt/jffs2/autorun.sh
```

---

## 6. Test key-based login

Run `install_key.sh` manually to apply the changes without rebooting:

```bash
ssh root@192.168.2.1 "sh /mnt/jffs2/ssh/install_key.sh"
```

Then reconnect using the config alias:

```bash
ssh pluto-usb
```

If this connects without a password prompt, key-based auth is working.

---

## 7. Cold-boot and verify host key stability

Power-cycle the board fully (pull the USB cable, wait a few seconds, reconnect).
After it comes back up, verify the host key matches what is stored in jffs2:

```bash
ssh pluto-usb "md5sum /etc/dropbear/dropbear_ed25519_host_key /mnt/jffs2/ssh/host_keys/dropbear_ed25519_host_key"
```

Both MD5s should match. If your SSH client connects without a host key warning,
the host fingerprint is stable.

---

## Adding keys for additional users

`authorized_keys` supports one public key per line, multiple users can have
access simultaneously. **Use `>>` (append) not `>` (overwrite)** when adding a
second key, otherwise you will lock out the first user.

The new user generates their key pair on their own machine and sends you their
`~/.ssh/id_plutosky.pub` (the public key only, never the private key).

SSH in and append their key:

```bash
ssh pluto-usb
echo "<their public key here>" >> /mnt/jffs2/ssh/authorized_keys
sh /mnt/jffs2/ssh/install_key.sh
exit
```

Verify both keys are present:

```bash
ssh pluto-usb "cat /mnt/jffs2/ssh/authorized_keys"
```

The new user only needs to:
1. Have their key pair generated (step 1)
2. Have their public key appended as above
3. Add the SSH config entry (step 2) pointing to their private key

### Removing a user's access

SSH in, delete their line from `authorized_keys`, and re-apply:

```bash
ssh pluto-usb
vi /mnt/jffs2/ssh/authorized_keys
sh /mnt/jffs2/ssh/install_key.sh
exit
```

---

## Troubleshooting

### `REMOTE HOST IDENTIFICATION HAS CHANGED`

If the jffs2 host key was deleted or `install_key.sh` failed to run, dropbear
will generate a new key and your SSH client will refuse to connect. Clear the
stale entry and reconnect:

```bash
ssh-keygen -R 192.168.2.1
ssh -o StrictHostKeyChecking=no root@192.168.2.1
```

Then re-run step 7 to verify and persist the new host key.

### Host key warning on Windows / Git Bash

On Windows, Git Bash's SSH may store `known_hosts` in an unexpected location
such as `C:/Users/<you>/AppData/Roaming/SPB_Data/.ssh/known_hosts`. If you
get a host key warning but `~/.ssh/known_hosts` looks correct, clear it from
the alternate path:

```bash
ssh-keygen -R 192.168.2.1 -f "/c/Users/<you>/AppData/Roaming/SPB_Data/.ssh/known_hosts"
```

### Connection refused / board not visible

The USB gadget network interface (`usb0`, `192.168.2.1`) takes ~25–30 seconds
to come up after power-on. Wait for the interface to appear on your host before
attempting to connect.
