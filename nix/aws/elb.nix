{ config, name, lib, ... }:
with lib;
let
  common = import ./common.nix { inherit lib; };
  inherit (common) infra;
in
{
  options = {
    inherit (common) accessKeyId region;

    name = mkOption {
      example = "the-best-elb";
      default = name;
      type = types.str;
      description = "Unique name of the ELB.";
    };

    subnets = mkOption {
      type = types.listOf (infra "ec2-subnet");
      default = [];
      apply = map (x: if builtins.isString x then x else x._name);
    };

    instances = mkOption {
      type = types.listOf (infra "ec2-instance");
      default = [];
      apply = map (x: if builtins.isString x then x else x._name);
    };

    listeners = mkOption {
      type = types.listOf (types.submodule ({ lib, name, ... }: with lib; {
        options = {
          lbPort = mkOption { type = types.int; default = 80; };
          lbProtocol = mkOption { type = types.string; default = "http"; };
          instancePort = mkOption { type = types.int; default = 80; };
          instanceProtocol = mkOption { type = types.string; default = "http"; };
          sslCertificateId = mkOption { type = types.string; default = ""; };
          lbStickinessCookieExpiration = mkOption { type = types.int; default = -1; };
        };
      }));
      default = [
        { lbPort = 80; lbProtocol = "http"; instancePort = 80; instanceProtocol = "http"; }
      ];
    };

    securityGroups = mkOption {
      example = [ "my-group" "my-other-group" ];
      type = types.listOf (infra "ec2-sg");
      apply = map (x: if builtins.isString x then x else x._name);
      description = "Security groups for the ELB withing its VPC";
      default = [];
    };

    internal = mkOption {
      type = types.bool;
      default = false;
    };

    accessLog = mkOption {
      type = types.submodule ({ lib, name, ... }: with lib; {
        options = {
          enable = mkOption { type = types.bool; default = false; };
          emitInterval = mkOption { type = types.int; default = 60; };
          s3BucketName = mkOption { type = types.string; default = ""; };
          s3BucketPrefix = mkOption { type = types.string; default = ""; };
        };
      });
      default = {
        enable = false;
        emitInterval = 60;
      };
    };

    connectionDraining = mkOption {
      type = types.submodule ({ lib, name, ... }: with lib; {
        options = {
          enable = mkOption { type = types.bool; default = true; };
          timeout = mkOption { type = types.int; default = 300; };
        };
      });
      default = {
        enable = true;
        timeout = 300;
      };
    };

    crossZoneLoadBalancing = mkOption {
      type = types.bool;
      default = true;
    };

    healthCheck = mkOption {
      default = {
        timeout = 5;
        interval = 30;
        healthyThreshold = 2;
        unhealthyThreshold = 10;
        target = {
          protocol = "TCP";
          port = 80;
          path = "";
        };
      };
    };

    route53Aliases = mkOption {
      type = types.attrsOf (types.submodule ({ lib, name, ... }: with lib; {
        options = {
          zoneId = mkOption { type = types.string; example = "ZOZONEZONEZONE"; };
        };
      }));
      default = {};
    };
  };

  config._type = "elb";
}
