# based on: <nixpkgs/nixos/modules/virtualisation/amazon-image.nix>
# - does not install configuration.nix
# - does not use unionfs on instance-store instances
# - does not add extra software
{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.ec2;
in
{
  imports = [
    <nixpkgs/nixos/modules/profiles/headless.nix>
    <nixpkgs/nixos/modules/virtualisation/ec2-data.nix>
  ];

  options = {
    ec2 = {
      hvm = mkOption {
        default = true;
        description = ''
          Whether the EC2 instance is a HVM instance.
        '';
      };
    };
  };

  config = {
    system.build.amazonImage =
      pkgs.vmTools.runInLinuxVM (
        pkgs.runCommand "amazon-image"
          { preVM =
              ''
                mkdir $out
                diskImage=$out/nixos.img
                ${pkgs.vmTools.qemu}/bin/qemu-img create -f raw $diskImage "10G"
                mv closure xchg/
              '';
            buildInputs = [ pkgs.utillinux pkgs.perl ];
            exportReferencesGraph =
              [ "closure" config.system.build.toplevel ];
          }
          ''
            ${if cfg.hvm then ''
              # Create a single / partition.
              ${pkgs.parted}/sbin/parted /dev/vda mklabel msdos
              ${pkgs.parted}/sbin/parted /dev/vda -- mkpart primary ext2 1M -1s
              . /sys/class/block/vda1/uevent
              mknod /dev/vda1 b $MAJOR $MINOR

              # Create an empty filesystem and mount it.
              ${pkgs.e2fsprogs}/sbin/mkfs.ext4 -L nixos /dev/vda1
              ${pkgs.e2fsprogs}/sbin/tune2fs -c 0 -i 0 /dev/vda1
              mkdir /mnt
              mount /dev/vda1 /mnt
            '' else ''
              # Create an empty filesystem and mount it.
              ${pkgs.e2fsprogs}/sbin/mkfs.ext4 -L nixos /dev/vda
              ${pkgs.e2fsprogs}/sbin/tune2fs -c 0 -i 0 /dev/vda
              mkdir /mnt
              mount /dev/vda /mnt
            ''}

            # The initrd expects these directories to exist.
            mkdir /mnt/dev /mnt/proc /mnt/sys

            mount -o bind /proc /mnt/proc
            mount -o bind /dev /mnt/dev
            mount -o bind /sys /mnt/sys

            # Copy all paths in the closure to the filesystem.
            storePaths=$(perl ${pkgs.pathsFromGraph} /tmp/xchg/closure)

            mkdir -p /mnt/nix/store
            echo "copying everything (will take a while)..."
            cp -prd $storePaths /mnt/nix/store/

            # Register the paths in the Nix database.
            printRegistration=1 perl ${pkgs.pathsFromGraph} /tmp/xchg/closure | \
                chroot /mnt ${config.nix.package}/bin/nix-store --load-db --option build-users-group ""

            # Create the system profile to allow nixos-rebuild to work.
            chroot /mnt ${config.nix.package}/bin/nix-env --option build-users-group "" \
                -p /nix/var/nix/profiles/system --set ${config.system.build.toplevel}

            # `nixos-rebuild' requires an /etc/NIXOS.
            mkdir -p /mnt/etc
            touch /mnt/etc/NIXOS

            # `switch-to-configuration' requires a /bin/sh
            mkdir -p /mnt/bin
            ln -s ${config.system.build.binsh}/bin/sh /mnt/bin/sh

            # Generate the GRUB menu.
            ln -s vda /dev/xvda
            chroot /mnt ${config.system.build.toplevel}/bin/switch-to-configuration boot

            umount /mnt/proc /mnt/dev /mnt/sys
            umount /mnt
          ''
      );

    fileSystems."/".device = "/dev/disk/by-label/nixos";

    boot.initrd.kernelModules = [ "xen-blkfront" "xen-fbfront" "xen-blkback" ];
    boot.kernelModules = [ "xen-netfront" ];
    boot.kernelParams = [ "console=ttyS0" "earlyprintk=ttyS0" ];

    # Generate a GRUB menu.  Amazon's pv-grub uses this to boot our kernel/initrd.
    boot.loader.grub.version = if cfg.hvm then 2 else 1;
    boot.loader.grub.device = if cfg.hvm then "/dev/xvda" else "nodev";
    boot.loader.grub.timeout = 0;
    boot.loader.grub.extraPerEntryConfig = "root (hd0${lib.optionalString cfg.hvm ",0"})";

    boot.initrd.postDeviceCommands =
      ''
        # Force udev to exit to prevent random "Device or resource busy
        # while trying to open /dev/xvda" errors from fsck.
        udevadm control --exit || true
        kill -9 -1
      '';

    # Mount all formatted ephemeral disks and activate all swap devices.
    # We cannot do this with the ‘fileSystems’ and ‘swapDevices’ options
    # because the set of devices is dependent on the instance type
    # (e.g. "m1.large" has one ephemeral filesystem and one swap device,
    # while "m1.large" has two ephemeral filesystems and no swap
    # devices).  Also, put /tmp and /var on /disk0, since it has a lot
    # more space than the root device.
    #
    # UPCAST: DO NOT "move" /nix to /disk0 and use unionfs on instance-store volumes.
    boot.initrd.postMountCommands =
      ''
        diskNr=0
        firstNonRootExt3Disk=
        for device in /dev/xvd[abcde]*; do
            if [ "$device" = /dev/xvda -o "$device" = /dev/xvda1 ]; then continue; fi
            fsType=$(blkid -o value -s TYPE "$device" || true)
            if [ "$fsType" = swap ]; then
                echo "activating swap device $device..."
                swapon "$device" || true
            elif [ "$fsType" = ext3 ]; then
                mp="/disk$diskNr"
                diskNr=$((diskNr + 1))
                echo "mounting $device on $mp..."
                if mountFS "$device" "$mp" "" ext3; then
                    if [ -z "$firstNonRootExt3Disk" ]; then firstNonRootExt3Disk="$mp"; fi
                fi
            else
                echo "skipping unknown device type $device"
            fi
        done

        if [ -n "$firstNonRootExt3Disk" ]; then
            mkdir -m 755 -p $targetRoot/$firstNonRootExt3Disk/root

            mkdir -m 1777 -p $targetRoot/$firstNonRootExt3Disk/root/tmp $targetRoot/tmp
            mount --bind $targetRoot/$firstNonRootExt3Disk/root/tmp $targetRoot/tmp

            if [ ! -e $targetRoot/.ebs ]; then
                mkdir -m 755 -p $targetRoot/$firstNonRootExt3Disk/root/var $targetRoot/var
                mount --bind $targetRoot/$firstNonRootExt3Disk/root/var $targetRoot/var
            fi
        fi
      '';

    boot.initrd.extraUtilsCommands =
      ''
        # We need swapon in the initrd.
        cp --remove-destination ${pkgs.utillinux}/sbin/swapon $out/bin
      '';

    # Don't put old configurations in the GRUB menu.  The user has no
    # way to select them anyway.
    boot.loader.grub.configurationLimit = 0;

    # Allow root logins only using the SSH key that the user specified
    # at instance creation time.
    services.openssh.enable = true;
    services.openssh.permitRootLogin = "without-password";

    # Force getting the hostname from EC2.
    networking.hostName = mkDefault "";
  };
}
