Upcast is a tool that provisions cloud infrastructure based on a declarative spec (*infra spec*)
in [Nix](http://nixos.org/nix/) expression language.
Upcast also includes a [opinionated base NixOS configuration](https://github.com/zalora/upcast/tree/master/nix/nixos)
suitable for cloud deployments.
Upcast is inspired by NixOps.

[![Build Status](https://travis-ci.org/zalora/upcast.svg?branch=master)](https://travis-ci.org/zalora/upcast)

### Upcast tour

```console
% cabal install
```

Contents of `infra.nix`:
```nix
{ lib ? import <upcast/lib> }:
let
  ec2-args = {
    accessKeyId = "default";
    region = "eu-west-1";
    zone = "eu-west-1a";
    securityGroups = [ "sg-bbbbbbbb" ];
    subnet = "subnet-ffffffff";
    keyPair = "my-keypair";
  };
  instance = instanceType: ec2-args // { inherit instanceType; };
in
{
  infra = {
    ec2-instance = {
      node1 = instance "m3.large";
      node2 = instance "m3.large";
      ubuntu = instance "m3.large" // {
        # http://cloud-images.ubuntu.com/locator/ec2/
        ami = "ami-befc43c9";
      };
    };
  };

  # you need <nixpkgs> in your $NIX_PATH to build this
  # <upcast/nixos> is a drop-in replacement for <nixpkgs/nixos>
  some-image = (import <upcast/nixos> {
    configuration = { config, pkgs, lib, ... }: {
      config.services.nginx.enable = true;
    };
  }).system;
}
```

`upcast infra-tree` dumps the full json configuration of what's going to be provisioned,
note that upcast only evaluates the top level `infra` attribute.

`upcast infra` actually provisions all resources and outputs the `ssh_config(5)` for all compute
nodes in the spec.

```console
% upcast infra-tree infra.nix | jq -r .

% upcast infra infra.nix > ssh_config
```

`upcast build-remote` and `upcast install` are wrappers over Nix/NixOS toolchain
that hugely [boost productivity](#achieving-productivity).
Here they are used to build NixOS closures and install them on `node1`.

```console
% upcast build-remote -t hydra -A some-image infra.nix \
    | xargs -tn1 upcast install -c ssh_config -f hydra -t node1 
```

Same example without `build-remote`:

```console
% nix-build -I upcast=$(upcast nix-path) -A some-image -A some-image infra.nix
% upcast install -c ssh_config -t node1 $(readlink ./result)
```

For more examples see [nix-adhoc](https://github.com/proger/nix-adhoc) and upcast [tests](https://github.com/zalora/upcast/tree/master/test).

### Goals

- simplicity, extensibility;
- shared state stored as nix expressions next to machines expressions;
- first-class AWS support (including AWS features nixops doesn't have);
- pleasant user experience and network performance (see below);
- support for running day-to-day operations on infrastructure, services and machines.

### Notable features

- the infrastructure spec is evaluated separately from NixOS system closures
  (installation must also be handled separately and is outside of `upcast` cli tool);
- state is kept in a text file that you can commit into your VCS.
- Upcast includes opinionated default NixOS configuration for
  [EC2 instance-store instances](https://github.com/zalora/upcast/blob/master/nix/nixos/env-ec2.nix)
  (see also the [list of AMIs](https://github.com/zalora/upcast/blob/master/nix/aws/ec2-amis.nix))
  and [VirtualBox](https://github.com/zalora/upcast/blob/master/nix/nixos/env-virtualbox.nix).

### Infrastructure services

(this is what used to be called `resources` in NixOps)

- New: EC2-VPC support, ELB support;
- Additionally planned: AWS autoscaling, EBS snapshotting;
- Different in EC2: CreateKeyPair (autogenerated private keys by amazon) is not supported, ImportKeyPair is used instead;
- Not supported: sqs, s3, elastic ips, ssh tunnels, adhoc nixos deployments,
                 deployments to expressions that span multiple AWS regions;
- Most likely will not be supported: hetzner, auto-luks, auto-raid0, `/run/keys` support, static route53 support (like nixops);

### Motivation

![motivation](http://i.imgur.com/HY2Gtk5.png)


### Achieving productivity


> tl;dr: do all of these steps if you're using a Mac and/or like visiting Starbucks

#### Remote builds

Unlike [Nix distributed builds](http://nixos.org/nix/manual/#chap-distributed-builds)
packages are not copied back and forth between the instance and your local machine.

```bash
upcast build-remote -t hydra.com -A something default.nix
```

If you want to update your existing systems as part of your CI workflow, you can do something like this:

```bash
upcast infra examples/vpc-nix-instance.nix > ssh_config

awk '/^Host/{print $2}' ssh_config | \
    xargs -I% -P4 -n1 -t ssh -F ssh_config % nix-collect-garbage -d

awk '/^Host/{print $2}' ssh_config | \
    xargs -I% -P4 -n1 -t upcast install -t % $(upcast build-remote -A some-system blah.nix)
```

#### Nix-profile uploads

Read more about Nix profiles [here](http://nixos.org/nix/manual/#sec-profiles).

Install a system closure to any NixOS system (i.e. update `system` profile) and switch to it:

```bash
# assuming the closure was built earlier
upcast install -t ec2-55-99-44-111.eu-central-1.compute.amazonaws.com /nix/store/72q9sd9an61h0h1pa4ydz7qa1cdpf0mj-nixos-14.10pre-git
```

Install a [buildEnv](https://github.com/NixOS/nixpkgs/blob/d232390d5dc3dcf912e76ea160aea62f049918e1/pkgs/build-support/buildenv/default.nix) package into `per-user/my-scripts` profile:

```bash
upcast build-remote -t hydra -A my-env default.nix | xargs -n1t upcast install -f hydra -p /nix/var/nix/profiles/per-user/my-scripts -t target-instance
```

#### Making instances download packages from a different host over ssh (a closure cache)

If you still want to (or have to) build most of the packages locally,
this is useful if one of your cache systems is accessible over ssh
and has better latency to the instance than the machine you run Upcast on.  

The key to that host must be already available in your ssh-agent.
Inherently, you should also propagate ssh keys of your instances to
that ssh-agent in this case.

```bash
export UPCAST_SSH_CLOSURE_CACHE=nix-ssh@hydra.com
```

#### SSH shared connections

`ControlMaster` helps speed up subsequent ssh sessions by reusing a single TCP connection. See [ssh_config(5)](http://www.openbsd.org/cgi-bin/man.cgi/OpenBSD-current/man5/ssh_config.5?query=ssh_config).

```console
% cat ~/.ssh/config
Host *
    ControlPath ~/.ssh/master-%r@%h:%p
    ControlMaster auto
    ControlPersist yes
```

### Known issues

- state files are not garbage collected, have to be often cleaned up manually;
- altering infra state is not supported properly (you need to remove using aws cli, cleanup the state file and try again);
- word "aterm" is naming a completely different thing;

Note: the app is currently in HEAVY development (and is already being used to power production cloud instances)
so interfaces may break without notice.

### More stuff

The AWS client code now lives in its own library: [zalora/aws-ec2](https://github.com/zalora/aws-ec2).
