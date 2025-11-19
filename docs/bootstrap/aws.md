AWS Bootstrap
-------------
> Creating a prod VM on AWS.

We're going to build an EC2 VM to host our stack to run the
prod show. We'll start from scratch and follow pretty much the same
procedure as that for the [Dev VM][devm]. So we'll keep the commentary
to the bare minimum, read the [Dev VM][devm] page if you need more
details.


### Creating an EC2 instance

We tested our AWS setup with both Graviton (ARM64) and Xeon (x86_64)
instance types. Specifically, we ran WP Box on the instance types
below, but any other ARM64 or x86_64 instance type should do.
- ARM64: `m6g.xlarge`, `m6g.2xlarge`, `c6g.xlarge`, `c6g.2xlarge`,
  `t4g.2xlarge`, `t4g.xlarge`, `t4g.medium`.
- x86_64: `t3.medium`, `t3.2xlarge`.

So start an on-demand EC2 VM, either ARM64 or x86_64, with these
settings:
- AMI: Official NixOS `25.05`.
- One EBS of 200GB to host the whole OS + data.
- One EBS of 10GB to host backups.
- Static IP: e.g. `99.80.119.231`.
- Inbound ports: `22`, `80`, `443`.


### Choosing a Box config

Pick the WP Box config for your EC2 VM's architecture:

- [nodes/aarch64-linux][aarch64-linux] for ARM64
- [nodes/x86_64-linux][x86_64-linux] for x86_64

Then insert your SSH pub key in the `nodes/<node>/configuration.nix` file here:

```nixos
# Admin user
  users.users.admin = {
    isNormalUser = true;
    extraGroups = [ "wheel" "systemd-journal" ];
    hashedPassword = "!";  # Set with passwd after deployment
    openssh.authorizedKeys.keys = [
      "KEY-HERE"
    ];
  };
```


The commands in the rest of this guide refer to a scenario with
- EC2 Graviton VM
- VM's IP address of `99.80.119.231`

Surely your IP address will be different, replace the above IP with
yours. Likewise, if you have an x86_64 VM, you'll have to use the
`x86_64-linux` config, so tweak the commands below accordingly.


### Preparing the backup disk

Partition the backup disk using a GPT scheme with just one partition
spanning the entire drive. Call that partition `backup` as this is the GPT partition label our NixOS config looks for to automatically
mount the backup disk.

```bash

$ ssh -i nodes/ec2-aarch64/vault/ssh/id_rsa root@99.80.119.231

$ sudo -i

$ lsblk -f
# ^ should list nvme0n1 and nvme1n1, pick the empty disk!

$ parted -a optimal /dev/nvme1n1 -- mklabel gpt

$ parted -a optimal /dev/nvme1n1 -- mkpart primary ext4 0% 100%
$ parted -a optimal /dev/nvme1n1 -- name 1 backup
```

Now format the partition with ext4.

```bash
$ mkfs.ext4 -L backup /dev/nvme1n1p1
```


### Installing The Box

First off, deploy the data bootstrap NixOS config.

```bash

$ NIX_SSHOPTS='-i path/to/your/pvt-key.pem' \
  nixos-rebuild switch --fast --flake .#nodes \
      --target-host root@IP --build-host root@IP
```


[devm]: ./dev-vm.md
[aarch64-linux]: ../../nodes/aarch64-linux/configuration.nix
[x86_64-linux]: ../../nodes/x86_64-linux/configuration.nix
